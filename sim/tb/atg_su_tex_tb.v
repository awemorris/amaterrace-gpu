/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_tex_tb: atg_su_tex (with atg_su_tex_ret) for NPHYS 8, 16 and 32
 * against a model TU.  Random texture instructions (texl, texb, texf,
 * texsz; random warp, slot, rd, scoreboard entry, operands and EXEC per
 * quad: full, partial, empty, a whole group empty), interleaved with
 * instructions of other units, go in as atg_su_opd sends them (a group
 * held until taken).  The model TU takes quads with a random tx_ready and
 * answers them in order after random delays with data made from each
 * lane's coordinates and the quad's tag; l_ready is random.  The TEX op
 * carries random modifier bits, the uop random texel offsets (imm) and
 * at random the .3 flag (sub[4]); a .c (op bit 2) or .3 form sends each
 * group twice as atg_su_opd does, the second pass (op bit 7) with rs1+2 on
 * x_a and rs1+3 on x_c, x_last only there, sometimes after idle cycles.
 *   send  every quad with an EXEC lane, in order: op (bits 6:0), slot, mask
 *         (EXEC), offsets, coordinates {third or 0, Dref or 0, rs2, rs1+1,
 *         rs1} per lane, tag {warp, quad, rd}, tx_last on the last quad of
 *         the instruction
 *   ret   per group, in order: rd..rd+3 (texsz rd) with the EXEC lanes'
 *         returned words, class t, l_last on the instruction's last beat
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_tex_run #(
	parameter NPHYS = 8,
	parameter GRP_W = 2,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] e_send,
	output reg [31:0] e_ret
);
	`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam NG = 32 / NPHYS;
	localparam NQ = NPHYS / 4;
	localparam NI = 300;	/* instructions */

	reg x_valid = 1'b0;
	reg [1:0] x_warp = 0;
	reg [GRP_W-1:0] x_grp = 0;
	reg x_last = 1'b0;
	reg [2:0] x_sbe = 0;
	reg [ATG_UOP_W-1:0] x_uop = 0;
	reg [DW-1:0] x_a = 0, x_b = 0, x_c = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg l_ready = 1'b0;
	reg tx_ready = 1'b0;
	reg tr_valid = 1'b0;
	reg [15:0] tr_tag = 0;
	reg [511:0] tr_data = 0;
	reg tr_last = 1'b0;
	wire x_ready, l_valid, l_wr, l_last, tx_valid, tx_last, tr_ready;
	wire [1:0] l_warp;
	wire [7:0] tx_op;
	wire [GRP_W-1:0] l_grp;
	wire [6:0] l_rd;
	wire [DW-1:0] l_data;
	wire [NPHYS-1:0] l_lanes;
	wire [2:0] l_sbe, l_cls;
	wire [3:0] tx_slot, tx_mask;
	wire [639:0] tx_coord;
	wire [11:0] tx_off;
	wire [15:0] tx_tag;

	atg_su_tex #(.NPHYS(NPHYS), .NWARPS(4), .WARP_W(2), .GRP_W(GRP_W), .SBE_W(2)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
		.x_c(x_c), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
		.l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
		.l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe),
		.l_cls(l_cls),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
		.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
		.tx_last(tx_last), .tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
		.tr_last(tr_last)
	);

	integer seed = SEED;

	/* The model TU's answer for a quad. */
	function [511:0] answer;
		input [639:0] crd;
		input [15:0] tag;
		integer l, c;
		begin
			for (l = 0; l < 4; l = l + 1)
				for (c = 0; c < 4; c = c + 1)
					answer[l*128 + c*32 +: 32] = crd[l*160 + c * 32 +: 32] ^
						(c * 32'h11111111) ^ {16'd0, tag} ^
						(c == 0 ? crd[l*160 + 128 +: 32] : 32'd0);
		end
	endfunction

	/* Expected quads (send) and groups (ret), in order. */
	reg [7:0] q_op [0:4095];
	reg [3:0] q_slot [0:4095], q_mask [0:4095];
	reg [639:0] q_crd [0:4095];
	reg [11:0] q_off [0:4095];
	reg [15:0] q_tag [0:4095];
	reg q_last [0:4095];
	integer qw = 0, qr = 0;
	reg [1:0] g_warp [0:2047];
	reg [GRP_W-1:0] g_grp [0:2047];
	reg [6:0] g_rd [0:2047];
	reg [2:0] g_sbe [0:2047];
	reg g_last [0:2047], g_sz [0:2047];
	reg [NPHYS-1:0] g_lanes [0:2047];
	reg [DW*4-1:0] g_data [0:2047];
	integer gw = 0, gr = 0;

	/* The model TU: takes quads (checked against the expected), answers in order. */
	reg [639:0] p_crd [0:4095];
	reg [15:0] p_tag [0:4095];
	reg p_last [0:4095];
	integer pw = 0, pr = 0;
	always @(posedge clk) begin
		tx_ready <= ($random(seed) & 3) != 0;
		if (tx_valid && tx_ready) begin
			if (qr >= qw || tx_op !== q_op[qr] || tx_slot !== q_slot[qr] ||
			    tx_mask !== q_mask[qr] || tx_coord !== q_crd[qr] || tx_tag !== q_tag[qr] ||
			    tx_off !== q_off[qr] ||
			    tx_last !== q_last[qr]) begin
				if (e_send < 8)
					$display("FAIL atg_su_tex(%0d): quad %0d: op %0d slot %0d mask %h tag %h last %b, want %0d %0d %h %h %b",
						NPHYS, qr, tx_op, tx_slot, tx_mask, tx_tag, tx_last, q_op[qr],
						q_slot[qr], q_mask[qr], q_tag[qr], q_last[qr]);
				e_send = e_send + 1;
			end
			qr = qr + 1;
			p_crd[pw] = tx_coord;
			p_tag[pw] = tx_tag;
			p_last[pw] = tx_last;
			pw = pw + 1;
		end
	end
	always @(posedge clk) begin
		if (tr_valid && tr_ready) begin
			tr_valid <= 1'b0;
			pr = pr + 1;
		end else if (!tr_valid && pr < pw && ($random(seed) & 3) == 0) begin
			tr_valid <= 1'b1;
			tr_data <= answer(p_crd[pr], p_tag[pr]);
			tr_tag <= p_tag[pr];
			tr_last <= p_last[pr];
		end
	end

	/* The long results. */
	integer beat = 0, nbeats = 0, j;
	always @(posedge clk) begin
		l_ready <= ($random(seed) & 3) != 0;
		if (l_valid && l_ready) begin
			nbeats = nbeats + 1;
			if (gr >= gw || l_warp !== g_warp[gr] || l_grp !== g_grp[gr] ||
			    l_rd !== g_rd[gr] + beat || l_lanes !== g_lanes[gr] || l_wr !== 1'b1 ||
			    l_sbe !== g_sbe[gr] || l_cls !== ATG_CLS_T ||
			    l_last !== (g_last[gr] && (g_sz[gr] || beat == 3))) begin
				if (e_ret < 8)
					$display("FAIL atg_su_tex(%0d): group %0d beat %0d: warp %0d grp %0d rd %0d lanes %h last %b",
						NPHYS, gr, beat, l_warp, l_grp, l_rd, l_lanes, l_last);
				e_ret = e_ret + 1;
			end
			for (j = 0; j < NPHYS; j = j + 1)
				if (g_lanes[gr][j] && l_data[j*32 +: 32] !== g_data[gr][beat*DW + j*32 +: 32]) begin
					if (e_ret < 8)
						$display("FAIL atg_su_tex(%0d): group %0d beat %0d lane %0d: %h, want %h",
							NPHYS, gr, beat, j, l_data[j*32 +: 32],
							g_data[gr][beat*DW + j*32 +: 32]);
					e_ret = e_ret + 1;
				end
			if (g_sz[gr] || beat == 3) begin
				beat = 0;
				gr = gr + 1;
			end else
				beat = beat + 1;
		end
	end

	integer n, g, q, l, c, kind, n0;
	reg [7:0] op;
	reg [3:0] slot;
	reg [6:0] rd;
	reg [1:0] warp;
	reg [2:0] sbe;
	reg [NPHYS-1:0] ex;
	reg [639:0] crd;
	reg [DW-1:0] dref, third, p2a, p2c;
	reg three, wide;
	reg [11:0] offs;
	reg [15:0] tag;
	reg [2:0] qn;
	reg [DW*4-1:0] gd;
	reg [511:0] ans;
	integer lastq;
	initial begin
		done = 1'b0;
		e_send = 0;
		e_ret = 0;
		@(posedge rst_n);
		repeat (2) @(posedge clk);
		for (n = 0; n < NI; n = n + 1) begin
			if (($random(seed) & 3) == 0) begin
				/* another unit's instruction: not taken by atg_su_tex */
				x_valid <= 1'b1;
				x_uop <= {$random(seed), $random(seed), $random(seed), $random(seed)};
				x_uop[ATG_UOP_UNIT +: 4] <= ATG_UNIT_ALU;
				@(posedge clk);
				x_valid <= 1'b0;
			end
			op = $random(seed) & 8'h7F;
			if (($random(seed) & 1) == 0)
				op[ATG_TEX_CFORM] = 1'b0;
			slot = $random(seed);
			three = $random(seed);
			wide = three || op[ATG_TEX_CFORM];
			offs = $random(seed);
			rd = $random(seed) & 7'h3F;
			warp = $random(seed);
			sbe = $random(seed);
			kind = $random(seed) & 7;
			for (g = 0; g < NG; g = g + 1) begin
				for (l = 0; l < NPHYS; l = l + 4)
					ex[l +: 4] = kind == 0 ? 4'h0 : kind < 4 ? 4'hF :
						($random(seed) & 1) ? 4'h0 : $random(seed);
				x_a <= {NPHYS{$random(seed)}} ^ {(DW/32){$random(seed)}};
				x_b <= {NPHYS{$random(seed)}} ^ {(DW/32){$random(seed)}};
				x_c <= {NPHYS{$random(seed)}} ^ {(DW/32){$random(seed)}};
				@(posedge clk);
				/* the operands are different per lane */
				for (l = 0; l < NPHYS; l = l + 1) begin
					x_a[l*32 +: 32] <= $random(seed);
					x_b[l*32 +: 32] <= $random(seed);
					x_c[l*32 +: 32] <= $random(seed);
				end
				/* the second pass: rs1+2 on x_a, rs1+3 on x_c */
				for (l = 0; l < NPHYS; l = l + 1) begin
					p2a[l*32 +: 32] = $random(seed);
					p2c[l*32 +: 32] = $random(seed);
					third[l*32 +: 32] = three ? p2a[l*32 +: 32] : 32'd0;
					dref[l*32 +: 32] = !op[ATG_TEX_CFORM] ? 32'd0 :
						three ? p2c[l*32 +: 32] : p2a[l*32 +: 32];
				end
				x_valid <= 1'b1;
				x_warp <= warp;
				x_grp <= g;
				x_last <= g == NG - 1 && !wide;
				x_sbe <= sbe;
				x_uop <= 0;
				x_uop[ATG_UOP_UNIT +: 4] <= ATG_UNIT_TEX;
				x_uop[ATG_UOP_OP +: 8] <= op;
				x_uop[ATG_UOP_SUB +: 5] <= {three, slot};
				x_uop[ATG_UOP_IMM +: 32] <= {20'd0, offs};
				x_uop[ATG_UOP_RD +: 7] <= rd;
				x_mask <= {{NPHYS{1'b1}}, ex};
				@(negedge clk);
				/* the expected quads and group */
				lastq = -1;
				for (q = 0; q < NQ; q = q + 1)
					if (ex[q*4 +: 4] != 4'h0)
						lastq = q;
				gd = 0;
				for (q = 0; q < NQ; q = q + 1)
					if (ex[q*4 +: 4] != 4'h0) begin
						for (l = 0; l < 4; l = l + 1)
							crd[l*160 +: 160] = {third[(q*4+l)*32 +: 32],
								dref[(q*4+l)*32 +: 32], x_b[(q*4+l)*32 +: 32],
								x_c[(q*4+l)*32 +: 32], x_a[(q*4+l)*32 +: 32]};
						qn = g * NQ + q;
						tag = {3'd0, 1'b0, warp, qn, rd};
						q_op[qw] = op;
						q_slot[qw] = slot;
						q_mask[qw] = ex[q*4 +: 4];
						q_crd[qw] = crd;
						q_off[qw] = offs;
						q_tag[qw] = tag;
						q_last[qw] = g == NG - 1 && q == lastq;
						qw = qw + 1;
						ans = answer(crd, tag);
						for (l = 0; l < 4; l = l + 1)
							for (c = 0; c < 4; c = c + 1)
								gd[c*DW + (q*4+l)*32 +: 32] = ans[l*128 + c*32 +: 32];
					end
				g_warp[gw] = warp;
				g_grp[gw] = g;
				g_rd[gw] = rd;
				g_sbe[gw] = sbe;
				g_last[gw] = g == NG - 1;
				g_sz[gw] = op[1:0] == 2'd3;
				g_lanes[gw] = ex;
				g_data[gw] = gd;
				gw = gw + 1;
				while (!x_ready)
					@(negedge clk);
				@(posedge clk);
				if (wide) begin
					/* the second operand pass: rs1+2 on x_a, rs1+3 on x_c */
					x_valid <= 1'b0;
					while (($random(seed) & 3) == 0)
						@(posedge clk);
					x_valid <= 1'b1;
					x_a <= p2a;
					x_b <= {NPHYS{32'hBADC0FFE}};
					x_c <= p2c;
					x_last <= g == NG - 1;
					x_uop[ATG_UOP_OP + ATG_TEX_PASS2] <= 1'b1;
					@(negedge clk);
					while (!x_ready)
						@(negedge clk);
					@(posedge clk);
				end
				x_valid <= 1'b0;
				x_a <= {NPHYS{32'hDEADBEEF}};
			end
		end
		n0 = 0;
		while ((gr < gw || qr < qw) && n0 < 100000) begin
			@(posedge clk);
			n0 = n0 + 1;
		end
		if (qr != qw || pr != pw) begin
			$display("FAIL atg_su_tex(%0d): %0d of %0d quads sent, %0d answered", NPHYS, qr,
				qw, pr);
			e_send = e_send + 1;
		end
		if (gr != gw) begin
			$display("FAIL atg_su_tex(%0d): %0d of %0d groups returned", NPHYS, gr, gw);
			e_ret = e_ret + 1;
		end
		done = 1'b1;
	end
endmodule

module atg_su_tex_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	wire d8, d16, d32;
	wire [31:0] s8, r8, s16, r16, s32, r32;
	atg_su_tex_run #(.NPHYS(8), .GRP_W(2), .SEED(21)) n8 (
		.clk(clk), .rst_n(rst_n), .done(d8), .e_send(s8), .e_ret(r8));
	atg_su_tex_run #(.NPHYS(16), .GRP_W(1), .SEED(22)) n16 (
		.clk(clk), .rst_n(rst_n), .done(d16), .e_send(s16), .e_ret(r16));
	atg_su_tex_run #(.NPHYS(32), .GRP_W(1), .SEED(23)) n32 (
		.clk(clk), .rst_n(rst_n), .done(d32), .e_send(s32), .e_ret(r32));

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		wait (d8 && d16 && d32);
		if (s8 + s16 + s32 == 0)
			$display("PASS atg_su_tex.send");
		if (r8 + r16 + r32 == 0)
			$display("PASS atg_su_tex.ret");
		if (s8 + s16 + s32 + r8 + r16 + r32 == 0)
			$display("PASS atg_su_tex");
		else
			$display("FAIL atg_su_tex: send %0d %0d %0d, ret %0d %0d %0d", s8, s16, s32, r8,
				r16, r32);
		$finish;
	end

	initial begin
		#50000000;
		$display("FAIL atg_su_tex: timeout");
		$finish;
	end
endmodule

`default_nettype wire
