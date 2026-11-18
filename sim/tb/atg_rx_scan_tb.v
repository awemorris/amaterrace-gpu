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
 * ones.  dx_ready is random.  HAS_SU 0: no quad goes to atg_rx_frag (fq_*).
 * Then a second instance with HAS_SU 1 (the warp path, fq_ready random):
 *   ms1x — the same triangles as non-raw ones with MS_CTRL 0: the quads
 *          with coverage, fq_scov bit 4 l = the lane's coverage, fq_ccov
 *          = the coverage (one sample: as before)
 *   ms   — sim/vec/rx_scan_ms.txt (tools/rx-msaa-vectors.py from
 *          tools/msmodel.py): 4 samples and 1, SAMPLE_KILL, shared edges
 *          through sample locations, a sliver across empty quads (the
 *          skip): fq_scov and fq_ccov of every quad with a sample.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

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
	wire [15:0] fq_scov;
	wire [3:0] fq_ccov;
	wire dx_valid, dx_last, sq_req, busy;
	wire [15:0] dx_seq;
	wire [31:0] dx_xy;
	wire [3:0] dx_mask;
	wire [127:0] dx_depth;

	atg_rx_scan #(.HAS_SU(0)) dut (.clk(clk), .rst_n(rst_n), .st_we(1'b0), .st_idx(9'd0),
		.st_wdata(32'd0), .sp_valid(sp_valid), .sp_ready(sp_ready), .sp_tri(sp_tri),
		.sp_last(1'b0), .pt_free(pt_free), .pt_free_idx(pt_free_idx),
		.fq_valid(fq_valid), .fq_ready(1'b1), .fq_xy(fq_xy), .fq_scov(fq_scov), .fq_ccov(fq_ccov), .fq_end(fq_end),
		.f_busy(1'b0),
		.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
		.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
		.sq_req(sq_req), .sq_seq(sq_cnt), .busy(busy));

	/* The warp path (HAS_SU 1). */
	reg w_st_we = 1'b0;
	reg [8:0] w_st_idx = 9'd0;
	reg [31:0] w_st_wdata = 32'd0;
	reg w_sp_valid = 1'b0;
	reg [767:0] w_sp_tri = 0;
	reg w_fq_ready = 1'b0;
	wire w_sp_ready, w_pt_free, w_fq_valid, w_fq_end, w_dx_valid, w_dx_last, w_sq_req, w_busy;
	wire [7:0] w_pt_free_idx;
	wire [31:0] w_fq_xy, w_dx_xy;
	wire [15:0] w_fq_scov, w_dx_seq;
	wire [3:0] w_fq_ccov, w_dx_mask;
	wire [127:0] w_dx_depth;

	atg_rx_scan #(.HAS_SU(1)) dw (.clk(clk), .rst_n(rst_n), .st_we(w_st_we), .st_idx(w_st_idx),
		.st_wdata(w_st_wdata), .sp_valid(w_sp_valid), .sp_ready(w_sp_ready), .sp_tri(w_sp_tri),
		.sp_last(1'b0), .pt_free(w_pt_free), .pt_free_idx(w_pt_free_idx),
		.fq_valid(w_fq_valid), .fq_ready(w_fq_ready), .fq_xy(w_fq_xy), .fq_scov(w_fq_scov),
		.fq_ccov(w_fq_ccov), .fq_end(w_fq_end), .f_busy(1'b0),
		.dx_valid(w_dx_valid), .dx_ready(1'b1), .dx_seq(w_dx_seq), .dx_xy(w_dx_xy),
		.dx_mask(w_dx_mask), .dx_depth(w_dx_depth), .dx_last(w_dx_last),
		.sq_req(w_sq_req), .sq_seq(16'd0), .busy(w_busy));

	/* The warp path's expected quads: x, y, scov, ccov. */
	reg [15:0] wq_x [0:MAXQ-1];
	reg [15:0] wq_y [0:MAXQ-1];
	reg [15:0] wq_s [0:MAXQ-1];
	reg [3:0] wq_c [0:MAXQ-1];
	reg wq_seen [0:MAXQ-1];
	integer w_got, w_err, w_n, w_ends;
	integer w_match_idx, w_search_k;
	reg w_found;
	always @(posedge clk) begin
		w_fq_ready <= ($random(seed) & 3) != 0;
		if (w_fq_valid && w_fq_ready) begin
			if (w_fq_end) begin
				w_ends = w_ends + 1;
			end else begin
				w_found = 1'b0;
				w_match_idx = -1;
				for (w_search_k = 0; w_search_k < w_n; w_search_k = w_search_k + 1) begin
					if (!w_found && !wq_seen[w_search_k] &&
					    {wq_y[w_search_k], wq_x[w_search_k]} === w_fq_xy) begin
						w_found = 1'b1;
						w_match_idx = w_search_k;
					end
				end
				if (!w_found) begin
					w_err = w_err + 1;
					if (w_err < 8)
						$display("FAIL atg_rx_scan.ms: unexpected quad %h scov %h ccov %h (w_got=%0d, w_n=%0d)",
							w_fq_xy, w_fq_scov, w_fq_ccov, w_got, w_n);
				end else begin
					wq_seen[w_match_idx] = 1'b1;
					if (w_fq_scov !== wq_s[w_match_idx] || w_fq_ccov !== wq_c[w_match_idx]) begin
						w_err = w_err + 1;
						if (w_err < 8)
							$display("FAIL atg_rx_scan.ms: quad %h scov %h ccov %h, want %h %h",
								w_fq_xy, w_fq_scov, w_fq_ccov, wq_s[w_match_idx], wq_c[w_match_idx]);
					end
				end
				w_got = w_got + 1;
			end
		end
		if (w_dx_valid) begin
			w_err = w_err + 1;
			$display("FAIL atg_rx_scan.ms: a direct quad on the warp path");
		end
	end

	task w_st;
		input [8:0] idx;
		input [31:0] v;
		begin
			@(posedge clk);
			w_st_we <= 1'b1;
			w_st_idx <= idx;
			w_st_wdata <= v;
			@(posedge clk);
			w_st_we <= 1'b0;
		end
	endtask

	/* One triangle on the warp path; wait for its end marker. */
	task w_tri;
		input [767:0] s;
		integer n0;
		begin
			n0 = w_ends;
			while (w_busy)
				@(posedge clk);
			w_sp_valid <= 1'b1;
			w_sp_tri <= s;
			@(posedge clk);
			while (!w_sp_ready)
				@(posedge clk);
			w_sp_valid <= 1'b0;
			@(posedge clk);
			#1;
			n0 = 0;
			while ((w_busy || w_fq_valid) && n0 < 200000) begin
				@(posedge clk);
				n0 = n0 + 1;
			end
		end
	endtask

	reg [767:0] t_sp [0:MAXT-1];
	integer t_nq [0:MAXT-1];
	reg [15:0] q_x [0:MAXQ-1];
	reg [15:0] q_y [0:MAXQ-1];
	reg [3:0] q_m [0:MAXQ-1];
	reg q_l [0:MAXQ-1];
	reg [127:0] q_z [0:MAXQ-1];
	reg q_seen [0:MAXQ-1];
	integer q_t [0:MAXQ-1];
	integer t_q0 [0:MAXT-1];
	integer nt, nq, fd, code, i, j, seed;
	reg [7:0] tag;
	reg [767:0] sp;
	reg [15:0] x, y;
	reg [3:0] m;
	reg [31:0] z0, z1, z2, z3;
	integer e_cov = 0, e_dir = 0, e_free = 0, got = 0, nfree = 0, want_free = 0, nseq = 0;
	integer cur_t, e_ms = 0, ntm, k;
	integer match_idx, search_k, qidx;
	reg found;
	reg [15:0] s16;
	reg [31:0] ms_ctrl, ms_kill;
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
			found = 1'b0;
			match_idx = -1;
			for (search_k = 0; search_k < t_nq[cur_t]; search_k = search_k + 1) begin
				if (!found && !q_seen[t_q0[cur_t] + search_k] &&
				    {q_y[t_q0[cur_t] + search_k], q_x[t_q0[cur_t] + search_k]} === dx_xy) begin
					found = 1'b1;
					match_idx = t_q0[cur_t] + search_k;
				end
			end
			if (!found) begin
				e_cov = e_cov + 1;
				if (e_cov < 8)
					$display("FAIL atg_rx_scan: tri %0d unexpected/dup quad %h mask %h", cur_t, dx_xy, dx_mask);
			end else begin
				q_seen[match_idx] = 1'b1;
				if (dx_mask !== q_m[match_idx]) begin
					e_cov = e_cov + 1;
					if (e_cov < 8)
						$display("FAIL atg_rx_scan: tri %0d quad %h mask %h, expected %h", cur_t, dx_xy, dx_mask, q_m[match_idx]);
				end
				if (dx_depth !== q_z[match_idx]) begin
					e_dir = e_dir + 1;
					if (e_dir < 8)
						$display("FAIL atg_rx_scan: tri %0d quad %h depth %h, expected %h", cur_t, dx_xy, dx_depth, q_z[match_idx]);
				end
				if (dx_seq !== t_seq[cur_t]) begin
					e_dir = e_dir + 1;
					if (e_dir < 8)
						$display("FAIL atg_rx_scan: tri %0d seq %h, expected %h", cur_t, dx_seq, t_seq[cur_t]);
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

	reg quick = 1'b0;
	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		if ($test$plusargs("quick"))
			quick = 1'b1;
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
				if (quick && nt >= 4) begin
					code = 0;
				end else begin
					t_sp[nt] = sp;
					t_nq[nt] = j;
					nt = nt + 1;
				end
			end else if (tag == "Q") begin
				code = $fscanf(fd, " %h %h %h %d %h %h %h %h\n", x, y, m, j, z0, z1, z2, z3);
				if (!quick || nt <= 4) begin
					q_x[nq] = x;
					q_y[nq] = y;
					q_m[nq] = m;
					q_l[nq] = j;
					q_z[nq] = {z3, z2, z1, z0};
					q_t[nq] = nt - 1;
					nq = nq + 1;
				end
			end else
				code = 0;
		end
		$fclose(fd);
		for (i = 0; i < nt; i = i + 1) begin
			if (i == 0)
				t_q0[i] = 0;
			else
				t_q0[i] = t_q0[i - 1] + t_nq[i - 1];
		end
		for (i = 0; i < nq; i = i + 1)
			q_seen[i] = 1'b0;
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
			for (i = 0; i < nq; i = i + 1)
				if (!q_seen[i])
					$display("MISSING QUAD: tri %0d quad %0d: %h mask %h", q_t[i], i, {q_y[i], q_x[i]}, q_m[i]);
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

		/* ms1x: the same triangles on the warp path, one sample. */
		w_err = 0;
		for (i = 0; i < nt; i = i + 1) begin
			w_got = 0;
			w_ends = 0;
			w_n = 0;
			for (j = 0; j < t_nq[i]; j = j + 1) begin
				qidx = t_q0[i] + j;
				if (q_m[qidx] != 4'd0) begin
					wq_x[w_n] = q_x[qidx];
					wq_y[w_n] = q_y[qidx];
					wq_s[w_n] = {3'd0, q_m[qidx][3], 3'd0, q_m[qidx][2], 3'd0, q_m[qidx][1], 3'd0, q_m[qidx][0]};
					wq_c[w_n] = q_m[qidx];
					wq_seen[w_n] = 1'b0;
					w_n = w_n + 1;
				end
			end
			sp = t_sp[i];
			sp[764] = 1'b0;
			w_tri(sp);
			if (w_n > 0 && (w_got != w_n || w_ends != 1)) begin
				w_err = w_err + 1;
				$display("FAIL atg_rx_scan.ms1x: tri %0d: %0d of %0d quads, %0d ends", i, w_got, w_n, w_ends);
			end
		end
		if (w_err == 0)
			$display("PASS atg_rx_scan.ms1x");
		e_ms = w_err;

		/* ms: the multisampling vectors. */
`ifdef CFG_ENABLE_MSAA
		if (`CFG_ENABLE_MSAA != 0) begin
			fd = $fopen("sim/vec/rx_scan_ms.txt", "r");
			if (fd == 0) begin
				e_ms = e_ms + 1;
				$display("FAIL atg_rx_scan.ms: no sim/vec/rx_scan_ms.txt");
			end
			w_err = 0;
			ntm = 0;
			code = fd != 0;
			while (code > 0) begin
				code = $fscanf(fd, "%c", tag);
				if (tag == "T") begin
					code = $fscanf(fd, " %h %h %h %d\n", sp, ms_ctrl, ms_kill, j);
					if (quick && ntm >= 4) begin
						code = 0;
					end else begin
						w_got = 0;
						w_ends = 0;
						w_n = j;
						for (k = 0; k < j; k = k + 1) begin
							code = $fscanf(fd, "Q %h %h %h %h\n", x, y, s16, m);
							wq_x[k] = x;
							wq_y[k] = y;
							wq_s[k] = s16;
							wq_c[k] = m;
							wq_seen[k] = 1'b0;
						end
						w_st(9'h05E, ms_ctrl);
						w_st(9'h05F, ms_kill);
						w_tri(sp);
						if (w_got != w_n || w_ends != 1) begin
							w_err = w_err + 1;
							$display("FAIL atg_rx_scan.ms: tri %0d: %0d of %0d quads, %0d ends", ntm, w_got,
								w_n, w_ends);
							for (k = 0; k < j; k = k + 1)
								if (!wq_seen[k])
									$display("MISSING MS QUAD: tri %0d quad %0d: %h scov %h ccov %h", ntm, k, {wq_y[k], wq_x[k]}, wq_s[k], wq_c[k]);
						end
						ntm = ntm + 1;
					end
				end else
					code = 0;
			end
			$display("atg_rx_scan: %0d multisampling triangles", ntm);
			if (w_err == 0 && (quick ? ntm >= 4 : ntm > 20))
				$display("PASS atg_rx_scan.ms");
			else
				e_ms = e_ms + 1;
		end else begin
			$display("SKIP atg_rx_scan.ms: CFG_ENABLE_MSAA=0");
		end
`else
		$display("SKIP atg_rx_scan.ms: CFG_ENABLE_MSAA=0");
`endif
		if (e_cov + e_dir + e_free + e_ms == 0)
			$display("PASS atg_rx_scan");
		$finish;
	end
endmodule

`default_nettype wire
