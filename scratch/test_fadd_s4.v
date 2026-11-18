`timescale 1ns / 1ps
`default_nettype none

module test_fadd_s4 (
	input wire clk,
	input wire rst_n,
	input wire v3,
	input wire sp3,
	input wire [31:0] spv3,
	input wire sx3,
	input wire sz3,
	input wire sub2_3,
	input wire [7:0] ex2_3,
	input wire [9:0] ex2_sub1_3,
	input wire [9:0] ex2_p1_3,
	input wire [9:0] ex2_p2_3,
	input wire [27:0] sum3,
	output reg [31:0] r_or,
	output reg r_ovalid
);

	/* Stage 4: Dual-path normalisation & rounding */

	/* Far path: lz <= 1 or addition */
	wire far_c = sum3[27];
	wire far_norm = sum3[26];
	wire [23:0] far_m_unrounded = far_c ? sum3[27:4] : (far_norm ? sum3[26:3] : sum3[25:2]);
	wire far_inc = far_c ? (sum3[3] && (|sum3[2:0] || sum3[4])) :
	               far_norm ? (sum3[2] && (|sum3[1:0] || sum3[3])) :
	               (sum3[1] && (sum3[0] || sum3[2]));

	wire [3:0] g_p;
	assign g_p[0] = &far_m_unrounded[5:0];
	assign g_p[1] = &far_m_unrounded[11:6];
	assign g_p[2] = &far_m_unrounded[17:12];
	assign g_p[3] = &far_m_unrounded[23:18];

	wire [3:0] g_cin;
	assign g_cin[0] = far_inc;
	assign g_cin[1] = far_inc & g_p[0];
	assign g_cin[2] = far_inc & g_p[0] & g_p[1];
	assign g_cin[3] = far_inc & g_p[0] & g_p[1] & g_p[2];
	wire far_cout = far_inc & (&g_p);

	wire [22:0] far_m_inc;
	genvar gi;
	generate
	for (gi = 0; gi < 23; gi = gi + 1) begin : g_fminc
		wire ci_g = g_cin[gi / 6];
		wire [gi % 6:0] slice = far_m_unrounded[(gi/6)*6 +: ((gi%6)+1)];
		assign far_m_inc[gi] = far_cout ? 1'b0 : (slice[gi%6] ^ (ci_g & (&slice)));
	end
	endgenerate

	wire [7:0] far_e = far_cout ? (far_c ? ex2_p2_3[7:0] : (far_norm ? ex2_p1_3[7:0] : ex2_3[7:0])) :
	                              (far_c ? ex2_p1_3[7:0] : (far_norm ? ex2_3[7:0]    : ex2_sub1_3[7:0]));
	wire far_ovf = (ex2_3 >= 8'd254) && (far_c || (far_cout && far_norm));
	wire far_unf = (ex2_3 <= 8'd1) && (!far_c && !far_norm && !far_cout);

	wire [31:0] far_r = far_ovf ? {sx3, 8'hFF, 23'd0} :
	                    far_unf ? {sx3, 31'd0} :
	                    {sx3, far_e, far_m_inc};

	/* Close path: large cancellation on subtraction (lz >= 2), result is exact (inc = 0) */
	/* Compute lz from sum3[26:0] */
	reg [4:0] lz;
	integer k;
	always @(*) begin
		lz = 5'd27;
		for (k = 0; k < 27; k = k + 1)
			if (sum3[k])
				lz = 5'd26 - k[4:0];
	end

	reg [26:0] nl_s1;
	always @(*) begin
		case (lz[1:0])
		2'd0: nl_s1 = sum3[26:0];
		2'd1: nl_s1 = {sum3[25:0], 1'b0};
		2'd2: nl_s1 = {sum3[24:0], 2'b00};
		default: nl_s1 = {sum3[23:0], 3'b000};
		endcase
	end

	reg [26:0] nl;
	always @(*) begin
		case (lz[4:2])
		3'd0: nl = nl_s1;
		3'd1: nl = {nl_s1[22:0], 4'd0};
		3'd2: nl = {nl_s1[18:0], 8'd0};
		3'd3: nl = {nl_s1[14:0], 12'd0};
		3'd4: nl = {nl_s1[10:0], 16'd0};
		3'd5: nl = {nl_s1[6:0], 20'd0};
		3'd6: nl = {nl_s1[2:0], 24'd0};
		default: nl = 27'd0;
		endcase
	end
	wire [22:0] close_m = nl[25:3];
	wire [7:0] close_e = ex2_3 - {3'd0, lz};
	wire close_unf = (ex2_3 <= {3'd0, lz});
	wire [31:0] close_r = close_unf ? {sx3, 31'd0} : {sx3, close_e, close_m};

	wire is_close = sub2_3 && (sum3[27:26] == 2'b00);

	wire [31:0] o_r_comb = sp3 ? spv3 :
	                       sz3 ? 32'd0 :
	                       is_close ? close_r : far_r;

	always @(posedge clk) begin
		r_ovalid <= rst_n && v3;
		r_or <= o_r_comb;
	end

endmodule
`default_nettype wire
