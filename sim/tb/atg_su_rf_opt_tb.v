/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_rf_opt_tb: Unit testbench for optimized SU register file (dual-port BRAM)
 * and operand collector (atg_su_rf + atg_su_opd).
 *
 * Verifies:
 * 1. Consecutive FMA instructions (3 register sources rs1, rs2, rs3) fetch all 3
 *    operands accurately across 2 cycles without structural hazards or port collisions.
 * 2. Mixed consecutive FMA and ALU instructions (2 register sources) execute with
 *    seamless transitions and full throughput.
 * 3. Concurrent writeback (WB stage writes to RF while operand collector reads
 *    from Port 1 and Port 2 in the same cycle).
 * 4. Read-during-write at same address returns old value (READ_FIRST semantics).
 * 5. Tested across NPHYS 4, 8, 16, 32.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_rf_opt_chk #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter NREGS = 32,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	input wire go,
	output reg done,
	output reg [31:0] errs
);
`include "atg_su_uop.vh"

	localparam G = 32 / NPHYS;
	localparam GRP_W = G > 1 ? $clog2(G) : 1;
	localparam DW = NPHYS * 32;
	localparam SBE_W = 2;
	localparam UOP_W = ATG_UOP_W;

	/* RF Write Port */
	reg w_en;
	reg [WARP_W-1:0] w_warp;
	reg [GRP_W-1:0] w_grp;
	reg [5:0] w_reg;
	reg [DW-1:0] w_data;
	reg [NPHYS-1:0] w_lanes;

	/* RF Read Port <-> OPD */
	wire r_en;
	wire [WARP_W-1:0] r_warp;
	wire [GRP_W-1:0] r_grp;
	wire [11:0] r_regs;
	wire [DW-1:0] r_data1, r_data2;

	/* OPD Issue Interface */
	reg i_valid;
	wire i_ready;
	reg [WARP_W-1:0] i_warp;
	reg [15:0] i_pc;
	reg [UOP_W-1:0] i_uop;
	reg [SBE_W:0] i_sbe;

	/* Execution Bus */
	wire x_valid;
	wire [WARP_W-1:0] x_warp;
	wire [GRP_W-1:0] x_grp;
	wire x_last;
	wire [SBE_W:0] x_sbe;
	wire [15:0] x_pc;
	wire [UOP_W-1:0] x_uop;
	wire [DW-1:0] x_a, x_b, x_c;
	wire [2*NPHYS-1:0] x_mask;
	wire [31:0] x_info;
	reg [15:0] unit_ready;

	/* DUT: atg_su_rf */
	atg_su_rf #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .NREGS(NREGS)
	) u_rf (
		.clk(clk), .rst_n(rst_n),
		.w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg),
		.w_data(w_data), .w_lanes(w_lanes),
		.r_en(r_en), .r_warp(r_warp), .r_grp(r_grp),
		.r_reg1(r_regs[5:0]), .r_reg2(r_regs[11:6]),
		.r_data1(r_data1), .r_data2(r_data2),
		.scrub(1'b0), .scrub_busy()
	);

	/* DUT: atg_su_opd */
	atg_su_opd #(
		.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W),
		.WARP_BASE(0)
	) u_opd (
		.clk(clk), .rst_n(rst_n),
		.i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc), .i_uop(i_uop),
		.i_sbe(i_sbe),
		.r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_regs(r_regs),
		.r_data({r_data2, r_data1}),
		.cr_en(), .cr_idx(), .cr_data(96'd0),
		.q_warp(), .q_info(160'd0), .q_exec(32'hFFFFFFFF), .q_killed(32'd0),
		.rq_pop(), .rq_data({DW{1'b0}}),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info),
		.unit_ready(unit_ready),
		.fwd_alu_ex4_valid(1'b0), .fwd_alu_ex4_warp({WARP_W{1'b0}}), .fwd_alu_ex4_grp({GRP_W{1'b0}}),
		.fwd_alu_ex4_rd(7'd0), .fwd_alu_ex4_data({DW{1'b0}}), .fwd_alu_ex4_lanes({NPHYS{1'b0}}),
		.fwd_alu_ex5_valid(1'b0), .fwd_alu_ex5_warp({WARP_W{1'b0}}), .fwd_alu_ex5_grp({GRP_W{1'b0}}),
		.fwd_alu_ex5_rd(7'd0), .fwd_alu_ex5_data({DW{1'b0}}), .fwd_alu_ex5_lanes({NPHYS{1'b0}}),
		.fwd_fpu_ex4_valid(1'b0), .fwd_fpu_ex4_warp({WARP_W{1'b0}}), .fwd_fpu_ex4_grp({GRP_W{1'b0}}),
		.fwd_fpu_ex4_rd(7'd0), .fwd_fpu_ex4_data({DW{1'b0}}), .fwd_fpu_ex4_lanes({NPHYS{1'b0}}),
		.fwd_fpu_ex5_valid(1'b0), .fwd_fpu_ex5_warp({WARP_W{1'b0}}), .fwd_fpu_ex5_grp({GRP_W{1'b0}}),
		.fwd_fpu_ex5_rd(7'd0), .fwd_fpu_ex5_data({DW{1'b0}}), .fwd_fpu_ex5_lanes({NPHYS{1'b0}}),
		.fwd_wb_valid(1'b0), .fwd_wb_warp({WARP_W{1'b0}}), .fwd_wb_grp({GRP_W{1'b0}}),
		.fwd_wb_rd(7'd0), .fwd_wb_data({DW{1'b0}}), .fwd_wb_lanes({NPHYS{1'b0}})
	);

	/* Golden Model */
	reg [31:0] model [0:NWARPS*NREGS*32-1];

	function integer idx;
		input integer w, r, g, lane;
		idx = (w * NREGS + r) * 32 + g * NPHYS + lane;
	endfunction

	integer seed = SEED;
	integer k, l, step, iter;

	reg [5:0] tr1, tr2, tr3;
	reg [WARP_W-1:0] tw;
	reg is_fma;

	/* Expected operand buffers per group */
	reg [31:0] exp_a [0:G-1][0:NPHYS-1];
	reg [31:0] exp_b [0:G-1][0:NPHYS-1];
	reg [31:0] exp_c [0:G-1][0:NPHYS-1];
	reg [UOP_W-1:0] exp_uop [0:G-1];
	reg [15:0] exp_pc [0:G-1];

	/* Sample RF read expectations and apply WB writes */
	always @(negedge clk) begin
		if (rst_n) begin
			if (r_en) begin
				exp_uop[r_grp] = u_opd.a_uop;
				exp_pc[r_grp] = u_opd.a_pc;
				if (!u_opd.a_step) begin
					for (l = 0; l < NPHYS; l = l + 1) begin
						exp_a[r_grp][l] = model[idx(r_warp, r_regs[5:0], r_grp, l)];
						exp_b[r_grp][l] = model[idx(r_warp, r_regs[11:6], r_grp, l)];
					end
				end else begin
					for (l = 0; l < NPHYS; l = l + 1) begin
						exp_c[r_grp][l] = model[idx(r_warp, r_regs[5:0], r_grp, l)];
					end
				end
			end

			/* Apply writeback after sampling reads (same cycle read returns old value) */
			if (w_en) begin
				for (l = 0; l < NPHYS; l = l + 1) begin
					if (w_lanes[l])
						model[idx(w_warp, w_reg, w_grp, l)] = w_data[l*32 +: 32];
				end
			end
		end
	end

	/* Checker process */
	always @(negedge clk) begin
		if (rst_n && x_valid && unit_ready[x_uop[ATG_UOP_UNIT +: 4]]) begin
			if (x_pc !== exp_pc[x_grp]) begin
				$display("FAIL atg_su_rf_opt: NPHYS %0d pc=%0d exp_pc=%0d grp=%0d",
					NPHYS, x_pc, exp_pc[x_grp], x_grp);
				errs = errs + 1;
			end

			for (l = 0; l < NPHYS; l = l + 1) begin
				if (x_a[l*32 +: 32] !== exp_a[x_grp][l]) begin
					$display("FAIL atg_su_rf_opt: NPHYS %0d pc=%0d grp=%0d lane=%0d x_a=%h want=%h",
						NPHYS, x_pc, x_grp, l, x_a[l*32 +: 32], exp_a[x_grp][l]);
					errs = errs + 1;
				end
				if (x_b[l*32 +: 32] !== exp_b[x_grp][l]) begin
					$display("FAIL atg_su_rf_opt: NPHYS %0d pc=%0d grp=%0d lane=%0d x_b=%h want=%h",
						NPHYS, x_pc, x_grp, l, x_b[l*32 +: 32], exp_b[x_grp][l]);
					errs = errs + 1;
				end
				if (x_uop[ATG_UOP_USE3] && (x_c[l*32 +: 32] !== exp_c[x_grp][l])) begin
					$display("FAIL atg_su_rf_opt: NPHYS %0d pc=%0d grp=%0d lane=%0d x_c=%h want=%h",
						NPHYS, x_pc, x_grp, l, x_c[l*32 +: 32], exp_c[x_grp][l]);
					errs = errs + 1;
				end
			end

			if (x_grp == G - 1) begin
				if (!x_last) begin
					$display("FAIL atg_su_rf_opt: NPHYS %0d x_last not asserted on final grp", NPHYS);
					errs = errs + 1;
				end
			end
		end
	end

	/* Task: issue an instruction */
	task issue;
		input [WARP_W-1:0] warp;
		input [5:0] r1;
		input [5:0] r2;
		input [5:0] r3;
		input is_fma;
		input [15:0] pc_val;
		reg [UOP_W-1:0] uop;
		begin
			uop = {UOP_W{1'b0}};
			uop[ATG_UOP_RS1 +: 7] = {1'b0, r1};
			uop[ATG_UOP_RS2 +: 7] = {1'b0, r2};
			uop[ATG_UOP_RS3 +: 7] = {1'b0, r3};
			uop[ATG_UOP_USE1] = 1'b1;
			uop[ATG_UOP_USE2] = 1'b1;
			if (is_fma) begin
				uop[ATG_UOP_USE3] = 1'b1;
				uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_FPU;
			end else begin
				uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_ALU;
			end

			@(negedge clk);
			while (!i_ready) @(negedge clk);

			i_valid = 1'b1;
			i_warp = warp;
			i_pc = pc_val;
			i_uop = uop;
			i_sbe = 3'd0;

			@(negedge clk);
			i_valid = 1'b0;
		end
	endtask

	initial begin
		done = 1'b0;
		errs = 0;
		w_en = 1'b0;
		w_warp = 0;
		w_grp = 0;
		w_reg = 0;
		w_data = 0;
		w_lanes = 0;
		i_valid = 1'b0;
		i_warp = 0;
		i_pc = 0;
		i_uop = 0;
		i_sbe = 0;
		unit_ready = 16'hFFFF;

		@(posedge go);

		/* 1. Initialize register file with random values */
		for (k = 0; k < NWARPS * NREGS * G; k = k + 1) begin
			@(negedge clk);
			w_en = 1'b1;
			w_warp = k / (NREGS * G);
			w_reg = (k / G) % NREGS;
			w_grp = k % G;
			w_lanes = {NPHYS{1'b1}};
			for (l = 0; l < NPHYS; l = l + 1) begin
				w_data[l*32 +: 32] = $random(seed);
				model[idx(w_warp, w_reg, w_grp, l)] = w_data[l*32 +: 32];
			end
		end
		@(negedge clk);
		w_en = 1'b0;

		/* 2. Test consecutive FMA and ALU instructions */
		for (iter = 0; iter < 100; iter = iter + 1) begin
			tw = $unsigned($random(seed)) % NWARPS;
			tr1 = $unsigned($random(seed)) % NREGS;
			tr2 = $unsigned($random(seed)) % NREGS;
			tr3 = $unsigned($random(seed)) % NREGS;
			is_fma = iter[0]; /* alternate FMA and ALU */

			issue(tw, tr1, tr2, tr3, is_fma, iter[15:0]);
		end

		/* Wait for all issued instructions to complete */
		while (u_opd.a_act || u_opd.b_valid) @(negedge clk);

		/* 3. Test concurrent writeback during FMA execution */
		for (iter = 0; iter < 100; iter = iter + 1) begin
			tw = $unsigned($random(seed)) % NWARPS;
			tr1 = $unsigned($random(seed)) % NREGS;
			tr2 = $unsigned($random(seed)) % NREGS;
			tr3 = $unsigned($random(seed)) % NREGS;

			/* Start issue */
			issue(tw, tr1, tr2, tr3, 1'b1, 16'd500 + iter[15:0]);

			/* Inject concurrent writeback on the WB port for 1 cycle */
			@(negedge clk);
			w_en = 1'b1;
			w_warp = $unsigned($random(seed)) % NWARPS;
			w_grp = $unsigned($random(seed)) % G;
			w_reg = $unsigned($random(seed)) % NREGS;
			w_lanes = $random(seed);
			for (l = 0; l < NPHYS; l = l + 1)
				w_data[l*32 +: 32] = $random(seed);
			@(negedge clk);
			w_en = 1'b0;
		end

		while (u_opd.a_act || u_opd.b_valid) @(negedge clk);

		@(negedge clk);
		done = 1'b1;
	end
endmodule

module atg_su_rf_opt_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg go = 1'b0;
	wire [3:0] done;
	wire [31:0] e0, e1, e2, e3;

	always #5 clk = !clk;

	atg_su_rf_opt_chk #(.NPHYS(4), .SEED(10)) c0 (
		.clk(clk), .rst_n(rst_n), .go(go), .done(done[0]), .errs(e0)
	);
	atg_su_rf_opt_chk #(.NPHYS(8), .SEED(20)) c1 (
		.clk(clk), .rst_n(rst_n), .go(go), .done(done[1]), .errs(e1)
	);
	atg_su_rf_opt_chk #(.NPHYS(16), .SEED(30)) c2 (
		.clk(clk), .rst_n(rst_n), .go(go), .done(done[2]), .errs(e2)
	);
	atg_su_rf_opt_chk #(.NPHYS(32), .SEED(40)) c3 (
		.clk(clk), .rst_n(rst_n), .go(go), .done(done[3]), .errs(e3)
	);

	initial begin
		#12 rst_n = 1'b1;
		#20 go = 1'b1;
		wait (done == 4'b1111);
		if (e0 + e1 + e2 + e3 == 0) begin
			$display("PASS atg_su_rf_opt.fma_alu");
			$display("PASS atg_su_rf_opt.rw_hazard");
			$display("PASS atg_su_rf_opt");
		end else begin
			$display("FAIL atg_su_rf_opt errs: %0d %0d %0d %0d", e0, e1, e2, e3);
		end
		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL atg_su_rf_opt timeout");
		$finish;
	end
endmodule
