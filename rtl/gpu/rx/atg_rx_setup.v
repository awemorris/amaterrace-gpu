/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_setup: Stream Setup Engine (Phase 022):
 * Fully-pipelined hardware setup engine replacing the microcoded FSM.
 * Direct feedforward sequencing for perspective divide, viewport mapping,
 * integer edge calculation (atg_rx_edge), plane equations, and depth bias.
 * Instant 1-cycle triangle loading and zero-latency early culling bypass.
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
	output wire busy,
	/* Extended primitive interfaces */
	output wire [2:0] prim_type,
	output wire [15:0] cur_line_width,
	output wire [15:0] cur_point_size,
	output wire [3:0] cur_viewport_idx
);
	`include "ghci_regs.vh"

	localparam [31:0] ONE  = 32'h3F800000;
	localparam [31:0] HALF = 32'h3F000000;

	/* STATE: VIEWPORT 0x050-0x055 (16-entry array), SCISSOR 0x056-0x057 (16 entries),
	 * CULL 0x058, RAST_MODE 0x05A, DEPTH_BIAS_* 0x060-0x062, LINE_WIDTH 0x063,
	 * POINT_SIZE 0x064, VIEWPORT_IDX 0x065, RT_SIZE 0x073.
	 * VIEWPORT words: 0 x_scale, 1 y_scale, 2 x_offset, 3 y_offset, 4 z_scale, 5 z_offset. */
	reg [31:0] vp_array [0:15][0:5];
	reg [31:0] smin_array [0:15];
	reg [31:0] smax_array [0:15];
	reg [3:0] vp_idx;
	reg [15:0] line_width;
	reg [15:0] point_size;
	reg [31:0] rts, b_const, b_slope, b_clamp;
	reg [2:0] cull;
	reg [5:0] rm;	/* RAST_MODE[5:0] */

	wire [23:0] lw_fix, ps_fix;
	atg_rx_f2fix u_lw_fix (.f(st_wdata), .q(lw_fix));
	atg_rx_f2fix u_ps_fix (.f(st_wdata), .q(ps_fix));

	wire [31:0] ps_in_fp32;
	am_fp_fix2f #(.W(16), .F(8), .SIGNED(0)) u_ps2f (.v(st_wdata[15:0]), .f(ps_in_fp32));
	wire [31:0] div_b = (st_wdata[31:23] != 9'd0) ? st_wdata : ps_in_fp32;
	reg [31:0] inv_ps;
	wire [31:0] div_inv_ps;
	wire div_inv_done, div_busy;
	reg div_inv_start;
	am_fp_div u_ps_div (
		.clk(clk), .rst_n(rst_n),
		.i_start(div_inv_start),
		.i_a(32'h3F800000), .i_b(div_b),
		.busy(div_busy), .o_done(div_inv_done), .o_r(div_inv_ps)
	);

	assign prim_type = {1'b0, kind};
	assign cur_line_width = line_width;
	assign cur_point_size = point_size;
	assign cur_viewport_idx = vp_idx;

	integer vpi_init, vpk_init;
	always @(posedge clk)
		if (!rst_n) begin
			for (vpk_init = 0; vpk_init < 16; vpk_init = vpk_init + 1) begin
				smin_array[vpk_init] <= 32'd0;
				smax_array[vpk_init] <= 32'd0;
				for (vpi_init = 0; vpi_init < 6; vpi_init = vpi_init + 1)
					vp_array[vpk_init][vpi_init] <= 32'd0;
			end
			vp_idx <= 4'd0;
			line_width <= 16'h0100;
			point_size <= 16'h0100;
			inv_ps <= 32'h3F800000;
			div_inv_start <= 1'b0;
			rts <= 32'd0;
			cull <= 3'd0;
			rm <= 6'd0;
			b_const <= 32'd0;
			b_slope <= 32'd0;
			b_clamp <= 32'd0;
		end else begin
			div_inv_start <= 1'b0;
			if (st_we) begin
				if (st_idx == GHCI_S_VIEWPORT_IDX)
					vp_idx <= st_wdata[3:0];
				if (st_idx >= GHCI_S_VIEWPORT && st_idx <= GHCI_S_VIEWPORT + 9'd5)
					vp_array[vp_idx][st_idx[2:0]] <= st_wdata;
				if (st_idx == GHCI_S_SCISSOR_MIN)
					smin_array[vp_idx] <= st_wdata;
				if (st_idx == GHCI_S_SCISSOR_MAX)
					smax_array[vp_idx] <= st_wdata;
				if (st_idx == GHCI_S_LINE_WIDTH)
					line_width <= (st_wdata[31:23] != 9'd0) ? lw_fix[15:0] : st_wdata[15:0];
				if (st_idx == GHCI_S_POINT_SIZE) begin
					point_size <= (st_wdata[31:23] != 9'd0) ? ps_fix[15:0] : st_wdata[15:0];
					if (st_wdata == 32'h0100 || st_wdata == 32'h3F800000)
						inv_ps <= 32'h3F800000;
					else
						div_inv_start <= 1'b1;
				end
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
			if (div_inv_done)
				inv_ps <= div_inv_ps;
		end

	/*
	 * Hardware Sequencer FSM
	 */
	localparam [3:0]
		S_IDLE      = 4'd0,
		S_PERSP_W   = 4'd1,
		S_PERSP_XYZ = 4'd2,
		S_RECT      = 4'd3,
		S_EDGE      = 4'd4,
		S_PLANE_DIV = 4'd5,
		S_PLANE     = 4'd6,
		S_BIAS      = 4'd7,
		S_OUT       = 4'd8;

	reg [3:0] st;
	reg [4:0] seq_step;
	reg [1:0] p_plane;	/* 0: Z, 1: RW, 2: B0, 3: B1 */
	reg [3:0] p_step;
	reg [1:0] kind;
	reg [26:0] keep;
	reg lastq;
	reg raw;
	reg sub;
	reg more;

	reg [31:0] R [0:127];
	reg [31:0] pl [0:11];
	reg [31:0] T0, T1, T2;
	reg [31:0] b_m, b_o;

	function [4:0] inc5;
		input [4:0] v;
		case (v)
		5'd0: inc5 = 5'd1;
		5'd1: inc5 = 5'd2;
		5'd2: inc5 = 5'd3;
		5'd3: inc5 = 5'd4;
		5'd4: inc5 = 5'd5;
		5'd5: inc5 = 5'd6;
		5'd6: inc5 = 5'd7;
		5'd7: inc5 = 5'd8;
		5'd8: inc5 = 5'd9;
		5'd9: inc5 = 5'd10;
		5'd10: inc5 = 5'd11;
		5'd11: inc5 = 5'd12;
		5'd12: inc5 = 5'd13;
		5'd13: inc5 = 5'd14;
		5'd14: inc5 = 5'd15;
		5'd15: inc5 = 5'd16;
		5'd16: inc5 = 5'd17;
		5'd17: inc5 = 5'd18;
		5'd18: inc5 = 5'd19;
		5'd19: inc5 = 5'd20;
		5'd20: inc5 = 5'd21;
		5'd21: inc5 = 5'd22;
		5'd22: inc5 = 5'd23;
		5'd23: inc5 = 5'd24;
		5'd24: inc5 = 5'd25;
		5'd25: inc5 = 5'd26;
		5'd26: inc5 = 5'd27;
		5'd27: inc5 = 5'd28;
		5'd28: inc5 = 5'd29;
		5'd29: inc5 = 5'd30;
		5'd30: inc5 = 5'd31;
		default: inc5 = 5'd0;
		endcase
	endfunction

	function [3:0] inc4;
		input [3:0] v;
		case (v)
		4'd0: inc4 = 4'd1;
		4'd1: inc4 = 4'd2;
		4'd2: inc4 = 4'd3;
		4'd3: inc4 = 4'd4;
		4'd4: inc4 = 4'd5;
		4'd5: inc4 = 4'd6;
		4'd6: inc4 = 4'd7;
		4'd7: inc4 = 4'd8;
		4'd8: inc4 = 4'd9;
		4'd9: inc4 = 4'd10;
		4'd10: inc4 = 4'd11;
		4'd11: inc4 = 4'd12;
		4'd12: inc4 = 4'd13;
		4'd13: inc4 = 4'd14;
		4'd14: inc4 = 4'd15;
		default: inc4 = 4'd0;
		endcase
	endfunction

	function [1:0] inc2;
		input [1:0] v;
		case (v)
		2'd0: inc2 = 2'd1;
		2'd1: inc2 = 2'd2;
		2'd2: inc2 = 2'd3;
		default: inc2 = 2'd0;
		endcase
	endfunction

	/* the bias's r for D16 (2^-16) and D24 (2^-24) */
`ifdef MUT_BIAS_R
	localparam [31:0] R24 = 32'h34000000;
