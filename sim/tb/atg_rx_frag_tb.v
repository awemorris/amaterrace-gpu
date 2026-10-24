/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_frag_tb: atg_rx_frag with the set-up triangles and their covered
 * quads of sim/vec/rx_frag.txt (tools/rx-vectors.py: clip-space triangles
 * through the model's setup, VARYING_COUNT 0, 1, 4 and 32), a PT model
 * (word w of entry e reads {e, w, 0xC0DE}, one cycle after pt_rd), an SU
 * model (fl_gnt some cycles after fl_req) and a sequence counter.
 *   copy  — per warp: 3 × VARYING_COUNT primitive table writes (vertex v,
 *           word 4 + w, from PT entry v of the triangle) then the map
 *           (0xFFF, 0), after the grant; pt_busy while the PT is read
 *   warps — the warps of the model (up to 8 quads each): r0-r5 of every
 *           lane of their quads (b0, b1, b2, z, x + 0.5, y + 0.5) equal
 *           the model's bit for bit, then fl_go with the quads' EXEC, the
 *           coverage, a new sequence number and the facing.  One
 *           sample (MS_CTRL 0): r6 = the lane's coverage bit.
 *   ms    — sim/vec/rx_frag_ms.txt (tools/rx-msaa-vectors.py from
 *           tools/msmodel.py): 4 samples (fq_scov, fq_ccov), with and
 *           without CENTROID, and one sample with CENTROID: r0-r6 (r3 not
 *           clamped with 4 samples) and r7-r9, and with 4 samples the
 *           triangle's d_s as table words 0xFF8-0xFFB after the map of
 *           every warp.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_frag_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg t_load = 1'b0;
	reg [767:0] t_tri = 0;
	reg fq_valid = 1'b0, fq_end = 1'b0;
	reg [31:0] fq_xy = 0;
	reg [15:0] fq_scov = 0;
	reg [3:0] fq_ccov = 0;
	reg fl_gnt = 1'b0;
	reg [31:0] pt_rdata = 0;
	reg [15:0] seq = 16'd40;
	wire fq_ready, busy, pt_rd, pt_busy, fl_req, fl_we, fl_pw_we, fl_go, sq_req;
	wire [7:0] pt_idx;
	wire [5:0] pt_word, fl_reg;
	wire [4:0] fl_lane;
	wire [31:0] fl_data, fl_pw_data, fl_mask;
	wire [11:0] fl_pw_addr;
	wire [63:0] fl_info;

	atg_rx_frag dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .t_load(t_load), .t_tri(t_tri), .fq_valid(fq_valid),
		.fq_ready(fq_ready), .fq_xy(fq_xy), .fq_scov(fq_scov), .fq_ccov(fq_ccov), .fq_end(fq_end),
		.busy(busy),
		.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
		.pt_busy(pt_busy), .fl_req(fl_req), .fl_gnt(fl_gnt), .fl_we(fl_we), .fl_reg(fl_reg),
		.fl_lane(fl_lane), .fl_data(fl_data), .fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr),
		.fl_pw_data(fl_pw_data), .fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
		.sq_req(sq_req), .sq_seq(seq));

	reg [15:0] qs;
	integer e0;
	integer seed = 1, e_copy = 0, e_warp = 0, fd, rc, i, j, q, nw, nq, vc, ntri = 0, nwarp = 0;
	reg [8*2-1:0] kind;
	reg [31:0] lw [0:9];
	/* expected per warp: the lanes' registers, its quads */
	reg [31:0] x_reg [0:319];	/* (lane*nr + reg) */
	integer nr = 7, ms4 = 0, e_ms = 0, ntm = 0;
	reg [31:0] dsw [0:3];
	reg [31:0] ctrl, kl;
	reg [31:0] x_cov;
	integer x_nq;
	integer n_we, n_pw, gdelay;
	reg granted;

	/* PT and SU models, monitors. */
	always @(posedge clk) begin
		if (pt_rd)
			pt_rdata <= {pt_idx, 2'b00, pt_word, 16'hC0DE};
		if (pt_rd && !pt_busy) begin
			e_copy = e_copy + 1;
			$display("FAIL atg_rx_frag.copy: pt_rd without pt_busy");
		end
		fl_gnt <= 1'b0;
		if (fl_req && !fl_gnt && !granted) begin
			if (gdelay == 0) begin
				fl_gnt <= 1'b1;
				granted = 1'b1;
				n_pw = 0;
				n_we = 0;
			end else
				gdelay = gdelay - 1;
		end
		if (sq_req)
			seq <= seq + 16'd1;
	end

	/* Writes of the current warp, checked as they come. */
	reg [11:0] want_a;
	reg [31:0] want_d;
	integer pv, pw_, ln, rg;
	always @(posedge clk) begin
		#1;
		if (fl_pw_we) begin
			if (!granted) begin
				e_copy = e_copy + 1;
				$display("FAIL atg_rx_frag.copy: table write before the grant");
			end
			if (n_pw < 3 * vc) begin
				pv = n_pw / vc;
				pw_ = n_pw % vc;
				want_a = {1'b0, 3'd0, pv[1:0], 6'd4 + pw_[5:0]};
				want_d = {t_tri[736 + 8 * pv +: 8], 2'b00, 6'd4 + pw_[5:0], 16'hC0DE};
			end else if (n_pw == 3 * vc) begin
				want_a = 12'hFFF;
				want_d = 32'd0;
			end else begin
				pv = n_pw - 3 * vc - 1;
				want_a = 12'hFF8 + pv[1:0];
				want_d = dsw[pv[1:0]];
			end
			if (n_pw > 3 * vc + (ms4 ? 4 : 0) || fl_pw_addr !== want_a || fl_pw_data !== want_d) begin
				e_copy = e_copy + 1;
				$display("FAIL atg_rx_frag.copy: tri %0d write %0d: %h %h, want %h %h", ntri,
					n_pw, fl_pw_addr, fl_pw_data, want_a, want_d);
			end
			n_pw = n_pw + 1;
		end
		if (fl_we) begin
			ln = fl_lane;
			rg = fl_reg;
			if (n_we != (ln * nr + rg) || rg >= nr || n_pw != 3 * vc + 1 + (ms4 ? 4 : 0) ||
			    fl_data !== x_reg[ln * nr + rg]) begin
				e_warp = e_warp + 1;
				if (e_warp < 10)
					$display("FAIL atg_rx_frag.warps: tri %0d warp %0d lane %0d r%0d = %h, want %h (write %0d)",
						ntri, nwarp, ln, rg, fl_data, x_reg[ln * nr + rg], n_we);
			end
			n_we = n_we + 1;
		end
		if (fl_go) begin
			if (n_we != 4 * nr * x_nq || fl_mask !== (x_nq == 8 ? 32'hFFFFFFFF : (32'd1 << (4 * x_nq)) - 1) ||
			    fl_info !== {15'd0, t_tri[763], seq, x_cov}) begin
				e_warp = e_warp + 1;
				$display("FAIL atg_rx_frag.warps: tri %0d go: %0d writes, mask %h info %h", ntri,
					n_we, fl_mask, fl_info);
			end
			granted = 1'b0;
			nwarp = nwarp + 1;
		end
	end

	task tick;
		begin
			@(posedge clk);
			#2;
		end
	endtask

	task send_quad;
		input [31:0] xy;
		input [15:0] sv;
		input [3:0] cv;
		input e;
		begin
			while ($random(seed) & 1)
				tick;
			fq_valid = 1'b1;
			fq_xy = xy;
			fq_scov = sv;
			fq_ccov = cv;
			fq_end = e;
			while (!fq_ready)
				tick;
			tick;
			fq_valid = 1'b0;
			fq_end = 1'b0;
		end
	endtask

	reg [15:0] qx, qy;
	reg [3:0] qc;
	integer t;
	initial begin
		granted = 1'b0;
		gdelay = 0;
		repeat (3) tick;
		rst_n = 1'b1;
		tick;
		fd = $fopen("sim/vec/rx_frag.txt", "r");
		if (fd == 0) begin
			e_warp = e_warp + 1;
			$display("FAIL atg_rx_frag: no sim/vec/rx_frag.txt");
		end
		rc = $fscanf(fd, "%s", kind);
		while (fd != 0 && kind == "T") begin
			rc = $fscanf(fd, " %h %d %d\n", t_tri, vc, nw);
			st_we = 1'b1;
			st_idx = 9'h05B;
			st_wdata = vc;
			t_load = 1'b1;
			tick;
			st_we = 1'b0;
			t_load = 1'b0;
			for (i = 0; i < nw; i = i + 1) begin
				rc = $fscanf(fd, "W %d\n", nq);
				/* the warp's expectations, then its quads (the warp starts after its last) */
				t = 0;
				x_cov = 0;
				x_nq = nq;
				for (q = 0; q < nq; q = q + 1) begin
					rc = $fscanf(fd, "Q %h %h %h\n", qx, qy, qc);
					x_cov[4 * q +: 4] = qc;
					for (j = 0; j < 4; j = j + 1) begin
						rc = $fscanf(fd, "L %h %h %h %h %h %h\n", lw[0], lw[1], lw[2], lw[3],
							lw[4], lw[5]);
						for (t = 0; t < 6; t = t + 1)
							x_reg[(4 * q + j) * 7 + t] = lw[t];
						x_reg[(4 * q + j) * 7 + 6] = qc[j];
					end
					send_quad({qy, qx}, {3'd0, qc[3], 3'd0, qc[2], 3'd0, qc[1], 3'd0, qc[0]}, qc,
						1'b0);
				end
				if (nq < 8)
					send_quad(32'd0, 16'd0, 4'd0, 1'b1);
				gdelay = $unsigned($random(seed)) % 6;
				t = 0;
				while (granted || (busy && t < 20000) || fl_req) begin
					tick;
					t = t + 1;
				end
			end
			if (nw == 0 || x_nq == 8)
				send_quad(32'd0, 16'd0, 4'd0, 1'b1);	/* the end marker of the triangle */
			t = 0;
			while (busy && t < 20000) begin
				tick;
				t = t + 1;
			end
			if (busy) begin
				e_warp = e_warp + 1;
				$display("FAIL atg_rx_frag.warps: tri %0d stays busy", ntri);
			end
			ntri = ntri + 1;
			rc = $fscanf(fd, "%s", kind);
		end
		$display("atg_rx_frag: %0d triangles, %0d warps", ntri, nwarp);
		if (e_copy == 0)
			$display("PASS atg_rx_frag.copy");
		if (e_warp == 0 && ntri == 20)
			$display("PASS atg_rx_frag.warps");
		$fclose(fd);

		/* ms: the multisampling vectors. */
		e0 = e_copy + e_warp;
		fd = $fopen("sim/vec/rx_frag_ms.txt", "r");
		if (fd == 0) begin
			e_ms = e_ms + 1;
			$display("FAIL atg_rx_frag.ms: no sim/vec/rx_frag_ms.txt");
		end
		rc = $fscanf(fd, "%s", kind);
		while (fd != 0 && kind == "T") begin
			rc = $fscanf(fd, " %h %d %d %h %h\n", t_tri, vc, nw, ctrl, kl);
			ms4 = ctrl[3:0] == 4'd2;
			nr = ctrl[4] ? 10 : 7;
			if (ms4)
				rc = $fscanf(fd, "D %h %h %h %h\n", dsw[0], dsw[1], dsw[2], dsw[3]);
			st_we = 1'b1;
			st_idx = 9'h05E;
			st_wdata = ctrl;
			tick;
			st_idx = 9'h05B;
			st_wdata = vc;
			t_load = 1'b1;
			tick;
			st_we = 1'b0;
			t_load = 1'b0;
			for (i = 0; i < nw; i = i + 1) begin
				rc = $fscanf(fd, "W %d\n", nq);
				x_cov = 0;
				x_nq = nq;
				for (q = 0; q < nq; q = q + 1) begin
					rc = $fscanf(fd, "Q %h %h %h %h\n", qx, qy, qs, qc);
					for (j = 0; j < 4; j = j + 1) begin
						x_cov[4 * q + j] = qs[4 * j +: 4] != 4'd0;
						if (nr == 10)
							rc = $fscanf(fd, "L %h %h %h %h %h %h %h %h %h %h\n", lw[0], lw[1],
								lw[2], lw[3], lw[4], lw[5], lw[6], lw[7], lw[8], lw[9]);
						else
							rc = $fscanf(fd, "L %h %h %h %h %h %h %h\n", lw[0], lw[1], lw[2],
								lw[3], lw[4], lw[5], lw[6]);
						for (t = 0; t < nr; t = t + 1)
							x_reg[(4 * q + j) * nr + t] = lw[t];
					end
					send_quad({qy, qx}, qs, qc, 1'b0);
				end
				if (nq < 8)
					send_quad(32'd0, 16'd0, 4'd0, 1'b1);
				gdelay = $unsigned($random(seed)) % 6;
				t = 0;
				while (granted || (busy && t < 20000) || fl_req) begin
					tick;
					t = t + 1;
				end
			end
			if (nw == 0 || x_nq == 8)
				send_quad(32'd0, 16'd0, 4'd0, 1'b1);
			t = 0;
			while (busy && t < 20000) begin
				tick;
				t = t + 1;
			end
			ntri = ntri + 1;
			ntm = ntm + 1;
			rc = $fscanf(fd, "%s", kind);
		end
		$display("atg_rx_frag: %0d multisampling triangles", ntm);
		if (e_copy + e_warp == e0 && e_ms == 0 && ntm == 16)
			$display("PASS atg_rx_frag.ms");
		else
			e_ms = e_ms + 1;
		if (e_copy + e_warp + e_ms == 0 && ntri == 36)
			$display("PASS atg_rx_frag");
		else
			$display("FAIL atg_rx_frag: %0d + %0d + %0d errors", e_copy, e_warp, e_ms);
		$finish;
	end
endmodule

`default_nettype wire
