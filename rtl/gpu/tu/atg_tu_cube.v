/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cube: the face and the face coordinates of a cube map direction
 * (docs/ghci.md section 8.4; tools/tumodel.py cube_proj is the reference,
 * bit for bit).
 *
 * go (one cycle, while !bsy) takes the direction (x, y, z, fp32) and either
 * selects the face (Vulkan: the largest magnitude, z before y before x on
 * ties; zeros, denormals and NaN read as +0, infinities as the largest
 * finite value) or, with fix, uses fface.  The face coordinates are
 * computed by two serial divisions (s and t together, one bit a cycle, 26
 * cycles): with m the major axis's significand and e its exponent, sc' =
 * floor(sc 2^(150 - e)) clamped to [-3 m, 3 m], s = floor(2^23 (sc' + 3 m)
 * / m) - 2^24 (24 fraction bits: [0, 2^24] on the selected face, wider on
 * a forced one); a zero major axis gives s = t = 2^23 (the centre).  The
 * result (face, s, t) is held from the cycle bsy falls until the next go.
 * See spec/gpu/tu/atg_tu_cube.md.
 *
 * States: IDLE →(go)→ DIV (26 cycles) → IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_tu_cube (
	input wire clk,
	input wire rst_n,
	input wire go,
	input wire [31:0] x,
	input wire [31:0] y,
	input wire [31:0] z,
	input wire fix,
	input wire [2:0] fface,
	output wire bsy,
	output reg [2:0] face,
	output wire signed [26:0] s,
	output wire signed [26:0] t
);

`ifdef CFG_ENABLE_3D_CUBE
	localparam [3:0] IDLE = 4'd0,
	                 P0A  = 4'd1,
	                 P0B  = 4'd2,
	                 P0   = 4'd3,
	                 P1   = 4'd4,
	                 P2   = 4'd5,
	                 P3   = 4'd6,
	                 P4   = 4'd7,
	                 P5   = 4'd8,
	                 DIV  = 4'd9;

	wire rst_inv = !rst_n;

	(* extract_reset = "no" *) reg [31:0] rx, ry, rz;
	(* extract_reset = "no" *) reg rfix;
	(* extract_reset = "no" *) reg [2:0] rfface;

	(* keep = "true" *) wire rx_z_lo = (rx[30:23] == 8'd0) || (rx[30:23] == 8'hFF && rx[22:0] != 23'd0);
	(* keep = "true" *) wire rx_z_hi = (rx[30:23] == 8'd0) || (rx[30:23] == 8'hFF && rx[22:0] != 23'd0);
	(* keep = "true" *) wire rx_i_lo = (rx[30:23] == 8'hFF);
	(* keep = "true" *) wire rx_i_hi = (rx[30:23] == 8'hFF);
	wire [31:0] cx_w = {
		rx_z_hi ? 16'd0 : rx_i_hi ? {rx[31], 15'h7F7F} : rx[31:16],
		rx_z_lo ? 16'd0 : rx_i_lo ? 16'hFFFF           : rx[15:0]
	};

	(* keep = "true" *) wire ry_z_lo = (ry[30:23] == 8'd0) || (ry[30:23] == 8'hFF && ry[22:0] != 23'd0);
	(* keep = "true" *) wire ry_z_hi = (ry[30:23] == 8'd0) || (ry[30:23] == 8'hFF && ry[22:0] != 23'd0);
	(* keep = "true" *) wire ry_i_lo = (ry[30:23] == 8'hFF);
	(* keep = "true" *) wire ry_i_hi = (ry[30:23] == 8'hFF);
	wire [31:0] cy_w = {
		ry_z_hi ? 16'd0 : ry_i_hi ? {ry[31], 15'h7F7F} : ry[31:16],
		ry_z_lo ? 16'd0 : ry_i_lo ? 16'hFFFF           : ry[15:0]
	};

	(* keep = "true" *) wire rz_z_lo = (rz[30:23] == 8'd0) || (rz[30:23] == 8'hFF && rz[22:0] != 23'd0);
	(* keep = "true" *) wire rz_z_hi = (rz[30:23] == 8'd0) || (rz[30:23] == 8'hFF && rz[22:0] != 23'd0);
	(* keep = "true" *) wire rz_i_lo = (rz[30:23] == 8'hFF);
	(* keep = "true" *) wire rz_i_hi = (rz[30:23] == 8'hFF);
	wire [31:0] cz_w = {
		rz_z_hi ? 16'd0 : rz_i_hi ? {rz[31], 15'h7F7F} : rz[31:16],
		rz_z_lo ? 16'd0 : rz_i_lo ? 16'hFFFF           : rz[15:0]
	};

	(* extract_reset = "no" *) reg [31:0] cx_q, cy_q, cz_q;
	wire [30:0] cmp_zx_d, cmp_zy_d, cmp_yx_d;
	wire bo_zx, bo_zy, bo_yx;
	am_sub #(.W(31)) u_cmp_zx (.a(cz_q[30:0]), .b(cx_q[30:0]), .bi(1'b0), .d(cmp_zx_d), .bo(bo_zx));
	am_sub #(.W(31)) u_cmp_zy (.a(cz_q[30:0]), .b(cy_q[30:0]), .bi(1'b0), .d(cmp_zy_d), .bo(bo_zy));
	am_sub #(.W(31)) u_cmp_yx (.a(cy_q[30:0]), .b(cx_q[30:0]), .bi(1'b0), .d(cmp_yx_d), .bo(bo_yx));
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0] f_vm_0, f_vm_1, f_vm_2, f_vm_3, f_vs_lo, f_vs_hi, f_vt_lo, f_vt_hi, f_face;

	wire az_wins_p0b = !bo_zx && !bo_zy;
	wire ay_wins_p0b = !bo_yx;
	wire [2:0] sel_p0b = az_wins_p0b ? {2'd2, cz_q[31]} : ay_wins_p0b ? {2'd1, cy_q[31]} : {2'd0, cx_q[31]};
	wire [2:0] f_p0b = rfix ? rfface : sel_p0b;
	/* Vulkan's table: major axis, s_c and t_c (with their signs). */
	wire [31:0] vm_w = {
		(f_vm_3[2:1] == 2'd0) ? cx_q[31:24] : (f_vm_3[2:1] == 2'd1) ? cy_q[31:24] : cz_q[31:24],
		(f_vm_2[2:1] == 2'd0) ? cx_q[23:16] : (f_vm_2[2:1] == 2'd1) ? cy_q[23:16] : cz_q[23:16],
		(f_vm_1[2:1] == 2'd0) ? cx_q[15:8]  : (f_vm_1[2:1] == 2'd1) ? cy_q[15:8]  : cz_q[15:8],
		(f_vm_0[2:1] == 2'd0) ? cx_q[7:0]   : (f_vm_0[2:1] == 2'd1) ? cy_q[7:0]   : cz_q[7:0]
	};
	wire [31:0] vs_w = {
		(f_vs_hi[2:1] == 2'd0) ? cz_q[31:16] : cx_q[31:16],
		(f_vs_lo[2:1] == 2'd0) ? cz_q[15:0]  : cx_q[15:0]
	};
	wire [31:0] vt_w = {
		(f_vt_hi[2:1] == 2'd1) ? cz_q[31:16] : cy_q[31:16],
		(f_vt_lo[2:1] == 2'd1) ? cz_q[15:0]  : cy_q[15:0]
	};
	wire ns_w = (f_face == 3'd0 || f_face == 3'd5);
	wire nt_w = (f_face != 3'd2);

	(* extract_reset = "no" *) reg [31:0] vm, vs, vt;
	(* extract_reset = "no" *) reg ns, nt;

	wire [23:0] mm_in = {1'b1, vm[22:0]};
	/* s_c' and t_c' (atg_tu_cube_sc), from 3 m */
	wire [26:0] m3_w, sn_in, tn_in;
	wire [5:0] carry_unused;
	am_add #(.W(27)) u_m3 (.a({3'd0, mm_in}), .b({2'd0, mm_in, 1'b0}), .ci(1'b0), .s(m3_w),
		.co(carry_unused[0]));
	atg_tu_cube_sc u_sn (.clk(clk), .rst_n(rst_n), .v(vs), .neg(ns), .em(vm[30:23]), .m3(m3_w), .o(sn_in));
	atg_tu_cube_sc u_tn (.clk(clk), .rst_n(rst_n), .v(vt), .neg(nt), .em(vm[30:23]), .m3(m3_w), .o(tn_in));

	(* max_fanout = 16 *) reg [3:0] st;
	(* max_fanout = 16 *) reg [4:0] n;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] zero_s_r, zero_t_r;
	(* extract_reset = "no", max_fanout = 16 *) reg [23:0] mm;
	(* extract_reset = "no", max_fanout = 16 *) reg [26:0] ns_num, nt_num;	/* sc' + 3 m, tc' + 3 m */
	(* keep = "true", extract_reset = "no" *) reg [24:0] rs, rt;
	(* keep = "true", extract_reset = "no" *) reg [25:0] qs, qt;
	/* The numerator's next bit: num[2:0] then 23 zeros (num << 23). */
	(* extract_reset = "no" *) reg bs_q, bt_q;
	wire [25:0] ts = {rs, bs_q}, tt = {rt, bt_q};
	/* the remainders less m, n - 1, the quotients less 2^24 */
	wire [24:0] rs_m, rt_m;
	wire bo_rs, bo_rt;
	wire [4:0] n1;
	wire [26:0] s_q, t_q;
	am_sub #(.W(25)) u_rs_m (.a(ts[24:0]), .b({1'b0, mm}), .bi(1'b0), .d(rs_m), .bo(bo_rs));
	am_sub #(.W(25)) u_rt_m (.a(tt[24:0]), .b({1'b0, mm}), .bi(1'b0), .d(rt_m), .bo(bo_rt));
	wire gs = ts[25] || !bo_rs;
	wire gt = tt[25] || !bo_rt;
	wire [3:0] gs_s = {4{gs}};
	wire [3:0] gt_s = {4{gt}};
	assign carry_unused[1] = 1'b0;
	assign carry_unused[2] = 1'b0;
	am_sub #(.W(5)) u_n1 (.a(n), .b(5'd0), .bi(1'b1), .d(n1), .bo(carry_unused[3]));
	am_sub #(.W(27)) u_s_q (.a({1'b0, qs}), .b(27'd16777216), .bi(1'b0), .d(s_q), .bo(carry_unused[4]));
	am_sub #(.W(27)) u_t_q (.a({1'b0, qt}), .b(27'd16777216), .bi(1'b0), .d(t_q), .bo(carry_unused[5]));

	wire [6:0]  ce_idle = {7{st == IDLE && go}};
	wire [5:0]  ce_p0a  = {6{st == P0A}};
	wire [2:0]  ce_p0b  = {3{st == P0B}};
	(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]  ce_p0;
	(* keep = "true", equivalent_register_removal = "no" *) reg [12:0] ce_p5;
	(* keep = "true", equivalent_register_removal = "no" *) reg [12:0] ce_div;
	wire vm_zero_w = (vm_w[30:23] == 8'd0);

	always @(posedge clk) begin
		if (rst_inv) begin
			st <= IDLE;
			ce_p0  <= 10'd0;
			ce_p5  <= 13'd0;
			ce_div <= 13'd0;
		end else begin
			ce_p0  <= {10{ce_p0b[2]}};
			ce_p5  <= {13{st == P4}};
			ce_div <= {13{(st == P5) || (st == DIV && n != 5'd0)}};
			case (st)
			IDLE: if (go) st <= P0A;
			P0A: st <= P0B;
			P0B: st <= P0;
			P0: st <= P1;
			P1: st <= P2;
			P2: st <= P3;
			P3: st <= P4;
			P4: st <= P5;
			P5: st <= DIV;
			default: begin
				if (n == 5'd0)
					st <= IDLE;
			end
			endcase
		end
	end

	always @(posedge clk) begin
		if (ce_idle[0]) rx[15:0]  <= x[15:0];
		if (ce_idle[1]) rx[31:16] <= x[31:16];
		if (ce_idle[2]) ry[15:0]  <= y[15:0];
		if (ce_idle[3]) ry[31:16] <= y[31:16];
		if (ce_idle[4]) rz[15:0]  <= z[15:0];
		if (ce_idle[5]) rz[31:16] <= z[31:16];
		if (ce_idle[6]) begin
			rfix   <= fix;
			rfface <= fface;
		end

		if (ce_p0a[0]) cx_q[15:0]  <= cx_w[15:0];
		if (ce_p0a[1]) cx_q[31:16] <= cx_w[31:16];
		if (ce_p0a[2]) cy_q[15:0]  <= cy_w[15:0];
		if (ce_p0a[3]) cy_q[31:16] <= cy_w[31:16];
		if (ce_p0a[4]) cz_q[15:0]  <= cz_w[15:0];
		if (ce_p0a[5]) cz_q[31:16] <= cz_w[31:16];

		if (ce_p0b[0]) begin
			f_vm_0  <= f_p0b; f_vm_1  <= f_p0b;
			f_vm_2  <= f_p0b; f_vm_3  <= f_p0b;
		end
		if (ce_p0b[1]) begin
			f_vs_lo <= f_p0b; f_vs_hi <= f_p0b;
			f_vt_lo <= f_p0b; f_vt_hi <= f_p0b;
			f_face  <= f_p0b;
		end

		if (ce_p0[0]) vm[15:0]  <= vm_w[15:0];
		if (ce_p0[1]) vm[31:16] <= vm_w[31:16];
		if (ce_p0[2]) vs[15:0]  <= vs_w[15:0];
		if (ce_p0[3]) vs[31:16] <= vs_w[31:16];
		if (ce_p0[4]) vt[15:0]  <= vt_w[15:0];
		if (ce_p0[5]) vt[31:16] <= vt_w[31:16];
		if (ce_p0[6]) mm[15:0]  <= vm_w[15:0];
		if (ce_p0[7]) mm[23:16] <= {1'b1, vm_w[22:16]};
		if (ce_p0[8]) begin
			face <= f_face;
			ns   <= ns_w;
			nt   <= nt_w;
		end
		if (ce_p0[9]) begin
			zero_s_r <= {4{vm_zero_w}};
			zero_t_r <= {4{vm_zero_w}};
		end

		if (ce_p5[0]) ns_num[13:0]  <= sn_in[13:0];
		if (ce_p5[1]) ns_num[26:14] <= sn_in[26:14];
		if (ce_p5[2]) nt_num[13:0]  <= tn_in[13:0];
		if (ce_p5[3]) nt_num[26:14] <= tn_in[26:14];
		if (ce_p5[4])  rs[6:0]   <= sn_in[9:3];
		else if (ce_div[0]) rs[6:0]   <= gs_s[0] ? rs_m[6:0]   : ts[6:0];
		if (ce_p5[5])  rs[12:7]  <= sn_in[15:10];
		else if (ce_div[1]) rs[12:7]  <= gs_s[1] ? rs_m[12:7]  : ts[12:7];
		if (ce_p5[6])  rs[18:13] <= sn_in[21:16];
		else if (ce_div[2]) rs[18:13] <= gs_s[2] ? rs_m[18:13] : ts[18:13];
		if (ce_p5[7])  rs[24:19] <= {1'b0, sn_in[26:22]};
		else if (ce_div[3]) rs[24:19] <= gs_s[3] ? rs_m[24:19] : ts[24:19];
		if (ce_p5[8])  rt[6:0]   <= tn_in[9:3];
		else if (ce_div[4]) rt[6:0]   <= gt_s[0] ? rt_m[6:0]   : tt[6:0];
		if (ce_p5[9])  rt[12:7]  <= tn_in[15:10];
		else if (ce_div[5]) rt[12:7]  <= gt_s[1] ? rt_m[12:7]  : tt[12:7];
		if (ce_p5[10]) rt[18:13] <= tn_in[21:16];
		else if (ce_div[6]) rt[18:13] <= gt_s[2] ? rt_m[18:13] : tt[18:13];
		if (ce_p5[11]) rt[24:19] <= {1'b0, tn_in[26:22]};
		else if (ce_div[7]) rt[24:19] <= gt_s[3] ? rt_m[24:19] : tt[24:19];

		if (ce_p5[12]) begin
			bs_q <= sn_in[2];
			bt_q <= tn_in[2];
			n    <= 5'd25;
		end else if (ce_div[8]) begin
			bs_q <= (n1 == 5'd24) ? ns_num[1] : (n1 == 5'd23) ? ns_num[0] : 1'b0;
			bt_q <= (n1 == 5'd24) ? nt_num[1] : (n1 == 5'd23) ? nt_num[0] : 1'b0;
			n    <= n1;
		end

		if (ce_div[9])  qs[12:0]  <= {qs[11:0], gs};
		if (ce_div[10]) qs[25:13] <= qs[24:12];
		if (ce_div[11]) qt[12:0]  <= {qt[11:0], gt};
		if (ce_div[12]) qt[25:13] <= qt[24:12];
	end

	assign bsy = st != IDLE;
	wire [26:0] c_mid = 27'sd8388608;
	(* keep = "true" *) wire [26:0] s_out, t_out;
	assign s_out[6:0]   = zero_s_r[0] ? c_mid[6:0]   : s_q[6:0];
	assign s_out[13:7]  = zero_s_r[1] ? c_mid[13:7]  : s_q[13:7];
	assign s_out[20:14] = zero_s_r[2] ? c_mid[20:14] : s_q[20:14];
	assign s_out[26:21] = zero_s_r[3] ? c_mid[26:21] : s_q[26:21];
	assign t_out[6:0]   = zero_t_r[0] ? c_mid[6:0]   : t_q[6:0];
	assign t_out[13:7]  = zero_t_r[1] ? c_mid[13:7]  : t_q[13:7];
	assign t_out[20:14] = zero_t_r[2] ? c_mid[20:14] : t_q[20:14];
	assign t_out[26:21] = zero_t_r[3] ? c_mid[26:21] : t_q[26:21];
	assign s = s_out;
	assign t = t_out;

	wire unused_ok = &{1'b0, vm[31], vm_w[31], carry_unused, cmp_zx_d, cmp_zy_d, cmp_yx_d, ns_num[26:2], nt_num[26:2],
	                   f_vm_0[0], f_vm_1[0], f_vm_2[0], f_vm_3[0], f_vs_lo[0], f_vs_hi[0], f_vt_lo[0], f_vt_hi[0]};	/* |ma|: the sign of the major axis is the face's */

`else

	assign bsy = 1'b0;
	assign s = 27'sd0;
	assign t = 27'sd0;

	always @(posedge clk) begin
		if (!rst_n)
			face <= 3'd0;
		else
			face <= 3'd0;
	end

	wire unused_cube_stub = &{1'b0, go, x, y, z, fix, fface};

`endif

endmodule

`default_nettype wire
