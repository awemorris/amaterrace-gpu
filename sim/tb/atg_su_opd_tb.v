/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_opd_tb: operand collection for NPHYS 8, 16 and 32.  Random
 * instructions (random units, operand numbers 0-127 except 63, PAIR,
 * modifiers, PAIR with rs3: two operand passes) with a model RF and
 * constant bank behind the read ports and random unit_ready; every group
 * must leave once (a PAIR + USE3 group twice, the second pass with rs3 as
 * operand 1 and TEX op bit 7 set, x_last there), in order, with the
 * operands, masks and x_info of a behavioural reference.  The checker
 * counts errors per class (gpr, special, mods, mask).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_opd_chk #(
	parameter NPHYS = 8,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] e_gpr,
	output reg [31:0] e_spec,
	output reg [31:0] e_mod,
	output reg [31:0] e_mask
);
`include "atg_su_uop.vh"
	localparam G = 32 / NPHYS;
	localparam GRP_W = G > 1 ? $clog2(G) : 1;
	localparam DW = NPHYS * 32;
	localparam NI = 400;

	reg i_valid = 1'b0;
	wire i_ready;
	reg [1:0] i_warp = 0;
	reg [15:0] i_pc = 0;
	reg [ATG_UOP_W-1:0] i_uop = 0;
	reg [2:0] i_sbe = 0;
	wire r_en, cr_en, rq_pop;
	wire [1:0] r_warp, q_warp;
	wire [GRP_W-1:0] r_grp, x_grp;
	wire [17:0] r_regs;
	reg [3*DW-1:0] r_data = 0;
	wire [14:0] cr_idx;
	reg [95:0] cr_data = 0;
	wire x_valid, x_last;
	wire [1:0] x_warp;
	wire [2:0] x_sbe;
	wire [15:0] x_pc;
	wire [ATG_UOP_W-1:0] x_uop;
	wire [DW-1:0] x_a, x_b, x_c;
	wire [2*NPHYS-1:0] x_mask;
	wire [31:0] x_info;
	reg [15:0] unit_ready = 16'hFFFF;
	integer seed = SEED;

	/* Warp state tables. */
	reg [159:0] info [0:3];
	reg [31:0] exec [0:3];
	reg [31:0] killed [0:3];
	/* The model RF: value of (warp, reg, lane). */
	function [31:0] gv;
		input [1:0] w;
		input [5:0] r;
		input [4:0] lane;
		gv = {w, r, lane, 19'h5A5A5} ^ {lane, 27'd0} ^ ({26'd0, r} * 32'h01010101);
	endfunction
	function [31:0] cv;
		input [4:0] c;
		cv = 32'hC0000000 | {27'd0, c} * 32'h00030007;
	endfunction

	atg_su_opd #(.NPHYS(NPHYS), .GRP_W(GRP_W)) dut (
		.clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp),
		.i_pc(i_pc), .i_uop(i_uop), .i_sbe(i_sbe), .r_en(r_en), .r_warp(r_warp),
		.r_grp(r_grp), .r_regs(r_regs), .r_data(r_data), .cr_en(cr_en), .cr_idx(cr_idx),
		.cr_data(cr_data), .q_warp(q_warp), .q_info(info[q_warp]), .q_exec(exec[q_warp]),
		.q_killed(killed[q_warp]), .rq_pop(rq_pop), .rq_data({DW{1'b0}}),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .unit_ready(unit_ready)
	);

	integer l;
	always @(posedge clk) begin
		if (r_en)
			for (l = 0; l < NPHYS; l = l + 1) begin
				r_data[l*32 +: 32] <= gv(r_warp, r_regs[5:0], r_grp * NPHYS + l);
				r_data[DW + l*32 +: 32] <= gv(r_warp, r_regs[11:6], r_grp * NPHYS + l);
				r_data[2*DW + l*32 +: 32] <= gv(r_warp, r_regs[17:12], r_grp * NPHYS + l);
			end
		if (cr_en)
			cr_data <= {cv(cr_idx[14:10]), cv(cr_idx[9:5]), cv(cr_idx[4:0])};
	end

	/* The reference value of operand n of warp w in lane. */
	function [31:0] ref_op;
		input [6:0] n;
		input [1:0] w;
		input [4:0] lane;
		begin
			if (n < 63)
				ref_op = gv(w, n[5:0], lane);
			else if (n < 96)
				ref_op = n == 63 ? 32'd0 : cv(n[4:0]);
			else begin
				case (n)
				96: ref_op = 0;
				97: ref_op = 32'h3F800000;
				98: ref_op = 1;
				99: ref_op = 32'h3F000000;
				100: ref_op = 32'h40000000;
				101: ref_op = 32'hBF800000;
				102: ref_op = lane;
				103: ref_op = w;
				104: ref_op = exec[w];
				105: ref_op = killed[w][lane] ? 32'hFFFFFFFF : 0;
				106: ref_op = info[w][15:0];
				107: ref_op = info[w][31:16];
				108: ref_op = info[w][47:32];
				109, 112: ref_op = info[w][103:96] + lane;
				114: ref_op = info[w][106] ? 32'hFFFFFFFF : 0;
				115: ref_op = info[w][63:48];
				116: ref_op = info[w][79:64];
				117: ref_op = info[w][95:80];
				118: ref_op = 32'h3C003C00;
				119: ref_op = info[w][159:128];
				default: ref_op = 0;
				endcase
			end
		end
	endfunction

	function [31:0] ref_mod;
		input [31:0] v;
		input ng, ab;
		input [3:0] unit;
		reg [31:0] r;
		begin
			r = v;
			if (unit == ATG_UNIT_FPU || unit == ATG_UNIT_XU) begin
				if (ab) r[31] = 0;
				if (ng) r[31] = !r[31];
			end else if (unit == ATG_UNIT_PK) begin
				if (ab) begin r[31] = 0; r[15] = 0; end
				if (ng) begin r[31] = !r[31]; r[15] = !r[15]; end
			end
			ref_mod = r;
		end
	endfunction

	/* The issued instructions, checked in order. */
	reg [ATG_UOP_W-1:0] q_uop [0:NI-1];
	reg [1:0] q_w [0:NI-1];
	integer head, grp, n_iss, pass;
	integer k;
	reg [6:0] n1, n2, n3;
	reg [31:0] want, gotv;
	integer src;

	task check_group;
		reg [ATG_UOP_W-1:0] u;
		reg [1:0] w;
		reg [31:0] eg, kg, cg;
		reg [4:0] lane;
		reg wide;
		integer e;
		begin
			u = q_uop[head];
			w = q_w[head];
			wide = u[ATG_UOP_PAIR] && u[ATG_UOP_USE3];
			if (x_uop !== (pass ? u | ({{(ATG_UOP_W-1){1'b0}}, 1'b1} << (ATG_UOP_OP + 7)) : u) ||
			    x_warp !== w || x_grp !== grp || x_last !== (grp == G - 1 && (!wide || pass)) ||
			    x_pc !== head) begin
				if (e_gpr < 5)
					$display("FAIL opd NPHYS %0d head %0d grp %0d pass %0d: uop/last", NPHYS,
						head, grp, pass);
				e_gpr = e_gpr + 1;
			end
			n1 = pass ? u[ATG_UOP_RS3 +: 7] : u[ATG_UOP_RS1 +: 7];
			n2 = u[ATG_UOP_RS2 +: 7];
			n3 = u[ATG_UOP_PAIR] ? u[ATG_UOP_RS1 +: 7] + 1 : u[ATG_UOP_RS3 +: 7];
			for (l = 0; l < NPHYS; l = l + 1) begin
				lane = grp * NPHYS + l;
				for (src = 0; src < 3; src = src + 1) begin
					want = ref_op(src == 0 ? n1 : src == 1 ? n2 : n3, w, lane);
					want = ref_mod(want, u[ATG_UOP_MOD + 2*src], u[ATG_UOP_MOD + 2*src + 1],
						u[ATG_UOP_UNIT +: 4]);
					gotv = src == 0 ? x_a[l*32 +: 32] : src == 1 ? x_b[l*32 +: 32] :
						x_c[l*32 +: 32];
					if (gotv !== want) begin
						e = (src == 0 ? n1 : src == 1 ? n2 : n3);
						if (u[ATG_UOP_MOD + 2*src +: 2] != 0 && u[ATG_UOP_UNIT +: 4] <= 4)
							e_mod = e_mod + 1;
						else if (e >= 96)
							e_spec = e_spec + 1;
						else
							e_gpr = e_gpr + 1;
						if (e_gpr + e_spec + e_mod < 5)
							$display("FAIL opd NPHYS %0d pc %0d head %0d op%0d n=%0d lane %0d: %h want %h", NPHYS, x_pc, head,
								src + 1, e, lane, gotv, want);
					end
				end
			end
			eg = exec[w] >> (grp * NPHYS);
			kg = killed[w] >> (grp * NPHYS);
			cg = info[w][159:128] >> (grp * NPHYS);
			if (x_mask !== {eg[NPHYS-1:0] & cg[NPHYS-1:0] & ~kg[NPHYS-1:0], eg[NPHYS-1:0]} ||
			    x_info !== {13'd0, info[w][106], info[w][105:104], info[w][127:112]})
				e_mask = e_mask + 1;
			if (wide && !pass)
				pass = 1;
			else begin
				pass = 0;
				if (grp == G - 1) begin
					grp = 0;
					head = head + 1;
				end else
					grp = grp + 1;
			end
		end
	endtask

	/* Monitor at negedge: a group is taken when x_valid and its unit is ready. */
	always @(negedge clk) begin
		/* New random back-pressure for the next edge. */
		unit_ready = ($random(seed) & 3) == 0 ? $random(seed) : 16'hFFFF;
		if (rst_n && x_valid && unit_ready[x_uop[ATG_UOP_UNIT +: 4]])
			check_group;
	end

	reg [3:0] unit;
	initial begin
		done = 1'b0;
		e_gpr = 0;
		e_spec = 0;
		e_mod = 0;
		e_mask = 0;
		head = 0;
		grp = 0;
		pass = 0;
		for (k = 0; k < 4; k = k + 1) begin
			info[k] = {$random(seed), $random(seed), $random(seed), $random(seed),
				$random(seed)};
			exec[k] = $random(seed);
			killed[k] = $random(seed);
		end
		@(posedge rst_n);
		for (n_iss = 0; n_iss < NI; n_iss = n_iss + 1) begin
			@(negedge clk);
			while (($random(seed) & 3) == 0)
				@(negedge clk);
			i_valid = 1'b1;
			i_warp = $random(seed);
			i_pc = n_iss;
			i_sbe = $random(seed);
			unit = $random(seed);
			i_uop = 0;
			i_uop[ATG_UOP_UNIT +: 4] = unit;
			for (k = 0; k < 3; k = k + 1) begin
				n1 = $random(seed);
				if (n1 == 63)
					n1 = 62;
				i_uop[ATG_UOP_RS1 + 7*k +: 7] = n1;
			end
			i_uop[ATG_UOP_MOD +: 7] = $random(seed);
			i_uop[ATG_UOP_PAIR] = ($random(seed) & 3) == 0;
			if (i_uop[ATG_UOP_PAIR] && (i_uop[ATG_UOP_RS1 +: 7] == 62 ||
			    i_uop[ATG_UOP_RS1 +: 7] == 95 || i_uop[ATG_UOP_RS1 +: 7] == 127))
				i_uop[ATG_UOP_RS1 +: 7] = 7'd5;
			/* a four-operand uop (a texture .c form): PAIR and rs3 */
			i_uop[ATG_UOP_USE3] = i_uop[ATG_UOP_PAIR] && ($random(seed) & 1);
			q_uop[n_iss] = i_uop;
			q_w[n_iss] = i_warp;
			#1;
			while (!i_ready) begin
				@(negedge clk);
				#1;
			end
			@(negedge clk);
			i_valid = 1'b0;
		end
		wait (head == NI);
		done = 1'b1;
	end
endmodule

module atg_su_opd_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire [2:0] done;
	wire [31:0] g0, g1, g2, s0, s1, s2, m0, m1, m2, k0, k1, k2;

	always #5 clk = !clk;

	atg_su_opd_chk #(.NPHYS(8), .SEED(1)) c0 (.clk(clk), .rst_n(rst_n), .done(done[0]),
		.e_gpr(g0), .e_spec(s0), .e_mod(m0), .e_mask(k0));
	atg_su_opd_chk #(.NPHYS(16), .SEED(2)) c1 (.clk(clk), .rst_n(rst_n), .done(done[1]),
		.e_gpr(g1), .e_spec(s1), .e_mod(m1), .e_mask(k1));
	atg_su_opd_chk #(.NPHYS(32), .SEED(3)) c2 (.clk(clk), .rst_n(rst_n), .done(done[2]),
		.e_gpr(g2), .e_spec(s2), .e_mod(m2), .e_mask(k2));

	initial begin
		#25 rst_n = 1'b1;
		wait (&done);
		if (g0 + g1 + g2 == 0) $display("PASS atg_su_opd.gpr");
		else $display("FAIL atg_su_opd.gpr %0d %0d %0d", g0, g1, g2);
		if (s0 + s1 + s2 == 0) $display("PASS atg_su_opd.special");
		else $display("FAIL atg_su_opd.special %0d %0d %0d", s0, s1, s2);
		if (m0 + m1 + m2 == 0) $display("PASS atg_su_opd.mods");
		else $display("FAIL atg_su_opd.mods %0d %0d %0d", m0, m1, m2);
		if (k0 + k1 + k2 == 0) $display("PASS atg_su_opd.mask");
		else $display("FAIL atg_su_opd.mask %0d %0d %0d", k0, k1, k2);
		if (g0 + g1 + g2 + s0 + s1 + s2 + m0 + m1 + m2 + k0 + k1 + k2 == 0)
			$display("PASS atg_su_opd");
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_su_opd timeout");
		$finish;
	end
endmodule

`default_nettype wire
