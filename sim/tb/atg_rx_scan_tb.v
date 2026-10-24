/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_scan_tb: 43 set-up triangles (large, small, slivers, empty and
 * off-screen ones on a 128x96 target) through atg_rx_scan with HAS_SU 0;
 * the direct quads (position, coverage, depth, last flag) compared with
 * the reference rasterizer (sim/vec/rx_scan.txt from tools/rx-vectors.py:
 * top-left rule, exact edges, fp32 depth); one sequence number per
 * triangle with quads; pt_free once per flagged vertex of the non-raw
 * ones.  dx_ready is random.  HAS_SU 0: no quad goes to atg_rx_frag (fq_*); the
 * warp path is checked by atg_rx_frag_tb and atg_top_shade_tb.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_scan_tb;
	localparam MAXT = 64;
	localparam MAXQ = 4096;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg sp_valid = 1'b0;
	reg [767:0] sp_tri = 0;
	reg dx_ready = 1'b0;
	reg [15:0] sq_cnt = 16'd100;
	wire sp_ready, pt_free, fq_valid, fq_end;
	wire [7:0] pt_free_idx;
	wire [31:0] fq_xy;
	wire [3:0] fq_cov;
	wire dx_valid, dx_last, sq_req, busy;
	wire [15:0] dx_seq;
	wire [31:0] dx_xy;
	wire [3:0] dx_mask;
	wire [127:0] dx_depth;

	atg_rx_scan #(.HAS_SU(0)) dut (.clk(clk), .rst_n(rst_n), .st_we(1'b0), .st_idx(9'd0),
		.st_wdata(32'd0), .sp_valid(sp_valid), .sp_ready(sp_ready), .sp_tri(sp_tri),
		.sp_last(1'b0), .pt_free(pt_free), .pt_free_idx(pt_free_idx),
		.fq_valid(fq_valid), .fq_ready(1'b1), .fq_xy(fq_xy), .fq_cov(fq_cov), .fq_end(fq_end),
		.f_busy(1'b0),
		.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
		.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
		.sq_req(sq_req), .sq_seq(sq_cnt), .busy(busy));

	reg [767:0] t_sp [0:MAXT-1];
	integer t_nq [0:MAXT-1];
	reg [15:0] q_x [0:MAXQ-1];
	reg [15:0] q_y [0:MAXQ-1];
	reg [3:0] q_m [0:MAXQ-1];
	reg q_l [0:MAXQ-1];
	reg [127:0] q_z [0:MAXQ-1];
	integer q_t [0:MAXQ-1];
	integer nt, nq, fd, code, i, j, seed;
	reg [7:0] tag;
	reg [767:0] sp;
	reg [15:0] x, y;
	reg [3:0] m;
	reg [31:0] z0, z1, z2, z3;
	integer e_cov = 0, e_dir = 0, e_free = 0, got = 0, nfree = 0, want_free = 0, nseq = 0;
	integer cur_t;
	reg [15:0] t_seq [0:MAXT-1];

	/* sequence numbers as atg_rx_order gives them */
	always @(posedge clk)
		if (sq_req) begin
			sq_cnt <= sq_cnt + 16'd1;
			nseq = nseq + 1;
		end

	/* dx checker */
	always @(posedge clk) begin
		dx_ready <= ($random(seed) & 3) != 0;
		if (dx_valid && dx_ready) begin
			if (got >= nq) begin
				e_dir = e_dir + 1;
				$display("FAIL atg_rx_scan: extra quad %h", dx_xy);
			end else begin
				if (dx_xy !== {q_y[got], q_x[got]} || dx_mask !== q_m[got] ||
				    dx_last !== q_l[got]) begin
					e_cov = e_cov + 1;
					if (e_cov < 8)
						$display("FAIL atg_rx_scan: tri %0d quad %0d: %h mask %h last %b, expected %h %h %b",
							q_t[got], got, dx_xy, dx_mask, dx_last, {q_y[got], q_x[got]},
							q_m[got], q_l[got]);
				end
				if (dx_depth !== q_z[got]) begin
					e_dir = e_dir + 1;
					if (e_dir < 8)
						$display("FAIL atg_rx_scan: tri %0d quad %0d depth %h, expected %h",
							q_t[got], got, dx_depth, q_z[got]);
				end
				if (dx_seq !== t_seq[q_t[got]]) begin
					e_dir = e_dir + 1;
					$display("FAIL atg_rx_scan: tri %0d seq %h, expected %h", q_t[got], dx_seq,
						t_seq[q_t[got]]);
				end
			end
			got = got + 1;
		end
		if (pt_free) begin
			nfree = nfree + 1;
			if (pt_free_idx < cur_t || pt_free_idx > cur_t + 2) begin
				e_free = e_free + 1;
				$display("FAIL atg_rx_scan: tri %0d frees %0d", cur_t, pt_free_idx);
			end
		end
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		fd = $fopen("sim/vec/rx_scan.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rx_scan: no sim/vec/rx_scan.txt");
			$finish;
		end
		nt = 0;
		nq = 0;
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "T") begin
				code = $fscanf(fd, " %h %d\n", sp, j);
				t_sp[nt] = sp;
				t_nq[nt] = j;
				nt = nt + 1;
			end else if (tag == "Q") begin
				code = $fscanf(fd, " %h %h %h %d %h %h %h %h\n", x, y, m, j, z0, z1, z2, z3);
				q_x[nq] = x;
				q_y[nq] = y;
				q_m[nq] = m;
				q_l[nq] = j;
				q_z[nq] = {z3, z2, z1, z0};
				q_t[nq] = nt - 1;
				nq = nq + 1;
			end else
				code = 0;
		end
		$fclose(fd);
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		for (i = 0; i < nt; i = i + 1) begin
			while (busy)
				@(posedge clk);
			cur_t = i;
			t_seq[i] = sq_cnt;
			if (!t_sp[i][764])
				for (j = 0; j < 3; j = j + 1)
					want_free = want_free + t_sp[i][760 + j];
			sp_valid <= 1'b1;
			sp_tri <= t_sp[i];
			@(posedge clk);
			while (!sp_ready)
				@(posedge clk);
			sp_valid <= 1'b0;
			@(posedge clk);
		end
		j = 0;
		while ((busy || got < nq) && j < 200000) begin
			@(posedge clk);
			j = j + 1;
		end
		repeat (4) @(posedge clk);
		j = 0;
		for (i = 0; i < nt; i = i + 1)
			if (t_nq[i] > 0)
				j = j + 1;
		if (got != nq || nseq != j) begin
			e_dir = e_dir + 1;
			$display("FAIL atg_rx_scan: %0d of %0d quads, %0d numbers for %0d triangles", got, nq,
				nseq, j);
		end
		if (nfree != want_free) begin
			e_free = e_free + 1;
			$display("FAIL atg_rx_scan: %0d frees, expected %0d", nfree, want_free);
		end
		if (fq_valid) begin
			e_dir = e_dir + 1;
			$display("FAIL atg_rx_scan: warp path active");
		end
		$display("atg_rx_scan: %0d triangles, %0d quads", nt, nq);
		if (e_cov == 0)
			$display("PASS atg_rx_scan.coverage");
		if (e_dir == 0)
			$display("PASS atg_rx_scan.direct");
		if (e_free == 0)
			$display("PASS atg_rx_scan.free");
		if (e_cov + e_dir + e_free == 0)
			$display("PASS atg_rx_scan");
		$finish;
	end
endmodule

`default_nettype wire
