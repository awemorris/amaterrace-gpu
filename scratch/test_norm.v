`timescale 1ns / 1ps
`default_nettype none

module test_norm (
	input wire clk,
	input wire [26:0] sum3,
	output reg [22:0] close_m
);

	/* Stage 1: Coarse range detect */
	/* 27 bits divided into four 7-bit blocks:
	 * B3: sum3[26:20] (7 bits)
	 * B2: sum3[19:13] (7 bits)
	 * B1: sum3[12:6]  (7 bits)
	 * B0: sum3[5:0]   (6 bits)
	 */
	wire has_b3 = |sum3[26:20];
	wire has_b2 = |sum3[19:13];
	wire has_b1 = |sum3[12:6];

	wire [1:0] c_sel = has_b3 ? 2'd0 :
	                   has_b2 ? 2'd1 :
	                   has_b1 ? 2'd2 : 2'd3;

	/* Coarse shift (4:1 mux per bit: 1 LUT6) */
	reg [26:0] c_vec;
	always @(*) begin
		case (c_sel)
		2'd0: c_vec = sum3;
		2'd1: c_vec = {sum3[19:0], 7'd0};
		2'd2: c_vec = {sum3[12:0], 14'd0};
		default: c_vec = {sum3[5:0], 21'd0};
		endcase
	end

	/* Fine shift: leading 1 is in c_vec[26:20] */
	reg [2:0] f_sel;
	always @(*) begin
		if (c_vec[26])      f_sel = 3'd0;
		else if (c_vec[25]) f_sel = 3'd1;
		else if (c_vec[24]) f_sel = 3'd2;
		else if (c_vec[23]) f_sel = 3'd3;
		else if (c_vec[22]) f_sel = 3'd4;
		else if (c_vec[21]) f_sel = 3'd5;
		else                f_sel = 3'd6;
	end

	reg [26:0] f_vec;
	always @(*) begin
		case (f_sel)
		3'd0: f_vec = c_vec;
		3'd1: f_vec = {c_vec[25:0], 1'b0};
		3'd2: f_vec = {c_vec[24:0], 2'b00};
		3'd3: f_vec = {c_vec[23:0], 3'b000};
		3'd4: f_vec = {c_vec[22:0], 4'd0};
		3'd5: f_vec = {c_vec[21:0], 5'd0};
		default: f_vec = {c_vec[20:0], 6'd0};
		endcase
	end

	always @(posedge clk) begin
		close_m <= f_vec[25:3];
	end

endmodule
`default_nettype wire
