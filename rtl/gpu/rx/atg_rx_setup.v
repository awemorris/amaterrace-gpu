/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_setup: RX setup: perspective divide and viewport (VIEWPORT 0-5),
 * the integer steps through atg_rx_edge (snap, edges, bounding box ∩
 * scissor ∩ RT_SIZE ∩ the viewport's rectangle, facing and culling), the
 * plane equations of depth, 1/w and the perspective barycentrics, depth
 * bias, and the two sub-triangles of a line or a point.
 *
 * A micro-programmed fp32 datapath (include/atg_rx_setup_uc.vh: one fadd,
 * one fmul, one fdiv, 128 fp registers in distributed RAM; 120-127 read
 * DEPTH_BIAS_CONST, _SLOPE, _CLAMP, 0.5, 0 and the bias's r of D16 or D24)
 * does the floating-point steps; its INT micro-op runs atg_rx_edge, OUT
 * sends the first sub-triangle of a line or a point and continues.  One
 * primitive at a time; the last-use flags and sp_last go with the last
 * output only.  See spec/gpu/rx/atg_rx_setup.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_setup (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rx_clip */
	input wire cl_valid,
	output wire cl_ready,
	input wire [701:0] cl_tri,
	input wire cl_last,
	/* To atg_rx_scan */
	output reg sp_valid,
	input wire sp_ready,
	output wire [767:0] sp_tri,
	output wire sp_last,
	output wire busy
);
	`include "atg_rx_setup_uc.vh"
	`include "ghci_regs.vh"

	localparam [31:0] ONE = 32'h3F800000;

	/* STATE: VIEWPORT 0x050-0x055, SCISSOR 0x056-0x057, CULL 0x058,
	 * RAST_MODE 0x05A, DEPTH_BIAS_* 0x060-0x062, RT_SIZE 0x073. */
	reg [31:0] vp [0:5];
	reg [31:0] smin, smax, rts, b_const, b_slope, b_clamp;
	reg [2:0] cull;
	reg [5:0] rm;	/* RAST_MODE[5:0] */

	always @(posedge clk)
		if (!rst_n) begin
			smin <= 32'd0;
			smax <= 32'd0;
			rts <= 32'd0;
			cull <= 3'd0;
			rm <= 6'd0;
			b_const <= 32'd0;
			b_slope <= 32'd0;
			b_clamp <= 32'd0;
		end else if (st_we) begin
			if (st_idx >= GHCI_S_VIEWPORT && st_idx <= GHCI_S_VIEWPORT + 9'd5)
				vp[st_idx[2:0]] <= st_wdata;
			if (st_idx == GHCI_S_SCISSOR_MIN)
				smin <= st_wdata;
			if (st_idx == GHCI_S_SCISSOR_MAX)
				smax <= st_wdata;
			if (st_idx == GHCI_S_CULL)
				cull <= st_wdata[2:0];
			if (st_idx == GHCI_S_RAST_MODE)
				rm <= st_wdata[5:0];
			if (st_idx == GHCI_S_DEPTH_BIAS_CONST)
				b_const <= st_wdata;
			if (st_idx == GHCI_S_DEPTH_BIAS_SLOPE)
				b_slope <= st_wdata;
			if (st_idx == GHCI_S_DEPTH_BIAS_CLAMP)
				b_clamp <= st_wdata;
			if (st_idx == GHCI_S_RT_SIZE)
				rts <= st_wdata;
		end

	localparam [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_DEC = 3'd2, S_RD = 3'd3, S_GO = 3'd4,
		S_WAIT = 3'd5, S_INT = 3'd6, S_OUT = 3'd7;
	reg [2:0] st;
	reg [5:0] cnt;	/* S_LOAD word */
	reg [7:0] pc;
	reg [25:0] uc;
	wire [3:0] u_op = uc[25:22];
	wire [7:0] u_t = uc[21:14];	/* JMP and BRA target */
	wire [6:0] u_d = uc[20:14];
	wire [6:0] u_a = uc[13:7];
	wire [6:0] u_b = uc[6:0];
	reg raw;
	reg [1:0] kind;
	reg [26:0] keep;	/* PT entries [23:0], last-use flags [26:24] */
	reg lastq;	/* the primitive is the draw's last */
	reg sub;	/* the second sub-triangle (lines and points) */
	reg more;	/* an output with more to follow (OUT) */

	/* The fp registers (spec §4 lists the numbers); 120-127 read only. */
	reg [31:0] R [0:127];
	reg [31:0] pl [0:11];	/* the planes z, 1/w, b0/w, b1/w (registers 64-75) */
	reg [31:0] opa, opb;
	reg r_we;
	reg [6:0] r_wa;
	reg [31:0] r_wd;
	integer k;

	/* the bias's r for D16 (2^-16) and D24 (2^-24) */
`ifdef MUT_BIAS_R
	localparam [31:0] R24 = 32'h34000000;	/* the TB's mutation check: 2^-23 */
`else
	localparam [31:0] R24 = 32'h33800000;
`endif
	wire [31:0] rfmt = rm[5:4] == 2'd1 ? 32'h37800000 : rm[5:4] == 2'd2 ? R24 : 32'd0;
	function [31:0] rsrc;
		input [6:0] a;
		input [31:0] ra;
		case (a)
		7'd120: rsrc = b_const;
		7'd121: rsrc = b_slope;
		7'd122: rsrc = b_clamp;
		7'd123: rsrc = 32'h3F000000;	/* 0.5 */
		7'd124: rsrc = 32'd0;
		7'd125: rsrc = rfmt;
		7'd126, 7'd127: rsrc = 32'd0;
		default: rsrc = ra;
		endcase
	endfunction

	/* atg_rx_edge (the integer steps), sharing the register file. */
	reg e_start;
	wire [6:0] e_ra, e_wa;
	reg [31:0] e_rd;
	wire e_we, e_done, e_front, e_empty;
	wire [31:0] e_wd;
	wire [287:0] e_edges;
	wire [63:0] e_bbox;
	atg_rx_edge edge_u (.clk(clk), .rst_n(rst_n), .start(e_start),
		.mode({raw, sub, kind}), .smin(smin), .smax(smax), .rts(rts), .cull(cull),
		.vprect(rm[3]), .r_ra(e_ra), .r_rd(e_rd), .r_we(e_we), .r_wa(e_wa), .r_wd(e_wd),
		.done(e_done), .edges(e_edges), .bbox(e_bbox), .front(e_front), .empty(e_empty));

	always @(posedge clk) begin
		e_rd <= R[e_ra];
		if (r_we)
			R[r_wa] <= r_wd;
		else if (e_we)
			R[e_wa] <= e_wd;
	end

	/* The fp units. */
	reg fa_v, fm_v, fd_v;
	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(opa), .i_b(opb),
		.i_sub(u_op == 4'd2), .o_valid(fa_o), .o_r(fa_r));
	atg_rx_fmul fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(opa), .i_b(opb),
		.o_valid(fm_o), .o_r(fm_r));
	atg_rx_fdiv fdiv (.clk(clk), .rst_n(rst_n), .i_start(fd_v), .i_a(opa), .i_b(opb),
		.busy(fd_busy), .o_done(fd_o), .o_r(fd_r));

	/* a <= b for fp32, -0 = +0; 0 when either is NaN. */
	function fle;
		input [31:0] a, b;
		reg [32:0] ka, kb;
		begin
			/* the signed keys ka <= kb, from the signs and the magnitudes */
			ka = {2'd0, a[30:0]};
			kb = {2'd0, b[30:0]};
			fle = !(a[30:23] == 8'hFF && a[22:0] != 23'd0) &&
				!(b[30:23] == 8'hFF && b[22:0] != 23'd0) &&
				(a[31] ? (b[31] ? ka >= kb : 1'b1) : (b[31] ? ka == 0 && kb == 0 : ka <= kb));
		end
	endfunction

	/* e(a) - 23 (ULP); cnt + 1, cnt[2:0] - 5 (LOAD's VIEWPORT word); pc + 1 */
	wire [7:0] ea23, pc1;
	wire [5:0] cnt1;
	wire [2:0] vpi;
	wire [3:0] su_carry_unused;
	am_sub #(.W(8)) u_ea23 (.a(opa[30:23]), .b(8'd23), .bi(1'b0), .d(ea23), .bo(su_carry_unused[0]));
	am_add #(.W(6)) u_cnt1 (.a(cnt), .b(6'd0), .ci(1'b1), .s(cnt1), .co(su_carry_unused[1]));
	am_sub #(.W(3)) u_vpi (.a(cnt[2:0]), .b(3'd5), .bi(1'b0), .d(vpi), .bo(su_carry_unused[2]));
	am_add #(.W(8)) u_pc1 (.a(pc), .b(8'd0), .ci(1'b1), .s(pc1), .co(su_carry_unused[3]));

	/* The one-cycle micro-ops: MOV, ABS, MAX (of magnitudes), ULP, BCL. */
	reg [31:0] q1;
	always @(*)
		case (u_op)
		4'd9: q1 = {1'b0, opa[30:0]};
		4'd10: q1 = opb[30:0] > opa[30:0] ? opb : opa;
		/* 2^(e(a) - 23); 0 when below the normal range */
		4'd11: q1 = opa[30:23] > 8'd23 ? {1'b0, ea23, 23'd0} : 32'd0;
		/* the bias clamp: b > 0 min(a, b), b < 0 max(a, b), b = 0 a */
		4'd12: q1 = opb[30:0] == 31'd0 ? opa : !opb[31] ? (fle(opa, opb) ? opa : opb) :
			(fle(opb, opa) ? opa : opb);
		default: q1 = opa;
		endcase

	/* BRA's conditions. */
	reg cond;
	always @(*)
		case (u_a[2:0])
		3'd0: cond = kind == 2'd0;
		3'd1: cond = kind == 2'd1;
		3'd2: cond = !rm[0] || rm[5:4] == 2'd0 || kind != 2'd2;
		3'd3: cond = rm[5:4] != 2'd3;
		default: cond = !rm[3];
		endcase

	assign cl_ready = st == S_LOAD && cnt == 6'd27;
	assign busy = st != S_IDLE;
	assign sp_last = lastq && !more;

	always @(posedge clk) begin
		uc <= atg_rx_uc(pc);
		r_we <= 1'b0;
		fa_v <= 1'b0;
		fm_v <= 1'b0;
		fd_v <= 1'b0;
		e_start <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			sp_valid <= 1'b0;
			more <= 1'b0;
		end else case (st)
		S_IDLE:
			if (cl_valid) begin
				st <= S_LOAD;
				cnt <= 6'd0;
				raw <= cl_tri[699];
				kind <= cl_tri[699] || cl_tri[701:700] == 2'd3 ? 2'd2 : cl_tri[701:700];
				keep <= cl_tri[698:672];
				lastq <= cl_last;
				sub <= 1'b0;
				more <= 1'b0;
				for (k = 0; k < 12; k = k + 1)
					pl[k] <= 32'd0;
			end
		S_LOAD: begin
			/* fp registers 0-20 from cl_tri, 21-26 VIEWPORT, 27 1.0 */
			r_we <= 1'b1;
			r_wa <= {1'b0, cnt};
			r_wd <= cnt < 6'd21 ? cl_tri[cnt * 32 +: 32] : cnt < 6'd27 ? vp[vpi] : ONE;
			cnt <= cnt1;
			if (cnt == 6'd27) begin
				pc <= raw ? 8'd0 : ATG_RX_UC_PERSP;
				st <= S_DEC;
			end
		end
		S_DEC:
			st <= S_RD;	/* uc follows pc */
		S_RD: begin
			opa <= rsrc(u_a, R[u_a]);
			opb <= rsrc(u_b, R[u_b]);
			case (u_op)
			4'd0: st <= S_OUT;
			4'd8: if (raw) st <= S_OUT; else begin pc <= pc1; st <= S_DEC; end
			4'd7: begin pc <= u_t; st <= S_DEC; end
			4'd13: begin pc <= cond ? u_t : pc1; st <= S_DEC; end
			4'd14: begin more <= 1'b1; st <= S_OUT; end
			4'd6: begin e_start <= 1'b1; st <= S_INT; end
			default: st <= S_GO;
			endcase
		end
		S_GO:
			if (u_op == 4'd5 || u_op >= 4'd9) begin
				r_we <= 1'b1;
				r_wa <= u_d;
				r_wd <= q1;
				if (u_d >= 7'd64 && u_d < 7'd76)
					pl[u_d[3:0]] <= q1;
				pc <= pc1;
				st <= S_DEC;
			end else begin
				fa_v <= u_op == 4'd1 || u_op == 4'd2;
				fm_v <= u_op == 4'd3;
				fd_v <= u_op == 4'd4;
				st <= S_WAIT;
			end
		S_WAIT:
			if (fa_o || fm_o || fd_o) begin
				r_we <= 1'b1;
				r_wa <= u_d;
				r_wd <= fa_o ? fa_r : fm_o ? fm_r : fd_r;
				if (u_d >= 7'd64 && u_d < 7'd76)
					pl[u_d[3:0]] <= fa_o ? fa_r : fm_o ? fm_r : fd_r;
				pc <= pc1;
				st <= S_DEC;
			end
		S_INT:
			/* an empty result ends the primitive: one output with the flags */
			if (e_done) begin
				if (e_empty)
					st <= S_OUT;
				else begin
					pc <= pc1;
					st <= S_DEC;
				end
			end
		default: begin	/* S_OUT */
			sp_valid <= 1'b1;
			if (sp_valid && sp_ready) begin
				sp_valid <= 1'b0;
				if (more) begin
					more <= 1'b0;
					sub <= 1'b1;
					pc <= pc1;
					st <= S_DEC;
				end else
					st <= S_IDLE;
			end
		end
		endcase
	end

	genvar g;
	generate
	for (g = 0; g < 12; g = g + 1) begin : g_plane
		assign sp_tri[352 + 32 * g +: 32] = pl[g];
	end
	endgenerate
	assign sp_tri[351:0] = {e_bbox, e_edges};
	assign sp_tri[767:736] = {1'b0, kind, raw, e_front, more ? 3'd0 : keep[26:24], keep[23:0]};

	wire unused_ok = &{1'b0, fd_busy, uc[21], rm[2:1]};
endmodule

`default_nettype wire
