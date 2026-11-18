`timescale 1ns / 1ps
`default_nettype none

module am_mul_ref #(
	parameter AW = 18,
	parameter BW = 18,
	parameter SIGNED = 0,
	parameter LAT = 0
) (
	input wire clk,
	input wire en,
	input wire [AW-1:0] a,
	input wire [BW-1:0] b,
	output wire [AW+BW-1:0] p
);
	wire [AW+BW-1:0] m;
	generate
	if (SIGNED != 0) begin : g_s
		assign m = $signed(a) * $signed(b);
	end else begin : g_u
		assign m = a * b;
	end
	if (LAT == 0) begin : g_c
		assign p = m;
	end else begin : g_r
		reg [AW+BW-1:0] r [0:LAT-1];
		integer i;
		always @(posedge clk)
			if (en) begin
				r[0] <= m;
				for (i = 1; i < LAT; i = i + 1)
					r[i] <= r[i-1];
			end
		assign p = r[LAT-1];
	end
	endgenerate
endmodule

module am_mul_dsp_tb;
	reg clk;
	reg en;
	integer cycle;
	integer err_count;

	initial begin
		clk = 0;
		forever #5 clk = ~clk;
	end


	reg [7:0] a_1;
	reg [7:0] b_1;
	wire [15:0] p_ref_1;
	wire [15:0] p_dsp_1;

	am_mul_ref #(.AW(8), .BW(8), .SIGNED(0), .LAT(0)) u_ref_1 (
		.clk(clk), .en(en), .a(a_1), .b(b_1), .p(p_ref_1)
	);

	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(0)) u_dsp_1 (
		.clk(clk), .en(en), .a(a_1), .b(b_1), .p(p_dsp_1)
	);

	reg [7:0] a_2;
	reg [7:0] b_2;
	wire [15:0] p_ref_2;
	wire [15:0] p_dsp_2;

	am_mul_ref #(.AW(8), .BW(8), .SIGNED(0), .LAT(1)) u_ref_2 (
		.clk(clk), .en(en), .a(a_2), .b(b_2), .p(p_ref_2)
	);

	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(1)) u_dsp_2 (
		.clk(clk), .en(en), .a(a_2), .b(b_2), .p(p_dsp_2)
	);

	reg [7:0] a_3;
	reg [7:0] b_3;
	wire [15:0] p_ref_3;
	wire [15:0] p_dsp_3;

	am_mul_ref #(.AW(8), .BW(8), .SIGNED(0), .LAT(2)) u_ref_3 (
		.clk(clk), .en(en), .a(a_3), .b(b_3), .p(p_ref_3)
	);

	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(2)) u_dsp_3 (
		.clk(clk), .en(en), .a(a_3), .b(b_3), .p(p_dsp_3)
	);

	reg [7:0] a_4;
	reg [7:0] b_4;
	wire [15:0] p_ref_4;
	wire [15:0] p_dsp_4;

	am_mul_ref #(.AW(8), .BW(8), .SIGNED(0), .LAT(3)) u_ref_4 (
		.clk(clk), .en(en), .a(a_4), .b(b_4), .p(p_ref_4)
	);

	am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(3)) u_dsp_4 (
		.clk(clk), .en(en), .a(a_4), .b(b_4), .p(p_dsp_4)
	);

	reg [8:0] a_5;
	reg [8:0] b_5;
	wire [17:0] p_ref_5;
	wire [17:0] p_dsp_5;

	am_mul_ref #(.AW(9), .BW(9), .SIGNED(0), .LAT(0)) u_ref_5 (
		.clk(clk), .en(en), .a(a_5), .b(b_5), .p(p_ref_5)
	);

	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(0)) u_dsp_5 (
		.clk(clk), .en(en), .a(a_5), .b(b_5), .p(p_dsp_5)
	);

	reg [8:0] a_6;
	reg [8:0] b_6;
	wire [17:0] p_ref_6;
	wire [17:0] p_dsp_6;

	am_mul_ref #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_ref_6 (
		.clk(clk), .en(en), .a(a_6), .b(b_6), .p(p_ref_6)
	);

	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_dsp_6 (
		.clk(clk), .en(en), .a(a_6), .b(b_6), .p(p_dsp_6)
	);

	reg [8:0] a_7;
	reg [8:0] b_7;
	wire [17:0] p_ref_7;
	wire [17:0] p_dsp_7;

	am_mul_ref #(.AW(9), .BW(9), .SIGNED(0), .LAT(2)) u_ref_7 (
		.clk(clk), .en(en), .a(a_7), .b(b_7), .p(p_ref_7)
	);

	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(2)) u_dsp_7 (
		.clk(clk), .en(en), .a(a_7), .b(b_7), .p(p_dsp_7)
	);

	reg [8:0] a_8;
	reg [8:0] b_8;
	wire [17:0] p_ref_8;
	wire [17:0] p_dsp_8;

	am_mul_ref #(.AW(9), .BW(9), .SIGNED(0), .LAT(3)) u_ref_8 (
		.clk(clk), .en(en), .a(a_8), .b(b_8), .p(p_ref_8)
	);

	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(3)) u_dsp_8 (
		.clk(clk), .en(en), .a(a_8), .b(b_8), .p(p_dsp_8)
	);

	reg [15:0] a_9;
	reg [7:0] b_9;
	wire [23:0] p_ref_9;
	wire [23:0] p_dsp_9;

	am_mul_ref #(.AW(16), .BW(8), .SIGNED(0), .LAT(0)) u_ref_9 (
		.clk(clk), .en(en), .a(a_9), .b(b_9), .p(p_ref_9)
	);

	am_mul #(.AW(16), .BW(8), .SIGNED(0), .LAT(0)) u_dsp_9 (
		.clk(clk), .en(en), .a(a_9), .b(b_9), .p(p_dsp_9)
	);

	reg [15:0] a_10;
	reg [7:0] b_10;
	wire [23:0] p_ref_10;
	wire [23:0] p_dsp_10;

	am_mul_ref #(.AW(16), .BW(8), .SIGNED(0), .LAT(1)) u_ref_10 (
		.clk(clk), .en(en), .a(a_10), .b(b_10), .p(p_ref_10)
	);

	am_mul #(.AW(16), .BW(8), .SIGNED(0), .LAT(1)) u_dsp_10 (
		.clk(clk), .en(en), .a(a_10), .b(b_10), .p(p_dsp_10)
	);

	reg [15:0] a_11;
	reg [7:0] b_11;
	wire [23:0] p_ref_11;
	wire [23:0] p_dsp_11;

	am_mul_ref #(.AW(16), .BW(8), .SIGNED(0), .LAT(2)) u_ref_11 (
		.clk(clk), .en(en), .a(a_11), .b(b_11), .p(p_ref_11)
	);

	am_mul #(.AW(16), .BW(8), .SIGNED(0), .LAT(2)) u_dsp_11 (
		.clk(clk), .en(en), .a(a_11), .b(b_11), .p(p_dsp_11)
	);

	reg [15:0] a_12;
	reg [7:0] b_12;
	wire [23:0] p_ref_12;
	wire [23:0] p_dsp_12;

	am_mul_ref #(.AW(16), .BW(8), .SIGNED(0), .LAT(3)) u_ref_12 (
		.clk(clk), .en(en), .a(a_12), .b(b_12), .p(p_ref_12)
	);

	am_mul #(.AW(16), .BW(8), .SIGNED(0), .LAT(3)) u_dsp_12 (
		.clk(clk), .en(en), .a(a_12), .b(b_12), .p(p_dsp_12)
	);

	reg [7:0] a_13;
	reg [16:0] b_13;
	wire [24:0] p_ref_13;
	wire [24:0] p_dsp_13;

	am_mul_ref #(.AW(8), .BW(17), .SIGNED(0), .LAT(0)) u_ref_13 (
		.clk(clk), .en(en), .a(a_13), .b(b_13), .p(p_ref_13)
	);

	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(0)) u_dsp_13 (
		.clk(clk), .en(en), .a(a_13), .b(b_13), .p(p_dsp_13)
	);

	reg [7:0] a_14;
	reg [16:0] b_14;
	wire [24:0] p_ref_14;
	wire [24:0] p_dsp_14;

	am_mul_ref #(.AW(8), .BW(17), .SIGNED(0), .LAT(1)) u_ref_14 (
		.clk(clk), .en(en), .a(a_14), .b(b_14), .p(p_ref_14)
	);

	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(1)) u_dsp_14 (
		.clk(clk), .en(en), .a(a_14), .b(b_14), .p(p_dsp_14)
	);

	reg [7:0] a_15;
	reg [16:0] b_15;
	wire [24:0] p_ref_15;
	wire [24:0] p_dsp_15;

	am_mul_ref #(.AW(8), .BW(17), .SIGNED(0), .LAT(2)) u_ref_15 (
		.clk(clk), .en(en), .a(a_15), .b(b_15), .p(p_ref_15)
	);

	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(2)) u_dsp_15 (
		.clk(clk), .en(en), .a(a_15), .b(b_15), .p(p_dsp_15)
	);

	reg [7:0] a_16;
	reg [16:0] b_16;
	wire [24:0] p_ref_16;
	wire [24:0] p_dsp_16;

	am_mul_ref #(.AW(8), .BW(17), .SIGNED(0), .LAT(3)) u_ref_16 (
		.clk(clk), .en(en), .a(a_16), .b(b_16), .p(p_ref_16)
	);

	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(3)) u_dsp_16 (
		.clk(clk), .en(en), .a(a_16), .b(b_16), .p(p_dsp_16)
	);

	reg [15:0] a_17;
	reg [15:0] b_17;
	wire [31:0] p_ref_17;
	wire [31:0] p_dsp_17;

	am_mul_ref #(.AW(16), .BW(16), .SIGNED(0), .LAT(0)) u_ref_17 (
		.clk(clk), .en(en), .a(a_17), .b(b_17), .p(p_ref_17)
	);

	am_mul #(.AW(16), .BW(16), .SIGNED(0), .LAT(0)) u_dsp_17 (
		.clk(clk), .en(en), .a(a_17), .b(b_17), .p(p_dsp_17)
	);

	reg [15:0] a_18;
	reg [15:0] b_18;
	wire [31:0] p_ref_18;
	wire [31:0] p_dsp_18;

	am_mul_ref #(.AW(16), .BW(16), .SIGNED(0), .LAT(1)) u_ref_18 (
		.clk(clk), .en(en), .a(a_18), .b(b_18), .p(p_ref_18)
	);

	am_mul #(.AW(16), .BW(16), .SIGNED(0), .LAT(1)) u_dsp_18 (
		.clk(clk), .en(en), .a(a_18), .b(b_18), .p(p_dsp_18)
	);

	reg [15:0] a_19;
	reg [15:0] b_19;
	wire [31:0] p_ref_19;
	wire [31:0] p_dsp_19;

	am_mul_ref #(.AW(16), .BW(16), .SIGNED(0), .LAT(2)) u_ref_19 (
		.clk(clk), .en(en), .a(a_19), .b(b_19), .p(p_ref_19)
	);

	am_mul #(.AW(16), .BW(16), .SIGNED(0), .LAT(2)) u_dsp_19 (
		.clk(clk), .en(en), .a(a_19), .b(b_19), .p(p_dsp_19)
	);

	reg [15:0] a_20;
	reg [15:0] b_20;
	wire [31:0] p_ref_20;
	wire [31:0] p_dsp_20;

	am_mul_ref #(.AW(16), .BW(16), .SIGNED(0), .LAT(3)) u_ref_20 (
		.clk(clk), .en(en), .a(a_20), .b(b_20), .p(p_ref_20)
	);

	am_mul #(.AW(16), .BW(16), .SIGNED(0), .LAT(3)) u_dsp_20 (
		.clk(clk), .en(en), .a(a_20), .b(b_20), .p(p_dsp_20)
	);

	reg [16:0] a_21;
	reg [15:0] b_21;
	wire [32:0] p_ref_21;
	wire [32:0] p_dsp_21;

	am_mul_ref #(.AW(17), .BW(16), .SIGNED(0), .LAT(0)) u_ref_21 (
		.clk(clk), .en(en), .a(a_21), .b(b_21), .p(p_ref_21)
	);

	am_mul #(.AW(17), .BW(16), .SIGNED(0), .LAT(0)) u_dsp_21 (
		.clk(clk), .en(en), .a(a_21), .b(b_21), .p(p_dsp_21)
	);

	reg [16:0] a_22;
	reg [15:0] b_22;
	wire [32:0] p_ref_22;
	wire [32:0] p_dsp_22;

	am_mul_ref #(.AW(17), .BW(16), .SIGNED(0), .LAT(1)) u_ref_22 (
		.clk(clk), .en(en), .a(a_22), .b(b_22), .p(p_ref_22)
	);

	am_mul #(.AW(17), .BW(16), .SIGNED(0), .LAT(1)) u_dsp_22 (
		.clk(clk), .en(en), .a(a_22), .b(b_22), .p(p_dsp_22)
	);

	reg [16:0] a_23;
	reg [15:0] b_23;
	wire [32:0] p_ref_23;
	wire [32:0] p_dsp_23;

	am_mul_ref #(.AW(17), .BW(16), .SIGNED(0), .LAT(2)) u_ref_23 (
		.clk(clk), .en(en), .a(a_23), .b(b_23), .p(p_ref_23)
	);

	am_mul #(.AW(17), .BW(16), .SIGNED(0), .LAT(2)) u_dsp_23 (
		.clk(clk), .en(en), .a(a_23), .b(b_23), .p(p_dsp_23)
	);

	reg [16:0] a_24;
	reg [15:0] b_24;
	wire [32:0] p_ref_24;
	wire [32:0] p_dsp_24;

	am_mul_ref #(.AW(17), .BW(16), .SIGNED(0), .LAT(3)) u_ref_24 (
		.clk(clk), .en(en), .a(a_24), .b(b_24), .p(p_ref_24)
	);

	am_mul #(.AW(17), .BW(16), .SIGNED(0), .LAT(3)) u_dsp_24 (
		.clk(clk), .en(en), .a(a_24), .b(b_24), .p(p_dsp_24)
	);

	reg [15:0] a_25;
	reg [16:0] b_25;
	wire [32:0] p_ref_25;
	wire [32:0] p_dsp_25;

	am_mul_ref #(.AW(16), .BW(17), .SIGNED(0), .LAT(0)) u_ref_25 (
		.clk(clk), .en(en), .a(a_25), .b(b_25), .p(p_ref_25)
	);

	am_mul #(.AW(16), .BW(17), .SIGNED(0), .LAT(0)) u_dsp_25 (
		.clk(clk), .en(en), .a(a_25), .b(b_25), .p(p_dsp_25)
	);

	reg [15:0] a_26;
	reg [16:0] b_26;
	wire [32:0] p_ref_26;
	wire [32:0] p_dsp_26;

	am_mul_ref #(.AW(16), .BW(17), .SIGNED(0), .LAT(1)) u_ref_26 (
		.clk(clk), .en(en), .a(a_26), .b(b_26), .p(p_ref_26)
	);

	am_mul #(.AW(16), .BW(17), .SIGNED(0), .LAT(1)) u_dsp_26 (
		.clk(clk), .en(en), .a(a_26), .b(b_26), .p(p_dsp_26)
	);

	reg [15:0] a_27;
	reg [16:0] b_27;
	wire [32:0] p_ref_27;
	wire [32:0] p_dsp_27;

	am_mul_ref #(.AW(16), .BW(17), .SIGNED(0), .LAT(2)) u_ref_27 (
		.clk(clk), .en(en), .a(a_27), .b(b_27), .p(p_ref_27)
	);

	am_mul #(.AW(16), .BW(17), .SIGNED(0), .LAT(2)) u_dsp_27 (
		.clk(clk), .en(en), .a(a_27), .b(b_27), .p(p_dsp_27)
	);

	reg [15:0] a_28;
	reg [16:0] b_28;
	wire [32:0] p_ref_28;
	wire [32:0] p_dsp_28;

	am_mul_ref #(.AW(16), .BW(17), .SIGNED(0), .LAT(3)) u_ref_28 (
		.clk(clk), .en(en), .a(a_28), .b(b_28), .p(p_ref_28)
	);

	am_mul #(.AW(16), .BW(17), .SIGNED(0), .LAT(3)) u_dsp_28 (
		.clk(clk), .en(en), .a(a_28), .b(b_28), .p(p_dsp_28)
	);

	reg [23:0] a_29;
	reg [16:0] b_29;
	wire [40:0] p_ref_29;
	wire [40:0] p_dsp_29;

	am_mul_ref #(.AW(24), .BW(17), .SIGNED(0), .LAT(0)) u_ref_29 (
		.clk(clk), .en(en), .a(a_29), .b(b_29), .p(p_ref_29)
	);

	am_mul #(.AW(24), .BW(17), .SIGNED(0), .LAT(0)) u_dsp_29 (
		.clk(clk), .en(en), .a(a_29), .b(b_29), .p(p_dsp_29)
	);

	reg [23:0] a_30;
	reg [16:0] b_30;
	wire [40:0] p_ref_30;
	wire [40:0] p_dsp_30;

	am_mul_ref #(.AW(24), .BW(17), .SIGNED(0), .LAT(1)) u_ref_30 (
		.clk(clk), .en(en), .a(a_30), .b(b_30), .p(p_ref_30)
	);

	am_mul #(.AW(24), .BW(17), .SIGNED(0), .LAT(1)) u_dsp_30 (
		.clk(clk), .en(en), .a(a_30), .b(b_30), .p(p_dsp_30)
	);

	reg [23:0] a_31;
	reg [16:0] b_31;
	wire [40:0] p_ref_31;
	wire [40:0] p_dsp_31;

	am_mul_ref #(.AW(24), .BW(17), .SIGNED(0), .LAT(2)) u_ref_31 (
		.clk(clk), .en(en), .a(a_31), .b(b_31), .p(p_ref_31)
	);

	am_mul #(.AW(24), .BW(17), .SIGNED(0), .LAT(2)) u_dsp_31 (
		.clk(clk), .en(en), .a(a_31), .b(b_31), .p(p_dsp_31)
	);

	reg [23:0] a_32;
	reg [16:0] b_32;
	wire [40:0] p_ref_32;
	wire [40:0] p_dsp_32;

	am_mul_ref #(.AW(24), .BW(17), .SIGNED(0), .LAT(3)) u_ref_32 (
		.clk(clk), .en(en), .a(a_32), .b(b_32), .p(p_ref_32)
	);

	am_mul #(.AW(24), .BW(17), .SIGNED(0), .LAT(3)) u_dsp_32 (
		.clk(clk), .en(en), .a(a_32), .b(b_32), .p(p_dsp_32)
	);

	reg [17:0] a_33;
	reg [17:0] b_33;
	wire [35:0] p_ref_33;
	wire [35:0] p_dsp_33;

	am_mul_ref #(.AW(18), .BW(18), .SIGNED(0), .LAT(0)) u_ref_33 (
		.clk(clk), .en(en), .a(a_33), .b(b_33), .p(p_ref_33)
	);

	am_mul #(.AW(18), .BW(18), .SIGNED(0), .LAT(0)) u_dsp_33 (
		.clk(clk), .en(en), .a(a_33), .b(b_33), .p(p_dsp_33)
	);

	reg [17:0] a_34;
	reg [17:0] b_34;
	wire [35:0] p_ref_34;
	wire [35:0] p_dsp_34;

	am_mul_ref #(.AW(18), .BW(18), .SIGNED(0), .LAT(1)) u_ref_34 (
		.clk(clk), .en(en), .a(a_34), .b(b_34), .p(p_ref_34)
	);

	am_mul #(.AW(18), .BW(18), .SIGNED(0), .LAT(1)) u_dsp_34 (
		.clk(clk), .en(en), .a(a_34), .b(b_34), .p(p_dsp_34)
	);

	reg [17:0] a_35;
	reg [17:0] b_35;
	wire [35:0] p_ref_35;
	wire [35:0] p_dsp_35;

	am_mul_ref #(.AW(18), .BW(18), .SIGNED(0), .LAT(2)) u_ref_35 (
		.clk(clk), .en(en), .a(a_35), .b(b_35), .p(p_ref_35)
	);

	am_mul #(.AW(18), .BW(18), .SIGNED(0), .LAT(2)) u_dsp_35 (
		.clk(clk), .en(en), .a(a_35), .b(b_35), .p(p_dsp_35)
	);

	reg [17:0] a_36;
	reg [17:0] b_36;
	wire [35:0] p_ref_36;
	wire [35:0] p_dsp_36;

	am_mul_ref #(.AW(18), .BW(18), .SIGNED(0), .LAT(3)) u_ref_36 (
		.clk(clk), .en(en), .a(a_36), .b(b_36), .p(p_ref_36)
	);

	am_mul #(.AW(18), .BW(18), .SIGNED(0), .LAT(3)) u_dsp_36 (
		.clk(clk), .en(en), .a(a_36), .b(b_36), .p(p_dsp_36)
	);

	reg [23:0] a_37;
	reg [23:0] b_37;
	wire [47:0] p_ref_37;
	wire [47:0] p_dsp_37;

	am_mul_ref #(.AW(24), .BW(24), .SIGNED(0), .LAT(0)) u_ref_37 (
		.clk(clk), .en(en), .a(a_37), .b(b_37), .p(p_ref_37)
	);

	am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(0)) u_dsp_37 (
		.clk(clk), .en(en), .a(a_37), .b(b_37), .p(p_dsp_37)
	);

	reg [23:0] a_38;
	reg [23:0] b_38;
	wire [47:0] p_ref_38;
	wire [47:0] p_dsp_38;

	am_mul_ref #(.AW(24), .BW(24), .SIGNED(0), .LAT(1)) u_ref_38 (
		.clk(clk), .en(en), .a(a_38), .b(b_38), .p(p_ref_38)
	);

	am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(1)) u_dsp_38 (
		.clk(clk), .en(en), .a(a_38), .b(b_38), .p(p_dsp_38)
	);

	reg [23:0] a_39;
	reg [23:0] b_39;
	wire [47:0] p_ref_39;
	wire [47:0] p_dsp_39;

	am_mul_ref #(.AW(24), .BW(24), .SIGNED(0), .LAT(2)) u_ref_39 (
		.clk(clk), .en(en), .a(a_39), .b(b_39), .p(p_ref_39)
	);

	am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(2)) u_dsp_39 (
		.clk(clk), .en(en), .a(a_39), .b(b_39), .p(p_dsp_39)
	);

	reg [23:0] a_40;
	reg [23:0] b_40;
	wire [47:0] p_ref_40;
	wire [47:0] p_dsp_40;

	am_mul_ref #(.AW(24), .BW(24), .SIGNED(0), .LAT(3)) u_ref_40 (
		.clk(clk), .en(en), .a(a_40), .b(b_40), .p(p_ref_40)
	);

	am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(3)) u_dsp_40 (
		.clk(clk), .en(en), .a(a_40), .b(b_40), .p(p_dsp_40)
	);

	reg [31:0] a_41;
	reg [2:0] b_41;
	wire [34:0] p_ref_41;
	wire [34:0] p_dsp_41;

	am_mul_ref #(.AW(32), .BW(3), .SIGNED(0), .LAT(0)) u_ref_41 (
		.clk(clk), .en(en), .a(a_41), .b(b_41), .p(p_ref_41)
	);

	am_mul #(.AW(32), .BW(3), .SIGNED(0), .LAT(0)) u_dsp_41 (
		.clk(clk), .en(en), .a(a_41), .b(b_41), .p(p_dsp_41)
	);

	reg [31:0] a_42;
	reg [2:0] b_42;
	wire [34:0] p_ref_42;
	wire [34:0] p_dsp_42;

	am_mul_ref #(.AW(32), .BW(3), .SIGNED(0), .LAT(1)) u_ref_42 (
		.clk(clk), .en(en), .a(a_42), .b(b_42), .p(p_ref_42)
	);

	am_mul #(.AW(32), .BW(3), .SIGNED(0), .LAT(1)) u_dsp_42 (
		.clk(clk), .en(en), .a(a_42), .b(b_42), .p(p_dsp_42)
	);

	reg [31:0] a_43;
	reg [2:0] b_43;
	wire [34:0] p_ref_43;
	wire [34:0] p_dsp_43;

	am_mul_ref #(.AW(32), .BW(3), .SIGNED(0), .LAT(2)) u_ref_43 (
		.clk(clk), .en(en), .a(a_43), .b(b_43), .p(p_ref_43)
	);

	am_mul #(.AW(32), .BW(3), .SIGNED(0), .LAT(2)) u_dsp_43 (
		.clk(clk), .en(en), .a(a_43), .b(b_43), .p(p_dsp_43)
	);

	reg [31:0] a_44;
	reg [2:0] b_44;
	wire [34:0] p_ref_44;
	wire [34:0] p_dsp_44;

	am_mul_ref #(.AW(32), .BW(3), .SIGNED(0), .LAT(3)) u_ref_44 (
		.clk(clk), .en(en), .a(a_44), .b(b_44), .p(p_ref_44)
	);

	am_mul #(.AW(32), .BW(3), .SIGNED(0), .LAT(3)) u_dsp_44 (
		.clk(clk), .en(en), .a(a_44), .b(b_44), .p(p_dsp_44)
	);

	reg [31:0] a_45;
	reg [15:0] b_45;
	wire [47:0] p_ref_45;
	wire [47:0] p_dsp_45;

	am_mul_ref #(.AW(32), .BW(16), .SIGNED(0), .LAT(0)) u_ref_45 (
		.clk(clk), .en(en), .a(a_45), .b(b_45), .p(p_ref_45)
	);

	am_mul #(.AW(32), .BW(16), .SIGNED(0), .LAT(0)) u_dsp_45 (
		.clk(clk), .en(en), .a(a_45), .b(b_45), .p(p_dsp_45)
	);

	reg [31:0] a_46;
	reg [15:0] b_46;
	wire [47:0] p_ref_46;
	wire [47:0] p_dsp_46;

	am_mul_ref #(.AW(32), .BW(16), .SIGNED(0), .LAT(1)) u_ref_46 (
		.clk(clk), .en(en), .a(a_46), .b(b_46), .p(p_ref_46)
	);

	am_mul #(.AW(32), .BW(16), .SIGNED(0), .LAT(1)) u_dsp_46 (
		.clk(clk), .en(en), .a(a_46), .b(b_46), .p(p_dsp_46)
	);

	reg [31:0] a_47;
	reg [15:0] b_47;
	wire [47:0] p_ref_47;
	wire [47:0] p_dsp_47;

	am_mul_ref #(.AW(32), .BW(16), .SIGNED(0), .LAT(2)) u_ref_47 (
		.clk(clk), .en(en), .a(a_47), .b(b_47), .p(p_ref_47)
	);

	am_mul #(.AW(32), .BW(16), .SIGNED(0), .LAT(2)) u_dsp_47 (
		.clk(clk), .en(en), .a(a_47), .b(b_47), .p(p_dsp_47)
	);

	reg [31:0] a_48;
	reg [15:0] b_48;
	wire [47:0] p_ref_48;
	wire [47:0] p_dsp_48;

	am_mul_ref #(.AW(32), .BW(16), .SIGNED(0), .LAT(3)) u_ref_48 (
		.clk(clk), .en(en), .a(a_48), .b(b_48), .p(p_ref_48)
	);

	am_mul #(.AW(32), .BW(16), .SIGNED(0), .LAT(3)) u_dsp_48 (
		.clk(clk), .en(en), .a(a_48), .b(b_48), .p(p_dsp_48)
	);

	reg [16:0] a_49;
	reg [31:0] b_49;
	wire [48:0] p_ref_49;
	wire [48:0] p_dsp_49;

	am_mul_ref #(.AW(17), .BW(32), .SIGNED(0), .LAT(0)) u_ref_49 (
		.clk(clk), .en(en), .a(a_49), .b(b_49), .p(p_ref_49)
	);

	am_mul #(.AW(17), .BW(32), .SIGNED(0), .LAT(0)) u_dsp_49 (
		.clk(clk), .en(en), .a(a_49), .b(b_49), .p(p_dsp_49)
	);

	reg [16:0] a_50;
	reg [31:0] b_50;
	wire [48:0] p_ref_50;
	wire [48:0] p_dsp_50;

	am_mul_ref #(.AW(17), .BW(32), .SIGNED(0), .LAT(1)) u_ref_50 (
		.clk(clk), .en(en), .a(a_50), .b(b_50), .p(p_ref_50)
	);

	am_mul #(.AW(17), .BW(32), .SIGNED(0), .LAT(1)) u_dsp_50 (
		.clk(clk), .en(en), .a(a_50), .b(b_50), .p(p_dsp_50)
	);

	reg [16:0] a_51;
	reg [31:0] b_51;
	wire [48:0] p_ref_51;
	wire [48:0] p_dsp_51;

	am_mul_ref #(.AW(17), .BW(32), .SIGNED(0), .LAT(2)) u_ref_51 (
		.clk(clk), .en(en), .a(a_51), .b(b_51), .p(p_ref_51)
	);

	am_mul #(.AW(17), .BW(32), .SIGNED(0), .LAT(2)) u_dsp_51 (
		.clk(clk), .en(en), .a(a_51), .b(b_51), .p(p_dsp_51)
	);

	reg [16:0] a_52;
	reg [31:0] b_52;
	wire [48:0] p_ref_52;
	wire [48:0] p_dsp_52;

	am_mul_ref #(.AW(17), .BW(32), .SIGNED(0), .LAT(3)) u_ref_52 (
		.clk(clk), .en(en), .a(a_52), .b(b_52), .p(p_ref_52)
	);

	am_mul #(.AW(17), .BW(32), .SIGNED(0), .LAT(3)) u_dsp_52 (
		.clk(clk), .en(en), .a(a_52), .b(b_52), .p(p_dsp_52)
	);

	reg [24:0] a_53;
	reg [24:0] b_53;
	wire [49:0] p_ref_53;
	wire [49:0] p_dsp_53;

	am_mul_ref #(.AW(25), .BW(25), .SIGNED(1), .LAT(0)) u_ref_53 (
		.clk(clk), .en(en), .a(a_53), .b(b_53), .p(p_ref_53)
	);

	am_mul #(.AW(25), .BW(25), .SIGNED(1), .LAT(0)) u_dsp_53 (
		.clk(clk), .en(en), .a(a_53), .b(b_53), .p(p_dsp_53)
	);

	reg [24:0] a_54;
	reg [24:0] b_54;
	wire [49:0] p_ref_54;
	wire [49:0] p_dsp_54;

	am_mul_ref #(.AW(25), .BW(25), .SIGNED(1), .LAT(1)) u_ref_54 (
		.clk(clk), .en(en), .a(a_54), .b(b_54), .p(p_ref_54)
	);

	am_mul #(.AW(25), .BW(25), .SIGNED(1), .LAT(1)) u_dsp_54 (
		.clk(clk), .en(en), .a(a_54), .b(b_54), .p(p_dsp_54)
	);

	reg [24:0] a_55;
	reg [24:0] b_55;
	wire [49:0] p_ref_55;
	wire [49:0] p_dsp_55;

	am_mul_ref #(.AW(25), .BW(25), .SIGNED(1), .LAT(2)) u_ref_55 (
		.clk(clk), .en(en), .a(a_55), .b(b_55), .p(p_ref_55)
	);

	am_mul #(.AW(25), .BW(25), .SIGNED(1), .LAT(2)) u_dsp_55 (
		.clk(clk), .en(en), .a(a_55), .b(b_55), .p(p_dsp_55)
	);

	reg [24:0] a_56;
	reg [24:0] b_56;
	wire [49:0] p_ref_56;
	wire [49:0] p_dsp_56;

	am_mul_ref #(.AW(25), .BW(25), .SIGNED(1), .LAT(3)) u_ref_56 (
		.clk(clk), .en(en), .a(a_56), .b(b_56), .p(p_ref_56)
	);

	am_mul #(.AW(25), .BW(25), .SIGNED(1), .LAT(3)) u_dsp_56 (
		.clk(clk), .en(en), .a(a_56), .b(b_56), .p(p_dsp_56)
	);

	reg [26:0] a_57;
	reg [16:0] b_57;
	wire [43:0] p_ref_57;
	wire [43:0] p_dsp_57;

	am_mul_ref #(.AW(27), .BW(17), .SIGNED(1), .LAT(0)) u_ref_57 (
		.clk(clk), .en(en), .a(a_57), .b(b_57), .p(p_ref_57)
	);

	am_mul #(.AW(27), .BW(17), .SIGNED(1), .LAT(0)) u_dsp_57 (
		.clk(clk), .en(en), .a(a_57), .b(b_57), .p(p_dsp_57)
	);

	reg [26:0] a_58;
	reg [16:0] b_58;
	wire [43:0] p_ref_58;
	wire [43:0] p_dsp_58;

	am_mul_ref #(.AW(27), .BW(17), .SIGNED(1), .LAT(1)) u_ref_58 (
		.clk(clk), .en(en), .a(a_58), .b(b_58), .p(p_ref_58)
	);

	am_mul #(.AW(27), .BW(17), .SIGNED(1), .LAT(1)) u_dsp_58 (
		.clk(clk), .en(en), .a(a_58), .b(b_58), .p(p_dsp_58)
	);

	reg [26:0] a_59;
	reg [16:0] b_59;
	wire [43:0] p_ref_59;
	wire [43:0] p_dsp_59;

	am_mul_ref #(.AW(27), .BW(17), .SIGNED(1), .LAT(2)) u_ref_59 (
		.clk(clk), .en(en), .a(a_59), .b(b_59), .p(p_ref_59)
	);

	am_mul #(.AW(27), .BW(17), .SIGNED(1), .LAT(2)) u_dsp_59 (
		.clk(clk), .en(en), .a(a_59), .b(b_59), .p(p_dsp_59)
	);

	reg [26:0] a_60;
	reg [16:0] b_60;
	wire [43:0] p_ref_60;
	wire [43:0] p_dsp_60;

	am_mul_ref #(.AW(27), .BW(17), .SIGNED(1), .LAT(3)) u_ref_60 (
		.clk(clk), .en(en), .a(a_60), .b(b_60), .p(p_ref_60)
	);

	am_mul #(.AW(27), .BW(17), .SIGNED(1), .LAT(3)) u_dsp_60 (
		.clk(clk), .en(en), .a(a_60), .b(b_60), .p(p_dsp_60)
	);

	reg [29:0] a_61;
	reg [16:0] b_61;
	wire [46:0] p_ref_61;
	wire [46:0] p_dsp_61;

	am_mul_ref #(.AW(30), .BW(17), .SIGNED(1), .LAT(0)) u_ref_61 (
		.clk(clk), .en(en), .a(a_61), .b(b_61), .p(p_ref_61)
	);

	am_mul #(.AW(30), .BW(17), .SIGNED(1), .LAT(0)) u_dsp_61 (
		.clk(clk), .en(en), .a(a_61), .b(b_61), .p(p_dsp_61)
	);

	reg [29:0] a_62;
	reg [16:0] b_62;
	wire [46:0] p_ref_62;
	wire [46:0] p_dsp_62;

	am_mul_ref #(.AW(30), .BW(17), .SIGNED(1), .LAT(1)) u_ref_62 (
		.clk(clk), .en(en), .a(a_62), .b(b_62), .p(p_ref_62)
	);

	am_mul #(.AW(30), .BW(17), .SIGNED(1), .LAT(1)) u_dsp_62 (
		.clk(clk), .en(en), .a(a_62), .b(b_62), .p(p_dsp_62)
	);

	reg [29:0] a_63;
	reg [16:0] b_63;
	wire [46:0] p_ref_63;
	wire [46:0] p_dsp_63;

	am_mul_ref #(.AW(30), .BW(17), .SIGNED(1), .LAT(2)) u_ref_63 (
		.clk(clk), .en(en), .a(a_63), .b(b_63), .p(p_ref_63)
	);

	am_mul #(.AW(30), .BW(17), .SIGNED(1), .LAT(2)) u_dsp_63 (
		.clk(clk), .en(en), .a(a_63), .b(b_63), .p(p_dsp_63)
	);

	reg [29:0] a_64;
	reg [16:0] b_64;
	wire [46:0] p_ref_64;
	wire [46:0] p_dsp_64;

	am_mul_ref #(.AW(30), .BW(17), .SIGNED(1), .LAT(3)) u_ref_64 (
		.clk(clk), .en(en), .a(a_64), .b(b_64), .p(p_ref_64)
	);

	am_mul #(.AW(30), .BW(17), .SIGNED(1), .LAT(3)) u_dsp_64 (
		.clk(clk), .en(en), .a(a_64), .b(b_64), .p(p_dsp_64)
	);

	reg [23:0] a_65;
	reg [58:0] b_65;
	wire [82:0] p_ref_65;
	wire [82:0] p_dsp_65;

	am_mul_ref #(.AW(24), .BW(59), .SIGNED(0), .LAT(0)) u_ref_65 (
		.clk(clk), .en(en), .a(a_65), .b(b_65), .p(p_ref_65)
	);

	am_mul #(.AW(24), .BW(59), .SIGNED(0), .LAT(0)) u_dsp_65 (
		.clk(clk), .en(en), .a(a_65), .b(b_65), .p(p_dsp_65)
	);

	reg [23:0] a_66;
	reg [58:0] b_66;
	wire [82:0] p_ref_66;
	wire [82:0] p_dsp_66;

	am_mul_ref #(.AW(24), .BW(59), .SIGNED(0), .LAT(1)) u_ref_66 (
		.clk(clk), .en(en), .a(a_66), .b(b_66), .p(p_ref_66)
	);

	am_mul #(.AW(24), .BW(59), .SIGNED(0), .LAT(1)) u_dsp_66 (
		.clk(clk), .en(en), .a(a_66), .b(b_66), .p(p_dsp_66)
	);

	reg [23:0] a_67;
	reg [58:0] b_67;
	wire [82:0] p_ref_67;
	wire [82:0] p_dsp_67;

	am_mul_ref #(.AW(24), .BW(59), .SIGNED(0), .LAT(2)) u_ref_67 (
		.clk(clk), .en(en), .a(a_67), .b(b_67), .p(p_ref_67)
	);

	am_mul #(.AW(24), .BW(59), .SIGNED(0), .LAT(2)) u_dsp_67 (
		.clk(clk), .en(en), .a(a_67), .b(b_67), .p(p_dsp_67)
	);

	reg [23:0] a_68;
	reg [58:0] b_68;
	wire [82:0] p_ref_68;
	wire [82:0] p_dsp_68;

	am_mul_ref #(.AW(24), .BW(59), .SIGNED(0), .LAT(3)) u_ref_68 (
		.clk(clk), .en(en), .a(a_68), .b(b_68), .p(p_ref_68)
	);

	am_mul #(.AW(24), .BW(59), .SIGNED(0), .LAT(3)) u_dsp_68 (
		.clk(clk), .en(en), .a(a_68), .b(b_68), .p(p_dsp_68)
	);

	reg [32:0] a_69;
	reg [32:0] b_69;
	wire [65:0] p_ref_69;
	wire [65:0] p_dsp_69;

	am_mul_ref #(.AW(33), .BW(33), .SIGNED(1), .LAT(0)) u_ref_69 (
		.clk(clk), .en(en), .a(a_69), .b(b_69), .p(p_ref_69)
	);

	am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(0)) u_dsp_69 (
		.clk(clk), .en(en), .a(a_69), .b(b_69), .p(p_dsp_69)
	);

	reg [32:0] a_70;
	reg [32:0] b_70;
	wire [65:0] p_ref_70;
	wire [65:0] p_dsp_70;

	am_mul_ref #(.AW(33), .BW(33), .SIGNED(1), .LAT(1)) u_ref_70 (
		.clk(clk), .en(en), .a(a_70), .b(b_70), .p(p_ref_70)
	);

	am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(1)) u_dsp_70 (
		.clk(clk), .en(en), .a(a_70), .b(b_70), .p(p_dsp_70)
	);

	reg [32:0] a_71;
	reg [32:0] b_71;
	wire [65:0] p_ref_71;
	wire [65:0] p_dsp_71;

	am_mul_ref #(.AW(33), .BW(33), .SIGNED(1), .LAT(2)) u_ref_71 (
		.clk(clk), .en(en), .a(a_71), .b(b_71), .p(p_ref_71)
	);

	am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(2)) u_dsp_71 (
		.clk(clk), .en(en), .a(a_71), .b(b_71), .p(p_dsp_71)
	);

	reg [32:0] a_72;
	reg [32:0] b_72;
	wire [65:0] p_ref_72;
	wire [65:0] p_dsp_72;

	am_mul_ref #(.AW(33), .BW(33), .SIGNED(1), .LAT(3)) u_ref_72 (
		.clk(clk), .en(en), .a(a_72), .b(b_72), .p(p_ref_72)
	);

	am_mul #(.AW(33), .BW(33), .SIGNED(1), .LAT(3)) u_dsp_72 (
		.clk(clk), .en(en), .a(a_72), .b(b_72), .p(p_dsp_72)
	);

	reg [41:0] a_73;
	reg [41:0] b_73;
	wire [83:0] p_ref_73;
	wire [83:0] p_dsp_73;

	am_mul_ref #(.AW(42), .BW(42), .SIGNED(0), .LAT(0)) u_ref_73 (
		.clk(clk), .en(en), .a(a_73), .b(b_73), .p(p_ref_73)
	);

	am_mul #(.AW(42), .BW(42), .SIGNED(0), .LAT(0)) u_dsp_73 (
		.clk(clk), .en(en), .a(a_73), .b(b_73), .p(p_dsp_73)
	);

	reg [41:0] a_74;
	reg [41:0] b_74;
	wire [83:0] p_ref_74;
	wire [83:0] p_dsp_74;

	am_mul_ref #(.AW(42), .BW(42), .SIGNED(0), .LAT(1)) u_ref_74 (
		.clk(clk), .en(en), .a(a_74), .b(b_74), .p(p_ref_74)
	);

	am_mul #(.AW(42), .BW(42), .SIGNED(0), .LAT(1)) u_dsp_74 (
		.clk(clk), .en(en), .a(a_74), .b(b_74), .p(p_dsp_74)
	);

	reg [41:0] a_75;
	reg [41:0] b_75;
	wire [83:0] p_ref_75;
	wire [83:0] p_dsp_75;

	am_mul_ref #(.AW(42), .BW(42), .SIGNED(0), .LAT(2)) u_ref_75 (
		.clk(clk), .en(en), .a(a_75), .b(b_75), .p(p_ref_75)
	);

	am_mul #(.AW(42), .BW(42), .SIGNED(0), .LAT(2)) u_dsp_75 (
		.clk(clk), .en(en), .a(a_75), .b(b_75), .p(p_dsp_75)
	);

	reg [41:0] a_76;
	reg [41:0] b_76;
	wire [83:0] p_ref_76;
	wire [83:0] p_dsp_76;

	am_mul_ref #(.AW(42), .BW(42), .SIGNED(0), .LAT(3)) u_ref_76 (
		.clk(clk), .en(en), .a(a_76), .b(b_76), .p(p_ref_76)
	);

	am_mul #(.AW(42), .BW(42), .SIGNED(0), .LAT(3)) u_dsp_76 (
		.clk(clk), .en(en), .a(a_76), .b(b_76), .p(p_dsp_76)
	);

	initial begin
		err_count = 0;
		en = 1;
		a_1 = 0; b_1 = 0;
		a_2 = 0; b_2 = 0;
		a_3 = 0; b_3 = 0;
		a_4 = 0; b_4 = 0;
		a_5 = 0; b_5 = 0;
		a_6 = 0; b_6 = 0;
		a_7 = 0; b_7 = 0;
		a_8 = 0; b_8 = 0;
		a_9 = 0; b_9 = 0;
		a_10 = 0; b_10 = 0;
		a_11 = 0; b_11 = 0;
		a_12 = 0; b_12 = 0;
		a_13 = 0; b_13 = 0;
		a_14 = 0; b_14 = 0;
		a_15 = 0; b_15 = 0;
		a_16 = 0; b_16 = 0;
		a_17 = 0; b_17 = 0;
		a_18 = 0; b_18 = 0;
		a_19 = 0; b_19 = 0;
		a_20 = 0; b_20 = 0;
		a_21 = 0; b_21 = 0;
		a_22 = 0; b_22 = 0;
		a_23 = 0; b_23 = 0;
		a_24 = 0; b_24 = 0;
		a_25 = 0; b_25 = 0;
		a_26 = 0; b_26 = 0;
		a_27 = 0; b_27 = 0;
		a_28 = 0; b_28 = 0;
		a_29 = 0; b_29 = 0;
		a_30 = 0; b_30 = 0;
		a_31 = 0; b_31 = 0;
		a_32 = 0; b_32 = 0;
		a_33 = 0; b_33 = 0;
		a_34 = 0; b_34 = 0;
		a_35 = 0; b_35 = 0;
		a_36 = 0; b_36 = 0;
		a_37 = 0; b_37 = 0;
		a_38 = 0; b_38 = 0;
		a_39 = 0; b_39 = 0;
		a_40 = 0; b_40 = 0;
		a_41 = 0; b_41 = 0;
		a_42 = 0; b_42 = 0;
		a_43 = 0; b_43 = 0;
		a_44 = 0; b_44 = 0;
		a_45 = 0; b_45 = 0;
		a_46 = 0; b_46 = 0;
		a_47 = 0; b_47 = 0;
		a_48 = 0; b_48 = 0;
		a_49 = 0; b_49 = 0;
		a_50 = 0; b_50 = 0;
		a_51 = 0; b_51 = 0;
		a_52 = 0; b_52 = 0;
		a_53 = 0; b_53 = 0;
		a_54 = 0; b_54 = 0;
		a_55 = 0; b_55 = 0;
		a_56 = 0; b_56 = 0;
		a_57 = 0; b_57 = 0;
		a_58 = 0; b_58 = 0;
		a_59 = 0; b_59 = 0;
		a_60 = 0; b_60 = 0;
		a_61 = 0; b_61 = 0;
		a_62 = 0; b_62 = 0;
		a_63 = 0; b_63 = 0;
		a_64 = 0; b_64 = 0;
		a_65 = 0; b_65 = 0;
		a_66 = 0; b_66 = 0;
		a_67 = 0; b_67 = 0;
		a_68 = 0; b_68 = 0;
		a_69 = 0; b_69 = 0;
		a_70 = 0; b_70 = 0;
		a_71 = 0; b_71 = 0;
		a_72 = 0; b_72 = 0;
		a_73 = 0; b_73 = 0;
		a_74 = 0; b_74 = 0;
		a_75 = 0; b_75 = 0;
		a_76 = 0; b_76 = 0;

		// Wait 150 ns for GSR deassertion as specified in work-spec
		#150;
		@(posedge clk);

		// Run 300 cycles of random stimuli + random enable
		for (cycle = 0; cycle < 300; cycle = cycle + 1) begin
			@(negedge clk);
			en = ($random % 5) != 0; // 80% enable, 20% disable
			a_1 = {$random, $random, $random}; b_1 = {$random, $random, $random};
			a_2 = {$random, $random, $random}; b_2 = {$random, $random, $random};
			a_3 = {$random, $random, $random}; b_3 = {$random, $random, $random};
			a_4 = {$random, $random, $random}; b_4 = {$random, $random, $random};
			a_5 = {$random, $random, $random}; b_5 = {$random, $random, $random};
			a_6 = {$random, $random, $random}; b_6 = {$random, $random, $random};
			a_7 = {$random, $random, $random}; b_7 = {$random, $random, $random};
			a_8 = {$random, $random, $random}; b_8 = {$random, $random, $random};
			a_9 = {$random, $random, $random}; b_9 = {$random, $random, $random};
			a_10 = {$random, $random, $random}; b_10 = {$random, $random, $random};
			a_11 = {$random, $random, $random}; b_11 = {$random, $random, $random};
			a_12 = {$random, $random, $random}; b_12 = {$random, $random, $random};
			a_13 = {$random, $random, $random}; b_13 = {$random, $random, $random};
			a_14 = {$random, $random, $random}; b_14 = {$random, $random, $random};
			a_15 = {$random, $random, $random}; b_15 = {$random, $random, $random};
			a_16 = {$random, $random, $random}; b_16 = {$random, $random, $random};
			a_17 = {$random, $random, $random}; b_17 = {$random, $random, $random};
			a_18 = {$random, $random, $random}; b_18 = {$random, $random, $random};
			a_19 = {$random, $random, $random}; b_19 = {$random, $random, $random};
			a_20 = {$random, $random, $random}; b_20 = {$random, $random, $random};
			a_21 = {$random, $random, $random}; b_21 = {$random, $random, $random};
			a_22 = {$random, $random, $random}; b_22 = {$random, $random, $random};
			a_23 = {$random, $random, $random}; b_23 = {$random, $random, $random};
			a_24 = {$random, $random, $random}; b_24 = {$random, $random, $random};
			a_25 = {$random, $random, $random}; b_25 = {$random, $random, $random};
			a_26 = {$random, $random, $random}; b_26 = {$random, $random, $random};
			a_27 = {$random, $random, $random}; b_27 = {$random, $random, $random};
			a_28 = {$random, $random, $random}; b_28 = {$random, $random, $random};
			a_29 = {$random, $random, $random}; b_29 = {$random, $random, $random};
			a_30 = {$random, $random, $random}; b_30 = {$random, $random, $random};
			a_31 = {$random, $random, $random}; b_31 = {$random, $random, $random};
			a_32 = {$random, $random, $random}; b_32 = {$random, $random, $random};
			a_33 = {$random, $random, $random}; b_33 = {$random, $random, $random};
			a_34 = {$random, $random, $random}; b_34 = {$random, $random, $random};
			a_35 = {$random, $random, $random}; b_35 = {$random, $random, $random};
			a_36 = {$random, $random, $random}; b_36 = {$random, $random, $random};
			a_37 = {$random, $random, $random}; b_37 = {$random, $random, $random};
			a_38 = {$random, $random, $random}; b_38 = {$random, $random, $random};
			a_39 = {$random, $random, $random}; b_39 = {$random, $random, $random};
			a_40 = {$random, $random, $random}; b_40 = {$random, $random, $random};
			a_41 = {$random, $random, $random}; b_41 = {$random, $random, $random};
			a_42 = {$random, $random, $random}; b_42 = {$random, $random, $random};
			a_43 = {$random, $random, $random}; b_43 = {$random, $random, $random};
			a_44 = {$random, $random, $random}; b_44 = {$random, $random, $random};
			a_45 = {$random, $random, $random}; b_45 = {$random, $random, $random};
			a_46 = {$random, $random, $random}; b_46 = {$random, $random, $random};
			a_47 = {$random, $random, $random}; b_47 = {$random, $random, $random};
			a_48 = {$random, $random, $random}; b_48 = {$random, $random, $random};
			a_49 = {$random, $random, $random}; b_49 = {$random, $random, $random};
			a_50 = {$random, $random, $random}; b_50 = {$random, $random, $random};
			a_51 = {$random, $random, $random}; b_51 = {$random, $random, $random};
			a_52 = {$random, $random, $random}; b_52 = {$random, $random, $random};
			a_53 = {$random, $random, $random}; b_53 = {$random, $random, $random};
			a_54 = {$random, $random, $random}; b_54 = {$random, $random, $random};
			a_55 = {$random, $random, $random}; b_55 = {$random, $random, $random};
			a_56 = {$random, $random, $random}; b_56 = {$random, $random, $random};
			a_57 = {$random, $random, $random}; b_57 = {$random, $random, $random};
			a_58 = {$random, $random, $random}; b_58 = {$random, $random, $random};
			a_59 = {$random, $random, $random}; b_59 = {$random, $random, $random};
			a_60 = {$random, $random, $random}; b_60 = {$random, $random, $random};
			a_61 = {$random, $random, $random}; b_61 = {$random, $random, $random};
			a_62 = {$random, $random, $random}; b_62 = {$random, $random, $random};
			a_63 = {$random, $random, $random}; b_63 = {$random, $random, $random};
			a_64 = {$random, $random, $random}; b_64 = {$random, $random, $random};
			a_65 = {$random, $random, $random}; b_65 = {$random, $random, $random};
			a_66 = {$random, $random, $random}; b_66 = {$random, $random, $random};
			a_67 = {$random, $random, $random}; b_67 = {$random, $random, $random};
			a_68 = {$random, $random, $random}; b_68 = {$random, $random, $random};
			a_69 = {$random, $random, $random}; b_69 = {$random, $random, $random};
			a_70 = {$random, $random, $random}; b_70 = {$random, $random, $random};
			a_71 = {$random, $random, $random}; b_71 = {$random, $random, $random};
			a_72 = {$random, $random, $random}; b_72 = {$random, $random, $random};
			a_73 = {$random, $random, $random}; b_73 = {$random, $random, $random};
			a_74 = {$random, $random, $random}; b_74 = {$random, $random, $random};
			a_75 = {$random, $random, $random}; b_75 = {$random, $random, $random};
			a_76 = {$random, $random, $random}; b_76 = {$random, $random, $random};

			@(posedge clk);
			#1;
			if (cycle >= 10) begin
				if (p_ref_1 !== p_dsp_1) begin
					$display("FAIL cycle %0d inst 1 (8x8_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_1, p_dsp_1);
					err_count = err_count + 1;
				end
				if (p_ref_2 !== p_dsp_2) begin
					$display("FAIL cycle %0d inst 2 (8x8_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_2, p_dsp_2);
					err_count = err_count + 1;
				end
				if (p_ref_3 !== p_dsp_3) begin
					$display("FAIL cycle %0d inst 3 (8x8_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_3, p_dsp_3);
					err_count = err_count + 1;
				end
				if (p_ref_4 !== p_dsp_4) begin
					$display("FAIL cycle %0d inst 4 (8x8_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_4, p_dsp_4);
					err_count = err_count + 1;
				end
				if (p_ref_5 !== p_dsp_5) begin
					$display("FAIL cycle %0d inst 5 (9x9_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_5, p_dsp_5);
					err_count = err_count + 1;
				end
				if (p_ref_6 !== p_dsp_6) begin
					$display("FAIL cycle %0d inst 6 (9x9_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_6, p_dsp_6);
					err_count = err_count + 1;
				end
				if (p_ref_7 !== p_dsp_7) begin
					$display("FAIL cycle %0d inst 7 (9x9_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_7, p_dsp_7);
					err_count = err_count + 1;
				end
				if (p_ref_8 !== p_dsp_8) begin
					$display("FAIL cycle %0d inst 8 (9x9_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_8, p_dsp_8);
					err_count = err_count + 1;
				end
				if (p_ref_9 !== p_dsp_9) begin
					$display("FAIL cycle %0d inst 9 (16x8_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_9, p_dsp_9);
					err_count = err_count + 1;
				end
				if (p_ref_10 !== p_dsp_10) begin
					$display("FAIL cycle %0d inst 10 (16x8_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_10, p_dsp_10);
					err_count = err_count + 1;
				end
				if (p_ref_11 !== p_dsp_11) begin
					$display("FAIL cycle %0d inst 11 (16x8_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_11, p_dsp_11);
					err_count = err_count + 1;
				end
				if (p_ref_12 !== p_dsp_12) begin
					$display("FAIL cycle %0d inst 12 (16x8_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_12, p_dsp_12);
					err_count = err_count + 1;
				end
				if (p_ref_13 !== p_dsp_13) begin
					$display("FAIL cycle %0d inst 13 (8x17_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_13, p_dsp_13);
					err_count = err_count + 1;
				end
				if (p_ref_14 !== p_dsp_14) begin
					$display("FAIL cycle %0d inst 14 (8x17_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_14, p_dsp_14);
					err_count = err_count + 1;
				end
				if (p_ref_15 !== p_dsp_15) begin
					$display("FAIL cycle %0d inst 15 (8x17_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_15, p_dsp_15);
					err_count = err_count + 1;
				end
				if (p_ref_16 !== p_dsp_16) begin
					$display("FAIL cycle %0d inst 16 (8x17_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_16, p_dsp_16);
					err_count = err_count + 1;
				end
				if (p_ref_17 !== p_dsp_17) begin
					$display("FAIL cycle %0d inst 17 (16x16_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_17, p_dsp_17);
					err_count = err_count + 1;
				end
				if (p_ref_18 !== p_dsp_18) begin
					$display("FAIL cycle %0d inst 18 (16x16_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_18, p_dsp_18);
					err_count = err_count + 1;
				end
				if (p_ref_19 !== p_dsp_19) begin
					$display("FAIL cycle %0d inst 19 (16x16_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_19, p_dsp_19);
					err_count = err_count + 1;
				end
				if (p_ref_20 !== p_dsp_20) begin
					$display("FAIL cycle %0d inst 20 (16x16_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_20, p_dsp_20);
					err_count = err_count + 1;
				end
				if (p_ref_21 !== p_dsp_21) begin
					$display("FAIL cycle %0d inst 21 (17x16_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_21, p_dsp_21);
					err_count = err_count + 1;
				end
				if (p_ref_22 !== p_dsp_22) begin
					$display("FAIL cycle %0d inst 22 (17x16_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_22, p_dsp_22);
					err_count = err_count + 1;
				end
				if (p_ref_23 !== p_dsp_23) begin
					$display("FAIL cycle %0d inst 23 (17x16_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_23, p_dsp_23);
					err_count = err_count + 1;
				end
				if (p_ref_24 !== p_dsp_24) begin
					$display("FAIL cycle %0d inst 24 (17x16_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_24, p_dsp_24);
					err_count = err_count + 1;
				end
				if (p_ref_25 !== p_dsp_25) begin
					$display("FAIL cycle %0d inst 25 (16x17_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_25, p_dsp_25);
					err_count = err_count + 1;
				end
				if (p_ref_26 !== p_dsp_26) begin
					$display("FAIL cycle %0d inst 26 (16x17_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_26, p_dsp_26);
					err_count = err_count + 1;
				end
				if (p_ref_27 !== p_dsp_27) begin
					$display("FAIL cycle %0d inst 27 (16x17_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_27, p_dsp_27);
					err_count = err_count + 1;
				end
				if (p_ref_28 !== p_dsp_28) begin
					$display("FAIL cycle %0d inst 28 (16x17_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_28, p_dsp_28);
					err_count = err_count + 1;
				end
				if (p_ref_29 !== p_dsp_29) begin
					$display("FAIL cycle %0d inst 29 (24x17_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_29, p_dsp_29);
					err_count = err_count + 1;
				end
				if (p_ref_30 !== p_dsp_30) begin
					$display("FAIL cycle %0d inst 30 (24x17_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_30, p_dsp_30);
					err_count = err_count + 1;
				end
				if (p_ref_31 !== p_dsp_31) begin
					$display("FAIL cycle %0d inst 31 (24x17_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_31, p_dsp_31);
					err_count = err_count + 1;
				end
				if (p_ref_32 !== p_dsp_32) begin
					$display("FAIL cycle %0d inst 32 (24x17_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_32, p_dsp_32);
					err_count = err_count + 1;
				end
				if (p_ref_33 !== p_dsp_33) begin
					$display("FAIL cycle %0d inst 33 (18x18_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_33, p_dsp_33);
					err_count = err_count + 1;
				end
				if (p_ref_34 !== p_dsp_34) begin
					$display("FAIL cycle %0d inst 34 (18x18_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_34, p_dsp_34);
					err_count = err_count + 1;
				end
				if (p_ref_35 !== p_dsp_35) begin
					$display("FAIL cycle %0d inst 35 (18x18_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_35, p_dsp_35);
					err_count = err_count + 1;
				end
				if (p_ref_36 !== p_dsp_36) begin
					$display("FAIL cycle %0d inst 36 (18x18_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_36, p_dsp_36);
					err_count = err_count + 1;
				end
				if (p_ref_37 !== p_dsp_37) begin
					$display("FAIL cycle %0d inst 37 (24x24_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_37, p_dsp_37);
					err_count = err_count + 1;
				end
				if (p_ref_38 !== p_dsp_38) begin
					$display("FAIL cycle %0d inst 38 (24x24_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_38, p_dsp_38);
					err_count = err_count + 1;
				end
				if (p_ref_39 !== p_dsp_39) begin
					$display("FAIL cycle %0d inst 39 (24x24_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_39, p_dsp_39);
					err_count = err_count + 1;
				end
				if (p_ref_40 !== p_dsp_40) begin
					$display("FAIL cycle %0d inst 40 (24x24_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_40, p_dsp_40);
					err_count = err_count + 1;
				end
				if (p_ref_41 !== p_dsp_41) begin
					$display("FAIL cycle %0d inst 41 (32x3_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_41, p_dsp_41);
					err_count = err_count + 1;
				end
				if (p_ref_42 !== p_dsp_42) begin
					$display("FAIL cycle %0d inst 42 (32x3_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_42, p_dsp_42);
					err_count = err_count + 1;
				end
				if (p_ref_43 !== p_dsp_43) begin
					$display("FAIL cycle %0d inst 43 (32x3_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_43, p_dsp_43);
					err_count = err_count + 1;
				end
				if (p_ref_44 !== p_dsp_44) begin
					$display("FAIL cycle %0d inst 44 (32x3_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_44, p_dsp_44);
					err_count = err_count + 1;
				end
				if (p_ref_45 !== p_dsp_45) begin
					$display("FAIL cycle %0d inst 45 (32x16_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_45, p_dsp_45);
					err_count = err_count + 1;
				end
				if (p_ref_46 !== p_dsp_46) begin
					$display("FAIL cycle %0d inst 46 (32x16_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_46, p_dsp_46);
					err_count = err_count + 1;
				end
				if (p_ref_47 !== p_dsp_47) begin
					$display("FAIL cycle %0d inst 47 (32x16_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_47, p_dsp_47);
					err_count = err_count + 1;
				end
				if (p_ref_48 !== p_dsp_48) begin
					$display("FAIL cycle %0d inst 48 (32x16_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_48, p_dsp_48);
					err_count = err_count + 1;
				end
				if (p_ref_49 !== p_dsp_49) begin
					$display("FAIL cycle %0d inst 49 (17x32_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_49, p_dsp_49);
					err_count = err_count + 1;
				end
				if (p_ref_50 !== p_dsp_50) begin
					$display("FAIL cycle %0d inst 50 (17x32_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_50, p_dsp_50);
					err_count = err_count + 1;
				end
				if (p_ref_51 !== p_dsp_51) begin
					$display("FAIL cycle %0d inst 51 (17x32_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_51, p_dsp_51);
					err_count = err_count + 1;
				end
				if (p_ref_52 !== p_dsp_52) begin
					$display("FAIL cycle %0d inst 52 (17x32_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_52, p_dsp_52);
					err_count = err_count + 1;
				end
				if (p_ref_53 !== p_dsp_53) begin
					$display("FAIL cycle %0d inst 53 (25x25_s, LAT=0): ref=%h dsp=%h", cycle, p_ref_53, p_dsp_53);
					err_count = err_count + 1;
				end
				if (p_ref_54 !== p_dsp_54) begin
					$display("FAIL cycle %0d inst 54 (25x25_s, LAT=1): ref=%h dsp=%h", cycle, p_ref_54, p_dsp_54);
					err_count = err_count + 1;
				end
				if (p_ref_55 !== p_dsp_55) begin
					$display("FAIL cycle %0d inst 55 (25x25_s, LAT=2): ref=%h dsp=%h", cycle, p_ref_55, p_dsp_55);
					err_count = err_count + 1;
				end
				if (p_ref_56 !== p_dsp_56) begin
					$display("FAIL cycle %0d inst 56 (25x25_s, LAT=3): ref=%h dsp=%h", cycle, p_ref_56, p_dsp_56);
					err_count = err_count + 1;
				end
				if (p_ref_57 !== p_dsp_57) begin
					$display("FAIL cycle %0d inst 57 (27x17_s, LAT=0): ref=%h dsp=%h", cycle, p_ref_57, p_dsp_57);
					err_count = err_count + 1;
				end
				if (p_ref_58 !== p_dsp_58) begin
					$display("FAIL cycle %0d inst 58 (27x17_s, LAT=1): ref=%h dsp=%h", cycle, p_ref_58, p_dsp_58);
					err_count = err_count + 1;
				end
				if (p_ref_59 !== p_dsp_59) begin
					$display("FAIL cycle %0d inst 59 (27x17_s, LAT=2): ref=%h dsp=%h", cycle, p_ref_59, p_dsp_59);
					err_count = err_count + 1;
				end
				if (p_ref_60 !== p_dsp_60) begin
					$display("FAIL cycle %0d inst 60 (27x17_s, LAT=3): ref=%h dsp=%h", cycle, p_ref_60, p_dsp_60);
					err_count = err_count + 1;
				end
				if (p_ref_61 !== p_dsp_61) begin
					$display("FAIL cycle %0d inst 61 (30x17_s, LAT=0): ref=%h dsp=%h", cycle, p_ref_61, p_dsp_61);
					err_count = err_count + 1;
				end
				if (p_ref_62 !== p_dsp_62) begin
					$display("FAIL cycle %0d inst 62 (30x17_s, LAT=1): ref=%h dsp=%h", cycle, p_ref_62, p_dsp_62);
					err_count = err_count + 1;
				end
				if (p_ref_63 !== p_dsp_63) begin
					$display("FAIL cycle %0d inst 63 (30x17_s, LAT=2): ref=%h dsp=%h", cycle, p_ref_63, p_dsp_63);
					err_count = err_count + 1;
				end
				if (p_ref_64 !== p_dsp_64) begin
					$display("FAIL cycle %0d inst 64 (30x17_s, LAT=3): ref=%h dsp=%h", cycle, p_ref_64, p_dsp_64);
					err_count = err_count + 1;
				end
				if (p_ref_65 !== p_dsp_65) begin
					$display("FAIL cycle %0d inst 65 (24x59_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_65, p_dsp_65);
					err_count = err_count + 1;
				end
				if (p_ref_66 !== p_dsp_66) begin
					$display("FAIL cycle %0d inst 66 (24x59_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_66, p_dsp_66);
					err_count = err_count + 1;
				end
				if (p_ref_67 !== p_dsp_67) begin
					$display("FAIL cycle %0d inst 67 (24x59_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_67, p_dsp_67);
					err_count = err_count + 1;
				end
				if (p_ref_68 !== p_dsp_68) begin
					$display("FAIL cycle %0d inst 68 (24x59_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_68, p_dsp_68);
					err_count = err_count + 1;
				end
				if (p_ref_69 !== p_dsp_69) begin
					$display("FAIL cycle %0d inst 69 (33x33_s, LAT=0): ref=%h dsp=%h", cycle, p_ref_69, p_dsp_69);
					err_count = err_count + 1;
				end
				if (p_ref_70 !== p_dsp_70) begin
					$display("FAIL cycle %0d inst 70 (33x33_s, LAT=1): ref=%h dsp=%h", cycle, p_ref_70, p_dsp_70);
					err_count = err_count + 1;
				end
				if (p_ref_71 !== p_dsp_71) begin
					$display("FAIL cycle %0d inst 71 (33x33_s, LAT=2): ref=%h dsp=%h", cycle, p_ref_71, p_dsp_71);
					err_count = err_count + 1;
				end
				if (p_ref_72 !== p_dsp_72) begin
					$display("FAIL cycle %0d inst 72 (33x33_s, LAT=3): ref=%h dsp=%h", cycle, p_ref_72, p_dsp_72);
					err_count = err_count + 1;
				end
				if (p_ref_73 !== p_dsp_73) begin
					$display("FAIL cycle %0d inst 73 (42x42_u, LAT=0): ref=%h dsp=%h", cycle, p_ref_73, p_dsp_73);
					err_count = err_count + 1;
				end
				if (p_ref_74 !== p_dsp_74) begin
					$display("FAIL cycle %0d inst 74 (42x42_u, LAT=1): ref=%h dsp=%h", cycle, p_ref_74, p_dsp_74);
					err_count = err_count + 1;
				end
				if (p_ref_75 !== p_dsp_75) begin
					$display("FAIL cycle %0d inst 75 (42x42_u, LAT=2): ref=%h dsp=%h", cycle, p_ref_75, p_dsp_75);
					err_count = err_count + 1;
				end
				if (p_ref_76 !== p_dsp_76) begin
					$display("FAIL cycle %0d inst 76 (42x42_u, LAT=3): ref=%h dsp=%h", cycle, p_ref_76, p_dsp_76);
					err_count = err_count + 1;
				end
			end
		end

		if (err_count == 0) begin
			$display("PASS am_mul_dsp");
			$display("PASS am_mul_dsp_tb (all 76 instances clean)");
		end else begin
			$display("FAIL am_mul_dsp_tb: %0d errors", err_count);
		end
		$finish;
	end
endmodule
