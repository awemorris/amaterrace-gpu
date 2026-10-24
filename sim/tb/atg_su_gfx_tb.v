/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_gfx_tb: the shader unit's graphics warps (design §3.1 M10,
 * §3.8), with PACKED and SUBGROUP, on NPHYS 8, 16 and 32 (the NPHYS 16 SU
 * in the KC705's shape: 8 scoreboard entries, FRAG_RESERVE 2).  The
 * testbench is the VF (vl_*), the RX (fl_*, pt_free) and the ROP (ex_*)
 * of one SU; code and data memories as in atg_su_tb.  Two parts:
 *
 *   gfx: sim/tb/su/gfx.s runs as one vertex warp (slot 0) and three
 *     fragment warps (slots 1-3, sequence numbers 1, 0, 2) whose r0-r6 the
 *     testbench writes first (sim/tb/su/gfx.init, the warps in gfx.warps,
 *     both from gen_gfx.py).  Fragment EXEC is whole quads and the mask
 *     operand the coverage, so the program's qd, shfl, vote and ballot see
 *     helper lanes, while sw, atom, sts and exp must skip them and the
 *     killed lanes.  Checked against tools/gsi1model.py --warps: every
 *     register the model wrote (gfx.exp), the data memory (gfx.mexp), the
 *     quads at the ROP in sequence order with their positions, masks,
 *     colours and depths (gfx.xexp; the ROP is held off until every warp
 *     has started, so the slots are 0-3), and the vertex warp's PT entries
 *     read through pt_* (gfx.pexp; the words it must not write still X).
 *     ms: the fragment warps' r6 (the RX's sample mask, some lanes 0) and
 *     two SAMPLE_MASK exports (0x105): the quads' masks and their ex_aux
 *     sample masks and DEPTH lanes on the mask's lanes (gfx.msexp).
 *   loop: the closed loop of design §3.8 with the testbench's VF and RX:
 *     NV vertex warps (gfxv.s: r0 to the PT) with random vl_mask (also 0);
 *     for each, after its pt_done, 1-3 fragment warps (gfxf.s: a loop of
 *     r0 iterations, so they end out of order) of random quads, then the
 *     block's PT entries are freed except the last three of vl_mask, which
 *     wait for the next block's fragment warps (the primitive that
 *     atg_vf_asm holds back).  The ROP takes quads at random.  Checked: it
 *     ends (no progress for 20000 cycles is a deadlock), every vertex
 *     grant leaves more than FRAG_RESERVE slots free and gets a PT block
 *     with no entry in use, the quads come in sequence order with the
 *     coverage as mask and the iteration count in COLOR0 R.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_gfx_chk #(
	parameter NPHYS = 8,
	parameter SEED = 1,
	parameter FRAG_RESERVE = 1,
	parameter SB_ENTRIES = 4,
	parameter SBE_W = 2,
	parameter PT_ENTRIES = 64,
	parameter NV = 12	/* vertex warps of the loop */
) (
	input wire clk,
	input wire go,
	output reg done,
	output reg [31:0] e_gfx,
	output reg [31:0] e_loop,
	output reg [31:0] e_ms
);
	`include "ghci_regs.vh"

	localparam G = 32 / NPHYS;
	localparam GRP_W = G > 1 ? $clog2(G) : 1;
	localparam NREGS = 32;
	localparam VARY = 16;
	localparam NWARPS = 4;
	localparam DATA = 32'h8000;
	localparam DWORDS = 4096;
	localparam [31:0] CODE = 32'h1000, VCODE = 32'h3000, FCODE = 32'h3800;

	reg rst_n = 1'b0;
	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg vl_req = 1'b0, vl_we = 1'b0, vl_go = 1'b0;
	reg [5:0] vl_reg = 0;
	reg [4:0] vl_lane = 0;
	reg [31:0] vl_data = 0, vl_mask = 0;
	wire vl_gnt;
	wire [1:0] vl_slot;
	wire [7:0] vl_ptbase;
	reg fl_req = 1'b0, fl_we = 1'b0, fl_go = 1'b0;
	reg [5:0] fl_reg = 0;
	reg [4:0] fl_lane = 0;
	reg [31:0] fl_data = 0, fl_mask = 0;
	reg [63:0] fl_info = 0;
	wire fl_gnt;
	wire [1:0] fl_slot;
	reg pt_rd = 1'b0, pt_free = 1'b0;
	reg [7:0] pt_idx = 0, pt_free_idx = 0;
	reg [5:0] pt_word = 0;
	wire [31:0] pt_rdata;
	wire [7:0] pt_done;
	reg ex_ready = 1'b0;
	reg [15:0] ex_next = 0;
	wire ex_valid, ex_last;
	wire [15:0] ex_seq;
	wire [31:0] ex_xy;
	wire [3:0] ex_mask;
	wire [511:0] ex_color;
	wire [127:0] ex_depth;
	wire [153:0] ex_aux;
	reg [31:0] msexp [0:32];
	wire i_req_valid, i_req_ready, i_req_write, i_rsp_valid, i_rsp_write, i_rsp_error;
	wire [26:0] i_req_line;
	wire [31:0] i_req_be;
	wire [255:0] i_req_wdata, i_rsp_rdata;
	wire [7:0] i_req_tag, i_rsp_tag;
	wire busy, fault;
	wire [31:0] fault_addr;
	wire d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_write, d_rsp_error;
	wire [26:0] d_req_line;
	wire [31:0] d_req_be;
	wire [255:0] d_req_wdata, d_rsp_rdata;
	wire [7:0] d_req_tag, d_rsp_tag;
	wire at_valid, at_ready, at_rsp_valid, at_error;
	wire [3:0] at_op;
	wire [29:0] at_addr;
	wire [31:0] at_a, at_b, at_old;
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

	atg_su #(.NPHYS(NPHYS), .GRP_W(GRP_W), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W),
		.FRAG_RESERVE(FRAG_RESERVE), .PACKED(1), .SUBGROUP(1), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(1'b0), .lc_kick(1'b0), .inv(4'd0),
		.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_slot(vl_slot), .vl_ptbase(vl_ptbase),
		.vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane), .vl_data(vl_data), .vl_go(vl_go),
		.vl_mask(vl_mask),
		.fl_req(fl_req), .fl_gnt(fl_gnt), .fl_slot(fl_slot), .fl_we(fl_we), .fl_reg(fl_reg),
		.fl_lane(fl_lane), .fl_data(fl_data), .fl_pw_we(1'b0), .fl_pw_addr(12'd0),
		.fl_pw_data(32'd0), .fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
		.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
		.pt_free(pt_free), .pt_free_idx(pt_free_idx), .pt_done(pt_done),
		.tx_valid(), .tx_ready(1'b1), .tx_op(), .tx_slot(), .tx_mask(), .tx_coord(), .tx_off(),
		.tx_tag(), .tx_last(), .tr_valid(1'b0), .tr_ready(), .tr_tag(16'd0),
		.tr_data(512'd0), .tr_last(1'b0),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next), .ex_aux(ex_aux),
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
	reg [32:0] init [0:4*NREGS*32-1];
	reg [32:0] exp [0:4*NREGS*32-1];
	reg [31:0] dat [0:DWORDS-1];
	reg [31:0] mexp [0:DWORDS-1];
	reg [31:0] wv [0:19];
	reg [31:0] xexp [0:22*32];
	reg [32:0] pexp [0:32*(4+VARY)-1];
	integer lane_err [0:NPHYS-1];
	event check;
	integer seed;

	always @(posedge clk)
		if (rst_n && fault) begin
			$display("FAIL atg_su_gfx NPHYS %0d: ISA fault at pc %0d", NPHYS, fault_addr);
			e_gfx = e_gfx + 1;
		end

	/* Per physical lane: the RF copy 1 against the model (hierarchical). */
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
									$display("FAIL atg_su_gfx NPHYS %0d slot %0d r%0d lane %0d: %h want %h",
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

	/* ---- The ROP: takes quads at random (when rop_on), in ex_next order. */
	reg rop_on = 1'b0;
	reg loop_mode = 1'b0;
	integer nq_got, q_err;
	/* The loop's expectations per sequence number: iterations, quads, coverage. */
	reg [7:0] l_iter [0:255];
	reg [3:0] l_nq [0:255];
	reg [31:0] l_cov [0:255];
	integer l_qn;	/* quad of the current warp */
	integer progress;
	integer li;
	always @(negedge clk)
		ex_ready <= rop_on && ($random(seed) & 1);
	always @(posedge clk) begin
		if (rst_n && ex_valid && ex_ready) begin
			progress = 0;
			if (!loop_mode) begin
				if (nq_got >= xexp[0] || ex_seq !== xexp[1 + 22 * nq_got][31:16] ||
				    ex_last !== xexp[1 + 22 * nq_got][8] || ex_mask !== xexp[1 + 22 * nq_got][3:0] ||
				    ex_aux[153:149] !== xexp[1 + 22 * nq_got][14:10] ||
				    ex_xy !== xexp[2 + 22 * nq_got]) begin
					if (q_err < 4)
						$display("FAIL atg_su_gfx NPHYS %0d: quad %0d seq %0d last %b mask %b xy %h, want %h %h",
							NPHYS, nq_got, ex_seq, ex_last, ex_mask, ex_xy,
							xexp[1 + 22 * nq_got], xexp[2 + 22 * nq_got]);
					q_err = q_err + 1;
				end else begin
					if ((ex_aux[15:0] & {{4{ex_mask[3]}}, {4{ex_mask[2]}}, {4{ex_mask[1]}},
					     {4{ex_mask[0]}}}) !== msexp[nq_got][15:0] ||
					    (ex_aux[19:16] & ex_mask) !== msexp[nq_got][19:16]) begin
						if (e_ms < 4)
							$display("FAIL atg_su_gfx.ms NPHYS %0d: quad %0d ex_aux %h mask %b, want %h",
								NPHYS, nq_got, ex_aux[19:0], ex_mask, msexp[nq_got]);
						e_ms = e_ms + 1;
					end
					for (li = 0; li < 4; li = li + 1)
						if (ex_mask[li] && ({ex_depth[32 * li +: 32], ex_color[128 * li +: 128]} !==
						    {xexp[3 + 22 * nq_got + 5 * li + 4], xexp[3 + 22 * nq_got + 5 * li + 3],
						     xexp[3 + 22 * nq_got + 5 * li + 2], xexp[3 + 22 * nq_got + 5 * li + 1],
						     xexp[3 + 22 * nq_got + 5 * li]})) begin
							if (q_err < 4)
								$display("FAIL atg_su_gfx NPHYS %0d: quad %0d lane %0d colour %h depth %h",
									NPHYS, nq_got, li, ex_color[128 * li +: 128],
									ex_depth[32 * li +: 32]);
							q_err = q_err + 1;
						end
				end
			end else begin
				if (ex_seq !== ex_next || ex_mask !== l_cov[ex_next[7:0]][4 * l_qn +: 4] ||
				    ex_last !== (l_qn + 1 == l_nq[ex_next[7:0]])) begin
					if (q_err < 4)
						$display("FAIL atg_su_gfx NPHYS %0d loop: seq %0d (next %0d) quad %0d mask %b last %b",
							NPHYS, ex_seq, ex_next, l_qn, ex_mask, ex_last);
					q_err = q_err + 1;
				end
				for (li = 0; li < 4; li = li + 1)
					if (ex_mask[li] && ex_color[128 * li +: 32] !== {24'd0, l_iter[ex_next[7:0]]}) begin
						if (q_err < 4)
							$display("FAIL atg_su_gfx NPHYS %0d loop: seq %0d lane %0d R %h want %0d",
								NPHYS, ex_seq, li, ex_color[128 * li +: 32],
								l_iter[ex_next[7:0]]);
						q_err = q_err + 1;
					end
				l_qn = l_qn + 1;
			end
			nq_got = nq_got + 1;
			if (ex_last) begin
				ex_next <= ex_next + 16'd1;
				l_qn = 0;
			end
		end
	end

	/* ---- Slot occupancy (granted, not yet released) and the PT blocks in use. */
	integer occ;
	integer blk_use [0:7];
	always @(posedge clk)
		if (rst_n) begin
			if (vl_gnt || fl_gnt)
				progress = 0;
			occ = occ + (vl_gnt ? 1 : 0) + (fl_gnt ? 1 : 0) - (dut.xr_valid ? 1 : 0);
			if (pt_free)
				blk_use[pt_free_idx[7:5]] = blk_use[pt_free_idx[7:5]] - 1;
		end
	always @(posedge clk)
		progress = progress + 1;

	/* ---- Driving the VF and RX ports. */
	task vwrite;	/* one VF register write */
		input [5:0] r;
		input [4:0] l;
		input [31:0] v;
		begin
			@(negedge clk);
			vl_we = 1'b1;
			vl_reg = r;
			vl_lane = l;
			vl_data = v;
			@(negedge clk);
			vl_we = 1'b0;
			if ($random(seed) & 1)
				@(negedge clk);
		end
	endtask

	task fwrite;	/* one RX register write */
		input [5:0] r;
		input [4:0] l;
		input [31:0] v;
		begin
			@(negedge clk);
			fl_we = 1'b1;
			fl_reg = r;
			fl_lane = l;
			fl_data = v;
			@(negedge clk);
			fl_we = 1'b0;
			if ($random(seed) & 1)
				@(negedge clk);
		end
	endtask

	reg [1:0] g_slot;
	reg [7:0] g_base;
	task vgrant;
		begin
			@(negedge clk);
			vl_req = 1'b1;
			#1;
			while (!vl_gnt) begin
				@(negedge clk);
				#1;
			end
			g_slot = vl_slot;
			g_base = vl_ptbase;
			if (loop_mode && NWARPS - occ <= FRAG_RESERVE) begin
				$display("FAIL atg_su_gfx NPHYS %0d loop: vertex grant with %0d slots free",
					NPHYS, NWARPS - occ);
				e_loop = e_loop + 1;
			end
			if (loop_mode && blk_use[vl_ptbase[7:5]] != 0) begin
				$display("FAIL atg_su_gfx NPHYS %0d loop: PT block %0d granted with %0d entries in use",
					NPHYS, vl_ptbase[7:5], blk_use[vl_ptbase[7:5]]);
				e_loop = e_loop + 1;
			end
			@(posedge clk);
			@(negedge clk);
			vl_req = 1'b0;
		end
	endtask

	task vgo;
		input [31:0] m;
		begin
			@(negedge clk);
			vl_go = 1'b1;
			vl_mask = m;
			@(negedge clk);
			vl_go = 1'b0;
		end
	endtask

	task fgrant;
		begin
			@(negedge clk);
			fl_req = 1'b1;
			#1;
			while (!fl_gnt) begin
				@(negedge clk);
				#1;
			end
			g_slot = fl_slot;
			@(posedge clk);
			@(negedge clk);
			fl_req = 1'b0;
		end
	endtask

	task fgo;
		input [31:0] m;
		input [63:0] info;
		begin
			@(negedge clk);
			fl_go = 1'b1;
			fl_mask = m;
			fl_info = info;
			@(negedge clk);
			fl_go = 1'b0;
		end
	endtask

	task load;
		input [31:0] addr;
		integer i;
		begin
			for (i = 0; i < 4096; i = i + 1)
				if (code[i] !== 32'bx)
					mem.poke(addr + 4 * i, code[i]);
		end
	endtask

	/* ---- The loop's RX: the blocks of the vertex warps in order. */
	reg [31:0] lv_mask [0:NV-1];
	reg [7:0] lv_base [0:NV-1];
	integer lv_n;	/* vertex warps started */
	integer f_seq;
	integer v_done;

	task rx_free;	/* frees the entries of mask (lanes from..to) of block base */
		input [31:0] m;
		input [7:0] base;
		input integer from;
		input integer to;
		integer l;
		begin
			for (l = from; l <= to; l = l + 1)
				if (m[l]) begin
					@(negedge clk);
					pt_free = 1'b1;
					pt_free_idx = base + l[7:0];
					@(negedge clk);
					pt_free = 1'b0;
				end
		end
	endtask

	/* The lane above which the last three lanes of m are (-1: fewer). */
	function integer held_from;
		input [31:0] m;
		integer l, c;
		begin
			held_from = 0;
			c = 0;
			for (l = 31; l >= 0; l = l - 1)
				if (m[l] && c < 3) begin
					c = c + 1;
					held_from = l;
				end
		end
	endfunction

	task rx_frag;	/* one fragment warp of random quads with sequence number f_seq */
		integer nq, q, i, n;
		reg [31:0] cov, ex;
		reg [3:0] c;
		begin
			nq = 1 + {$random(seed)} % 8;
			n = 1 + {$random(seed)} % 12;
			cov = 32'd0;
			for (q = 0; q < nq; q = q + 1) begin
				c = $random(seed);
				if (c == 4'd0)
					c = 4'd9;
				cov[4 * q +: 4] = c;
			end
			ex = nq == 8 ? 32'hFFFFFFFF : (32'd1 << (4 * nq)) - 32'd1;
			l_iter[f_seq[7:0]] = n[7:0];
			l_nq[f_seq[7:0]] = nq[3:0];
			l_cov[f_seq[7:0]] = cov;
			fgrant;
			for (i = 0; i < 4 * nq; i = i + 1) begin
				fwrite(6'd0, i[4:0], n);
				fwrite(6'd3, i[4:0], 32'h3F000000);
				if (i % 4 == 0) begin
					fwrite(6'd4, i[4:0], 32'h40200000 + {i[7:2], 17'd0});	/* x + 0.5 */
					fwrite(6'd5, i[4:0], 32'h40200000);
				end
			end
			fgo(ex, {15'd0, 1'b1, f_seq[15:0], cov});
			f_seq = f_seq + 1;
		end
	endtask

	integer i, l, t, s, k, w, merr, perr, hf, hf_prev, nf;
	reg [31:0] v;
	initial begin
		seed = SEED;
		done = 1'b0;
		e_gfx = 0;
		e_loop = 0;
		e_ms = 0;
		nq_got = 0;
		q_err = 0;
		occ = 0;
		l_qn = 0;
		for (i = 0; i < 8; i = i + 1)
			blk_use[i] = 0;
		@(posedge go);

		/* ---- gfx */
		$readmemh("sim/tb/su/gfx.hex", code);
		$readmemh("sim/tb/su/gfx.init", init);
		$readmemh("sim/tb/su/gfx.exp", exp);
		$readmemh("sim/tb/su/gfx.dat", dat);
		$readmemh("sim/tb/su/gfx.mexp", mexp);
		$readmemh("sim/tb/su/gfx.warps", wv);
		$readmemh("sim/tb/su/gfx.xexp", xexp);
		$readmemh("sim/tb/su/gfx.pexp", pexp);
		$readmemh("sim/tb/su/gfx.msexp", msexp);
		load(CODE);
		for (i = 0; i < DWORDS; i = i + 1)
			dmem.poke(DATA + 4 * i, dat[i]);
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		state(GHCI_S_VS_BASE, CODE);
		state(GHCI_S_FS_BASE, CODE);
		/* The vertex warp's slot first (its start waits until the fragment
		 * warps have theirs, so that no slot is released before). */
		vgrant;
		if (g_slot != 2'd0) begin
			$display("FAIL atg_su_gfx NPHYS %0d: vertex slot %0d", NPHYS, g_slot);
			e_gfx = e_gfx + 1;
		end
		for (s = 0; s < 4; s = s + 1) begin
			if (s != 0)
				fgrant;
			if (s != 0 && g_slot != s[1:0]) begin
				$display("FAIL atg_su_gfx NPHYS %0d: fragment slot %0d want %0d", NPHYS, g_slot, s);
				e_gfx = e_gfx + 1;
			end
			for (k = 0; k < 7; k = k + 1)	/* r0-r5, and a fragment warp's r6 */
				for (l = 0; l < 32; l = l + 1)
					if (init[(s * NREGS + k) * 32 + l][32]) begin
						if (s == 0)
							vwrite(k[5:0], l[4:0], init[(s * NREGS + k) * 32 + l][31:0]);
						else
							fwrite(k[5:0], l[4:0], init[(s * NREGS + k) * 32 + l][31:0]);
					end
			if (s != 0)
				fgo(wv[5 * s + 1], {15'd0, wv[5 * s + 4][0], wv[5 * s + 3][15:0], wv[5 * s + 2]});
		end
		vgo(wv[2]);
		rop_on = 1'b1;
		t = 0;
		while ((busy || nq_got < xexp[0]) && t < 400000) begin
			@(negedge clk);
			t = t + 1;
		end
		if (busy || nq_got != xexp[0]) begin
			$display("FAIL atg_su_gfx NPHYS %0d: still busy, %0d of %0d quads", NPHYS, nq_got,
				xexp[0]);
			e_gfx = e_gfx + 1;
		end
		rop_on = 1'b0;
		-> check;
		#1;
		for (l = 0; l < NPHYS; l = l + 1)
			e_gfx = e_gfx + lane_err[l];
		merr = 0;
		for (i = 0; i < DWORDS; i = i + 1)
			if (dmem.peek(DATA + 4 * i) !== mexp[i]) begin
				if (merr < 3)
					$display("FAIL atg_su_gfx NPHYS %0d: memory %h: %h want %h", NPHYS,
						DATA + 4 * i, dmem.peek(DATA + 4 * i), mexp[i]);
				merr = merr + 1;
			end
		/* The vertex warp's PT entries (block 0). */
		perr = 0;
		for (l = 0; l < 32; l = l + 1)
			for (w = 0; w < 4 + VARY; w = w + 1) begin
				@(negedge clk);
				pt_rd = 1'b1;
				pt_idx = l[7:0];
				pt_word = w[5:0];
				@(negedge clk);
				pt_rd = 1'b0;
				/* A word the model did not write must still be unwritten (X: the
				 * PT has no reset and this is its first warp since time 0). */
				if (pexp[l * (4 + VARY) + w][32] ? pt_rdata !== pexp[l * (4 + VARY) + w][31:0] :
				    pt_rdata !== 32'bx) begin
					if (perr < 3)
						$display("FAIL atg_su_gfx NPHYS %0d: PT entry %0d word %0d: %h want %h",
							NPHYS, l, w, pt_rdata, pexp[l * (4 + VARY) + w][31:0]);
					perr = perr + 1;
				end
			end
		e_gfx = e_gfx + merr + perr + q_err;
		$display("atg_su_gfx NPHYS %0d gfx: %0d cycles, %0d quads", NPHYS, t, nq_got);

		/* ---- loop */
		rst_n = 1'b0;
		for (i = 0; i < 4096; i = i + 1)
			code[i] = 32'bx;
		$readmemh("sim/tb/su/gfxv.hex", code);
		load(VCODE);
		for (i = 0; i < 4096; i = i + 1)
			code[i] = 32'bx;
		$readmemh("sim/tb/su/gfxf.hex", code);
		load(FCODE);
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		ex_next = 16'd0;
		nq_got = 0;
		q_err = 0;
		occ = 0;
		l_qn = 0;
		loop_mode = 1'b1;
		lv_n = 0;
		v_done = 0;
		f_seq = 0;
		progress = 0;
		state(GHCI_S_VS_BASE, VCODE);
		state(GHCI_S_FS_BASE, FCODE);
		rop_on = 1'b1;
		fork
			/* The VF. */
			begin : vf
				for (k = 0; k < NV; k = k + 1) begin
					vgrant;
					v = $random(seed);
					if (k % 5 == 3)
						v = 32'd0;	/* no primitive uses the warp */
					lv_base[k] = g_base;
					lv_mask[k] = v;
					for (l = 0; l < 32; l = l + 1)
						if (v[l])
							vwrite(6'd0, l[4:0], {k[15:0], l[15:0]});
					blk_use[g_base[7:5]] = 0;
					for (l = 0; l < 32; l = l + 1)
						if (v[l])
							blk_use[g_base[7:5]] = blk_use[g_base[7:5]] + 1;
					vgo(v);
					lv_n = k + 1;
				end
			end
			/* The RX: per block in order, after pt_done: fragment warps, then the
			 * entries but the last three, which wait for the next block. */
			begin : rx
				hf_prev = 32;
				for (w = 0; w < NV; w = w + 1) begin
					while (lv_n <= w || !pt_done[lv_base[w][7:5]])
						@(negedge clk);
					nf = 1 + w % 3;
					for (i = 0; i < nf; i = i + 1)
						rx_frag;
					if (w > 0)
						rx_free(lv_mask[w - 1], lv_base[w - 1], hf_prev, 31);
					hf = held_from(lv_mask[w]);
					rx_free(lv_mask[w], lv_base[w], 0, hf - 1);
					hf_prev = hf;
				end
				rx_free(lv_mask[NV - 1], lv_base[NV - 1], hf_prev, 31);
				v_done = 1;
			end
			/* Deadlock watch. */
			begin : watch
				while (!(v_done && ex_next == f_seq[15:0] && !busy) && progress < 20000)
					@(negedge clk);
				if (progress >= 20000) begin
					$display("FAIL atg_su_gfx NPHYS %0d loop: deadlock (%0d vertex warps started, %0d fragment warps, ROP at %0d)",
						NPHYS, lv_n, f_seq, ex_next);
					e_loop = e_loop + 1;
					disable vf;
					disable rx;
				end
			end
		join
		rop_on = 1'b0;
		e_loop = e_loop + q_err;
		for (i = 0; i < 8; i = i + 1)
			if (i < PT_ENTRIES / 32 && blk_use[i] != 0) begin
				$display("FAIL atg_su_gfx NPHYS %0d loop: PT block %0d has %0d entries at the end",
					NPHYS, i, blk_use[i]);
				e_loop = e_loop + 1;
			end
		$display("atg_su_gfx NPHYS %0d loop: %0d vertex warps, %0d fragment warps, %0d quads",
			NPHYS, lv_n, f_seq, nq_got);
		done = 1'b1;
	end
endmodule

module atg_su_gfx_tb;
	reg clk = 1'b0;
	reg go = 1'b0;
	wire [2:0] done;
	wire [31:0] g0, g1, g2, l0, l1, l2, m0, m1, m2;

	always #5 clk = !clk;

	atg_su_gfx_chk #(.NPHYS(8), .SEED(1)) n8 (.clk(clk), .go(go), .done(done[0]),
		.e_gfx(g0), .e_loop(l0), .e_ms(m0));
	atg_su_gfx_chk #(.NPHYS(16), .SEED(2), .FRAG_RESERVE(2), .SB_ENTRIES(8), .SBE_W(3)) n16 (
		.clk(clk), .go(go), .done(done[1]), .e_gfx(g1), .e_loop(l1), .e_ms(m1));
	atg_su_gfx_chk #(.NPHYS(32), .SEED(3)) n32 (.clk(clk), .go(go), .done(done[2]),
		.e_gfx(g2), .e_loop(l2), .e_ms(m2));

	initial begin
		#20 go = 1'b1;
		wait (&done);
		if (g0 + g1 + g2 == 0) $display("PASS atg_su_gfx.gfx");
		if (l0 + l1 + l2 == 0) $display("PASS atg_su_gfx.loop");
		if (m0 + m1 + m2 == 0) $display("PASS atg_su_gfx.ms");
		if (g0 + g1 + g2 + l0 + l1 + l2 + m0 + m1 + m2 == 0)
			$display("PASS atg_su_gfx");
		$finish;
	end

	initial begin
		#100000000;
		$display("FAIL atg_su_gfx timeout");
		$finish;
	end
endmodule

`default_nettype wire
