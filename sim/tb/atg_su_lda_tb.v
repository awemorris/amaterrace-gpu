/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lda_tb: atg_su_lda in a small shape (NPHYS 8, 20 words per
 * vertex) and the KC705 shape (NPHYS 16, 36 words), both written by the
 * same RX-style primitive table writes (random words of 8 primitives × 3
 * vertices of each of 4 warps, then a primitive map per warp that puts
 * different primitives in the quads), then lda lane groups with random
 * EXEC: every lane gets word imm[7:2] of vertex imm[1:0] of its quad's
 * primitive (0 past the vertex's words or for vertex 3), exactly
 * SHORT_LAT cycles later, s_rd and s_lanes (= EXEC) with it, and no
 * result for other units' instructions.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lda_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg pw_we = 1'b0;
	reg [1:0] pw_warp = 0;
	reg [11:0] pw_addr = 0;
	reg [31:0] pw_data = 0;
	reg x_valid = 1'b0;
	reg [1:0] x_warp = 0;
	reg [1:0] x_grp = 0;
	reg [103:0] x_uop = 0;
	reg [31:0] x_mask = 0;
	reg [1:0] dsel = 0;	/* which shape gets the group: 1 NPHYS 8, 2 KC705 */

	wire s8_valid, s16_valid;
	wire [1:0] s8_warp, s16_warp;
	wire [1:0] s8_grp;
	wire [0:0] s16_grp;
	wire [6:0] s8_rd, s16_rd;
	wire [255:0] s8_data;
	wire [511:0] s16_data;
	wire [7:0] s8_lanes;
	wire [15:0] s16_lanes;

	atg_su_lda #(.NPHYS(8), .GRP_W(2), .VARY_WORDS(20)) d8 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid && dsel[0]), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(256'd0), .x_b(256'd0),
		.x_c(256'd0), .x_mask({8'd0, x_mask[7:0]}), .x_info(32'h10000), .x_ready(),
		.s_valid(s8_valid), .s_warp(s8_warp), .s_grp(s8_grp), .s_rd(s8_rd), .s_data(s8_data),
		.s_lanes(s8_lanes),
		.pw_we(pw_we), .pw_warp(pw_warp), .pw_addr(pw_addr), .pw_data(pw_data));
	atg_su_lda #(.NPHYS(16), .GRP_W(1), .VARY_WORDS(36)) d16 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid && dsel[1]), .x_warp(x_warp),
		.x_grp(x_grp[0]), .x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop),
		.x_a(512'd0), .x_b(512'd0), .x_c(512'd0), .x_mask({16'd0, x_mask[15:0]}),
		.x_info(32'h10000), .x_ready(),
		.s_valid(s16_valid), .s_warp(s16_warp), .s_grp(s16_grp), .s_rd(s16_rd),
		.s_data(s16_data), .s_lanes(s16_lanes),
		.pw_we(pw_we), .pw_warp(pw_warp), .pw_addr(pw_addr), .pw_data(pw_data));

	integer seed = 1, errors = 0, i, w, p, v, d, n, cyc = 0;
	reg [31:0] tab [0:4*8*3*64-1];	/* warp, prim, vertex, word (64) */
	reg [23:0] pmap [0:3];

	task tick;
		begin
			@(posedge clk);
			#1;
		end
	endtask

	task pw;
		input [1:0] w_;
		input [11:0] a;
		input [31:0] dv;
		begin
			pw_we = 1'b1;
			pw_warp = w_;
			pw_addr = a;
			pw_data = dv;
			tick;
			pw_we = 1'b0;
		end
	endtask

	/* expected results: per issue cycle, checked SHORT_LAT (6) cycles later */
	reg [63:0] q_meta [0:1023];	/* {valid, shape, warp, grp, rd, lanes(16)} */
	reg [511:0] q_data [0:1023];
	always @(posedge clk)
		cyc <= cyc + 1;

	function [31:0] word_of;
		input integer w_, q_, imm_, vw;
		integer pr, vx, wd;
		begin
			pr = (pmap[w_] >> (3 * q_)) & 7;
			vx = imm_ & 3;
			wd = (imm_ >> 2) & 63;
			word_of = vx < 3 && wd < vw ? tab[((w_ * 8 + pr) * 3 + vx) * 64 + wd] : 32'd0;
		end
	endfunction

	/* one lda group at the current cycle */
	task issue;
		input integer shape;	/* 0 NPHYS 8, 1 KC705 */
		input integer unit;
		integer np, g, imm, rd, ln;
		reg [511:0] dv;
		begin
			np = shape ? 16 : 8;
			x_valid = 1'b1;
			dsel = shape ? 2'b10 : 2'b01;
			x_warp = $random(seed);
			g = $unsigned($random(seed)) % (32 / np);
			x_grp = g;
			imm = $unsigned($random(seed)) % 256;
			rd = $unsigned($random(seed)) % 32;
			x_uop = 104'd0;
			x_uop[3:0] = unit;
			x_uop[12 +: 7] = rd;
			x_uop[40 +: 32] = imm;
			x_uop[98] = 1'b1;
			x_mask = $random(seed);
			dv = 512'd0;
			for (ln = 0; ln < np; ln = ln + 1)
				dv[32 * ln +: 32] = word_of(x_warp, (g * np + ln) / 4, imm, shape ? 36 : 20);
			q_meta[(cyc + 6) % 1024] = {31'd0, unit == 11, shape[0], x_warp, g[1:0], rd[6:0],
				shape ? x_mask[15:0] : {8'd0, x_mask[7:0]}};
			q_data[(cyc + 6) % 1024] = dv;
			tick;
			x_valid = 1'b0;
			dsel = 2'b00;
		end
	endtask

	/* the check, every cycle */
	reg [63:0] m;
	always @(posedge clk) begin
		#2;
		m = q_meta[cyc % 1024];
		q_meta[cyc % 1024] = 64'd0;
		if (s8_valid !== (m[28] && !m[27]) || s16_valid !== (m[28] && m[27])) begin
			errors = errors + 1;
			$display("FAIL atg_su_lda.rw: cycle %0d valid %b %b, expected %b shape %b", cyc,
				s8_valid, s16_valid, m[28], m[27]);
		end else if (s8_valid && (s8_warp !== m[26:25] || s8_grp !== m[24:23] ||
		    s8_rd !== m[22:16] || s8_lanes !== m[7:0] || s8_data !== q_data[cyc % 1024][255:0])) begin
			errors = errors + 1;
			$display("FAIL atg_su_lda.rw: NPHYS 8 result at cycle %0d", cyc);
		end else if (s16_valid && (s16_warp !== m[26:25] || s16_grp !== m[23] ||
		    s16_rd !== m[22:16] || s16_lanes !== m[15:0] || s16_data !== q_data[cyc % 1024])) begin
			errors = errors + 1;
			$display("FAIL atg_su_lda.rw: KC705 result at cycle %0d", cyc);
		end
	end

	initial begin
		for (i = 0; i < 1024; i = i + 1)
			q_meta[i] = 64'd0;
		repeat (3) tick;
		rst_n = 1'b1;
		tick;
		for (w = 0; w < 4; w = w + 1)
			for (p = 0; p < 8; p = p + 1)
				for (v = 0; v < 3; v = v + 1)
					for (d = 0; d < 36; d = d + 1) begin
						tab[((w * 8 + p) * 3 + v) * 64 + d] = $random(seed);
						pw(w, {1'b0, p[2:0], v[1:0], d[5:0]}, tab[((w * 8 + p) * 3 + v) * 64 + d]);
					end
		/* two rounds: the maps of the first round, then new maps */
		for (n = 0; n < 2; n = n + 1) begin
			for (w = 0; w < 4; w = w + 1) begin
				pmap[w] = n == 0 ? 24'd0 : $random(seed);
				pw(w, 12'hFFF, {8'hAB, pmap[w]});
			end
			for (i = 0; i < 400; i = i + 1) begin
				issue($random(seed) & 1, ($random(seed) & 7) == 0 ? 1 : 11);
				if ($random(seed) & 1)
					tick;
			end
			repeat (10) tick;
		end
		if (errors == 0)
			$display("PASS atg_su_lda.rw");
		if (errors == 0)
			$display("PASS atg_su_lda");
		else
			$display("FAIL atg_su_lda: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
