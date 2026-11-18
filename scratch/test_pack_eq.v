/* scratch/test_pack_eq.v */
`timescale 1ns / 1ps
`default_nettype none

module test_pack_eq;
	reg [127:0] c;
	reg [63:0] un;
	reg [63:0] hf;
	reg [7:0] fmt;
	reg [3:0] wm;
	wire [255:0] pk_ref;
	wire [255:0] pk_direct;

	localparam [55:0] PFF = {8'd97, 8'd83, 8'd76, 8'd64, 8'd57, 8'd50, 8'd43};

	atg_fmt_pack #(.N(7), .FMTS(PFF), .LAT(0)) u_ref (
		.clk(1'b0), .rst_n(1'b1), .en(1'b1),
		.c(c), .un(un), .hf(hf),
		.fmt(fmt), .wm(wm), .o(pk_ref)
	);

	/* Direct pack implementation */
	reg [127:0] raw_direct;
	reg [127:0] keep_direct;

	wire [7:0] srgb0 = c[7:0];
	wire [7:0] srgb1 = c[39:32];
	wire [7:0] srgb2 = c[71:64];

	wire [15:0] un0 = un[15:0];
	wire [15:0] un1 = un[31:16];
	wire [15:0] un2 = un[47:32];
	wire [15:0] un3 = un[63:48];

	wire [15:0] hf0 = hf[15:0];
	wire [15:0] hf1 = hf[31:16];
	wire [15:0] hf2 = hf[47:32];
	wire [15:0] hf3 = hf[63:48];

	always @(*) begin
		raw_direct = 128'd0;
		keep_direct = {128{1'b1}};
		case (fmt)
		8'd43: begin /* R8G8B8A8_SRGB */
			raw_direct[31:0] = {wm[3] ? un3[7:0] : 8'd0, wm[2] ? srgb2 : 8'd0, wm[1] ? srgb1 : 8'd0, wm[0] ? srgb0 : 8'd0};
			keep_direct[31:0] = {wm[3] ? 8'd0 : 8'hFF, wm[2] ? 8'd0 : 8'hFF, wm[1] ? 8'd0 : 8'hFF, wm[0] ? 8'd0 : 8'hFF};
		end
		8'd50: begin /* B8G8R8A8_SRGB */
			raw_direct[31:0] = {wm[3] ? un3[7:0] : 8'd0, wm[0] ? srgb0 : 8'd0, wm[1] ? srgb1 : 8'd0, wm[2] ? srgb2 : 8'd0};
			keep_direct[31:0] = {wm[3] ? 8'd0 : 8'hFF, wm[0] ? 8'd0 : 8'hFF, wm[1] ? 8'd0 : 8'hFF, wm[2] ? 8'd0 : 8'hFF};
		end
		8'd57: begin /* A8B8G8R8_SRGB_PACK32 */
			raw_direct[31:0] = {wm[3] ? un3[7:0] : 8'd0, wm[2] ? srgb2 : 8'd0, wm[1] ? srgb1 : 8'd0, wm[0] ? srgb0 : 8'd0};
			keep_direct[31:0] = {wm[3] ? 8'd0 : 8'hFF, wm[2] ? 8'd0 : 8'hFF, wm[1] ? 8'd0 : 8'hFF, wm[0] ? 8'd0 : 8'hFF};
		end
		8'd64: begin /* A2B10G10R10_UNORM_PACK32 */
			raw_direct[31:0] = {wm[3] ? un3[1:0] : 2'd0, wm[2] ? un2[9:0] : 10'd0, wm[1] ? un1[9:0] : 10'd0, wm[0] ? un0[9:0] : 10'd0};
			keep_direct[31:0] = {wm[3] ? 2'd0 : 2'b11, wm[2] ? 10'd0 : 10'h3FF, wm[1] ? 10'd0 : 10'h3FF, wm[0] ? 10'd0 : 10'h3FF};
		end
		8'd76: begin /* R16_SFLOAT */
			raw_direct[63:0] = {48'd0, wm[0] ? hf0 : 16'd0};
			keep_direct[63:0] = {48'hFFFF_FFFF_FFFF, wm[0] ? 16'd0 : 16'hFFFF};
		end
		8'd83: begin /* R16G16_SFLOAT */
			raw_direct[63:0] = {32'd0, wm[1] ? hf1 : 16'd0, wm[0] ? hf0 : 16'd0};
			keep_direct[63:0] = {32'hFFFF_FFFF, wm[1] ? 16'd0 : 16'hFFFF, wm[0] ? 16'd0 : 16'hFFFF};
		end
		8'd97: begin /* R16G16B16A16_SFLOAT */
			raw_direct[63:0] = {wm[3] ? hf3 : 16'd0, wm[2] ? hf2 : 16'd0, wm[1] ? hf1 : 16'd0, wm[0] ? hf0 : 16'd0};
			keep_direct[63:0] = {wm[3] ? 16'd0 : 16'hFFFF, wm[2] ? 16'd0 : 16'hFFFF, wm[1] ? 16'd0 : 16'hFFFF, wm[0] ? 16'd0 : 16'hFFFF};
		end
		default: begin
			raw_direct = 128'd0;
			keep_direct = {128{1'b1}};
		end
		endcase
	end

	assign pk_direct = {keep_direct, raw_direct};

	integer iter, errors;
	integer fmts [0:6];
	integer fi;

	initial begin
		fmts[0] = 43; fmts[1] = 50; fmts[2] = 57; fmts[3] = 64;
		fmts[4] = 76; fmts[5] = 83; fmts[6] = 97;
		errors = 0;
		for (iter = 0; iter < 10000; iter = iter + 1) begin
			c = {$random, $random, $random, $random};
			un = {$random, $random};
			hf = {$random, $random};
			wm = $random;
			fi = $random % 7;
			if (fi < 0) fi = -fi;
			fmt = fmts[fi];
			#1;
			if (pk_ref[63:0] !== pk_direct[63:0] || pk_ref[191:128] !== pk_direct[191:128]) begin
				$display("MISMATCH on fmt %0d wm %b: ref={%h, %h} dir={%h, %h}",
					fmt, wm, pk_ref[191:128], pk_ref[63:0], pk_direct[191:128], pk_direct[63:0]);
				errors = errors + 1;
				if (errors > 5) $finish;
			end
		end
		if (errors == 0)
			$display("SUCCESS: 10000 random tests 100% matched!");
		$finish;
	end
endmodule
`default_nettype wire
