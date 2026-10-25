/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pt_tb: atg_su_pt (NPHYS 8, 4 warps, 128 entries = 4 blocks, 64
 * varyings: the KC705's PT words 0-67) driven like atg_su: grants (pt_take with a slot), exp lane
 * groups of vertex warps on the execution bus, vl_go, warp ends, RX's
 * reads and frees.
 *   pt    — vertex exports (position 0-3, varyings 0x10+k, random lanes of
 *           the side-effect mask) land in entry base + lane and read back;
 *           fragment warps' exp, point size 0x004 and targets past the
 *           varyings are not stored.
 *   alloc — a reference count per 32-entry block: pt_ok/pt_base (lowest
 *           free block), vl_go returning the lanes outside vl_mask (also
 *           mask 0), pt_free; pt_done only after the owning warp's end,
 *           cleared at the next take, not set by an earlier owner's end.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pt_tb;
	localparam NPHYS = 8, G = 4, NE = 128, NB = 4, VW = 64, WPV = 68;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0;
	reg [1:0] x_warp = 0;
	reg [1:0] x_grp = 0;
	reg [103:0] x_uop = 0;
	reg [NPHYS*32-1:0] x_b = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg [31:0] x_info = 0;
	reg pt_rd = 1'b0, pt_free = 1'b0, pt_take = 1'b0, vl_go = 1'b0, wc_end = 1'b0;
	reg [7:0] pt_idx = 0, pt_free_idx = 0;
	reg [6:0] pt_word = 0;
	reg [1:0] pt_warp = 0, wc_warp = 0;
	reg [31:0] vl_mask = 0;
	wire [31:0] pt_rdata;
	wire pt_ok;
	wire [7:0] pt_base, pt_done;

	atg_su_pt #(.NPHYS(NPHYS), .PT_ENTRIES(NE), .VARY_WORDS(VW)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.scrub(1'b0), .scrub_busy(),
		.x_uop(x_uop), .x_b(x_b), .x_mask(x_mask), .x_info(x_info),
		.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
		.pt_free(pt_free), .pt_free_idx(pt_free_idx), .pt_ok(pt_ok), .pt_take(pt_take),
		.pt_warp(pt_warp), .pt_base(pt_base), .vl_go(vl_go), .vl_mask(vl_mask),
		.pt_done(pt_done), .wc_end(wc_end), .wc_warp(wc_warp));

	integer seed = 1, errors = 0, e0, i, j, k, t, n;
	reg [31:0] mem [0:NE*WPV-1];	/* reference PT */
	reg [NE*WPV-1:0] known;
	integer cnt [0:NB-1];
	integer owner [0:NB-1];
	reg [NB-1:0] rdone;
	integer wblk [0:3];

	task tick;
		begin
			@(posedge clk);
			#1;
		end
	endtask

	/* one exp lane group: warp w, group g, target tg, kind kd, side lanes sm */
	task exp_grp;
		input [1:0] w;
		input [1:0] g;
		input [31:0] tg;
		input [1:0] kd;
		input [NPHYS-1:0] sm;
		integer l, word;
		begin
			x_valid = 1'b1;
			x_warp = w;
			x_grp = g;
			x_uop = 104'd0;
			x_uop[3:0] = 4'd10;
			x_uop[40 +: 32] = tg;
			x_info = {14'd0, kd, 16'd0};
			x_mask = {sm, {NPHYS{1'b1}}};
			for (l = 0; l < NPHYS; l = l + 1)
				x_b[32 * l +: 32] = $random(seed);
			word = tg < 4 ? tg : tg >= 32'h10 && tg < 32'h10 + VW ? tg - 32'h10 + 4 : -1;
			if (kd == 2'd0 && word >= 0)
				for (l = 0; l < NPHYS; l = l + 1)
					if (sm[l]) begin
						mem[(wblk[w] * 32 + g * NPHYS + l) * WPV + word] = x_b[32 * l +: 32];
						known[(wblk[w] * 32 + g * NPHYS + l) * WPV + word] = 1'b1;
					end
			tick;
			x_valid = 1'b0;
		end
	endtask

	task take;
		input [1:0] w;
		begin
			if (!pt_ok) begin
				errors = errors + 1;
				$display("FAIL atg_su_pt.alloc: no free block for a take");
			end
			wblk[w] = pt_base >> 5;
			cnt[wblk[w]] = 32;
			owner[wblk[w]] = w;
			rdone[wblk[w]] = 1'b0;
			pt_take = 1'b1;
			pt_warp = w;
			tick;
			pt_take = 1'b0;
		end
	endtask

	task go;
		input [31:0] m;
		input [1:0] w;
		integer l;
		begin
			vl_go = 1'b1;
			vl_mask = m;
			for (l = 0; l < 32; l = l + 1)
				if (!m[l])
					cnt[wblk[w]] = cnt[wblk[w]] - 1;
			tick;
			vl_go = 1'b0;
		end
	endtask

	task wend;
		input [1:0] w;
		begin
			wc_end = 1'b1;
			wc_warp = w;
			if (owner[wblk[w]] == w)
				rdone[wblk[w]] = 1'b1;
			tick;
			wc_end = 1'b0;
		end
	endtask

	task free1;
		input [7:0] e;
		begin
			pt_free = 1'b1;
			pt_free_idx = e;
			cnt[e >> 5] = cnt[e >> 5] - 1;
			tick;
			pt_free = 1'b0;
		end
	endtask

	/* the model's view: lowest free block, done bits */
	task check_alloc;
		input [8*8-1:0] what;
		integer b, fb;
		begin
			fb = -1;
			for (b = NB - 1; b >= 0; b = b - 1)
				if (cnt[b] == 0)
					fb = b;
			if (pt_ok !== (fb >= 0) || (fb >= 0 && pt_base !== fb * 32)) begin
				errors = errors + 1;
				$display("FAIL atg_su_pt.alloc (%0s): pt_ok %b base %0d, model block %0d", what,
					pt_ok, pt_base, fb);
			end
			if (pt_done[NB-1:0] !== rdone) begin
				errors = errors + 1;
				$display("FAIL atg_su_pt.alloc (%0s): pt_done %b, model %b", what, pt_done, rdone);
			end
		end
	endtask

	task read_all;
		integer e, wd, got;
		begin
			for (e = 0; e < NE; e = e + 1)
				for (wd = 0; wd < WPV; wd = wd + 1)
					if (known[e * WPV + wd]) begin
						pt_rd = 1'b1;
						pt_idx = e;
						pt_word = wd;
						tick;
						pt_rd = 1'b0;
						pt_idx = $random(seed);	/* the data must not follow pt_idx */
						got = pt_rdata;
						if (got !== mem[e * WPV + wd]) begin
							errors = errors + 1;
							$display("FAIL atg_su_pt.pt: entry %0d word %0d: %h want %h", e, wd,
								got, mem[e * WPV + wd]);
						end
					end
		end
	endtask

	initial begin
		known = 0;
		for (i = 0; i < NB; i = i + 1) begin
			cnt[i] = 0;
			owner[i] = -1;
		end
		rdone = 0;
		repeat (3) tick;
		rst_n = 1'b1;
		tick;

		/* pt: two vertex warps (slots 1, 2), every word of every group with
		 * random side masks; fragment and out-of-range exports between. */
		take(2'd1);
		take(2'd2);
		for (k = 0; k < 2; k = k + 1)
			for (j = 0; j < G; j = j + 1)
				for (i = 0; i < WPV + 4; i = i + 1) begin
					t = i < 4 ? i : i < WPV ? 32'h10 + i - 4 : i == WPV ? 4 :
						i == WPV + 1 ? 32'h10 + VW : i == WPV + 2 ? 32'h100 : 32'h7F;
					exp_grp(k + 1, j, t, 2'd0, $random(seed) | (i == 0 ? 8'hFF : 8'h00));
					if (i < 4)
						exp_grp(k + 1, j, t, 2'd1, 8'hFF);	/* fragment: ignored */
				end
		read_all;
		if (errors == 0)
			$display("PASS atg_su_pt.pt");
		e0 = errors;

		/* alloc: return the two blocks, then random rounds of grants. */
		go(32'hFFFFFFFF, 2'd2);
		check_alloc("go");
		wend(2'd1);
		wend(2'd2);
		check_alloc("end");
		for (i = 0; i < 64; i = i + 1)
			free1(wblk[1] * 32 + i % 32 + (i >= 32 ? (wblk[2] - wblk[1]) * 32 : 0));
		check_alloc("free");
		for (n = 0; n < 200; n = n + 1) begin
			/* a take when possible, the warp in slot n % 4 */
			if (pt_ok) begin
				k = n % 4;
				take(k);
				check_alloc("take");
				case ($random(seed) & 3)
				0: go(32'd0, k);
				1: go(32'hFFFFFFFF, k);
				default: go($random(seed), k);
				endcase
				check_alloc("go");
				wend(k);
				check_alloc("end");
			end
			/* free some entries still counted */
			for (j = 0; j < 8; j = j + 1) begin
				t = $unsigned($random(seed)) % NB;
				if (cnt[t] > 0 && rdone[t])
					free1(t * 32);
			end
			check_alloc("frees");
		end
		/* a stale end: warp 0 takes, ends after warp 1 took the same block */
		for (t = 0; t < NB; t = t + 1)
			while (cnt[t] > 0)
				free1(t * 32);
		check_alloc("drain");
		take(2'd0);
		go(32'd0, 2'd0);
		take(2'd1);	/* the same block (its count is 0 again) */
		check_alloc("retake");
		wend(2'd0);	/* not the owner any more */
		check_alloc("stale");
		wend(2'd1);
		check_alloc("owner");
		if (errors == e0)
			$display("PASS atg_su_pt.alloc");

		if (errors == 0)
			$display("PASS atg_su_pt");
		else
			$display("FAIL atg_su_pt: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
