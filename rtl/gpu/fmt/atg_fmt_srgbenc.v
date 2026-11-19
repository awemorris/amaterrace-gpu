/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_srgbenc: the sRGB encoder of the ROP and the BLT: a linear fp32
 * colour component to the nearest 8-bit sRGB code (the code whose interval
 * of the sRGB EOTF holds it), by an 8-step binary search over the 255
 * thresholds of include/atg_srgb.vh (atg_srgb_thr: the smallest fp32 above
 * EOTF((c + 0.5) / 255)): the code is the count of thresholds <= x.  A
 * positive fp32 orders as its bits, so each step is an integer compare.
 * The step is a one-hot bit (2^7 down to 2^0) and below it the bits
 * under it: lo has no bit under the step, so lo + step - 1 is lo | below
 * and lo + step is lo | step (no adder, docs/style.md "Arithmetic").
 * NaN, negative values and -0 give 0; values >= 1 (and +infinity) 255.
 *
 * i_valid/i_ready: one component, taken in IDLE.  o_valid/o_ready: the
 * code, held until taken: o_valid comes 9 cycles after the accept (eight
 * steps), one component at a time.
 * spec/gpu/fmt/atg_fmt_srgbenc.md; mk/fmtmodel.py (srgb_encode) is the
 * reference.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_srgbenc (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	output wire i_ready,
	input wire [31:0] i_x,
	output wire o_valid,
	input wire o_ready,
	output wire [7:0] o_code
);
	`include "atg_srgb.vh"

	localparam [3:0]
		S_IDLE = 4'd0, S_C1 = 4'd1, S_C2 = 4'd2, S_C3 = 4'd3, S_C4 = 4'd4,
		S_C5   = 4'd5, S_C6 = 4'd6, S_C7 = 4'd7, S_C8 = 4'd8, S_OUT = 4'd9;

	function cmp_ge32;
		input [31:0] a;
		input [31:0] b;
		reg [3:0] gt, eq;
		begin
			gt[3] = a[31:24] > b[31:24]; eq[3] = (a[31:24] == b[31:24]);
			gt[2] = a[23:16] > b[23:16]; eq[2] = (a[23:16] == b[23:16]);
			gt[1] = a[15:8]  > b[15:8];  eq[1] = (a[15:8]  == b[15:8]);
			gt[0] = a[7:0]   >= b[7:0];  eq[0] = 1'b0;
			cmp_ge32 = gt[3] || (eq[3] && (gt[2] || (eq[2] && (gt[1] || (eq[1] && gt[0])))));
		end
	endfunction

	reg [3:0] state;
	reg [30:0] x;	/* the magnitude; the sign and NaN are folded to 0 on input */
	reg [7:0] lo;
	reg [31:0] t_mid, t_lo, t_hi, t_c3;

	wire [31:0] xf = {1'b0, x};
	wire c1_127 = cmp_ge32(xf, atg_srgb_thr(8'd127));
	wire c1_063 = cmp_ge32(xf, atg_srgb_thr(8'd63));
	wire c1_191 = cmp_ge32(xf, atg_srgb_thr(8'd191));
	wire c1_031 = cmp_ge32(xf, atg_srgb_thr(8'd31));
	wire c1_095 = cmp_ge32(xf, atg_srgb_thr(8'd95));
	wire c1_159 = cmp_ge32(xf, atg_srgb_thr(8'd159));
	wire c1_223 = cmp_ge32(xf, atg_srgb_thr(8'd223));

	wire cmp_mid = cmp_ge32(xf, t_mid);
	wire cmp_lo  = cmp_ge32(xf, t_lo);
	wire cmp_hi  = cmp_ge32(xf, t_hi);

	wire nan = i_x[30:23] == 8'hFF && i_x[22:0] != 23'd0;

	assign i_ready = state == S_IDLE;
	assign o_valid = state == S_OUT;
	assign o_code = lo;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state <= S_IDLE;
			x <= 31'd0;
			lo <= 8'd0;
			t_mid <= 32'd0;
			t_lo <= 32'd0;
			t_hi <= 32'd0;
			t_c3 <= 32'd0;
		end else begin
			case (state)
			S_IDLE:
				if (i_valid) begin
					x <= i_x[31] || nan ? 31'd0 : i_x[30:0];
					lo <= 8'd0;
					state <= S_C1;
				end
			S_C1: begin
				lo[7] <= c1_127;
				lo[6] <= c1_127 ? c1_191 : c1_063;
				lo[5] <= c1_127 ? (c1_191 ? c1_223 : c1_159) : (c1_063 ? c1_095 : c1_031);
				state <= S_C2;
			end
			S_C2: begin
				t_mid <= atg_srgb_thr({lo[7:5], 5'b01111});
				t_lo  <= atg_srgb_thr({lo[7:5], 5'b00111});
				t_hi  <= atg_srgb_thr({lo[7:5], 5'b10111});
				state <= S_C3;
			end
			S_C3: begin
				lo[4] <= cmp_mid;
				lo[3] <= cmp_mid ? cmp_hi : cmp_lo;
				state <= S_C4;
			end
			S_C4: begin
				t_mid <= atg_srgb_thr({lo[7:3], 3'b011});
				t_lo  <= atg_srgb_thr({lo[7:3], 3'b001});
				t_hi  <= atg_srgb_thr({lo[7:3], 3'b101});
				state <= S_C5;
			end
			S_C5: begin
				lo[2] <= cmp_mid;
				lo[1] <= cmp_mid ? cmp_hi : cmp_lo;
				state <= S_C6;
			end
			S_C6: begin
				t_lo  <= atg_srgb_thr({lo[7:3], 3'b000});
				t_mid <= atg_srgb_thr({lo[7:3], 3'b010});
				t_hi  <= atg_srgb_thr({lo[7:3], 3'b100});
				t_c3  <= atg_srgb_thr({lo[7:3], 3'b110});
				state <= S_C7;
			end
			S_C7: begin
				t_mid <= lo[2] ? (lo[1] ? t_c3 : t_hi) : (lo[1] ? t_mid : t_lo);
				state <= S_C8;
			end
			S_C8: begin
				lo[0] <= cmp_mid;
				state <= S_OUT;
			end
			S_OUT:
				if (o_ready)
					state <= S_IDLE;
			default:
				state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
