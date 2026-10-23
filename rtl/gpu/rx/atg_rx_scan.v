/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_scan: RX quad traversal: walks the bounding box in 2×2 quads,
 * evaluates the edges for coverage, packs up to 8 quads of one triangle
 * into a 32-lane fragment warp (or sends quads directly to the ROP without
 * an SU), copies the vertices' varyings into the SU's primitive table,
 * frees PT entries.
 *
 * WS288 p007: the direct path (quads to the ROP with their depth, one
 * sequence number per triangle).  The fragment-warp path is p009; until
 * then HAS_SU 1 also sends direct quads and fl_* stay 0.  Edges step one
 * quad per cycle; a covered quad's depth takes 20 cycles (one fmul and one
 * fadd, the four lanes interleaved).  See spec/gpu/rx/atg_rx_scan.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_scan #(
	parameter HAS_SU = 1	/* 1: fragment warps to the SU; 0: quads straight to the ROP with DEBUG_COLOR (bitstream 3) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rx_setup */
	input wire sp_valid,
	output wire sp_ready,
	input wire [767:0] sp_tri,
	input wire sp_last,
	/* PT read (shared with atg_rx_scan in atg_rx: scan has priority) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [5:0] pt_word,
	input wire [31:0] pt_rdata,
	output wire pt_busy,
	output reg pt_free,
	output reg [7:0] pt_free_idx,
	/* Fragment warps to the SU (atg_su fl_*) */
	output wire fl_req,
	input wire fl_gnt,
	output wire fl_we,
	output wire [5:0] fl_reg,
	output wire [4:0] fl_lane,
	output wire [31:0] fl_data,
	output wire fl_pw_we,
	output wire [11:0] fl_pw_addr,
	output wire [31:0] fl_pw_data,
	output wire fl_go,
	output wire [31:0] fl_mask,
	output wire [63:0] fl_info,
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	output reg dx_valid,
	input wire dx_ready,
	output reg [15:0] dx_seq,
	output reg [31:0] dx_xy,
	output reg [3:0] dx_mask,
	output reg [127:0] dx_depth,
	output reg dx_last,
	/* Sequence numbers (atg_rx_order) */
	output wire sq_req,
	input wire [15:0] sq_seq,
	output wire busy
);
	localparam [2:0] S_IDLE = 3'd0, S_SEQ = 3'd1, S_WALK = 3'd2, S_Z = 3'd3, S_EMIT = 3'd4,
		S_LAST = 3'd5, S_FREE = 3'd6;
	reg [2:0] st;

	/* The triangle. */
	reg signed [47:0] a8 [0:2];	/* A << 8: one pixel in x */
	reg signed [47:0] b8 [0:2];
	reg signed [47:0] er [0:2];	/* the edges at the row's first quad */
	reg signed [47:0] ec [0:2];	/* at the current quad */
	reg [15:0] bx0, by0, bx1, by1, qx, qy;
	reg [31:0] az, bz, cz;
	reg [23:0] ent;
	reg [2:0] fl;
	reg raw;
	reg [1:0] fi;	/* S_FREE: vertex */
	integer k;

	wire signed [47:0] a8_0 = a8[0], a8_1 = a8[1], a8_2 = a8[2];
	wire signed [47:0] b8_0 = b8[0], b8_1 = b8[1], b8_2 = b8[2];
	wire signed [47:0] ec_0 = ec[0], ec_1 = ec[1], ec_2 = ec[2];

	/* Coverage of the current quad: lane l at (qx + l[0], qy + l[1]). */
	reg [3:0] cov;
	reg signed [47:0] lv;
	always @(*) begin
		for (k = 0; k < 4; k = k + 1) begin
			cov[k] = 1'b1;
			lv = ec_0 + (k[0] ? a8_0 : 48'sd0) + (k[1] ? b8_0 : 48'sd0);
			if (lv[47])
				cov[k] = 1'b0;
			lv = ec_1 + (k[0] ? a8_1 : 48'sd0) + (k[1] ? b8_1 : 48'sd0);
			if (lv[47])
				cov[k] = 1'b0;
			lv = ec_2 + (k[0] ? a8_2 : 48'sd0) + (k[1] ? b8_2 : 48'sd0);
			if (lv[47])
				cov[k] = 1'b0;
			if ({16'd0, qx} + {31'd0, k[0]} < {16'd0, bx0} ||
			    {16'd0, qx} + {31'd0, k[0]} >= {16'd0, bx1} ||
			    {16'd0, qy} + {31'd0, k[1]} < {16'd0, by0} ||
			    {16'd0, qy} + {31'd0, k[1]} >= {16'd0, by1})
				cov[k] = 1'b0;
		end
	end
	wire row_end = {1'b0, qx} + 17'd2 >= {1'b0, bx1};
	wire walk_end = row_end && {1'b0, qy} + 17'd2 >= {1'b0, by1};

	/* Depth: z = (Az i + Bz j) + Cz, i = x - bx0, j = y - by0, clamped to [0, 1]. */
	function [31:0] i2f;	/* a small signed integer to fp32 (exact) */
		input [16:0] v;
		reg [16:0] m;
		reg [4:0] lz;
		integer b;
		begin
			m = v[16] ? -v : v;
			lz = 5'd0;
			for (b = 0; b < 17; b = b + 1)
				if (m[b])
					lz = 5'd16 - b[4:0];
			m = m << lz;
			i2f = m == 17'd0 ? 32'd0 : {v[16], 8'd127 + 8'd16 - {3'd0, lz}, m[15:0], 7'd0};
		end
	endfunction

	reg [4:0] zc;
	reg [3:0] zmask;
	reg [31:0] t1 [0:3];
	reg [127:0] zv;
	wire [1:0] zl = zc[1:0];
	wire [16:0] li = {1'b0, qx} + {16'd0, zl[0]} - {1'b0, bx0};
	wire [16:0] lj = {1'b0, qy} + {16'd0, zl[1]} - {1'b0, by0};
	wire fm_v = st == S_Z && zc < 5'd8;
	wire [31:0] fm_a = zc < 5'd4 ? az : bz;
	wire [31:0] fm_b = zc < 5'd4 ? i2f(li) : i2f(lj);
	wire fa_v = st == S_Z && zc >= 5'd8 && zc < 5'd16;
	wire fm_o, fa_o;
	wire [31:0] fm_r, fa_r;
	wire [31:0] fa_a = zc < 5'd12 ? t1[zl] : fa_r;
	wire [31:0] fa_b = zc < 5'd12 ? fm_r : cz;
	atg_rx_fmul fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r));
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(1'b0), .o_valid(fa_o), .o_r(fa_r));
	wire [31:0] zcl = fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0) ? 32'd0 :
		fa_r > 32'h3F800000 ? 32'h3F800000 : fa_r;

	/* The quad that waits for its successor (to know which is the last). */
	reg pend;
	reg [31:0] p_xy;
	reg [3:0] p_mask;
	reg [127:0] p_z;
	reg [15:0] seq;

	assign sp_ready = st == S_IDLE;
	assign sq_req = st == S_SEQ;
	assign busy = st != S_IDLE;

	always @(posedge clk) begin
		pt_free <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			dx_valid <= 1'b0;
		end else case (st)
		S_IDLE:
			if (sp_valid) begin
				for (k = 0; k < 3; k = k + 1) begin
					a8[k] <= {{16{sp_tri[96 * k + 23]}}, sp_tri[96 * k +: 24], 8'd0};
					b8[k] <= {{16{sp_tri[96 * k + 47]}}, sp_tri[96 * k + 24 +: 24], 8'd0};
					/* back to the quad origin (even x, y) */
					er[k] <= $signed(sp_tri[96 * k + 48 +: 48]) -
						(sp_tri[288] ? $signed({{16{sp_tri[96 * k + 23]}}, sp_tri[96 * k +: 24], 8'd0}) : 48'sd0) -
						(sp_tri[304] ? $signed({{16{sp_tri[96 * k + 47]}}, sp_tri[96 * k + 24 +: 24], 8'd0}) : 48'sd0);
				end
				bx0 <= sp_tri[303:288];
				by0 <= sp_tri[319:304];
				bx1 <= sp_tri[335:320];
				by1 <= sp_tri[351:336];
				qx <= {sp_tri[303:289], 1'b0};
				qy <= {sp_tri[319:305], 1'b0};
				{cz, bz, az} <= sp_tri[447:352];
				ent <= sp_tri[759:736];
				fl <= sp_tri[762:760];
				raw <= sp_tri[764];
				pend <= 1'b0;
				fi <= 2'd0;
				st <= sp_tri[335:320] > sp_tri[303:288] && sp_tri[351:336] > sp_tri[319:304] ?
					S_SEQ : S_FREE;
			end
		S_SEQ: begin
			seq <= sq_seq;
			for (k = 0; k < 3; k = k + 1)
				ec[k] <= er[k];
			st <= S_WALK;
		end
		S_WALK:
			if (cov != 4'd0) begin
				zmask <= cov;
				zc <= 5'd0;
				zv <= 128'd0;
				st <= S_Z;
			end else if (walk_end) begin
				st <= S_LAST;
			end else
				st <= S_WALK;
		S_Z: begin
			zc <= zc + 5'd1;
			if (zc >= 5'd4 && zc < 5'd8)
				t1[zl] <= fm_r;
			if (zc >= 5'd16 && zmask[zl])
				zv[32 * zl +: 32] <= zcl;
			if (zc == 5'd19)
				st <= S_EMIT;
		end
		S_EMIT:
			/* the pending quad goes out (not last), this one waits */
			if (pend && !(dx_valid && dx_ready)) begin
				dx_valid <= 1'b1;
				dx_seq <= seq;
				dx_xy <= p_xy;
				dx_mask <= p_mask;
				dx_depth <= p_z;
				dx_last <= 1'b0;
			end else begin
				dx_valid <= 1'b0;
				pend <= 1'b1;
				p_xy <= {qy, qx};
				p_mask <= zmask;
				p_z <= zv;
				st <= walk_end ? S_LAST : S_WALK;
			end
		S_LAST:
			if (dx_valid && dx_ready) begin
				dx_valid <= 1'b0;
				st <= S_FREE;
			end else begin
				dx_valid <= 1'b1;
				dx_seq <= seq;
				dx_xy <= pend ? p_xy : {by0[15:1], 1'b0, bx0[15:1], 1'b0};
				dx_mask <= pend ? p_mask : 4'd0;
				dx_depth <= pend ? p_z : 128'd0;
				dx_last <= 1'b1;
			end
		default: begin	/* S_FREE: the flagged PT entries (none for DRAW_RAW) */
			fi <= fi + 2'd1;
			if (fi < 2'd3 && fl[fi] && !raw) begin
				pt_free <= 1'b1;
				pt_free_idx <= ent[8 * fi +: 8];
			end
			if (fi == 2'd3)
				st <= S_IDLE;
		end
		endcase
		/* the walk: next quad (also after a covered quad's depth) */
		if (rst_n && ((st == S_WALK && cov == 4'd0) || (st == S_EMIT && !(pend && !(dx_valid && dx_ready))))
		    && !walk_end) begin
			if (row_end) begin
				qx <= {bx0[15:1], 1'b0};
				qy <= qy + 16'd2;
				for (k = 0; k < 3; k = k + 1) begin
					er[k] <= er[k] + (b8[k] <<< 1);
					ec[k] <= er[k] + (b8[k] <<< 1);
				end
			end else begin
				qx <= qx + 16'd2;
				for (k = 0; k < 3; k = k + 1)
					ec[k] <= ec[k] + (a8[k] <<< 1);
			end
		end
	end

	/* p009: the warp path. */
	assign pt_rd = 1'b0;
	assign pt_idx = 8'd0;
	assign pt_word = 6'd0;
	assign pt_busy = 1'b0;
	assign fl_req = 1'b0;
	assign fl_we = 1'b0;
	assign fl_reg = 6'd0;
	assign fl_lane = 5'd0;
	assign fl_data = 32'd0;
	assign fl_pw_we = 1'b0;
	assign fl_pw_addr = 12'd0;
	assign fl_pw_data = 32'd0;
	assign fl_go = 1'b0;
	assign fl_mask = 32'd0;
	assign fl_info = 64'd0;

	wire unused_ok = &{1'b0, st_we, st_idx, st_wdata, sp_last, pt_rdata, fl_gnt, fm_o, fa_o,
		sp_tri[767:765], sp_tri[735:448], li[16], lj[16], HAS_SU != 0};
endmodule

`default_nettype wire
