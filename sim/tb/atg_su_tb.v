/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_tb: the shader unit running GSI1 programs (the check that
 * the same binary gives the same results on NPHYS 4, 8, 16 and 32).  Four
 * SUs (NPHYS 4, 8, 16, 32; NWARPS 4, NREGS 32; SUBGROUP 1) fetch code and load constants
 * from one amb_mem behind their I$ port, and access data through a second
 * amb_mem behind their D$ port; at_* goes to atg_mc_atom, whose AMB port
 * shares that second amb_mem with the D$ through am_amb_mux.
 * For each program of sim/tb/su (built by tools/su-tests.sh) the data image
 * NAME.dat goes to 0x8000 of both memories, LOAD_CONST loads its first 256
 * words into the constant bank, and the program runs as a compute dispatch
 * (DISPATCH groups x 1 x 1); when the SU is idle every register that
 * tools/gsi1model.py says the program wrote is compared, lane by lane, and
 * the data memory with the model's NAME.mexp.  The graphics and SA ports
 * are tied off.
 *   alu: integer ops, dependent chains, specials (128 lanes)
 *   branch: exec mask, divergence, loops, branches, bar, kill (100 lanes)
 *   rand: a random integer program with masked sections (128 lanes)
 *   frand: a random fp32/transcendental/divide program (128 lanes)
 *   mem: lw/sw/atom/fence, lwc and c operands, LDS with bar (128 lanes)
 *   vadd: fp32 vector add over 2 workgroups (memory only)
 *   reduce: fp32 tree reduction in LDS and an integer atomic sum (128 lanes)
 *   sub: qd, shfl/vote/ballot with EXEC full, partial and empty (100 lanes)
 * A fifth SU (NPHYS 8, SUBGROUP 0) runs sub only and must report an ISA
 * fault (the CP's kind 8) at the model's pc for every warp (sub.fault), with
 * the registers written before it (sub.fexp).
 * +quick (the short run, sim/run.sh -q): NPHYS 4 (the KC705's), 8 and 32
 * only, without frand.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_chk #(
	parameter NPHYS = 8,
	parameter SEED = 1,
	parameter SUBGROUP = 1,
	parameter P_FIRST = 0,	/* the first program to run */
	parameter FAULTS = 0	/* expect the ISA faults of sub.fault (SUBGROUP 0) */
) (
	input wire clk,
	input wire go,
	output reg done,
	output reg [31:0] errs,
	output reg [31:0] cycles
);
	localparam G = 32 / NPHYS;
	localparam GRP_W = G > 1 ? $clog2(G) : 1;
	localparam NREGS = 32;
	localparam NP = 8;	/* programs */
	localparam DATA = 32'h8000;
	localparam DWORDS = 4096;

	reg rst_n = 1'b0;
	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg cs_kick = 1'b0;
	wire i_req_valid, i_req_ready, i_req_write, i_rsp_valid, i_rsp_write, i_rsp_error;
	wire [26:0] i_req_line;
	wire [31:0] i_req_be;
	wire [255:0] i_req_wdata, i_rsp_rdata;
	wire [7:0] i_req_tag, i_rsp_tag;
	wire busy, fault;
	wire [31:0] fault_addr;
	reg lc_kick = 1'b0;
	wire d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_write, d_rsp_error;
	wire [26:0] d_req_line;
	wire [31:0] d_req_be;
	wire [255:0] d_req_wdata, d_rsp_rdata;
	wire [7:0] d_req_tag, d_rsp_tag;
	wire at_valid, at_ready, at_rsp_valid, at_error;
	wire [3:0] at_op;
	wire [29:0] at_addr;
	wire [31:0] at_a, at_b, at_old;
	/* The D$ (requester 0) and the atomic unit (1) into dmem. */
	wire a_req_valid, a_req_ready, a_req_write, a_rsp_valid, m_rsp_write;
	wire [26:0] a_req_line;
	wire [31:0] a_req_be;
	wire [255:0] a_req_wdata, m_rsp_rdata;
	wire [7:0] a_req_tag, m_rsp_tag;
	wire [1:0] x_rsp_valid;
	wire m_req_valid, m_req_ready, m_req_write, m_rsp_valid, m_rsp_error;
	wire [26:0] m_req_line;
	wire [31:0] m_req_be;
	wire [255:0] m_req_wdata, x_rsp_rdata;
	wire [7:0] m_req_tag, x_rsp_tag;
	wire x_rsp_write, x_rsp_error;

	atg_su #(.NPHYS(NPHYS), .GRP_W(GRP_W), .SUBGROUP(SUBGROUP)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.scrub(1'b0), .scrub_busy(),
		.cs_kick(cs_kick), .lc_kick(lc_kick), .inv(4'd0),
		.vl_req(1'b0), .vl_gnt(), .vl_slot(), .vl_ptbase(), .vl_we(1'b0), .vl_reg(6'd0),
		.vl_lane(5'd0), .vl_data(32'd0), .vl_go(1'b0), .vl_mask(32'd0),
		.fl_req(1'b0), .fl_gnt(), .fl_slot(), .fl_we(1'b0), .fl_reg(6'd0), .fl_lane(5'd0),
		.fl_data(32'd0), .fl_pw_we(1'b0), .fl_pw_addr(12'd0), .fl_pw_data(32'd0),
		.fl_go(1'b0), .fl_mask(32'd0), .fl_info(64'd0),
		.pt_rd(1'b0), .pt_idx(8'd0), .pt_word(7'd0), .pt_rdata(), .pt_free(1'b0),
		.pt_free_idx(8'd0), .pt_done(),
		.tx_valid(), .tx_ready(1'b1), .tx_op(), .tx_slot(), .tx_mask(), .tx_coord(), .tx_off(),
		.tx_tag(), .tx_last(), .tr_valid(1'b0), .tr_ready(), .tr_tag(16'd0),
		.tr_data(512'd0), .tr_last(1'b0),
		.ex_valid(), .ex_ready(1'b1), .ex_seq(), .ex_xy(), .ex_mask(), .ex_color(),
		.ex_depth(), .ex_last(), .ex_next(16'd0),
		.d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_write(d_req_write),
		.d_req_line(d_req_line), .d_req_be(d_req_be), .d_req_wdata(d_req_wdata),
		.d_req_tag(d_req_tag), .d_rsp_valid(d_rsp_valid), .d_rsp_write(d_rsp_write),
		.d_rsp_tag(d_rsp_tag), .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
		.i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_write(i_req_write),
		.i_req_line(i_req_line), .i_req_be(i_req_be), .i_req_wdata(i_req_wdata),
		.i_req_tag(i_req_tag), .i_rsp_valid(i_rsp_valid), .i_rsp_write(i_rsp_write),
		.i_rsp_tag(i_rsp_tag), .i_rsp_rdata(i_rsp_rdata), .i_rsp_error(i_rsp_error),
		.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
		.at_a(at_a), .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
		.at_error(at_error),
		.sa_push_valid(), .sa_push_ready(1'b1), .sa_push_data(), .sa_pop_valid(1'b0),
		.sa_pop_ready(), .sa_pop_data({(NPHYS*32){1'b0}}), .sa_ctl_valid(), .sa_ctl_data(),
		.sa_qstat(32'd0), .sa_stat(32'd0), .sa_qtag(32'd0),
		.busy(busy), .fault(fault), .fault_addr(fault_addr)
	);
	atg_mc_atom #(.NATOM(1), .AW(1)) atom (
		.clk(clk), .rst_n(rst_n),
		.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
		.at_a(at_a), .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
		.at_error(at_error), .busy(),
		.req_valid(a_req_valid), .req_ready(a_req_ready), .req_write(a_req_write),
		.req_line(a_req_line), .req_be(a_req_be), .req_wdata(a_req_wdata),
		.req_tag(a_req_tag), .rsp_valid(a_rsp_valid), .rsp_write(x_rsp_write),
		.rsp_tag(x_rsp_tag), .rsp_rdata(x_rsp_rdata), .rsp_error(x_rsp_error)
	);
	am_amb_mux #(.N(2), .ID_W(1)) dmux (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid({a_req_valid, d_req_valid}), .i_req_ready({a_req_ready, d_req_ready}),
		.i_req_write({a_req_write, d_req_write}), .i_req_line({a_req_line, d_req_line}),
		.i_req_be({a_req_be, d_req_be}), .i_req_wdata({a_req_wdata, d_req_wdata}),
		.i_req_tag({a_req_tag, d_req_tag}), .i_rsp_valid(x_rsp_valid),
		.i_rsp_write(x_rsp_write), .i_rsp_tag(x_rsp_tag), .i_rsp_rdata(x_rsp_rdata),
		.i_rsp_error(x_rsp_error),
		.o_req_valid(m_req_valid), .o_req_ready(m_req_ready), .o_req_write(m_req_write),
		.o_req_line(m_req_line), .o_req_be(m_req_be), .o_req_wdata(m_req_wdata),
		.o_req_tag(m_req_tag), .o_rsp_valid(m_rsp_valid), .o_rsp_write(m_rsp_write),
		.o_rsp_tag(m_rsp_tag), .o_rsp_rdata(m_rsp_rdata), .o_rsp_error(m_rsp_error)
	);
	assign d_rsp_valid = x_rsp_valid[0];
	assign a_rsp_valid = x_rsp_valid[1];
	assign d_rsp_write = x_rsp_write;
	assign d_rsp_tag = x_rsp_tag;
	assign d_rsp_rdata = x_rsp_rdata;
	assign d_rsp_error = x_rsp_error;
	amb_mem #(.MEM_WORDS(16384), .SEED(SEED + 10)) dmem (
		.clk(clk), .rst_n(rst_n), .req_valid(m_req_valid), .req_ready(m_req_ready),
		.req_write(m_req_write), .req_line(m_req_line), .req_be(m_req_be),
		.req_wdata(m_req_wdata), .req_tag(m_req_tag), .rsp_valid(m_rsp_valid),
		.rsp_write(m_rsp_write), .rsp_tag(m_rsp_tag), .rsp_rdata(m_rsp_rdata),
		.rsp_error(m_rsp_error)
	);

	amb_mem #(.MEM_WORDS(16384), .SEED(SEED)) mem (
		.clk(clk), .rst_n(rst_n), .req_valid(i_req_valid), .req_ready(i_req_ready),
		.req_write(i_req_write), .req_line(i_req_line), .req_be(i_req_be),
		.req_wdata(i_req_wdata), .req_tag(i_req_tag), .rsp_valid(i_rsp_valid),
		.rsp_write(i_rsp_write), .rsp_tag(i_rsp_tag), .rsp_rdata(i_rsp_rdata),
		.rsp_error(i_rsp_error)
	);

	reg [31:0] code [0:4095];
	reg [32:0] exp [0:4*NREGS*32-1];
	reg [31:0] dat [0:DWORDS-1];
	reg [31:0] mexp [0:DWORDS-1];
	integer lane_err [0:NPHYS-1];
	event check;
	integer n_fault, f_bad, nf_exp, q;
	reg [31:0] fexp [0:7];
	reg f_hit;
	always @(posedge clk)
		if (fault) begin
			f_hit = 1'b0;
			for (q = 0; q < nf_exp; q = q + 1)
				if (fexp[2 * q + 1] == fault_addr)
					f_hit = 1'b1;
			if (!FAULTS || !f_hit) begin
				$display("FAIL atg_su NPHYS %0d: ISA fault at pc %0d", NPHYS, fault_addr);
				f_bad = f_bad + 1;
			end
			n_fault = n_fault + 1;
		end

	/* Per physical lane: compare the RF copy 1 with the model (hierarchical). */
	genvar gl;
	generate
		for (gl = 0; gl < NPHYS; gl = gl + 1) begin : cmp
			integer s, r, g, a, e;
			always @(check) begin
				lane_err[gl] = 0;
				for (s = 0; s < 4; s = s + 1)
					for (r = 0; r < NREGS; r = r + 1)
						for (g = 0; g < G; g = g + 1) begin
							a = (s * NREGS + r) * G + g;
							e = (s * NREGS + r) * 32 + g * NPHYS + gl;
							if (exp[e][32] && dut.rf.lane[gl].m1[a] !== exp[e][31:0]) begin
								if (lane_err[gl] < 3)
									$display("FAIL atg_su NPHYS %0d slot %0d r%0d lane %0d: %h want %h",
										NPHYS, s, r, g * NPHYS + gl,
										dut.rf.lane[gl].m1[a], exp[e][31:0]);
								lane_err[gl] = lane_err[gl] + 1;
							end
						end
			end
		end
	endgenerate

	task state;
		input [8:0] idx;
		input [31:0] v;
		begin
			@(negedge clk);
			st_we = 1'b1;
			st_idx = idx;
			st_wdata = v;
			@(negedge clk);
			st_we = 1'b0;
		end
	endtask

	integer p, i, t, lanes, groups, l, merr;
	reg quick;
	initial begin
		quick = $test$plusargs("quick");
		done = 1'b0;
		errs = 0;
		cycles = 0;
		n_fault = 0;
		f_bad = 0;
		nf_exp = 0;
		@(posedge go);
		for (p = P_FIRST; p < NP; p = p + 1) begin
			if (quick && p == 3)
				p = 4;	/* no frand */
			for (i = 0; i < 4096; i = i + 1)
				code[i] = 32'd0;
			lanes = 128;
			groups = 1;
			case (p)
			0: begin
				$readmemh("sim/tb/su/alu.hex", code);
				$readmemh("sim/tb/su/alu.exp", exp);
				$readmemh("sim/tb/su/alu.dat", dat);
				$readmemh("sim/tb/su/alu.mexp", mexp);
			end
			1: begin
				$readmemh("sim/tb/su/branch.hex", code);
				$readmemh("sim/tb/su/branch.exp", exp);
				$readmemh("sim/tb/su/branch.dat", dat);
				$readmemh("sim/tb/su/branch.mexp", mexp);
				lanes = 100;
			end
			2: begin
				$readmemh("sim/tb/su/rand.hex", code);
				$readmemh("sim/tb/su/rand.exp", exp);
				$readmemh("sim/tb/su/rand.dat", dat);
				$readmemh("sim/tb/su/rand.mexp", mexp);
			end
			3: begin
				$readmemh("sim/tb/su/frand.hex", code);
				$readmemh("sim/tb/su/frand.exp", exp);
				$readmemh("sim/tb/su/frand.dat", dat);
				$readmemh("sim/tb/su/frand.mexp", mexp);
			end
			4: begin
				$readmemh("sim/tb/su/mem.hex", code);
				$readmemh("sim/tb/su/mem.exp", exp);
				$readmemh("sim/tb/su/mem.dat", dat);
				$readmemh("sim/tb/su/mem.mexp", mexp);
			end
			5: begin
				$readmemh("sim/tb/su/vadd.hex", code);
				$readmemh("sim/tb/su/vadd.exp", exp);
				$readmemh("sim/tb/su/vadd.dat", dat);
				$readmemh("sim/tb/su/vadd.mexp", mexp);
				groups = 2;
			end
			6: begin
				$readmemh("sim/tb/su/reduce.hex", code);
				$readmemh("sim/tb/su/reduce.exp", exp);
				$readmemh("sim/tb/su/reduce.dat", dat);
				$readmemh("sim/tb/su/reduce.mexp", mexp);
			end
			default: begin
				$readmemh("sim/tb/su/sub.hex", code);
				if (FAULTS) begin
					$readmemh("sim/tb/su/sub.fexp", exp);
					$readmemh("sim/tb/su/sub.fault", fexp);
					nf_exp = 4;
				end else
					$readmemh("sim/tb/su/sub.exp", exp);
				$readmemh("sim/tb/su/sub.dat", dat);
				$readmemh("sim/tb/su/sub.mexp", mexp);
				lanes = 100;
			end
			endcase
			n_fault = 0;
			rst_n = 1'b0;
			for (i = 0; i < 4096; i = i + 1)
				mem.poke(32'h1000 + 4 * i, code[i]);
			for (i = 0; i < DWORDS; i = i + 1) begin
				mem.poke(DATA + 4 * i, dat[i]);
				dmem.poke(DATA + 4 * i, dat[i]);
			end
			repeat (3) @(negedge clk);
			rst_n = 1'b1;
			/* LOAD_CONST: region 0, the image's first 256 words. */
			state(9'h1EC, 0);
			state(9'h1ED, DATA);
			state(9'h1EE, 256);
			@(negedge clk);
			lc_kick = 1'b1;
			@(negedge clk);
			lc_kick = 1'b0;
			t = 0;
			while (busy && t < 10000) begin
				@(negedge clk);
				t = t + 1;
			end
			state(9'h194, 32'h1000);
			state(9'h199, {8'd0, 8'd1, 8'd1, lanes[7:0]});
			state(9'h1E9, groups);
			state(9'h1EA, 1);
			state(9'h1EB, 1);
			@(negedge clk);
			cs_kick = 1'b1;
			@(negedge clk);
			cs_kick = 1'b0;
			t = 0;
			while ((busy || t < 4) && t < 1000000 && !(FAULTS && n_fault >= nf_exp)) begin
				@(negedge clk);
				t = t + 1;
			end
			if (FAULTS) begin
				/* The faulted warps stay in the SU (the CP recovers it). */
				repeat (200) @(negedge clk);
				if (n_fault != nf_exp) begin
					$display("FAIL atg_su NPHYS %0d program %0d: %0d ISA faults, want %0d",
						NPHYS, p, n_fault, nf_exp);
					errs = errs + 1;
				end
			end else if (busy) begin
				$display("FAIL atg_su NPHYS %0d program %0d: still busy", NPHYS, p);
				errs = errs + 1;
			end
			cycles = cycles + t;
			-> check;
			#1;
			for (l = 0; l < NPHYS; l = l + 1)
				errs = errs + lane_err[l];
			merr = 0;
			for (i = 0; i < DWORDS; i = i + 1)
				if (dmem.peek(DATA + 4 * i) !== mexp[i]) begin
					if (merr < 3)
						$display("FAIL atg_su NPHYS %0d program %0d: memory %h: %h want %h",
							NPHYS, p, DATA + 4 * i, dmem.peek(DATA + 4 * i), mexp[i]);
					merr = merr + 1;
				end
			errs = errs + merr;
			$display("atg_su NPHYS %0d program %0d: %0d cycles", NPHYS, p, t);
		end
		errs = errs + f_bad;
		done = 1'b1;
	end
endmodule

module atg_su_tb;
	reg clk = 1'b0;
	reg go = 1'b0;
	wire [4:0] done;
	wire [31:0] e0, e1, e2, e3, e4, c0, c1, c2, c3, c4;

	always #5 clk = !clk;
	/* +quick: NPHYS 16 gets no clock and is not waited for. */
	reg quick;
	initial
		quick = $test$plusargs("quick");
	wire clk16 = clk & !quick;

	atg_su_chk #(.NPHYS(8), .SEED(1)) n8 (.clk(clk), .go(go), .done(done[0]), .errs(e0),
		.cycles(c0));
	atg_su_chk #(.NPHYS(16), .SEED(2)) n16 (.clk(clk16), .go(go), .done(done[1]), .errs(e1),
		.cycles(c1));
	atg_su_chk #(.NPHYS(32), .SEED(3)) n32 (.clk(clk), .go(go), .done(done[2]), .errs(e2),
		.cycles(c2));
	atg_su_chk #(.NPHYS(8), .SEED(4), .SUBGROUP(0), .P_FIRST(7), .FAULTS(1)) n8f (.clk(clk),
		.go(go), .done(done[3]), .errs(e3), .cycles(c3));
	atg_su_chk #(.NPHYS(4), .SEED(5)) n4 (.clk(clk), .go(go), .done(done[4]), .errs(e4),
		.cycles(c4));

	initial begin
		#20 go = 1'b1;
		wait (done[0] && (done[1] || quick) && done[2] && done[3] && done[4]);
		if (e4 == 0) $display("PASS atg_su.nphys4");
		if (e0 == 0) $display("PASS atg_su.nphys8");
		if (e1 == 0 && !quick) $display("PASS atg_su.nphys16");
		if (e2 == 0) $display("PASS atg_su.nphys32");
		if (e3 == 0) $display("PASS atg_su.nosubgroup");
		if (e0 + e1 + e2 + e3 + e4 == 0)
			$display("PASS atg_su");
		$finish;
	end

	initial begin
		#100000000;
		$display("FAIL atg_su timeout");
		$finish;
	end
endmodule

`default_nettype wire
