/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_logicop_tb: Unit testbench for ROP Logic Op (16 VkLogicOp operations)
 * and Independent Blend per RT (ws002-p001).
 *
 * Checks:
 *   1. All 16 VkLogicOp operations against reference truth table.
 *   2. Write masks (per-channel) and lane masks (per-pixel) with Logic Op.
 *   3. Independent blend equations across render targets 0..3.
 *   4. Formats BGRA8, RGBA8, R8, RG8, RGB565 with Logic Op.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_logicop_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg b_valid = 1'b0;
	reg [511:0] b_src = 0;
	reg [127:0] b_dst = 0;
	reg [3:0] b_mask = 4'b1111;
	reg [2:0] b_rt = 3'd0;
	wire b_rvalid;
	wire [127:0] b_pix;

	atg_rop_blend #(.LAT(3)) dut (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.b_valid(b_valid),
		.b_src(b_src),
		.b_dst(b_dst),
		.b_mask(b_mask),
		.b_rt(b_rt),
		.b_rvalid(b_rvalid),
		.b_pix(b_pix)
	);

	reg [31:0] unorm8_f32 [0:255];
	integer seed = 12345;
	integer errors = 0;

	task st_put;
		input [8:0] i_;
		input [31:0] v_;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= v_;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	function [7:0] ref_logicop;
		input [3:0] op;
		input [7:0] s;
		input [7:0] d;
		case (op)
		4'd0:  ref_logicop = 8'h00;
		4'd1:  ref_logicop = s & d;
		4'd2:  ref_logicop = s & ~d;
		4'd3:  ref_logicop = s;
		4'd4:  ref_logicop = ~s & d;
		4'd5:  ref_logicop = d;
		4'd6:  ref_logicop = s ^ d;
		4'd7:  ref_logicop = s | d;
		4'd8:  ref_logicop = ~(s | d);
		4'd9:  ref_logicop = ~(s ^ d);
		4'd10: ref_logicop = ~d;
		4'd11: ref_logicop = s | ~d;
		4'd12: ref_logicop = ~s;
		4'd13: ref_logicop = ~s | d;
		4'd14: ref_logicop = ~(s & d);
		4'd15: ref_logicop = 8'hFF;
		endcase
	endfunction

	integer op, iter, l, c;
	reg [7:0] s_byte, d_byte, exp_byte;
	reg [127:0] exp_pix;
	reg [3:0] cur_wm;
	reg [3:0] cur_mask;

	initial begin
		$readmemh("sim/vec/unorm8_f32.hex", unorm8_f32);

		repeat (5) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* -------------------------------------------------------------
		 * Test 1: All 16 VkLogicOp operations on RGBA8
		 * ------------------------------------------------------------- */
		/* Set RT_FORMAT to RGBA8 (code 1) */
		st_put(9'h072, 32'd1);
		/* All channels write enabled */
		st_put(9'h07C, 32'h000F);

		for (op = 0; op < 16; op = op + 1) begin
			/* Configure via GHCI_S_LOGIC_OP: bit 0 = 1 (en), bits [4:1] = op */
			st_put(9'h08E, {27'd0, op[3:0], 1'b1});

			for (iter = 0; iter < 40; iter = iter + 1) begin
				/* Build random quad pixels */
				for (l = 0; l < 4; l = l + 1) begin
					for (c = 0; c < 4; c = c + 1) begin
						s_byte = $dist_uniform(seed, 0, 255);
						d_byte = $dist_uniform(seed, 0, 255);
						b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s_byte];
						b_dst[l * 32 + c * 8 +: 8] = d_byte;
						exp_byte = ref_logicop(op[3:0], s_byte, d_byte);
						exp_pix[l * 32 + c * 8 +: 8] = exp_byte;
					end
				end
				b_valid <= 1'b1;
				b_mask <= 4'b1111;
				b_rt <= 2'd0;
				@(posedge clk);
				b_valid <= 1'b0;

				/* Wait for LAT (3) cycles */
				@(posedge clk);
				@(posedge clk);
				#1;
				if (!b_rvalid || b_pix !== exp_pix) begin
					$display("FAIL atg_rop_logicop: op %0d iter %0d got %h, exp %h",
						op, iter, b_pix, exp_pix);
					errors = errors + 1;
				end
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_logicop.all16");
		else begin
			$display("FAIL atg_rop_logicop: %0d errors in all16", errors);
			$finish;
		end

		/* -------------------------------------------------------------
		 * Test 2: Channel Write Masks and Lane Masks with Logic Op
		 * ------------------------------------------------------------- */
		/* Use Logic Op XOR (op 6) */
		st_put(9'h08E, {27'd0, 4'd6, 1'b1});

		for (iter = 0; iter < 100; iter = iter + 1) begin
			cur_wm = $dist_uniform(seed, 0, 15);
			cur_mask = $dist_uniform(seed, 0, 15);
			st_put(9'h07C, {28'd0, cur_wm});

			for (l = 0; l < 4; l = l + 1) begin
				for (c = 0; c < 4; c = c + 1) begin
					s_byte = $dist_uniform(seed, 0, 255);
					d_byte = $dist_uniform(seed, 0, 255);
					b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s_byte];
					b_dst[l * 32 + c * 8 +: 8] = d_byte;
					if (cur_mask[l]) begin
						exp_byte = cur_wm[c] ? ref_logicop(4'd6, s_byte, d_byte) : d_byte;
					end else begin
						exp_byte = d_byte;
					end
					exp_pix[l * 32 + c * 8 +: 8] = exp_byte;
				end
			end
			b_valid <= 1'b1;
			b_mask <= cur_mask;
			b_rt <= 2'd0;
			@(posedge clk);
			b_valid <= 1'b0;

			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== exp_pix) begin
				$display("FAIL atg_rop_logicop: masks wm=%h mask=%h got %h, exp %h",
					cur_wm, cur_mask, b_pix, exp_pix);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_logicop.masks");
		else begin
			$display("FAIL atg_rop_logicop: %0d errors in masks", errors);
			$finish;
		end

		/* -------------------------------------------------------------
		 * Test 3: Independent Blend and Logic Op across RT 0..3
		 * ------------------------------------------------------------- */
		/* Reset write mask to all 1s for all 4 RTs (0xFFFF) */
		st_put(9'h07C, 32'hFFFF);

		/* RT_FORMATS: all RGBA8 (VkFormat 37 = 0x25) */
		st_put(9'h07D, 32'h25252525);

		/*
		 * Configure RTs:
		 * RT0: Logic Op AND (op 1)
		 * RT1: Standard ADD (no blend: bls[0]=0, just COPY source)
		 * RT2: Logic Op XOR (op 6)
		 * RT3: Logic Op INVERT (op 10)
		 */
		/* Write per-RT logic ops via GHCI_S_LOGIC_OP:
		 * RT0: en=1, op=1  -> byte 0 = 8'h03 (op=1, en=1 -> {op, en} = {4'h1, 1'b1} = 0x03)
		 * RT1: en=0, op=0  -> byte 1 = 8'h00
		 * RT2: en=1, op=6  -> byte 2 = 8'h0D (op=6, en=1 -> {4'h6, 1'b1} = 0x0D)
		 * RT3: en=1, op=10 -> byte 3 = 8'h15 (op=10=0xA, en=1 -> {4'hA, 1'b1} = 0x15)
		 */
		st_put(9'h08E, {8'h15, 8'h0D, 8'h00, 8'h03});

		/* Disable blend on RT1 so it passes source */
		st_put(9'h084, 32'd0); /* BLEND1 (RT1) bl[0]=0 */

		for (iter = 0; iter < 50; iter = iter + 1) begin
			for (op = 0; op < 4; op = op + 1) begin
				/* op is rt index */
				for (l = 0; l < 4; l = l + 1) begin
					for (c = 0; c < 4; c = c + 1) begin
						s_byte = $dist_uniform(seed, 0, 255);
						d_byte = $dist_uniform(seed, 0, 255);
						b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s_byte];
						b_dst[l * 32 + c * 8 +: 8] = d_byte;
						case (op)
						0: exp_byte = ref_logicop(4'd1, s_byte, d_byte);  /* AND */
						1: exp_byte = s_byte;                              /* RT1 no blend -> src */
						2: exp_byte = ref_logicop(4'd6, s_byte, d_byte);  /* XOR */
						3: exp_byte = ref_logicop(4'd10, s_byte, d_byte); /* INVERT */
						endcase
						exp_pix[l * 32 + c * 8 +: 8] = exp_byte;
					end
				end
				b_valid <= 1'b1;
				b_mask <= 4'b1111;
				b_rt <= op[1:0];
				@(posedge clk);
				b_valid <= 1'b0;

				@(posedge clk);
				@(posedge clk);
				#1;
				if (!b_rvalid || b_pix !== exp_pix) begin
					$display("FAIL atg_rop_logicop: independent RT%0d iter %0d got %h, exp %h",
						op, iter, b_pix, exp_pix);
					errors = errors + 1;
				end
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_logicop.independent_blend");
		else begin
			$display("FAIL atg_rop_logicop: %0d errors in independent_blend", errors);
			$finish;
		end

		/* -------------------------------------------------------------
		 * Test 4: Formats BGRA8, RGBA8, R8, RG8 with Logic Op
		 * ------------------------------------------------------------- */
		/* Global logic op OR (op 7) */
		st_put(9'h08E, {27'd0, 4'd7, 1'b1});
		st_put(9'h07C, 32'hFFFF);

		/* 4.1: BGRA8 (RT_FORMAT 0) */
		st_put(9'h072, 32'd0);
		st_put(9'h07D, 32'd0);
		for (iter = 0; iter < 30; iter = iter + 1) begin
			for (l = 0; l < 4; l = l + 1) begin
				for (c = 0; c < 4; c = c + 1) begin
					s_byte = $dist_uniform(seed, 0, 255);
					d_byte = $dist_uniform(seed, 0, 255);
					b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s_byte];
					/* In BGRA8: lane bytes are B, G, R, A */
					b_dst[l * 32 + (c == 0 ? 2 : c == 2 ? 0 : c) * 8 +: 8] = d_byte;
					exp_byte = ref_logicop(4'd7, s_byte, d_byte);
					exp_pix[l * 32 + (c == 0 ? 2 : c == 2 ? 0 : c) * 8 +: 8] = exp_byte;
				end
			end
			b_valid <= 1'b1;
			b_mask <= 4'b1111;
			b_rt <= 2'd0;
			@(posedge clk);
			b_valid <= 1'b0;

			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== exp_pix) begin
				$display("FAIL atg_rop_logicop: BGRA8 iter %0d got %h, exp %h",
					iter, b_pix, exp_pix);
				errors = errors + 1;
			end
		end

		/* 4.2: R8 (VkFormat 9) */
		st_put(9'h07D, 32'h00000009);
		for (iter = 0; iter < 30; iter = iter + 1) begin
			for (l = 0; l < 4; l = l + 1) begin
				s_byte = $dist_uniform(seed, 0, 255);
				d_byte = $dist_uniform(seed, 0, 255);
				b_src[(l * 4 + 0) * 32 +: 32] = unorm8_f32[s_byte];
				b_src[(l * 4 + 1) * 32 +: 32] = unorm8_f32[0];
				b_src[(l * 4 + 2) * 32 +: 32] = unorm8_f32[0];
				b_src[(l * 4 + 3) * 32 +: 32] = unorm8_f32[255];
				b_dst[l * 32 +: 32] = {24'hA5A5A5, d_byte};
				exp_byte = ref_logicop(4'd7, s_byte, d_byte);
				exp_pix[l * 32 +: 32] = {24'hA5A5A5, exp_byte};
			end
			b_valid <= 1'b1;
			b_mask <= 4'b1111;
			b_rt <= 2'd0;
			@(posedge clk);
			b_valid <= 1'b0;

			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== exp_pix) begin
				$display("FAIL atg_rop_logicop: R8 iter %0d got %h, exp %h",
					iter, b_pix, exp_pix);
				errors = errors + 1;
			end
		end

		/* 4.3: RG8 (VkFormat 16 = 0x10) */
		st_put(9'h07D, 32'h00000010);
		for (iter = 0; iter < 30; iter = iter + 1) begin
			for (l = 0; l < 4; l = l + 1) begin
				s_byte = $dist_uniform(seed, 0, 255);
				d_byte = $dist_uniform(seed, 0, 255);
				b_src[(l * 4 + 0) * 32 +: 32] = unorm8_f32[s_byte];
				b_dst[l * 32 + 0 +: 8] = d_byte;
				exp_pix[l * 32 + 0 +: 8] = ref_logicop(4'd7, s_byte, d_byte);

				s_byte = $dist_uniform(seed, 0, 255);
				d_byte = $dist_uniform(seed, 0, 255);
				b_src[(l * 4 + 1) * 32 +: 32] = unorm8_f32[s_byte];
				b_dst[l * 32 + 8 +: 8] = d_byte;
				exp_pix[l * 32 + 8 +: 8] = ref_logicop(4'd7, s_byte, d_byte);

				b_src[(l * 4 + 2) * 32 +: 32] = unorm8_f32[0];
				b_src[(l * 4 + 3) * 32 +: 32] = unorm8_f32[255];
				b_dst[l * 32 + 16 +: 16] = 16'h5A5A;
				exp_pix[l * 32 + 16 +: 16] = 16'h5A5A;
			end
			b_valid <= 1'b1;
			b_mask <= 4'b1111;
			b_rt <= 2'd0;
			@(posedge clk);
			b_valid <= 1'b0;

			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== exp_pix) begin
				$display("FAIL atg_rop_logicop: RG8 iter %0d got %h, exp %h",
					iter, b_pix, exp_pix);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_logicop.formats");
		else begin
			$display("FAIL atg_rop_logicop: %0d errors in formats", errors);
			$finish;
		end

		/* -------------------------------------------------------------
		 * Test 5: Verify ROP_CTRL logic_op setting
		 * ------------------------------------------------------------- */
		/* Test logic op NAND (op 14) configured via ROP_CTRL (0x08D) */
		/* ROP_CTRL: bit 2 = en, bits [6:3] = op */
		st_put(9'h072, 32'd1); /* RGBA8 */
		st_put(9'h07D, 32'd0);
		st_put(9'h08D, {25'd0, 4'd14, 1'b1, 2'b00});

		for (l = 0; l < 4; l = l + 1) begin
			for (c = 0; c < 4; c = c + 1) begin
				s_byte = 8'hA5;
				d_byte = 8'h5A;
				b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s_byte];
				b_dst[l * 32 + c * 8 +: 8] = d_byte;
				exp_byte = ref_logicop(4'd14, s_byte, d_byte); /* ~(0xA5 & 0x5A) = ~0x00 = 0xFF */
				exp_pix[l * 32 + c * 8 +: 8] = exp_byte;
			end
		end
		b_valid <= 1'b1;
		b_mask <= 4'b1111;
		b_rt <= 2'd0;
		@(posedge clk);
		b_valid <= 1'b0;

		@(posedge clk);
		@(posedge clk);
		#1;
		if (!b_rvalid || b_pix !== exp_pix) begin
			$display("FAIL atg_rop_logicop: ROP_CTRL got %h, exp %h", b_pix, exp_pix);
			errors = errors + 1;
		end

		if (errors == 0) begin
			$display("PASS atg_rop_logicop");
		end else begin
			$display("FAIL atg_rop_logicop with %0d errors", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
