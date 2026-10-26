/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_dualsrc_tb: Unit testbench for Dual Source Blending (ws002-p002).
 *
 * Verifies:
 *   1. Blend factors SRC1_COLOR (15), ONE_MINUS_SRC1_COLOR (16),
 *      SRC1_ALPHA (17), ONE_MINUS_SRC1_ALPHA (18).
 *   2. Subpixel font anti-aliasing (LCD subpixel rendering) where
 *      src0 = text color and src1 = per-channel coverage mask.
 *   3. Write masks (per-channel) and lane masks (per-pixel).
 *   4. Render target formats (RGBA8, BGRA8).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_dualsrc_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg b_valid = 1'b0;
	reg [511:0] b_src = 0;
	reg [511:0] b_src1 = 0;
	reg b_has_src1 = 1'b0;
	reg [127:0] b_dst = 0;
	reg [3:0] b_mask = 4'b1111;
	reg [1:0] b_rt = 2'd0;
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
		.b_src1(b_src1),
		.b_has_src1(b_has_src1),
		.b_dst(b_dst),
		.b_mask(b_mask),
		.b_rt(b_rt),
		.b_rvalid(b_rvalid),
		.b_pix(b_pix)
	);

	reg [31:0] unorm8_f32 [0:255];
	integer seed = 54321;
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

	function [7:0] get_factor;
		input [4:0] f;
		input [7:0] sc, dc, sa, da, s1c, s1a;
		input is_a;
		case (f)
		5'd0:  get_factor = 8'd0;
		5'd1:  get_factor = 8'd255;
		5'd2:  get_factor = sc;
		5'd3:  get_factor = ~sc;
		5'd4:  get_factor = dc;
		5'd5:  get_factor = ~dc;
		5'd6:  get_factor = sa;
		5'd7:  get_factor = ~sa;
		5'd8:  get_factor = da;
		5'd9:  get_factor = ~da;
		5'd14: get_factor = is_a ? 8'd255 : (sa < ~da ? sa : ~da);
		5'd15: get_factor = s1c;
		5'd16: get_factor = ~s1c;
		5'd17: get_factor = s1a;
		5'd18: get_factor = ~s1a;
		default: get_factor = 8'd0;
		endcase
	endfunction

	function [7:0] calc_ref_blend;
		input [4:0] fs_code;
		input [4:0] fd_code;
		input [2:0] op;
		input [7:0] sc, dc, sa, da, s1c, s1a;
		input is_a;
		integer fs, fd, p, q, pq, res;
		begin
			fs = get_factor(fs_code, sc, dc, sa, da, s1c, s1a, is_a);
			fd = get_factor(fd_code, sc, dc, sa, da, s1c, s1a, is_a);
			p = sc * fs;
			q = dc * fd;
			case (op)
			3'd1:    pq = p > q ? (p - q) : 0;
			3'd2:    pq = q > p ? (q - p) : 0;
			3'd3:    pq = -1; /* min */
			3'd4:    pq = -2; /* max */
			default: pq = p + q;
			endcase
			if (pq == -1)
				res = sc < dc ? sc : dc;
			else if (pq == -2)
				res = sc > dc ? sc : dc;
			else begin
				/* round(pq / 255) = (2 * pq + 255) / 510 */
				res = (2 * pq + 255) / 510;
				if (res > 255) res = 255;
			end
			calc_ref_blend = res[7:0];
		end
	endfunction

	integer iter, l, c, f_idx;
	reg [7:0] s0_b, s1_b, d_b, s0_a, s1_a, d_a;
	reg [7:0] exp_byte;
	reg [127:0] exp_pix;
	reg [4:0] test_factors [0:3];
	reg [4:0] cur_fs, cur_fd;
	reg [31:0] bl_val;
	reg [3:0] cur_wm, cur_mask;

	initial begin
		$readmemh("sim/vec/unorm8_f32.hex", unorm8_f32);
		test_factors[0] = 5'd15; /* SRC1_COLOR */
		test_factors[1] = 5'd16; /* ONE_MINUS_SRC1_COLOR */
		test_factors[2] = 5'd17; /* SRC1_ALPHA */
		test_factors[3] = 5'd18; /* ONE_MINUS_SRC1_ALPHA */

		repeat (5) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* -------------------------------------------------------------
		 * Test 1: Dual Source Blending Factors (15, 16, 17, 18)
		 * ------------------------------------------------------------- */
		/* RGBA8 format (code 1), write mask all enabled (0xF) */
		st_put(9'h072, 32'd1);
		st_put(9'h07C, 32'h000F);
		/* Enable dual-source blend in ROP_CTRL bit 7 */
		st_put(9'h08D, {24'd0, 1'b1, 7'd0});

		for (f_idx = 0; f_idx < 4; f_idx = f_idx + 1) begin
			cur_fs = test_factors[f_idx];
			cur_fd = 5'd1; /* ONE */

			/* Build BLEND word:
			 * [0] = 1 (enable)
			 * [4:1] = cur_fs[3:0]
			 * [8:5] = cur_fd[3:0] (1)
			 * [11:9] = 0 (ADD)
			 * [15:12] = cur_fs[3:0] (alpha fs)
			 * [19:16] = cur_fd[3:0] (alpha fd)
			 * [22:20] = 0 (ADD)
			 * [23] = cur_fs[4]
			 * [24] = cur_fd[4]
			 * [25] = cur_fs[4]
			 * [26] = cur_fd[4]
			 */
			bl_val = {5'd0, cur_fd[4], cur_fs[4], cur_fd[4], cur_fs[4],
				3'd0, cur_fd[3:0], cur_fs[3:0], 3'd0, cur_fd[3:0], cur_fs[3:0], 1'b1};
			st_put(9'h07A, bl_val);

			for (iter = 0; iter < 40; iter = iter + 1) begin
				for (l = 0; l < 4; l = l + 1) begin
					/* Generate alpha first so channels can access it */
					s0_a = $dist_uniform(seed, 0, 255);
					s1_a = $dist_uniform(seed, 0, 255);
					d_a  = $dist_uniform(seed, 0, 255);
					b_src[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s0_a];
					b_src1[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s1_a];
					b_dst[l * 32 + 24 +: 8] = d_a;

					for (c = 0; c < 3; c = c + 1) begin
						s0_b = $dist_uniform(seed, 0, 255);
						s1_b = $dist_uniform(seed, 0, 255);
						d_b  = $dist_uniform(seed, 0, 255);
						b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s0_b];
						b_src1[(l * 4 + c) * 32 +: 32] = unorm8_f32[s1_b];
						b_dst[l * 32 + c * 8 +: 8] = d_b;

						exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
							s0_b, d_b, s0_a, d_a, s1_b, s1_a, 1'b0);
						exp_pix[l * 32 + c * 8 +: 8] = exp_byte;
					end
					/* Alpha channel result */
					exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
						s0_a, d_a, s0_a, d_a, s1_a, s1_a, 1'b1);
					exp_pix[l * 32 + 24 +: 8] = exp_byte;
				end

				b_valid <= 1'b1;
				b_has_src1 <= 1'b1;
				b_mask <= 4'b1111;
				b_rt <= 2'd0;
				@(posedge clk);
				b_valid <= 1'b0;

				@(posedge clk);
				@(posedge clk);
				#1;
				if (!b_rvalid || b_pix !== exp_pix) begin
					$display("FAIL atg_rop_dualsrc.factors: fs=%0d iter=%0d got=%h exp=%h",
						cur_fs, iter, b_pix, exp_pix);
					errors = errors + 1;
				end
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_dualsrc.factors");
		else begin
			$display("FAIL atg_rop_dualsrc: %0d errors in factors", errors);
			$finish;
		end

		/* -------------------------------------------------------------
		 * Test 2: Subpixel Font Anti-Aliasing (LCD text rendering)
		 * Equation: result = text_color * mask + dst_color * (1 - mask)
		 * fs = SRC1_COLOR (15), fd = ONE_MINUS_SRC1_COLOR (16)
		 * ------------------------------------------------------------- */
		cur_fs = 5'd15; /* SRC1_COLOR */
		cur_fd = 5'd16; /* ONE_MINUS_SRC1_COLOR */
		bl_val = {5'd0, cur_fd[4], cur_fs[4], cur_fd[4], cur_fs[4],
			3'd0, cur_fd[3:0], cur_fs[3:0], 3'd0, cur_fd[3:0], cur_fs[3:0], 1'b1};
		st_put(9'h07A, bl_val);

		for (iter = 0; iter < 100; iter = iter + 1) begin
			for (l = 0; l < 4; l = l + 1) begin
				s0_a = $dist_uniform(seed, 128, 255); /* text alpha */
				s1_a = $dist_uniform(seed, 0, 255);   /* coverage alpha */
				d_a  = $dist_uniform(seed, 0, 255);   /* background alpha */
				b_src[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s0_a];
				b_src1[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s1_a];
				b_dst[l * 32 + 24 +: 8] = d_a;

				for (c = 0; c < 3; c = c + 1) begin
					/* Text colour, subpixel coverage mask per channel, destination background */
					s0_b = $dist_uniform(seed, 0, 255);
					s1_b = $dist_uniform(seed, 0, 255); /* RGB subpixel mask */
					d_b  = $dist_uniform(seed, 0, 255);
					b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s0_b];
					b_src1[(l * 4 + c) * 32 +: 32] = unorm8_f32[s1_b];
					b_dst[l * 32 + c * 8 +: 8] = d_b;

					exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
						s0_b, d_b, s0_a, d_a, s1_b, s1_a, 1'b0);
					exp_pix[l * 32 + c * 8 +: 8] = exp_byte;
				end
				exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
					s0_a, d_a, s0_a, d_a, s1_a, s1_a, 1'b1);
				exp_pix[l * 32 + 24 +: 8] = exp_byte;
			end

			b_valid <= 1'b1;
			b_has_src1 <= 1'b1;
			b_mask <= 4'b1111;
			b_rt <= 2'd0;
			@(posedge clk);
			b_valid <= 1'b0;

			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== exp_pix) begin
				$display("FAIL atg_rop_dualsrc.subpixel_font: iter=%0d got=%h exp=%h",
					iter, b_pix, exp_pix);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_dualsrc.subpixel_font");
		else begin
			$display("FAIL atg_rop_dualsrc: %0d errors in subpixel_font", errors);
			$finish;
		end

		/* -------------------------------------------------------------
		 * Test 3: Channel Write Masks and Lane Masks with Dual Source
		 * ------------------------------------------------------------- */
		for (iter = 0; iter < 80; iter = iter + 1) begin
			cur_wm = $dist_uniform(seed, 0, 15);
			cur_mask = $dist_uniform(seed, 0, 15);
			st_put(9'h07C, {28'd0, cur_wm});

			for (l = 0; l < 4; l = l + 1) begin
				s0_a = $dist_uniform(seed, 0, 255);
				s1_a = $dist_uniform(seed, 0, 255);
				d_a  = $dist_uniform(seed, 0, 255);
				b_src[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s0_a];
				b_src1[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s1_a];
				b_dst[l * 32 + 24 +: 8] = d_a;

				for (c = 0; c < 3; c = c + 1) begin
					s0_b = $dist_uniform(seed, 0, 255);
					s1_b = $dist_uniform(seed, 0, 255);
					d_b  = $dist_uniform(seed, 0, 255);
					b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s0_b];
					b_src1[(l * 4 + c) * 32 +: 32] = unorm8_f32[s1_b];
					b_dst[l * 32 + c * 8 +: 8] = d_b;

					if (cur_mask[l] && cur_wm[c])
						exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
							s0_b, d_b, s0_a, d_a, s1_b, s1_a, 1'b0);
					else
						exp_byte = d_b;
					exp_pix[l * 32 + c * 8 +: 8] = exp_byte;
				end
				if (cur_mask[l] && cur_wm[3])
					exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
						s0_a, d_a, s0_a, d_a, s1_a, s1_a, 1'b1);
				else
					exp_byte = d_a;
				exp_pix[l * 32 + 24 +: 8] = exp_byte;
			end

			b_valid <= 1'b1;
			b_has_src1 <= 1'b1;
			b_mask <= cur_mask;
			b_rt <= 2'd0;
			@(posedge clk);
			b_valid <= 1'b0;

			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== exp_pix) begin
				$display("FAIL atg_rop_dualsrc.masks: wm=%h mask=%h got=%h exp=%h",
					cur_wm, cur_mask, b_pix, exp_pix);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_dualsrc.masks");
		else begin
			$display("FAIL atg_rop_dualsrc: %0d errors in masks", errors);
			$finish;
		end

		/* -------------------------------------------------------------
		 * Test 4: Format BGRA8 with Dual Source Blending
		 * ------------------------------------------------------------- */
		st_put(9'h072, 32'd0); /* BGRA8 */
		st_put(9'h07C, 32'h000F);

		for (iter = 0; iter < 40; iter = iter + 1) begin
			for (l = 0; l < 4; l = l + 1) begin
				s0_a = $dist_uniform(seed, 0, 255);
				s1_a = $dist_uniform(seed, 0, 255);
				d_a  = $dist_uniform(seed, 0, 255);
				b_src[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s0_a];
				b_src1[(l * 4 + 3) * 32 +: 32] = unorm8_f32[s1_a];
				b_dst[l * 32 + 24 +: 8] = d_a;

				for (c = 0; c < 3; c = c + 1) begin
					s0_b = $dist_uniform(seed, 0, 255);
					s1_b = $dist_uniform(seed, 0, 255);
					d_b  = $dist_uniform(seed, 0, 255);
					b_src[(l * 4 + c) * 32 +: 32] = unorm8_f32[s0_b];
					b_src1[(l * 4 + c) * 32 +: 32] = unorm8_f32[s1_b];
					/* In BGRA8: lane bytes are B, G, R, A */
					b_dst[l * 32 + (c == 0 ? 2 : c == 2 ? 0 : c) * 8 +: 8] = d_b;

					exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
						s0_b, d_b, s0_a, d_a, s1_b, s1_a, 1'b0);
					exp_pix[l * 32 + (c == 0 ? 2 : c == 2 ? 0 : c) * 8 +: 8] = exp_byte;
				end
				exp_byte = calc_ref_blend(cur_fs, cur_fd, 3'd0,
					s0_a, d_a, s0_a, d_a, s1_a, s1_a, 1'b1);
				exp_pix[l * 32 + 24 +: 8] = exp_byte;
			end

			b_valid <= 1'b1;
			b_has_src1 <= 1'b1;
			b_mask <= 4'b1111;
			b_rt <= 2'd0;
			@(posedge clk);
			b_valid <= 1'b0;

			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== exp_pix) begin
				$display("FAIL atg_rop_dualsrc.formats: BGRA8 got=%h exp=%h",
					b_pix, exp_pix);
				errors = errors + 1;
			end
		end

		if (errors == 0)
			$display("PASS atg_rop_dualsrc.formats");
		else begin
			$display("FAIL atg_rop_dualsrc: %0d errors in formats", errors);
			$finish;
		end

		if (errors == 0) begin
			$display("PASS atg_rop_dualsrc");
		end else begin
			$display("FAIL atg_rop_dualsrc with %0d errors", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
