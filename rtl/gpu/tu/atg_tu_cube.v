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
	localparam IDLE = 1'b0, DIV = 1'b1;

	/* A component: zeros, denormals, NaN +0; infinities the largest finite. */
	function [31:0] comp;
		input [31:0] f;
		begin
			if (f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0))
				comp = 32'd0;
			else if (f[30:23] == 8'hFF)
				comp = {f[31], 31'h7F7FFFFF};
			else
				comp = f;
		end
	endfunction

	wire [31:0] cx = comp(x), cy = comp(y), cz = comp(z);
	wire az_wins = cz[30:0] >= cx[30:0] && cz[30:0] >= cy[30:0];
	wire ay_wins = cy[30:0] >= cx[30:0];
	wire [2:0] sel = az_wins ? {2'd2, cz[31]} : ay_wins ? {2'd1, cy[31]} : {2'd0, cx[31]};
	wire [2:0] f = fix ? fface : sel;
	/* Vulkan's table: major axis, s_c and t_c (with their signs). */
	reg [31:0] vm, vs, vt;
	reg ns, nt;
	always @(*) begin
		case (f)
		3'd0: begin vm = cx; vs = cz; ns = 1'b1; vt = cy; nt = 1'b1; end
		3'd1: begin vm = cx; vs = cz; ns = 1'b0; vt = cy; nt = 1'b1; end
		3'd2: begin vm = cy; vs = cx; ns = 1'b0; vt = cz; nt = 1'b0; end
		3'd3: begin vm = cy; vs = cx; ns = 1'b0; vt = cz; nt = 1'b1; end
		3'd4: begin vm = cz; vs = cx; ns = 1'b0; vt = cy; nt = 1'b1; end
		default: begin vm = cz; vs = cx; ns = 1'b1; vt = cy; nt = 1'b1; end
		endcase
	end
	wire [23:0] mm_in = {1'b1, vm[22:0]};
	/* s_c' and t_c' (atg_tu_cube_sc), from 3 m */
	wire [26:0] m3, sn_in, tn_in;
	wire [5:0] carry_unused;
	am_add #(.W(27)) u_m3 (.a({3'd0, mm_in}), .b({2'd0, mm_in, 1'b0}), .ci(1'b0), .s(m3),
		.co(carry_unused[0]));
	atg_tu_cube_sc u_sn (.v(vs), .neg(ns), .em(vm[30:23]), .m3(m3), .o(sn_in));
	atg_tu_cube_sc u_tn (.v(vt), .neg(nt), .em(vm[30:23]), .m3(m3), .o(tn_in));

	reg st;
	reg [4:0] n;
	reg zero;	/* a zero major axis */
	reg [23:0] mm;
	reg [26:0] ns_num, nt_num;	/* sc' + 3 m, tc' + 3 m */
	reg [24:0] rs, rt;
	reg [25:0] qs, qt;
	/* The numerator's next bit: num[2:0] then 23 zeros (num << 23). */
	reg bs, bt;	/* num[n - 23] for n >= 23 */
	integer b;
	always @(*) begin
		bs = 1'b0;
		bt = 1'b0;
		for (b = 0; b < 9; b = b + 1)
			if ({27'd0, n} == b + 23) begin
				bs = ns_num[b];
				bt = nt_num[b];
			end
	end
	wire [25:0] ts = {rs, bs}, tt = {rt, bt};
	wire gs = ts >= {2'b00, mm}, gt = tt >= {2'b00, mm};
	/* the remainders less m, n - 1, the quotients less 2^24 */
	wire [24:0] rs_m, rt_m;
	wire [4:0] n1;
	wire [26:0] s_q, t_q;
	am_sub #(.W(25)) u_rs_m (.a(ts[24:0]), .b({1'b0, mm}), .bi(1'b0), .d(rs_m), .bo(carry_unused[1]));
	am_sub #(.W(25)) u_rt_m (.a(tt[24:0]), .b({1'b0, mm}), .bi(1'b0), .d(rt_m), .bo(carry_unused[2]));
	am_sub #(.W(5)) u_n1 (.a(n), .b(5'd0), .bi(1'b1), .d(n1), .bo(carry_unused[3]));
	am_sub #(.W(27)) u_s_q (.a({1'b0, qs}), .b(27'd16777216), .bi(1'b0), .d(s_q), .bo(carry_unused[4]));
	am_sub #(.W(27)) u_t_q (.a({1'b0, qt}), .b(27'd16777216), .bi(1'b0), .d(t_q), .bo(carry_unused[5]));

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (go) begin
				face <= f;
				zero <= vm[30:23] == 8'd0;
				mm <= mm_in;
				ns_num <= sn_in;
				nt_num <= tn_in;
				rs <= {1'b0, sn_in[26:3]};
				rt <= {1'b0, tn_in[26:3]};
				n <= 5'd25;
				st <= DIV;
			end
			default: begin
				rs <= gs ? rs_m : ts[24:0];
				rt <= gt ? rt_m : tt[24:0];
				qs <= {qs[24:0], gs};
				qt <= {qt[24:0], gt};
				n <= n1;
				if (n == 5'd0)
					st <= IDLE;
			end
			endcase
		end
	end

	assign bsy = st == DIV;
	assign s = zero ? 27'sd8388608 : s_q;
	assign t = zero ? 27'sd8388608 : t_q;

	wire unused_ok = &{1'b0, vm[31]};	/* |ma|: the sign of the major axis is the face's */
endmodule

`default_nettype wire