`else
	localparam [31:0] R24 = 32'h33800000;
`endif
	wire [31:0] rfmt = rm[5:4] == 2'd1 ? 32'h37800000 : rm[5:4] == 2'd2 ? R24 : 32'd0;

	/* atg_rx_edge (the integer steps), sharing the register file. */
	reg e_start;
	wire [6:0] e_ra, e_wa;
	reg [31:0] e_rd;
	wire e_we, e_done, e_front, e_empty;
	wire [31:0] e_wd;
	wire [287:0] e_edges;
	wire [63:0] e_bbox;

	atg_rx_edge edge_u (
		.clk(clk), .rst_n(rst_n), .start(e_start),
		.mode({raw, sub, kind}), .smin(smin_array[vp_idx]), .smax(smax_array[vp_idx]), .rts(rts), .cull(cull),
		.vprect(rm[3]), .line_width(line_width), .point_size(point_size),
		.r_ra(e_ra), .r_rd(e_rd), .r_we(e_we), .r_wa(e_wa), .r_wd(e_wd),
		.done(e_done), .edges(e_edges), .bbox(e_bbox), .front(e_front), .empty(e_empty)
	);

	/* Floating-point arithmetic units */
	reg fa_v, fm_v, fd_v;
	reg [31:0] fa_a, fa_b;
	reg fa_sub;
	reg [31:0] fm_a, fm_b;
	reg [31:0] fd_a, fd_b;
	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;

	am_fp_add #(.LAT(4)) fadd (
		.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(fa_sub), .o_valid(fa_o), .o_r(fa_r)
	);
	am_fp_mul #(.LAT(4)) fmul (
		.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r)
	);
	am_fp_div fdiv (
		.clk(clk), .rst_n(rst_n), .i_start(fd_v), .i_a(fd_a), .i_b(fd_b),
		.busy(fd_busy), .o_done(fd_o), .o_r(fd_r)
	);

	/* fp32 compare: a <= b */
	function fle;
		input [31:0] a, b;
		reg [32:0] ka, kb;
		begin
			ka = {2'd0, a[30:0]};
			kb = {2'd0, b[30:0]};
			fle = !(a[30:23] == 8'hFF && a[22:0] != 23'd0) &&
				!(b[30:23] == 8'hFF && b[22:0] != 23'd0) &&
				(a[31] ? (b[31] ? ka >= kb : 1'b1) : (b[31] ? ka == 0 && kb == 0 : ka <= kb));
		end
	endfunction

	function [31:0] bcl;
		input [31:0] a, b;
		bcl = b[30:0] == 31'd0 ? a : !b[31] ? (fle(a, b) ? a : b) : (fle(b, a) ? a : b);
	endfunction

	function [31:0] max_mag;
		input [31:0] a, b;
		max_mag = b[30:0] > a[30:0] ? b : a;
	endfunction

	wire [7:0] ea23;
	wire su_bo_unused;
	reg [7:0] ea_in;
	am_sub #(.W(8)) u_ea23 (.a(ea_in), .b(8'd23), .bi(1'b0), .d(ea23), .bo(su_bo_unused));

	wire [31:0] max_z01 = max_mag({1'b0, R[33][30:0]}, {1'b0, R[36][30:0]});
	wire [31:0] max_z   = max_mag(max_z01, {1'b0, R[39][30:0]});

	assign cl_ready = (st == S_IDLE);
	assign busy = (st != S_IDLE);
	assign sp_last = lastq && !more;

	/* Plane source registers */
	reg [6:0] pf0, pf1, pf2;
	always @(*)
		case (p_plane)
		2'd0: begin pf0 = 7'd33; pf1 = 7'd36; pf2 = 7'd39; end	/* Z */
		2'd1: begin pf0 = 7'd28; pf1 = 7'd29; pf2 = 7'd30; end	/* RW */
		2'd2: begin pf0 = 7'd52; pf1 = 7'd53; pf2 = 7'd54; end	/* B0W */
		default: begin pf0 = 7'd55; pf1 = 7'd56; pf2 = 7'd57; end	/* B1W */
		endcase

	wire [31:0] cur_A = (p_plane == 2'd0) ? pl[0] : (p_plane == 2'd1) ? pl[3] : (p_plane == 2'd2) ? pl[6] : pl[9];
	wire [31:0] cur_B = (p_plane == 2'd0) ? pl[1] : (p_plane == 2'd1) ? pl[4] : (p_plane == 2'd2) ? pl[7] : pl[10];

	integer i;
	always @(posedge clk) begin
		e_rd <= R[e_ra];
		fa_v <= 1'b0;
		fm_v <= 1'b0;
		fd_v <= 1'b0;
		e_start <= 1'b0;

		if (e_we)
			R[e_wa] <= e_wd;

		if (!rst_n) begin
			st <= S_IDLE;
			sp_valid <= 1'b0;
			more <= 1'b0;
			sub <= 1'b0;
			seq_step <= 5'd0;
			p_plane <= 2'd0;
			p_step <= 4'd0;
			ea_in <= 8'd0;
			for (i = 0; i < 12; i = i + 1)
				pl[i] <= 32'd0;
		end else case (st)
		S_IDLE:
			if (cl_valid) begin
				raw <= cl_tri[699];
				kind <= cl_tri[699] || cl_tri[701:700] == 2'd3 ? 2'd2 : cl_tri[701:700];
				keep <= cl_tri[698:672];
				lastq <= cl_last;
				sub <= 1'b0;
				more <= 1'b0;
				for (i = 0; i < 12; i = i + 1)
					pl[i] <= 32'd0;

				/* 1-cycle parallel load */
				for (i = 0; i < 21; i = i + 1)
					R[i] <= cl_tri[i * 32 +: 32];
				R[21] <= vp_array[vp_idx][0]; R[22] <= vp_array[vp_idx][1]; R[23] <= vp_array[vp_idx][2];
				R[24] <= vp_array[vp_idx][3]; R[25] <= vp_array[vp_idx][4]; R[26] <= vp_array[vp_idx][5];
				R[27] <= ONE;

				if (cl_tri[699]) begin
					/* RAW screen space: load X, Y, Z directly */
					R[31] <= cl_tri[31:0];   R[32] <= cl_tri[63:32];   R[33] <= cl_tri[95:64];
					R[34] <= cl_tri[159:128]; R[35] <= cl_tri[191:160]; R[36] <= cl_tri[223:192];
					R[37] <= cl_tri[287:256]; R[38] <= cl_tri[319:288]; R[39] <= cl_tri[351:320];
					st <= S_EDGE;
					e_start <= 1'b1;
				end else begin
					/* Clip space: start 1/w0 divide */
					fd_v <= 1'b1;
					fd_a <= ONE;
					fd_b <= cl_tri[127:96];
					seq_step <= 5'd0;
					st <= S_PERSP_W;
				end
			end

		S_PERSP_W:
			if (fd_o) begin
				case (seq_step)
				5'd0: begin
					R[28] <= fd_r;	/* RW0 */
					fd_v <= 1'b1;
					fd_a <= ONE;
					fd_b <= R[7];	/* V1.w */
					seq_step <= 5'd1;
				end
				5'd1: begin
					R[29] <= fd_r;	/* RW1 */
					fd_v <= 1'b1;
					fd_a <= ONE;
					fd_b <= R[11];	/* V2.w */
					seq_step <= 5'd2;
				end
				default: begin
					R[30] <= fd_r;	/* RW2 */
					seq_step <= 5'd0;
					st <= S_PERSP_XYZ;
				end
				endcase
			end

		S_PERSP_XYZ:
			case (seq_step)
			/* Vertex 0: X0, Y0, Z0, B0W0, B1W0 */
			5'd0: begin
				fm_v <= 1'b1; fm_a <= R[0]; fm_b <= R[28];	/* V0.x * RW0 */
				seq_step <= inc5(seq_step);
			end
			5'd1: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[21];	/* * XS */
				seq_step <= inc5(seq_step);
			end
			5'd2: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[23]; fa_sub <= 1'b0;	/* + XO */
				seq_step <= inc5(seq_step);
			end
			5'd3: if (fa_o) begin
				R[31] <= fa_r;	/* X0 */
				fm_v <= 1'b1; fm_a <= R[1]; fm_b <= R[28];	/* V0.y * RW0 */
				seq_step <= inc5(seq_step);
			end
			5'd4: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[22];	/* * YS */
				seq_step <= inc5(seq_step);
			end
			5'd5: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[24]; fa_sub <= 1'b0;	/* + YO */
				seq_step <= inc5(seq_step);
			end
			5'd6: if (fa_o) begin
				R[32] <= fa_r;	/* Y0 */
				fm_v <= 1'b1; fm_a <= R[2]; fm_b <= R[28];	/* V0.z * RW0 */
				seq_step <= inc5(seq_step);
			end
			5'd7: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[25];	/* * ZS */
				seq_step <= inc5(seq_step);
			end
			5'd8: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[26]; fa_sub <= 1'b0;	/* + ZO */
				seq_step <= inc5(seq_step);
			end
			5'd9: if (fa_o) begin
				R[33] <= fa_r;	/* Z0 */
				fm_v <= 1'b1; fm_a <= R[12]; fm_b <= R[28];	/* W0.0 * RW0 */
				seq_step <= inc5(seq_step);
			end
			5'd10: if (fm_o) begin
				R[52] <= fm_r;	/* B0W0 */
				fm_v <= 1'b1; fm_a <= R[13]; fm_b <= R[28];	/* W0.1 * RW0 */
				seq_step <= inc5(seq_step);
			end
			5'd11: if (fm_o) begin
				R[55] <= fm_r;	/* B1W0 */
				/* Vertex 1: X1, Y1, Z1, B0W1, B1W1 */
				fm_v <= 1'b1; fm_a <= R[4]; fm_b <= R[29];	/* V1.x * RW1 */
				seq_step <= inc5(seq_step);
			end
			5'd12: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[21];	/* * XS */
				seq_step <= inc5(seq_step);
			end
			5'd13: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[23]; fa_sub <= 1'b0;	/* + XO */
				seq_step <= inc5(seq_step);
			end
			5'd14: if (fa_o) begin
				R[34] <= fa_r;	/* X1 */
				fm_v <= 1'b1; fm_a <= R[5]; fm_b <= R[29];	/* V1.y * RW1 */
				seq_step <= inc5(seq_step);
			end
			5'd15: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[22];	/* * YS */
				seq_step <= inc5(seq_step);
			end
			5'd16: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[24]; fa_sub <= 1'b0;	/* + YO */
				seq_step <= inc5(seq_step);
			end
			5'd17: if (fa_o) begin
				R[35] <= fa_r;	/* Y1 */
				fm_v <= 1'b1; fm_a <= R[6]; fm_b <= R[29];	/* V1.z * RW1 */
				seq_step <= inc5(seq_step);
			end
			5'd18: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[25];	/* * ZS */
				seq_step <= inc5(seq_step);
			end
			5'd19: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[26]; fa_sub <= 1'b0;	/* + ZO */
				seq_step <= inc5(seq_step);
			end
			5'd20: if (fa_o) begin
				R[36] <= fa_r;	/* Z1 */
				fm_v <= 1'b1; fm_a <= R[15]; fm_b <= R[29];	/* W1.0 * RW1 */
				seq_step <= inc5(seq_step);
			end
			5'd21: if (fm_o) begin
				R[53] <= fm_r;	/* B0W1 */
				fm_v <= 1'b1; fm_a <= R[16]; fm_b <= R[29];	/* W1.1 * RW1 */
				seq_step <= inc5(seq_step);
			end
			5'd22: if (fm_o) begin
				R[56] <= fm_r;	/* B1W1 */
				/* Vertex 2: X2, Y2, Z2, B0W2, B1W2 */
				fm_v <= 1'b1; fm_a <= R[8]; fm_b <= R[30];	/* V2.x * RW2 */
				seq_step <= inc5(seq_step);
			end
			5'd23: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[21];	/* * XS */
				seq_step <= inc5(seq_step);
			end
			5'd24: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[23]; fa_sub <= 1'b0;	/* + XO */
				seq_step <= inc5(seq_step);
			end
			5'd25: if (fa_o) begin
				R[37] <= fa_r;	/* X2 */
				fm_v <= 1'b1; fm_a <= R[9]; fm_b <= R[30];	/* V2.y * RW2 */
				seq_step <= inc5(seq_step);
			end
			5'd26: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[22];	/* * YS */
				seq_step <= inc5(seq_step);
			end
			5'd27: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[24]; fa_sub <= 1'b0;	/* + YO */
				seq_step <= inc5(seq_step);
			end
			5'd28: if (fa_o) begin
				R[38] <= fa_r;	/* Y2 */
				fm_v <= 1'b1; fm_a <= R[10]; fm_b <= R[30];	/* V2.z * RW2 */
				seq_step <= inc5(seq_step);
			end
			5'd29: if (fm_o) begin
				fm_v <= 1'b1; fm_a <= fm_r; fm_b <= R[25];	/* * ZS */
				seq_step <= inc5(seq_step);
			end
			5'd30: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[26]; fa_sub <= 1'b0;	/* + ZO */
				seq_step <= inc5(seq_step);
			end
			default: if (fa_o) begin
				R[39] <= fa_r;	/* Z2 */
				fm_v <= 1'b1; fm_a <= R[18]; fm_b <= R[30];	/* W2.0 * RW2 */
				st <= S_RECT;
				seq_step <= 5'd0;
			end
			endcase

		S_RECT:
			case (seq_step)
			5'd0: if (fm_o) begin
				R[54] <= fm_r;	/* B0W2 */
				fm_v <= 1'b1; fm_a <= R[19]; fm_b <= R[30];	/* W2.1 * RW2 */
				seq_step <= inc5(seq_step);
			end
			5'd1: if (fm_o) begin
				R[57] <= fm_r;	/* B1W2 */
				if (!rm[3]) begin
					/* No viewport rectangle: dispatch edge directly */
					if (kind == 2'd1) begin
						R[39] <= R[33]; R[30] <= R[28]; R[54] <= R[52]; R[57] <= R[55];
					end
					st <= S_EDGE;
					e_start <= 1'b1;
				end else begin
					/* Viewport rectangle: RX0, RX1, RY0, RY1 */
					fa_v <= 1'b1; fa_a <= R[23]; fa_b <= {1'b0, R[21][30:0]}; fa_sub <= 1'b1;	/* XO - |XS| */
					seq_step <= inc5(seq_step);
				end
			end
			5'd2: if (fa_o) begin
				R[76] <= fa_r;	/* RX0 */
				fa_v <= 1'b1; fa_a <= R[23]; fa_b <= {1'b0, R[21][30:0]}; fa_sub <= 1'b0;	/* XO + |XS| */
				seq_step <= inc5(seq_step);
			end
			5'd3: if (fa_o) begin
				R[77] <= fa_r;	/* RX1 */
				fa_v <= 1'b1; fa_a <= R[24]; fa_b <= {1'b0, R[22][30:0]}; fa_sub <= 1'b1;	/* YO - |YS| */
				seq_step <= inc5(seq_step);
			end
			5'd4: if (fa_o) begin
				R[78] <= fa_r;	/* RY0 */
				fa_v <= 1'b1; fa_a <= R[24]; fa_b <= {1'b0, R[22][30:0]}; fa_sub <= 1'b0;	/* YO + |YS| */
				seq_step <= inc5(seq_step);
			end
			default: if (fa_o) begin
				R[79] <= fa_r;	/* RY1 */
				if (kind == 2'd1) begin
					R[39] <= R[33]; R[30] <= R[28]; R[54] <= R[52]; R[57] <= R[55];
				end
				st <= S_EDGE;
				e_start <= 1'b1;
			end
			endcase

		S_EDGE:
			if (e_done) begin
				if (e_empty) begin
					/* Early culling / zero-area / out-of-screen: zero-latency drop! */
					st <= S_OUT;
				end else if (kind == 2'd0) begin
					/* Point: direct plane assignment */
					pl[0] <= 32'd0; pl[1] <= 32'd0; pl[2] <= R[33];
					pl[3] <= 32'd0; pl[4] <= 32'd0; pl[5] <= ONE;
					pl[6] <= inv_ps; pl[7] <= 32'd0;
					pl[9] <= 32'd0; pl[10] <= inv_ps;
					if (point_size != 16'h0100) begin
						fm_v <= 1'b1; fm_a <= R[45]; fm_b <= inv_ps;
						seq_step <= 5'd0;
						st <= S_PLANE_DIV;
					end else begin
						fa_v <= 1'b1; fa_a <= HALF; fa_b <= R[45]; fa_sub <= 1'b0;	/* 0.5 + OX */
						seq_step <= 5'd2;
						st <= S_PLANE_DIV;
					end
				end else begin
					/* Triangle or line: start 1/DF */
					fd_v <= 1'b1;
					fd_a <= ONE;
					fd_b <= R[44];	/* DF */
					st <= S_PLANE_DIV;
					seq_step <= 5'd0;
				end
			end

		S_PLANE_DIV:
			if (kind == 2'd0) begin
				/* Point path: cleanly serialized arithmetic (no missed pulse races) */
				case (seq_step)
				5'd0: if (fm_o) begin
					fa_v <= 1'b1; fa_a <= HALF; fa_b <= fm_r; fa_sub <= 1'b0;	/* 0.5 + OX_scaled */
					seq_step <= 5'd1;
				end
				5'd1: if (fa_o) begin
					pl[8] <= fa_r;	/* b0/w C */
					fm_v <= 1'b1; fm_a <= R[46]; fm_b <= inv_ps;	/* launch OY * inv_ps */
					seq_step <= 5'd3;
				end
				5'd3: if (fm_o) begin
					fa_v <= 1'b1; fa_a <= HALF; fa_b <= fm_r; fa_sub <= 1'b0;	/* 0.5 + OY_scaled */
					seq_step <= 5'd4;
				end
				5'd2: if (fa_o) begin
					pl[8] <= fa_r;	/* b0/w C */
					fa_v <= 1'b1; fa_a <= HALF; fa_b <= R[46]; fa_sub <= 1'b0;	/* 0.5 + OY */
					seq_step <= 5'd4;
				end
				5'd4: if (fa_o) begin
					pl[11] <= fa_r;	/* b1/w C */
					more <= !sub;	/* 1st sub-triangle: more=1; 2nd: more=0 */
					st <= S_OUT;
				end
				default: ;
				endcase
			end else if (fd_o) begin
				R[47] <= fd_r;	/* RD = 1/DF */
				p_plane <= 2'd0;
				p_step <= 4'd0;
				st <= S_PLANE;
			end

		S_PLANE:
			case (p_step)
			4'd0: begin
				fa_v <= 1'b1; fa_a <= R[pf1]; fa_b <= R[pf0]; fa_sub <= 1'b1;	/* T0 = f1 - f0 */
				p_step <= inc4(p_step);
			end
			4'd1: if (fa_o) begin
				T0 <= fa_r;
				fa_v <= 1'b1; fa_a <= R[pf2]; fa_b <= R[pf0]; fa_sub <= 1'b1;	/* T1 = f2 - f0 */
				p_step <= inc4(p_step);
			end
			4'd2: if (fa_o) begin
				T1 <= fa_r;
				fm_v <= 1'b1; fm_a <= T0; fm_b <= R[43];	/* T2 = T0 * DY2 */
				p_step <= inc4(p_step);
			end
			4'd3: if (fm_o) begin
				T2 <= fm_r;
				fm_v <= 1'b1; fm_a <= T1; fm_b <= R[41];	/* T3 = T1 * DY1 */
				p_step <= inc4(p_step);
			end
			4'd4: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= T2; fa_b <= fm_r; fa_sub <= 1'b1;	/* T2 = T2 - T3 */
				p_step <= inc4(p_step);
			end
			4'd5: if (fa_o) begin
				fm_v <= 1'b1; fm_a <= fa_r; fm_b <= R[47];	/* a[0] = T2 * RD (A) */
				p_step <= inc4(p_step);
			end
			4'd6: if (fm_o) begin
				case (p_plane)
				2'd0: pl[0] <= fm_r;
				2'd1: pl[3] <= fm_r;
				2'd2: pl[6] <= fm_r;
				default: pl[9] <= fm_r;
				endcase
				fm_v <= 1'b1; fm_a <= T1; fm_b <= R[40];	/* T2 = T1 * DX1 */
				p_step <= inc4(p_step);
			end
			4'd7: if (fm_o) begin
				T2 <= fm_r;
				fm_v <= 1'b1; fm_a <= T0; fm_b <= R[42];	/* T3 = T0 * DX2 */
				p_step <= inc4(p_step);
			end
			4'd8: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= T2; fa_b <= fm_r; fa_sub <= 1'b1;	/* T2 = T2 - T3 */
				p_step <= inc4(p_step);
			end
			4'd9: if (fa_o) begin
				fm_v <= 1'b1; fm_a <= fa_r; fm_b <= R[47];	/* a[1] = T2 * RD (B) */
				p_step <= inc4(p_step);
			end
			4'd10: if (fm_o) begin
				case (p_plane)
				2'd0: pl[1] <= fm_r;
				2'd1: pl[4] <= fm_r;
				2'd2: pl[7] <= fm_r;
				default: pl[10] <= fm_r;
				endcase
				fm_v <= 1'b1; fm_a <= cur_A; fm_b <= R[45];	/* T2 = A * OX */
				p_step <= inc4(p_step);
			end
			4'd11: if (fm_o) begin
				T2 <= fm_r;
				fm_v <= 1'b1; fm_a <= cur_B; fm_b <= R[46];	/* T3 = B * OY */
				p_step <= inc4(p_step);
			end
			4'd12: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= T2; fa_b <= fm_r; fa_sub <= 1'b0;	/* T2 = T2 + T3 */
				p_step <= inc4(p_step);
			end
			4'd13: if (fa_o) begin
				fa_v <= 1'b1; fa_a <= R[pf0]; fa_b <= fa_r; fa_sub <= 1'b0;	/* C = f0 + T2 */
				p_step <= inc4(p_step);
			end
			default: if (fa_o) begin
				case (p_plane)
				2'd0: pl[2] <= fa_r;
				2'd1: pl[5] <= fa_r;
				2'd2: pl[8] <= fa_r;
				default: pl[11] <= fa_r;
				endcase
				p_step <= 4'd0;
				if (raw) begin
					/* RAW triangle: Z plane only, done */
					st <= S_OUT;
				end else if (p_plane != 2'd3) begin
					p_plane <= inc2(p_plane);
				end else if (kind == 2'd1) begin
					/* Line: sub-triangle 0 done */
					more <= !sub;
					st <= S_OUT;
				end else if (rm[0] && rm[5:4] != 2'd0) begin
					/* Triangle with depth bias */
					seq_step <= 5'd0;
					st <= S_BIAS;
				end else begin
					st <= S_OUT;
				end
			end
			endcase

		/* S_BIAS */
		S_BIAS:
			case (seq_step)
			5'd0: begin
				b_m <= max_mag({1'b0, pl[0][30:0]}, {1'b0, pl[1][30:0]});	/* max(|Az|, |Bz|) */
				seq_step <= inc5(seq_step);
			end
			5'd1: begin
				fm_v <= 1'b1; fm_a <= b_m; fm_b <= b_slope;	/* T0 = m * SLOPE */
				seq_step <= inc5(seq_step);
			end
			5'd2: if (fm_o) begin
				T0 <= fm_r;
				if (rm[5:4] == 2'd3) begin
					/* D32_SFLOAT: ULP(max(|z0|, |z1|, |z2|)) */
					ea_in <= max_z[30:23];
					seq_step <= 5'd3;
				end else begin
					/* D16 / D24 */
					fm_v <= 1'b1; fm_a <= rfmt; fm_b <= b_const;	/* T1 = r * CONST */
					seq_step <= 5'd4;
				end
			end
			5'd3: begin
				fm_v <= 1'b1;
				fm_a <= (ea_in > 8'd23) ? {1'b0, ea23, 23'd0} : 32'd0;
				fm_b <= b_const;
				seq_step <= 5'd4;
			end
			5'd4: if (fm_o) begin
				fa_v <= 1'b1; fa_a <= T0; fa_b <= fm_r; fa_sub <= 1'b0;	/* T0 = T0 + T1 */
				seq_step <= inc5(seq_step);
			end
			5'd5: if (fa_o) begin
				b_o <= bcl(fa_r, b_clamp);	/* BCL(T0, CLAMP) */
				seq_step <= inc5(seq_step);
			end
			5'd6: begin
				fa_v <= 1'b1; fa_a <= pl[2]; fa_b <= b_o; fa_sub <= 1'b0;	/* Cz + o */
				seq_step <= inc5(seq_step);
			end
			default: if (fa_o) begin
				pl[2] <= fa_r;	/* Cz biased */
				st <= S_OUT;
			end
			endcase

		/* S_OUT */
		S_OUT: begin
			sp_valid <= 1'b1;
			if (sp_valid && sp_ready) begin
				sp_valid <= 1'b0;
				if (more) begin
					more <= 1'b0;
					sub <= 1'b1;
					st <= S_EDGE;
					e_start <= 1'b1;
				end else begin
					st <= S_IDLE;
				end
			end
		end
		default: ;
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

	wire unused_ok = &{1'b0, fd_busy, rm[2:1], su_bo_unused, max_z[31], max_z[22:0]};
endmodule

`default_nettype wire
