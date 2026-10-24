/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_clip_tb: 60 primitives read from a PT model (all inside, all
 * outside, one and two vertices behind the near plane, random) and 4
 * DRAW_RAW triangles through atg_rx_clip; each cl_tri compared with the
 * reference model's (sim/vec/rx_clip.txt from tools/rx-vectors.py).
 * pt_busy is random and no PT read may happen under it; cl_ready is
 * random.  Then the CAPS[30] cases of sim/vec/rx_clip2.txt (from
 * tools/rx-clip-vectors.py, the model's clip2): lines, points, DEPTH_CLAMP,
 * the w, far and guard-band planes, the last-use flags and rasterizer
 * discard, each with its STATE writes; every output word by word, the
 * kind included.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_clip_tb;
	localparam MAXC = 512;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0, raw_kick = 1'b0, prim_valid = 1'b0, prim_last = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg [25:0] prim_vtx = 0;
	reg [2:0] prim_free = 0;
	reg pt_busy = 1'b0, cl_ready = 1'b0;
	reg [31:0] pt_rdata = 0;
	wire prim_ready, pt_rd, cl_valid, cl_last, busy;
	wire [7:0] pt_idx;
	wire [5:0] pt_word;
	wire [701:0] cl_tri;

	atg_rx_clip dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .raw_kick(raw_kick), .prim_valid(prim_valid),
		.prim_ready(prim_ready), .prim_vtx(prim_vtx), .prim_free(prim_free),
		.prim_last(prim_last), .pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word),
		.pt_rdata(pt_rdata), .pt_busy(pt_busy), .cl_valid(cl_valid), .cl_ready(cl_ready),
		.cl_tri(cl_tri), .cl_last(cl_last), .busy(busy));

	reg [31:0] pt [0:255][0:3];
	reg [701:0] exp_c [0:MAXC-1];
	reg exp_l [0:MAXC-1];
	reg exp_last [0:MAXC-1];	/* the last output of its primitive */
	integer exp_n = 0, got = 0;
	integer e_pass = 0, e_near = 0, e_raw = 0, e_busy = 0;
	integer is_raw [0:MAXC-1];
	integer is_near [0:MAXC-1];
	integer sect_of [0:MAXC-1];	/* -1: rx_clip.txt; 0-7: rx_clip2.txt's section */
	integer e_s [0:7];
	integer e_lu = 0, nfail = 0;
	reg [8:0] sidx;
	reg [31:0] sval;
	integer sect, kind, lst;
	integer fd, code, i, j, seed, nt, cnt;
	reg [7:0] tag;
	reg [31:0] wv [0:11];
	reg [7:0] e0, e1, e2;
	reg [2:0] fr;
	reg [699:0] cv;

	/* the PT model: data the cycle after pt_rd */
	always @(posedge clk) begin
		pt_busy <= ($random(seed) & 3) == 0;
		cl_ready <= ($random(seed) & 1) != 0;
		if (pt_rd) begin
			pt_rdata <= pt[pt_idx][pt_word[1:0]];
			if (pt_busy) begin
				e_busy = e_busy + 1;
				$display("FAIL atg_rx_clip: PT read under pt_busy");
			end
		end
		if (cl_valid && cl_ready) begin
			if (got < exp_n && cl_tri[698:696] != 3'd0 && !exp_last[got]) begin
				e_lu = e_lu + 1;
				$display("FAIL atg_rx_clip: output %0d has last-use flags but is not its primitive's last", got);
			end
			if (got >= exp_n || cl_tri !== exp_c[got] || cl_last !== exp_l[got]) begin
				if (got < exp_n && sect_of[got] >= 0)
					e_s[sect_of[got]] = e_s[sect_of[got]] + 1;
				else if (is_raw[got])
					e_raw = e_raw + 1;
				else if (is_near[got])
					e_near = e_near + 1;
				else
					e_pass = e_pass + 1;
				nfail = nfail + 1;
				if (nfail < 8)
					$display("FAIL atg_rx_clip: triangle %0d last %b\n got %h\n exp %h", got,
						cl_last, cl_tri, exp_c[got]);
			end
			got = got + 1;
		end
	end

	task st_put;
		input [8:0] i_;
		input [31:0] v;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= v;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		fd = $fopen("sim/vec/rx_clip.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rx_clip: no sim/vec/rx_clip.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		code = 1;
		cnt = 0;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "P") begin
				code = $fscanf(fd, " %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %d\n",
					wv[0], wv[1], wv[2], wv[3], wv[4], wv[5], wv[6], wv[7], wv[8], wv[9],
					wv[10], wv[11], e0, e1, e2, fr, nt);
				for (j = 0; j < 4; j = j + 1) begin
					pt[e0][j] = wv[j];
					pt[e1][j] = wv[4 + j];
					pt[e2][j] = wv[8 + j];
				end
				for (i = 0; i < nt; i = i + 1) begin
					code = $fscanf(fd, "C %h\n", cv);
					exp_c[exp_n] = {2'd2, cv};
					exp_l[exp_n] = i == nt - 1 && cnt[0];
					is_raw[exp_n] = 0;
					is_near[exp_n] = wv[2][31] || wv[6][31] || wv[10][31];
					sect_of[exp_n] = -1;
					exp_last[exp_n] = i == nt - 1;
					exp_n = exp_n + 1;
				end
				prim_valid <= 1'b1;
				prim_vtx <= {2'd2, e2, e1, e0};
				prim_free <= fr;
				prim_last <= cnt[0];
				@(posedge clk);
				while (!prim_ready)
					@(posedge clk);
				prim_valid <= 1'b0;
				@(posedge clk);
				while (busy)
					@(posedge clk);
				cnt = cnt + 1;
			end else if (tag == "R") begin
				code = $fscanf(fd, " %h %h %h %h %h %h %h %h %h\n", wv[0], wv[1], wv[2], wv[3],
					wv[4], wv[5], wv[6], wv[7], wv[8]);
				code = $fscanf(fd, "C %h\n", cv);
				exp_c[exp_n] = {2'd2, cv};
				exp_l[exp_n] = 1'b1;
				is_raw[exp_n] = 1;
				is_near[exp_n] = 0;
				sect_of[exp_n] = -1;
				exp_last[exp_n] = 1'b1;
				exp_n = exp_n + 1;
				for (j = 0; j < 9; j = j + 1)
					st_put(9'h1E0 + j, wv[j]);
				raw_kick <= 1'b1;
				@(posedge clk);
				raw_kick <= 1'b0;
				@(posedge clk);
				while (busy)
					@(posedge clk);
			end else
				code = 0;
		end
		$fclose(fd);

		/* the CAPS[30] cases */
		for (i = 0; i < 8; i = i + 1)
			e_s[i] = 0;
		fd = $fopen("sim/vec/rx_clip2.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rx_clip: no sim/vec/rx_clip2.txt");
			$finish;
		end
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "S") begin
				code = $fscanf(fd, " %h %h\n", sidx, sval);
				st_put(sidx, sval);
			end else if (tag == "P") begin
				code = $fscanf(fd, " %d %d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %d %d\n",
					sect, kind, wv[0], wv[1], wv[2], wv[3], wv[4], wv[5], wv[6], wv[7], wv[8],
					wv[9], wv[10], wv[11], e0, e1, e2, fr, lst, nt);
				for (j = 0; j < 4; j = j + 1) begin
					pt[e0][j] = wv[j];
					pt[e1][j] = wv[4 + j];
					pt[e2][j] = wv[8 + j];
				end
				for (i = 0; i < nt; i = i + 1) begin
					code = $fscanf(fd, "C %h\n", exp_c[exp_n]);
					exp_l[exp_n] = i == nt - 1 && lst != 0;
					exp_last[exp_n] = i == nt - 1;
					is_raw[exp_n] = 0;
					is_near[exp_n] = 0;
					sect_of[exp_n] = sect;
					exp_n = exp_n + 1;
				end
				prim_valid <= 1'b1;
				prim_vtx <= {kind[1:0], e2, e1, e0};
				prim_free <= fr;
				prim_last <= lst != 0;
				@(posedge clk);
				while (!prim_ready)
					@(posedge clk);
				prim_valid <= 1'b0;
				@(posedge clk);
				while (busy)
					@(posedge clk);
				cnt = cnt + 1;
			end else
				code = 0;
		end
		$fclose(fd);
		repeat (4) @(posedge clk);
		if (got != exp_n) begin
			e_pass = e_pass + 1;
			$display("FAIL atg_rx_clip: %0d of %0d triangles", got, exp_n);
		end
		$display("atg_rx_clip: %0d primitives, %0d triangles", cnt, got);
		if (e_pass == 0)
			$display("PASS atg_rx_clip.pass");
		if (e_near == 0)
			$display("PASS atg_rx_clip.near");
		if (e_raw == 0)
			$display("PASS atg_rx_clip.raw");
		if (e_busy == 0)
			$display("PASS atg_rx_clip.ptbusy");
		if (e_s[0] == 0)
			$display("PASS atg_rx_clip.line");
		if (e_s[1] == 0)
			$display("PASS atg_rx_clip.point");
		if (e_s[2] == 0)
			$display("PASS atg_rx_clip.clampw");
		if (e_s[3] == 0)
			$display("PASS atg_rx_clip.wneg");
		if (e_s[4] == 0)
			$display("PASS atg_rx_clip.guard");
		if (e_s[5] == 0)
			$display("PASS atg_rx_clip.guardline");
		if (e_s[6] == 0 && e_lu == 0)
			$display("PASS atg_rx_clip.lastuse");
		if (e_s[7] == 0)
			$display("PASS atg_rx_clip.discard");
		if (e_pass + e_near + e_raw + e_busy + e_lu + e_s[0] + e_s[1] + e_s[2] + e_s[3] +
			e_s[4] + e_s[5] + e_s[6] + e_s[7] == 0)
			$display("PASS atg_rx_clip");
		$finish;
	end
endmodule

`default_nettype wire
