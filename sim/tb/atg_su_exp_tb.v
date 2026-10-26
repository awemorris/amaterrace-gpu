/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp_tb: atg_su_exp (NPHYS 8, 4 warps) with the RX's register
 * writes (r3 z, r4/r5 the pixel centre), fl_go, fragment exps of the
 * colour attachments (0x100 + 16 k + c, a random subset of k per warp, none
 * in some) and DEPTH lane group by group under random side-effect masks,
 * warp ends in random order and a ROP model (ex_ready random, ex_next
 * counting the retired numbers).
 *   frag    — every fragment warp drains after its end and only when its
 *             sequence number is ex_next: its quads (those with coverage)
 *             in order, xy from r4/r5, mask = exported & covered lanes,
 *             the colours exported, the depth exported or else r3, ex_last
 *             on the last quad.
 *   release — xr_valid: a vertex (or compute) warp the cycle after its
 *             end, a fragment warp once after its last quad is taken.
 *   ms      — multisampling: the RX writes r6 of half the warps (other
 *             lanes take 1111) and the d_s table words 0xFF8-0xFFB of half
 *             of them (others 0: cleared at the release; the map and a
 *             varying word are not d_s), half the warps export SAMPLE_MASK
 *             (0x105) twice (the last value counts); ex_aux[147:0] = {the warp's
 *             d_s, the lanes that exported DEPTH, r6 & SAMPLE_MASK per
 *             lane} and a lane whose mask is 0 is not in ex_mask.
 *             -DMUT_SMASK_AND (the two exports ANDed) fails it.
 *   mrt     — the beats: one per attachment the warp exported (ascending;
 *             ex_aux rt, qfirst, qlast), or one without colour (nocol)
 *             when it exported none; the beat's colours are that
 *             attachment's; ex_aux[148] is the warp's facing (fl_info[48],
 *             random); a SECOND_COLOR target (0x108) is ignored.
 *             -DMUT_EXP_FRONT (the facing always 1) fails it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp_tb;
	localparam NPHYS = 8, G = 4;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0;
	reg [1:0] x_warp = 0, x_grp = 0;
	reg [103:0] x_uop = 0;
	reg [NPHYS*32-1:0] x_b = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg [31:0] x_info = 0;
	reg ex_ready = 1'b0;
	reg [15:0] ex_next = 0;
	reg fl_we = 1'b0, fl_go = 1'b0, wc_end = 1'b0;
	reg [1:0] fl_slot = 0, wc_warp = 0;
	reg [5:0] fl_reg = 0;
	reg [4:0] fl_lane = 0;
	reg [31:0] fl_data = 0;
	reg [63:0] fl_info = 0;
	reg fl_pw_we = 1'b0;
	reg [11:0] fl_pw_addr = 0;
	reg [31:0] fl_pw_data = 0;
	wire [153:0] ex_aux;
	wire x_ready, ex_valid, ex_last, xr_valid;
	wire [15:0] ex_seq;
	wire [31:0] ex_xy;
	wire [3:0] ex_mask;
	wire [511:0] ex_color;
	wire [127:0] ex_depth;
	wire [1:0] xr_warp;

	atg_su_exp #(.NPHYS(NPHYS)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.scrub(1'b0), .scrub_busy(),
		.x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a({NPHYS{32'd0}}),
		.x_b(x_b), .x_c({NPHYS{32'd0}}), .x_mask(x_mask), .x_info(x_info), .x_ready(x_ready),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next),
		.fl_we(fl_we), .fl_slot(fl_slot), .fl_reg(fl_reg), .fl_lane(fl_lane),
		.fl_data(fl_data), .fl_go(fl_go), .fl_info(fl_info),
		.fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data), .ex_aux(ex_aux),
		.xr_valid(xr_valid), .xr_warp(xr_warp), .wc_end(wc_end), .wc_warp(wc_warp),
		.ngg_valid(), .ngg_ready(1'b1), .ngg_tri(), .ngg_last(), .ngg_mesh_id(), .ngg_busy(),
		.ngg_lds_rd_en(), .ngg_lds_rd_addr(), .ngg_lds_rd_data(32'd0));

	integer seed = 1, errors = 0, e_rel = 0, i, j, k, l, c, r, t;
	/* per slot: the warp's reference */
	reg [31:0] cov [0:3];
	reg [31:0] xpl [0:3];
	reg [31:0] dwl [0:3];
	reg [15:0] sq [0:3];
	reg [15:0] qxs [0:31];	/* slot*8 + quad */
	reg [15:0] qys [0:31];
	reg [31:0] zv [0:127];	/* slot*32 + lane */
	reg [31:0] dv [0:127];
	reg [31:0] cv [0:2047];	/* (slot*32 + lane)*16 + 4 k + comp */
	reg [3:0] rtwl [0:3];	/* the attachments exported */
	reg [3:0] frs;	/* the warps' facing */
	integer e_mrt = 0;
	reg qstart;	/* the next beat starts a quad */
	reg [1:0] brt;	/* the attachment of the next beat */
	reg [3:0] r6v [0:127];	/* the RX's r6 */
	reg [3:0] smv [0:127];	/* the last SAMPLE_MASK */
	reg [31:0] smf [0:3];	/* SAMPLE_MASK exported */
	reg [3:0] r6f;		/* the RX wrote r6 of the slot's lanes */
	reg [31:0] dsr [0:15];	/* slot*4 + sample */
	integer e_ms = 0;
	reg [3:0] kind;	/* 1: fragment slot */
	reg [3:0] wait_rel;	/* a fragment slot whose drain is due */
	reg [3:0] drained;
	reg [3:0] vrel;	/* a vertex slot released after its end */
	integer slot_of_seq [0:65535];
	integer dq;	/* the next quad expected of the draining warp */
	integer vend_t [0:3];

	task tick;
		begin
			@(posedge clk);
			#1;
		end
	endtask

	/* fp32 of v + 0.5 for 0 <= v < 32768 */
	function [31:0] centre;
		input integer v;
		integer m, e;
		begin
			m = 2 * v + 1;
			e = 0;
			while ((m >> e) > 1)
				e = e + 1;
			centre = ((126 + e) << 23) | ((m << (23 - e)) & 32'h7FFFFF);
		end
	endfunction

	task flw;
		input [1:0] s;
		input [5:0] rg;
		input [4:0] ln;
		input [31:0] d;
		begin
			fl_we = 1'b1;
			fl_slot = s;
			fl_reg = rg;
			fl_lane = ln;
			fl_data = d;
			tick;
			fl_we = 1'b0;
		end
	endtask

	task pww;
		input [1:0] s;
		input [11:0] a;
		input [31:0] d;
		begin
			fl_pw_we = 1'b1;
			fl_slot = s;
			fl_pw_addr = a;
			fl_pw_data = d;
			tick;
			fl_pw_we = 1'b0;
		end
	endtask

	/* a fragment warp in slot s: nq quads, the RX's writes, fl_go */
	task frag_warp;
		input [1:0] s;
		input [15:0] seq;
		integer nq, q, ln, x, y;
		begin
			nq = 1 + $unsigned($random(seed)) % 8;
			cov[s] = 0;
			for (q = 0; q < nq; q = q + 1) begin
				cov[s][4 * q +: 4] = 1 + $unsigned($random(seed)) % 15;
				x = 2 * ($unsigned($random(seed)) % 500);
				y = 2 * ($unsigned($random(seed)) % 500);
				qxs[s * 8 + q] = x;
				qys[s * 8 + q] = y;
				for (ln = 4 * q; ln < 4 * q + 4; ln = ln + 1) begin
					zv[s * 32 + ln] = $random(seed);
					flw(s, 6'd3, ln, zv[s * 32 + ln]);
					flw(s, 6'd4, ln, centre(x + (ln & 1)));
					flw(s, 6'd5, ln, centre(y + ((ln >> 1) & 1)));
					flw(s, 6'd0, ln, $random(seed));	/* b0: not the exp's */
				end
			end
			/* multisampling: r6 and d_s of half the warps */
			r6f[s] = $random(seed) & 1;
			if (r6f[s])
				for (ln = 0; ln < 32; ln = ln + 1) begin
					r6v[s * 32 + ln] = ln < 4 * nq ? $random(seed) : 4'd0;
					flw(s, 6'd6, ln, {$random(seed) & 32'hFFFFFFF0} | r6v[s * 32 + ln]);
				end
			for (q = 0; q < 4; q = q + 1)
				dsr[s * 4 + q] = 32'd0;
			if ($random(seed) & 1)
				for (q = 0; q < 4; q = q + 1) begin
					dsr[s * 4 + q] = $random(seed);
					pww(s, 12'hFF8 + q, dsr[s * 4 + q]);
				end
			pww(s, 12'hFFF, $random(seed));
			pww(s, 12'h004, $random(seed));
			smf[s] = 0;
			sq[s] = seq;
			slot_of_seq[seq] = s;
			xpl[s] = 0;
			dwl[s] = 0;
			kind[s] = 1'b1;
			drained[s] = 1'b0;
			fl_go = 1'b1;
			fl_slot = s;
			frs[s] = $random(seed) & 1;
			rtwl[s] = 4'd0;
			fl_info = {15'd0, frs[s], seq, cov[s]};
			tick;
			fl_go = 1'b0;
		end
	endtask

	/* one exp lane group of slot s: target tg, data random, side within coverage */
	task exp_grp;
		input [1:0] s;
		input [1:0] g;
		input [31:0] tg;
		input [1:0] kd;
		integer ln;
		reg [NPHYS-1:0] sm;
		begin
			sm = $random(seed) & (cov[s] >> (g * NPHYS));
			x_valid = 1'b1;
			x_warp = s;
			x_grp = g;
			x_uop = 104'd0;
			x_uop[3:0] = 4'd10;
			x_uop[40 +: 32] = tg;
			x_info = {14'd0, kd, sq[s]};
			x_mask = {sm, {NPHYS{1'b1}}};
			for (ln = 0; ln < NPHYS; ln = ln + 1) begin
				x_b[32 * ln +: 32] = $random(seed);
				if (sm[ln] && kd == 2'd1 && (tg == 32'h104 || tg == 32'h105 ||
				    (tg[31:6] == 26'd4 && tg[3:2] == 2'd0))) begin
					xpl[s][g * NPHYS + ln] = 1'b1;
					if (tg == 32'h105) begin
						smf[s][g * NPHYS + ln] = 1'b1;
						smv[s * 32 + g * NPHYS + ln] = x_b[32 * ln +: 4];
					end else if (tg == 32'h104) begin
						dwl[s][g * NPHYS + ln] = 1'b1;
						dv[s * 32 + g * NPHYS + ln] = x_b[32 * ln +: 32];
					end else begin
						cv[(s * 32 + g * NPHYS + ln) * 16 + 4 * tg[5:4] + tg[1:0]] =
							x_b[32 * ln +: 32];
						rtwl[s][tg[5:4]] = 1'b1;
					end
				end
			end
			tick;
			x_valid = 1'b0;
		end
	endtask

	task wend;
		input [1:0] s;
		begin
			wc_end = 1'b1;
			wc_warp = s;
			if (!kind[s]) begin
				vend_t[s] = $time;
				vrel[s] = 1'b0;
			end
			tick;
			wc_end = 1'b0;
		end
	endtask

	/* The ROP model: takes beats in order, checks them. */
	reg [3:0] bab, bbe;	/* the warp's attachments above and below the beat's */
	reg blast;
	function [1:0] low4;
		input [3:0] m;
		low4 = m[0] ? 2'd0 : m[1] ? 2'd1 : m[2] ? 2'd2 : m[3] ? 2'd3 : 2'd0;
	endfunction
	reg [31:0] want;
	reg [15:0] lsm;
	reg [3:0] okm;
	integer ms, ml, mc;
	always @(posedge clk)
		ex_ready <= $random(seed) & 1;
	always @(negedge clk) begin
		if (ex_valid && ex_ready) begin
			if (ex_seq !== ex_next) begin
				errors = errors + 1;
				$display("FAIL atg_su_exp.frag: sequence %0d out while next is %0d", ex_seq, ex_next);
			end
			ms = slot_of_seq[ex_seq];
			if (qstart)
				brt = low4(rtwl[ms]);
			bab = rtwl[ms] & ~((4'd2 << brt) - 4'd1);
			bbe = rtwl[ms] & ((4'd1 << brt) - 4'd1);
			if (ex_aux[153:148] !== {rtwl[ms] == 4'd0 ? 2'd0 : brt, bab == 4'd0, bbe == 4'd0,
			    rtwl[ms] == 4'd0, frs[ms]}) begin
				e_mrt = e_mrt + 1;
				if (e_mrt < 6)
					$display("FAIL atg_su_exp.mrt: seq %0d quad %0d beat %b, want rt %0d of %b front %b",
						ex_seq, dq, ex_aux[153:148], brt, rtwl[ms], frs[ms]);
			end
			blast = bab == 4'd0;
			okm = 4'd0;
			for (ml = 0; ml < 4; ml = ml + 1) begin
				lsm[4 * ml +: 4] = (r6f[ms] ? r6v[ms * 32 + 4 * dq + ml] : 4'hF) &
					(smf[ms][4 * dq + ml] ? smv[ms * 32 + 4 * dq + ml] : 4'hF);
				okm[ml] = lsm[4 * ml +: 4] != 4'd0;
			end
			if (ex_aux[15:0] !== lsm ||
			    ex_aux[19:16] !== (dwl[ms][4 * dq +: 4] & xpl[ms][4 * dq +: 4] & cov[ms][4 * dq +: 4]) ||
			    ex_aux[147:20] !== {dsr[ms * 4 + 3], dsr[ms * 4 + 2], dsr[ms * 4 + 1], dsr[ms * 4]}) begin
				e_ms = e_ms + 1;
				if (e_ms < 6)
					$display("FAIL atg_su_exp.ms: seq %0d quad %0d ex_aux %h smask want %h", ex_seq, dq,
						ex_aux[147:0], lsm);
			end
			if (ex_xy !== {qys[ms * 8 + dq], qxs[ms * 8 + dq]} ||
			    ex_mask !== (cov[ms][4 * dq +: 4] & xpl[ms][4 * dq +: 4] & okm) ||
			    ex_last !== (blast && (dq == 7 || cov[ms][4 * dq + 4 +: 4] == 4'd0))) begin
				errors = errors + 1;
				$display("FAIL atg_su_exp.frag: seq %0d quad %0d xy %h mask %b last %b", ex_seq,
					dq, ex_xy, ex_mask, ex_last);
			end
			for (ml = 0; ml < 4; ml = ml + 1)
				if (ex_mask[ml]) begin
					want = dwl[ms][4 * dq + ml] ? dv[ms * 32 + 4 * dq + ml] : zv[ms * 32 + 4 * dq + ml];
					if (ex_depth[32 * ml +: 32] !== want) begin
						errors = errors + 1;
						$display("FAIL atg_su_exp.frag: seq %0d lane %0d depth %h want %h", ex_seq,
							4 * dq + ml, ex_depth[32 * ml +: 32], want);
					end
					for (mc = 0; mc < 4; mc = mc + 1)
						if (xpl[ms][4 * dq + ml] && rtwl[ms] != 4'd0 &&
						    ex_color[128 * ml + 32 * mc +: 32] !==
						    cv[(ms * 32 + 4 * dq + ml) * 16 + 4 * brt + mc]) begin
							e_mrt = e_mrt + 1;
							if (e_mrt < 6)
								$display("FAIL atg_su_exp.mrt: seq %0d lane %0d attachment %0d colour %0d",
									ex_seq, 4 * dq + ml, brt, mc);
						end
				end
			qstart = blast;
			if (!blast)
				brt = low4(bab);
			if (ex_last) begin
				ex_next <= ex_next + 16'd1;
				dq = 0;
				wait_rel[ms] = 1'b1;
			end else if (blast)
				dq = dq + 1;
		end
	end

	/* Releases. */
	always @(posedge clk) begin
		#3;
		if (xr_valid) begin
			if (kind[xr_warp]) begin
				if (!wait_rel[xr_warp]) begin
					e_rel = e_rel + 1;
					$display("FAIL atg_su_exp.release: fragment slot %0d released before its drain",
						xr_warp);
				end
				wait_rel[xr_warp] = 1'b0;
				drained[xr_warp] = 1'b1;
			end else if ($time - vend_t[xr_warp] == 12)
				vrel[xr_warp] = 1'b1;
			else begin
				e_rel = e_rel + 1;
				$display("FAIL atg_su_exp.release: vertex slot %0d released %0d after its end",
					xr_warp, $time - vend_t[xr_warp]);
			end
		end
	end

	reg [15:0] nseq;
	integer order [0:3];
	initial begin
		kind = 0;
		wait_rel = 0;
		drained = 0;
		dq = 0;
		qstart = 1'b1;
		brt = 2'd0;
		nseq = 0;
		repeat (3) tick;
		rst_n = 1'b1;
		tick;
		for (r = 0; r < 60; r = r + 1) begin
			/* slots 0-2 fragment warps (numbers in a random slot order), slot 3 vertex */
			for (i = 0; i < 3; i = i + 1)
				order[i] = i;
			for (i = 2; i > 0; i = i - 1) begin
				j = $unsigned($random(seed)) % (i + 1);
				k = order[i];
				order[i] = order[j];
				order[j] = k;
			end
			for (i = 0; i < 3; i = i + 1)
				frag_warp(order[i], nseq + i);
			kind[3] = 1'b0;
			for (i = 0; i < 3; i = i + 1) begin
				/* attachment 0 alone in half the warps, a random set in the others */
				t = ($random(seed) & 1) ? 1 : $random(seed) & 15;
				for (k = 0; k < 4; k = k + 1)
					if (t[k])
						for (c = 0; c < 4; c = c + 1)
							for (j = 0; j < G; j = j + 1)
								exp_grp(i, j, 32'h100 + 16 * k + c, 2'd1);
				exp_grp(i, 2, 32'h108, 2'd1);	/* SECOND_COLOR: ignored */
				if ($random(seed) & 1)
					for (j = 0; j < G; j = j + 1)
						exp_grp(i, j, 32'h104, 2'd1);
				if ($random(seed) & 1)
					for (c = 0; c < 2; c = c + 1)
						for (j = 0; j < G; j = j + 1)
							exp_grp(i, j, 32'h105, 2'd1);
				exp_grp(i, 0, 32'h000, 2'd1);	/* a vertex target from a fragment warp */
				exp_grp(i, 1, 32'h101, 2'd0);	/* a vertex warp's exp: not the buffer's */
			end
			/* end the three (numbers in another order), the vertex warp among them */
			for (i = 2; i >= 0; i = i - 1) begin
				wend(i);
				if (i == 1)
					wend(2'd3);
				repeat ($unsigned($random(seed)) % 30) tick;
			end
			t = 0;
			while (drained[2:0] != 3'b111 && t < 2000) begin
				tick;
				t = t + 1;
			end
			if (t >= 2000) begin
				errors = errors + 1;
				$display("FAIL atg_su_exp.frag: round %0d does not drain (%b)", r, drained);
			end
			if (!vrel[3]) begin
				e_rel = e_rel + 1;
				$display("FAIL atg_su_exp.release: round %0d: the vertex warp is not released", r);
			end
			nseq = nseq + 3;
		end
		if (errors == 0)
			$display("PASS atg_su_exp.frag");
		if (e_rel == 0)
			$display("PASS atg_su_exp.release");
		if (e_ms == 0)
			$display("PASS atg_su_exp.ms");
		if (e_mrt == 0)
			$display("PASS atg_su_exp.mrt");
		if (errors + e_rel + e_ms + e_mrt == 0)
			$display("PASS atg_su_exp");
		else
			$display("FAIL atg_su_exp: %0d errors", errors + e_rel + e_ms + e_mrt);
		$finish;
	end
endmodule

`default_nettype wire
