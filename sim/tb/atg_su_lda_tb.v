/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lda_tb: atg_su_lda in three shapes: NPHYS 8 with 16 varying
 * words (one read cycle per lane group), the KC705's NPHYS 16 with 64
 * (two read cycles) and NPHYS 32 with 32 (four), all written by the same
 * RX-style primitive table writes (random varying words 0-63 of 8
 * primitives × 3 vertices of each of 4 warps, then a primitive map per
 * warp that puts different primitives in the quads), then lda lane
 * groups with random EXEC, warps and immediates (PT words 0-127, vertex
 * 0-3), mixed with other units' groups, also in the read cycles:
 *   rw    — every lane gets varying word imm[8:2] - 4 of vertex imm[1:0]
 *           of its quad's primitive (0 for PT words 0-3, past the
 *           vertex's varyings or for vertex 3), exactly SHORT_LAT (6)
 *           cycles after the group was taken (x_valid && x_ready, the
 *           group held until then), s_rd and s_lanes (= EXEC) with it,
 *           and no result for other units' groups
 *   ms    — the RX's d_s words (0xFF8-0xFFB) touch neither table nor map
 *   ready — x_ready is 0 exactly in the read cycles after a group's
 *           first (NPHYS 16: 1, NPHYS 32: 3), 1 otherwise
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
	reg [2:0] dsel = 0;	/* which shape gets the group: bit 0 NPHYS 8, 1 NPHYS 16, 2 NPHYS 32 */

	wire [2:0] rdy;
	wire s8_valid, s16_valid, s32_valid;
	wire [1:0] s8_warp, s16_warp, s32_warp;
	wire [1:0] s8_grp;
	wire [0:0] s16_grp, s32_grp;
	wire [6:0] s8_rd, s16_rd, s32_rd;
	wire [255:0] s8_data;
	wire [511:0] s16_data;
	wire [1023:0] s32_data;
	wire [7:0] s8_lanes;
	wire [15:0] s16_lanes;
	wire [31:0] s32_lanes;

	atg_su_lda #(.NPHYS(8), .GRP_W(2), .VARY_WORDS(16)) d8 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid && dsel[0]), .x_warp(x_warp), .x_grp(x_grp),
		.scrub(1'b0), .scrub_busy(),
		.x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(256'd0), .x_b(256'd0),
		.x_c(256'd0), .x_mask({8'd0, x_mask[7:0]}), .x_info(32'h10000), .x_ready(rdy[0]),
		.s_valid(s8_valid), .s_warp(s8_warp), .s_grp(s8_grp), .s_rd(s8_rd), .s_data(s8_data),
		.s_lanes(s8_lanes),
		.pw_we(pw_we), .pw_warp(pw_warp), .pw_addr(pw_addr), .pw_data(pw_data));
	atg_su_lda #(.NPHYS(16), .GRP_W(1), .VARY_WORDS(64)) d16 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid && dsel[1]), .x_warp(x_warp),
		.scrub(1'b0), .scrub_busy(),
		.x_grp(x_grp[0]), .x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop),
		.x_a(512'd0), .x_b(512'd0), .x_c(512'd0), .x_mask({16'd0, x_mask[15:0]}),
		.x_info(32'h10000), .x_ready(rdy[1]),
		.s_valid(s16_valid), .s_warp(s16_warp), .s_grp(s16_grp), .s_rd(s16_rd),
		.s_data(s16_data), .s_lanes(s16_lanes),
		.pw_we(pw_we), .pw_warp(pw_warp), .pw_addr(pw_addr), .pw_data(pw_data));
	atg_su_lda #(.NPHYS(32), .GRP_W(1), .VARY_WORDS(32)) d32 (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid && dsel[2]), .x_warp(x_warp),
		.scrub(1'b0), .scrub_busy(),
		.x_grp(1'b0), .x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop),
		.x_a(1024'd0), .x_b(1024'd0), .x_c(1024'd0), .x_mask({32'd0, x_mask}),
		.x_info(32'h10000), .x_ready(rdy[2]),
		.s_valid(s32_valid), .s_warp(s32_warp), .s_grp(s32_grp), .s_rd(s32_rd),
		.s_data(s32_data), .s_lanes(s32_lanes),
		.pw_we(pw_we), .pw_warp(pw_warp), .pw_addr(pw_addr), .pw_data(pw_data));

	integer seed = 1, errors = 0, e_ready = 0, i, w, p, v, d, n, s, cyc = 0;
	integer bz [0:2];	/* the shape reads until this cycle */
	reg [31:0] tab [0:4*8*3*64-1];	/* warp, prim, vertex, varying word */
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
	reg [79:0] q_meta [0:1023];	/* {valid, shape(2), warp, grp(2), rd(7), lanes(32)} */
	reg [1023:0] q_data [0:1023];
	always @(posedge clk)
		cyc <= cyc + 1;

	function [31:0] word_of;
		input integer w_, q_, imm_, vw;
		integer pr, vx, wd;
		begin
			pr = (pmap[w_] >> (3 * q_)) & 7;
			vx = imm_ & 3;
			wd = (imm_ >> 2) & 127;
			word_of = vx < 3 && wd >= 4 && wd < 4 + vw ?
				tab[((w_ * 8 + pr) * 3 + vx) * 64 + wd - 4] : 32'd0;
		end
	endfunction

	/* one lane group of unit 11 (lda) or another, from the current cycle until taken */
	task issue;
		input integer shape;	/* 0 NPHYS 8, 1 NPHYS 16, 2 NPHYS 32 */
		input integer unit;
		integer np, nr, g, imm, rd, ln, vw;
		reg [1023:0] dv;
		begin
			np = shape == 2 ? 32 : shape ? 16 : 8;
			nr = shape == 2 ? 4 : shape ? 2 : 1;
			vw = shape == 2 ? 32 : shape ? 64 : 16;
			x_valid = 1'b1;
			dsel = 3'b001 << shape;
			x_warp = $random(seed);
			g = $unsigned($random(seed)) % (32 / np);
			x_grp = g;
			if ($random(seed) & 3)
				imm = (4 + $unsigned($random(seed)) % 64) * 4 + $unsigned($random(seed)) % 3;
			else
				imm = $unsigned($random(seed)) % 512;
			rd = $unsigned($random(seed)) % 32;
			x_uop = 104'd0;
			x_uop[3:0] = unit;
			x_uop[12 +: 7] = rd;
			x_uop[40 +: 32] = imm | ($random(seed) & 32'hFFFFFE00);	/* imm[31:9] ignored */
			x_uop[98] = 1'b1;
			x_mask = $random(seed);
			/* an lda waits for x_ready; it must be 0 exactly while the shape reads */
			while (unit == 11 && !rdy[shape]) begin
				if (cyc >= bz[shape]) begin
					e_ready = e_ready + 1;
					$display("FAIL atg_su_lda.ready: shape %0d not ready at cycle %0d", shape, cyc);
				end
				tick;
			end
			if (unit == 11 && cyc < bz[shape]) begin
				e_ready = e_ready + 1;
				$display("FAIL atg_su_lda.ready: shape %0d ready at cycle %0d, reading until %0d",
					shape, cyc, bz[shape]);
			end
			dv = 1024'd0;
			for (ln = 0; ln < np; ln = ln + 1)
				dv[32 * ln +: 32] = word_of(x_warp, (g * np + ln) / 4, imm, vw);
			q_meta[(cyc + 6) % 1024] = {31'd0, unit == 11, shape[1:0], x_warp, g[1:0], rd[6:0],
				shape == 2 ? x_mask : shape ? {16'd0, x_mask[15:0]} : {24'd0, x_mask[7:0]}};
			q_data[(cyc + 6) % 1024] = dv;
			if (unit == 11)
				bz[shape] = cyc + nr;
			tick;
			x_valid = 1'b0;
			dsel = 3'b000;
		end
	endtask

	/* the check, every cycle */
	reg [79:0] m;
	always @(posedge clk) begin
		#2;
		m = q_meta[cyc % 1024];
		q_meta[cyc % 1024] = 80'd0;
		if (s8_valid !== (m[45] && m[44:43] == 2'd0) || s16_valid !== (m[45] && m[44:43] == 2'd1) ||
		    s32_valid !== (m[45] && m[44:43] == 2'd2)) begin
			errors = errors + 1;
			$display("FAIL atg_su_lda.rw: cycle %0d valid %b %b %b, expected %b shape %0d", cyc,
				s8_valid, s16_valid, s32_valid, m[45], m[44:43]);
		end else if (s8_valid && (s8_warp !== m[42:41] || s8_grp !== m[40:39] ||
		    s8_rd !== m[38:32] || s8_lanes !== m[7:0] || s8_data !== q_data[cyc % 1024][255:0])) begin
			errors = errors + 1;
			$display("FAIL atg_su_lda.rw: NPHYS 8 result at cycle %0d", cyc);
		end else if (s16_valid && (s16_warp !== m[42:41] || s16_grp !== m[39] ||
		    s16_rd !== m[38:32] || s16_lanes !== m[15:0] ||
		    s16_data !== q_data[cyc % 1024][511:0])) begin
			errors = errors + 1;
			$display("FAIL atg_su_lda.rw: NPHYS 16 result at cycle %0d", cyc);
		end else if (s32_valid && (s32_warp !== m[42:41] || s32_rd !== m[38:32] ||
		    s32_lanes !== m[31:0] || s32_data !== q_data[cyc % 1024])) begin
			errors = errors + 1;
			$display("FAIL atg_su_lda.rw: NPHYS 32 result at cycle %0d", cyc);
		end
	end

	initial begin
		for (i = 0; i < 1024; i = i + 1)
			q_meta[i] = 80'd0;
		for (i = 0; i < 3; i = i + 1)
			bz[i] = 0;
		repeat (3) tick;
		rst_n = 1'b1;
		tick;
		for (w = 0; w < 4; w = w + 1)
			for (p = 0; p < 8; p = p + 1)
				for (v = 0; v < 3; v = v + 1)
					for (d = 0; d < 64; d = d + 1) begin
						tab[((w * 8 + p) * 3 + v) * 64 + d] = $random(seed);
						pw(w, {1'b0, p[2:0], v[1:0], d[5:0]}, tab[((w * 8 + p) * 3 + v) * 64 + d]);
					end
		/* two rounds: the maps of the first round, then new maps */
		for (n = 0; n < 2; n = n + 1) begin
			for (w = 0; w < 4; w = w + 1) begin
				pmap[w] = n == 0 ? 24'd0 : $random(seed);
				pw(w, 12'hFFF, {8'hAB, pmap[w]});
				/* the RX's d_s words (multisampling): neither table nor map */
				if (n == 1)
					for (d = 0; d < 4; d = d + 1)
						pw(w, 12'hFF8 + d[11:0], $random(seed));
			end
			for (i = 0; i < 900; i = i + 1) begin
				s = $unsigned($random(seed)) % 3;
				issue(s, ($random(seed) & 7) == 0 ? 1 : 11);
				if (($random(seed) & 3) == 0)
					tick;
			end
			repeat (10) tick;
		end
		if (errors == 0)
			$display("PASS atg_su_lda.rw");
		if (errors == 0)
			$display("PASS atg_su_lda.ms");
		if (e_ready == 0)
			$display("PASS atg_su_lda.ready");
		if (errors + e_ready == 0)
			$display("PASS atg_su_lda");
		else
			$display("FAIL atg_su_lda: %0d errors", errors + e_ready);
		$finish;
	end
endmodule

`default_nettype wire
