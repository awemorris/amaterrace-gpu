/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_seq: the class N µop sequencer (design §2.4.3): takes µop
 * packets from the ring or from the firmware (UOP_FIFO), writes STATE,
 * kicks the blocks, waits for idle, and hands fences, results and
 * WAIT_FENCE to atg_cp_fence.
 *
 * Source: fw_* while fw_active (sampled between packets), else n_*.
 * Header [31:30] class (0 standard, 1 vendor), [29:24] op, [23:16] tag,
 * [15:8] flags, [7:0] n.  The payload is taken one dword per cycle:
 * SET_REG writes STATE[index] = value per pair (index >= 0x300: fault 3;
 * a write to a block's range waits while it is busy, whose state must not
 * change under its work: atg_cp_seq_wait has the rules),
 * DISPATCH/LOAD_CONST/DRAW_RAW/DBG_MARK write their payload to the vendor
 * STATE words (DISPATCH and LOAD_CONST wait while the SUs are busy,
 * DRAW_RAW while the RX is), the fence µops keep theirs.  The µop runs:
 *   BLIT: wait for the BLT idle, kick; flags[0]: wait until it is done.
 *   DRAW: wait for the VF idle, inv[1:0] and draw_kick.  DISPATCH: cs_kick.
 *   FENCE: wait until every block is idle, request op 0 (flags[0] = IRQ).
 *   WAIT_IDLE: wait until the blocks of flags (0 = all) are idle.
 *   LOAD_CONST: SUs idle, lc_kick, SUs idle.  LOAD_PROGRAM: inv[3].
 *   WAIT_FENCE: request op 2, wait for !f_busy.  PERF_RESET.  WAIT_VSYNC:
 *   one vsync.  INVALIDATE: inv = flags[3:0].  RESULT: blocks idle and
 *   !f_busy, request op 1.  QUERY (CAPS[30]): as RESULT with the occlusion
 *   counter (occ_count, low word, then the high bits) at addr; flags[0]:
 *   no wait and no write, only occ_clear; flags[1]: occ_clear with the
 *   write's request.  DRAW_RAW: raw_kick.  NOP, SET_REG, DBG_MARK: none.
 *   DISP_SET (HAS_DISP): its pairs write the DISP2 registers through
 *   0x3C0 + offset / 4 (atg_cp_disp); flags[0]: kick K_DISP_IDLE, then
 *   wait for busy bit 8.  FLIP: payload to 0x3B8-0x3BB, waits for busy
 *   bit 8 (the plane; flags[0] also every unit), kick K_FLIP.
 * Kicks are one pulse (kick) with a code (kick_code, K_*): BLIT, DRAW,
 * DISPATCH, LOAD_CONST, DRAW_RAW, PERF_RESET, FLIP, DISP_SET's idle wait.
 * A wait after a kick starts one cycle later (busy rises after the kick).
 * Faults stop the sequencer until the core reset (rst_n): kind 2 for an
 * unknown op, a class 2/3 header, or an op whose unit is absent (UNITS,
 * HAS_VSYNC, HAS_DISP; DISP_SET and FLIP from the firmware); kind 3 for a
 * payload shorter than the op needs, a bad SET_REG index or DISP_SET
 * offset (fault_addr = the dword).  A longer payload is skipped.  The
 * header and payload decoders are atg_cp_seq_dec's.
 * halt is looked at only between packets.  cmd_active (the watchdog) is 1
 * from a header to the end of its µop, except while waiting for the
 * firmware's next dword.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_seq #(
	parameter [7:0] UNITS = 8'h03,	/* Present blocks, STATUS busy-bit order */
	parameter HAS_VSYNC = 0,	/* 1: a display's vsync reaches the CP (WAIT_VSYNC) */
	parameter HAS_DISP = 0	/* 1: a DISP2 controller (DISP_SET, FLIP; atg_cp_disp) */
) (
	input wire clk,
	input wire rst_n,
	/* µop packets from the ring (atg_cp_ring) */
	input wire n_valid,
	output wire n_ready,
	input wire [31:0] n_data,
	/* µop packets from the firmware (atg_cpu UOP_FIFO) */
	input wire fw_valid,
	output wire fw_ready,
	input wire [31:0] fw_data,
	input wire fw_active,
	input wire [6:0] fw_side,	/* session protection: the firmware µop's {SELF, slot} */
	input wire halt,
	/* STATE writes (to atg_cp_state) */
	output wire uop_we,
	output wire [9:0] uop_idx,
	output wire [31:0] uop_wdata,
	/* Kicks: a one-cycle pulse with its code (K_*) */
	output wire kick,
	output wire [2:0] kick_code,
	output wire [3:0] inv,
	input wire [8:0] busy_in,	/* [8]: atg_cp_disp's wait (not in B_ALL) */
	input wire vsync,
	/* Fences (to atg_cp_fence) */
	output wire f_valid,
	input wire f_ready,
	output wire [1:0] f_op,
	output wire [63:0] f_addr,
	output wire [31:0] f_value,
	output wire [31:0] f_aux,
	output wire f_irq,
	input wire f_busy,
	/* The occlusion counter (atg_rop_occ, QUERY) */
	input wire [39:0] occ_count,
	output wire occ_clear,
	/* Status */
	output wire busy,
	output wire cmd_active,
	/* Fault report to atg_cp_ctl (one source of its `src_*` vectors) */
	output wire fault,
	output wire [3:0] fault_kind,
	output wire [31:0] fault_addr,
	output wire [7:0] fault_tag,
	/* Session protection (atg_cp_prot): the µop's source and side, its unit kick */
	output wire u_fw,
	output wire [6:0] u_side,
	output wire [1:0] u_req,	/* [0] it starts a unit, [1] it uses the shader units */
	input wire u_ok		/* the units run for its slot: it may start them */
);
	`include "ghci_regs.vh"

	/* Standard µops (class 0) and Amaterrace's vendor µops (class 1); the header's
	 * rules are atg_cp_seq_dec's. */
	localparam [7:0] OP_SET_REG = 8'd1;
	localparam [7:0] OP_BLIT = 8'd2;
	localparam [7:0] OP_DRAW = 8'd3;
	localparam [7:0] OP_DISPATCH = 8'd4;
	localparam [7:0] OP_FENCE = 8'd5;
	localparam [7:0] OP_LOAD_CONST = 8'd7;
	localparam [7:0] OP_LOAD_PROGRAM = 8'd8;
	localparam [7:0] OP_WAIT_FENCE = 8'd9;
	localparam [7:0] OP_PERF_RESET = 8'd10;
	localparam [7:0] OP_WAIT_VSYNC = 8'd11;
	localparam [7:0] OP_INVALIDATE = 8'd12;
	localparam [7:0] OP_RESULT = 8'd13;
	localparam [7:0] OP_QUERY = 8'd14;
	localparam [7:0] OP_DISP_SET = 8'd15;
	localparam [7:0] OP_FLIP = 8'd16;

	/* GHCI 1.0 Structured Command Opcodes */
	/* verilator lint_off UNUSEDPARAM */
	localparam [7:0] CMD_BIND_PIPELINE         = 8'h20;
	localparam [7:0] CMD_BIND_VERTEX_BUFFERS   = 8'h21;
	localparam [7:0] CMD_BIND_INDEX_BUFFER     = 8'h22;
	localparam [7:0] CMD_BIND_DESCRIPTOR_TABLE = 8'h23;
	localparam [7:0] CMD_SET_VIEWPORT          = 8'h24;
	localparam [7:0] CMD_SET_SCISSOR           = 8'h25;
	localparam [7:0] CMD_SET_DYNAMIC_STATE     = 8'h26;
	localparam [7:0] CMD_DRAW                  = 8'h27;
	localparam [7:0] CMD_DRAW_INDEXED          = 8'h28;
	localparam [7:0] CMD_DRAW_INDIRECT         = 8'h29;
	localparam [7:0] CMD_DRAW_MESH_TASKS       = 8'h2a;
	localparam [7:0] CMD_DISPATCH              = 8'h30;
	localparam [7:0] CMD_BARRIER               = 8'h31;
	localparam [7:0] CMD_EXECUTE_COMMANDS      = 8'h32;
	localparam [7:0] CMD_FENCE                 = 8'h33;
	/* verilator lint_on UNUSEDPARAM */

	localparam [7:0] VOP_DRAW_RAW = 8'd0;

	localparam [2:0] K_BLT = 3'd0;
	localparam [2:0] K_DRAW = 3'd1;
	localparam [2:0] K_CS = 3'd2;
	localparam [2:0] K_LC = 3'd3;
	localparam [2:0] K_RAW = 3'd4;
	localparam [2:0] K_PERF = 3'd5;
	localparam [2:0] K_FLIP = 3'd6;
	localparam [2:0] K_DISP_IDLE = 3'd7;

	localparam [3:0] Q_IDLE = 4'd0;
	localparam [3:0] Q_PAY = 4'd1;	/* take the payload */
	localparam [3:0] Q_EXEC = 4'd2;	/* wait for pre, then act */
	localparam [3:0] Q_POST = 4'd3;	/* after a kick: wait for post */
	localparam [3:0] Q_FREQ = 4'd4;	/* fence request */
	localparam [3:0] Q_FWAIT = 4'd5;	/* WAIT_FENCE: wait for !f_busy */
	localparam [3:0] Q_VSYNC = 4'd6;
	localparam [3:0] Q_DEAD = 4'd7;
	localparam [3:0] Q_DEC = 4'd8;
	localparam [3:0] Q_DEC2 = 4'd9;

	(* max_fanout = 16 *) reg [3:0] st;
	(* max_fanout = 16 *) reg use_fw;
	reg [31:0] hdr_r;
	(* max_fanout = 16 *) reg is_ghci_hdr_r;
	(* max_fanout = 16 *) reg [7:0] ghci_n_r;
	reg dec_fault_r, dec_short_r;
	(* max_fanout = 16 *) reg h_zero_r;
	(* max_fanout = 16 *) reg is_query_r;
	(* max_fanout = 16 *) reg vendor;
	(* max_fanout = 16 *) reg [7:0] op;
	(* max_fanout = 16 *) reg [7:0] flags;
	reg [7:0] tag;
	(* max_fanout = 16 *) reg [6:0] side;
	(* max_fanout = 16 *) reg [7:0] n;
	(* max_fanout = 16 *) reg [7:0] p;	/* payload dwords taken */
	wire [7:0] p_n;	/* p + 1 */
	wire p_co;

	am_add #(.W(8)) p_add (.a(p), .b(8'd0), .ci(1'b1), .s(p_n), .co(p_co));
	reg [9:0] sidx;	/* SET_REG: the index of the pair */
	reg [31:0] a0, a0_hi, a1, a2;	/* fence payload */
	reg [39:0] occ_q;
	reg settle;

	wire in_valid = use_fw ? fw_valid : n_valid;
	wire [31:0] in_data = use_fw ? fw_data : n_data;
	wire [31:0] hdr = fw_active ? fw_data : n_data;
	wire hdr_valid = fw_active ? fw_valid : n_valid;

	/* Header and payload decode (combinational). */
	wire is_ghci_hdr_comb = (
		(hdr[7:0] >= 8'h10 && hdr[7:0] <= 8'h14) ||
		(hdr[7:0] >= 8'h20 && hdr[7:0] <= 8'h37) ||
		(hdr[7:0] >= 8'h40 && hdr[7:0] <= 8'h46) ||
		(hdr[7:0] >= 8'h50 && hdr[7:0] <= 8'h51)
	) && (hdr[15:8] >= 8'd1);
	wire [7:0] ghci_n_comb;
	wire ghci_sub_bo;
	am_sub #(.W(8)) sub_ghci_n (
		.a(hdr[15:8]), .b(8'd1), .bi(1'b0), .d(ghci_n_comb), .bo(ghci_sub_bo)
	);

	wire is_ghci_hdr = (st == Q_DEC) ? is_ghci_hdr_r : is_ghci_hdr_comb;
	wire h_vendor = is_ghci_hdr_r ? 1'b0 : hdr_r[30];
	wire [7:0] h_op = is_ghci_hdr_r ? hdr_r[7:0] : {2'b00, hdr_r[29:24]};
	wire [7:0] h_n = is_ghci_hdr_r ? ghci_n_r : hdr_r[7:0];

	wire dec_hdr_fault, dec_hdr_short, h_zero, pay_bad;
	atg_cp_seq_dec #(.UNITS(UNITS), .HAS_VSYNC(HAS_VSYNC), .HAS_DISP(HAS_DISP)) dec (
		.hdr(hdr_r), .hdr_fw(use_fw), .h_known(), .h_absent(),
		.h_need(), .h_short(), .h_zero(h_zero),
		.hdr_fault(dec_hdr_fault), .hdr_short(dec_hdr_short),
		.vendor(vendor), .op(op), .p(p), .in_data(in_data),
		.pay_bad(pay_bad)
	);

	reg is_set_r, is_dset_r, is_fence_cmd_r;

	/* Payload: what this dword does; the waits (atg_cp_seq_wait). */
	wire is_set = !vendor && op == OP_SET_REG;
	wire is_dset = !vendor && op == OP_DISP_SET;
	wire set_val = (is_set || is_dset) && p[0];
	wire set_bad = pay_bad;
	wire pay_we;
	wire [9:0] pay_idx;
	wire [8:0] pay_wait;	/* busy bits that hold this dword */
	wire [8:0] pre;
	wire pre_f;		/* also wait for !f_busy */
	wire [8:0] post;

	atg_cp_seq_wait wt (
		.vendor(vendor),
		.op(op),
		.flags(flags),
		.p(p),
		.set_val(set_val),
		.sidx(sidx),
		.pay_we(pay_we),
		.pay_idx(pay_idx),
		.pay_wait(pay_wait),
		.pre(pre),
		.pre_f(pre_f),
		.post(post)
	);

	wire pay_hold = |(pay_wait & busy_in);
	wire pay_take = (st == Q_PAY) && in_valid && !pay_hold;
	wire hdr_take = (st == Q_IDLE) && !halt && hdr_valid;

	assign n_ready = !halt && ((st == Q_IDLE && !fw_active) || (st == Q_PAY && !use_fw && !pay_hold));
	assign fw_ready = !halt && ((st == Q_IDLE && fw_active) || (st == Q_PAY && use_fw && !pay_hold));

`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg uop_we_r;
	(* max_fanout = 16 *) reg [9:0] uop_idx_r;
	(* max_fanout = 16 *) reg [31:0] uop_wdata_r;
	(* keep = "true" *) wire rst_high = ~rst_n;
	always @(posedge clk) begin
		if (rst_high) begin
			uop_we_r <= 1'b0;
			uop_idx_r <= 10'd0;
			uop_wdata_r <= 32'd0;
		end else begin
			uop_we_r <= pay_take && pay_we && !set_bad;
			uop_idx_r <= pay_idx;
			uop_wdata_r <= in_data;
		end
	end
	assign uop_we = uop_we_r;
	assign uop_idx = uop_idx_r;
	assign uop_wdata = uop_wdata_r;
`else
	assign uop_we = pay_take && pay_we && !set_bad;
	assign uop_idx = pay_idx;
	assign uop_wdata = in_data;
`endif

	/* A µop that starts a unit: BLIT, DRAW, DISPATCH, LOAD_CONST and class 1. */
	wire unit_op = vendor || op == OP_BLIT || op == OP_DRAW || op == OP_DISPATCH ||
		op == OP_LOAD_CONST || op == CMD_DRAW || op == CMD_DRAW_INDEXED ||
		op == CMD_DRAW_INDIRECT || op == CMD_DRAW_MESH_TASKS || op == CMD_DISPATCH;
	assign u_req = {st == Q_EXEC && unit_op && (vendor || op != OP_BLIT), st == Q_EXEC && unit_op};
	assign u_fw = use_fw;
	assign u_side = side;

	wire exec_go = st == Q_EXEC && !settle && !(|(pre & busy_in)) && !(pre_f && f_busy) &&
		(u_ok || !unit_op);
	wire is_op_std = !vendor && exec_go;

	reg k_on;
	reg [2:0] k_code;

	always @(*) begin
		k_on = is_op_std;
		k_code = K_BLT;
		if (vendor)
			{k_on, k_code} = {exec_go && op == VOP_DRAW_RAW, K_RAW};
		else case (op)
		OP_BLIT: k_code = K_BLT;
		OP_DRAW, CMD_DRAW, CMD_DRAW_INDEXED, CMD_DRAW_INDIRECT: k_code = K_DRAW;
		OP_DISPATCH, CMD_DISPATCH, CMD_DRAW_MESH_TASKS: k_code = K_CS;
		OP_LOAD_CONST: k_code = K_LC;
		OP_PERF_RESET: k_code = K_PERF;
		OP_FLIP: k_code = K_FLIP;
		OP_DISP_SET: {k_on, k_code} = {is_op_std && flags[0], K_DISP_IDLE};
		default: k_on = 1'b0;
		endcase
	end

	assign kick = k_on;
	assign kick_code = k_code;
	assign inv = !is_op_std ? 4'd0 : (op == OP_DRAW || op == CMD_DRAW || op == CMD_DRAW_INDEXED || op == CMD_DRAW_INDIRECT || op == CMD_DRAW_MESH_TASKS) ? 4'b0011 :
		op == OP_LOAD_PROGRAM ? 4'b1000 : op == OP_INVALIDATE ? flags[3:0] : 4'd0;

	wire is_query = !vendor && op == OP_QUERY;
	wire fence_op = !vendor && (op == OP_FENCE || op == OP_WAIT_FENCE || op == OP_RESULT ||
		(op == OP_QUERY && !flags[0]) || op == CMD_FENCE);
	assign occ_clear = (is_op_std && op == OP_QUERY && flags[0]) ||
		(st == Q_FREQ && f_ready && is_query && flags[1]);
	assign f_valid = st == Q_FREQ;
	assign f_op = (op == OP_FENCE || op == CMD_FENCE) ? 2'd0 : op == OP_RESULT || op == OP_QUERY ? 2'd1 : 2'd2;
	assign f_addr = (op == CMD_FENCE) ? {a0_hi, a0} : {32'd0, a0};
	assign f_value = (op == OP_QUERY) ? occ_q[31:0] : a1;
	assign f_aux = (op == OP_QUERY) ? {24'd0, occ_q[39:32]} : a2;
	assign f_irq = flags[0];

	reg f_pulse;
	reg [3:0] f_kind;
	reg [31:0] f_faddr;

`ifdef SYNTH_KINTEX7
	wire sidx_we_raw = (st == Q_PAY) && pay_take && (is_set_r || is_dset_r) && !p[0];
	wire [1:0] sidx_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_swe0 (.I0(sidx_we_raw), .O(sidx_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_swe1 (.I0(sidx_we_raw), .O(sidx_we_b[1]));

	wire f_fa_we_raw = (st == Q_PAY) && pay_take;
	wire [1:0] f_fa_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fawe0 (.I0(f_fa_we_raw), .O(f_fa_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fawe1 (.I0(f_fa_we_raw), .O(f_fa_we_b[1]));

	wire a0_we_raw = (st == Q_PAY) && pay_take && (p == 8'd0);
	wire [1:0] a0_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_a0we0 (.I0(a0_we_raw), .O(a0_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_a0we1 (.I0(a0_we_raw), .O(a0_we_b[1]));

	wire a1_we_raw = (st == Q_PAY) && in_valid && ((is_fence_cmd_r && p == 8'd2) || (!is_fence_cmd_r && p == 8'd1));
	wire [1:0] a1_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_a1we0 (.I0(a1_we_raw), .O(a1_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_a1we1 (.I0(a1_we_raw), .O(a1_we_b[1]));

	wire a2_we_raw = (st == Q_PAY) && in_valid && ((is_fence_cmd_r && p == 8'd3) || (!is_fence_cmd_r && p == 8'd2));
	wire [1:0] a2_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_a2we0 (.I0(a2_we_raw), .O(a2_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_a2we1 (.I0(a2_we_raw), .O(a2_we_b[1]));

	wire occ_we_raw = (st == Q_EXEC) && is_query_r;
	wire [1:0] occ_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_occwe0 (.I0(occ_we_raw), .O(occ_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_occwe1 (.I0(occ_we_raw), .O(occ_we_b[1]));
`endif

	assign fault = f_pulse;
	assign fault_kind = f_kind;
	assign fault_addr = f_faddr;
	assign fault_tag = tag;
	assign busy = st != Q_IDLE && st != Q_DEAD;
	assign cmd_active = busy && !(st == Q_PAY && use_fw && !fw_valid);

	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (rst_high) begin
`else
		if (!rst_n) begin
`endif
			st <= Q_IDLE;
			use_fw <= 1'b0;
			hdr_r <= 32'd0;
			is_ghci_hdr_r <= 1'b0;
			ghci_n_r <= 8'd0;
			is_set_r <= 1'b0;
			is_dset_r <= 1'b0;
			is_fence_cmd_r <= 1'b0;
			vendor <= 1'b0;
			op <= 8'd0;
			flags <= 8'd0;
			tag <= 8'd0;
			side <= 7'd0;
			n <= 8'd0;
			p <= 8'd0;
			sidx <= 10'd0;
			a0 <= 32'd0;
			a0_hi <= 32'd0;
			a1 <= 32'd0;
			a2 <= 32'd0;
			settle <= 1'b0;
			f_pulse <= 1'b0;
			f_kind <= 4'd0;
			f_faddr <= 32'd0;
			dec_fault_r <= 1'b0;
			dec_short_r <= 1'b0;
			h_zero_r <= 1'b0;
			is_query_r <= 1'b0;
			occ_q <= 40'd0;
		end else begin
			f_pulse <= 1'b0;
			settle <= 1'b0;
			case (st)
			Q_IDLE:
				if (hdr_take) begin
					use_fw <= fw_active;
					side <= fw_active ? fw_side : 7'd0;
					hdr_r <= hdr;
					is_ghci_hdr_r <= is_ghci_hdr_comb;
					ghci_n_r <= ghci_n_comb;
					st <= Q_DEC;
				end
			Q_DEC: begin
				vendor <= h_vendor;
				op <= h_op;
				is_set_r <= !h_vendor && (h_op == OP_SET_REG);
				is_dset_r <= !h_vendor && (h_op == OP_DISP_SET);
				is_fence_cmd_r <= (h_op == CMD_FENCE);
				is_query_r <= !h_vendor && (h_op == OP_QUERY);
				flags <= is_ghci_hdr ? hdr_r[31:24] : hdr_r[15:8];
				tag <= hdr_r[23:16];
				n <= h_n;
				p <= 8'd0;
`ifndef SYNTH_KINTEX7
				f_faddr <= 32'd0;
`endif
				dec_fault_r <= dec_hdr_fault;
				dec_short_r <= dec_hdr_short;
				h_zero_r <= h_zero;
				st <= Q_DEC2;
			end
			Q_DEC2: begin
				if (dec_fault_r) begin
					f_pulse <= 1'b1;
					f_kind <= dec_short_r ? GHCI_FAULT_RING : GHCI_FAULT_OPCODE;
					st <= Q_DEAD;
				end else begin
					st <= h_zero_r ? Q_EXEC : Q_PAY;
				end
			end
			Q_PAY:
				if (pay_take && set_bad) begin
					f_pulse <= 1'b1;
					f_kind <= GHCI_FAULT_RING;
`ifdef SYNTH_KINTEX7
					if (f_fa_we_b[0]) f_faddr[15:0] <= in_data[15:0];
					if (f_fa_we_b[1]) f_faddr[31:16] <= in_data[31:16];
`else
					f_faddr <= in_data;
`endif
					st <= Q_DEAD;
				end else if (pay_take) begin
`ifdef SYNTH_KINTEX7
					if (sidx_we_b[0]) sidx[4:0] <= (is_dset_r ? {4'b1111, in_data[2]} : in_data[4:0]);
					if (sidx_we_b[1]) sidx[9:5] <= (is_dset_r ? in_data[7:3] : in_data[9:5]);
					if (f_fa_we_b[0]) f_faddr[15:0] <= in_data[15:0];
					if (f_fa_we_b[1]) f_faddr[31:16] <= in_data[31:16];
					if (a0_we_b[0]) a0[15:0] <= in_data[15:0];
					if (a0_we_b[1]) a0[31:16] <= in_data[31:16];
					if (is_fence_cmd_r && p == 8'd1)
						a0_hi <= in_data;
					if (a1_we_b[0]) a1[15:0] <= in_data[15:0];
					if (a1_we_b[1]) a1[31:16] <= in_data[31:16];
					if (a2_we_b[0]) a2[15:0] <= in_data[15:0];
					if (a2_we_b[1]) a2[31:16] <= in_data[31:16];
`else
					if (is_set && !p[0])
						sidx <= in_data[9:0];
					if (is_dset && !p[0])
						sidx <= {4'b1111, in_data[7:2]};	/* 0x3C0 + offset / 4 */
					if (p == 8'd0)
						a0 <= in_data;
					if (op == CMD_FENCE && p == 8'd1)
						a0_hi <= in_data;
					if ((op == CMD_FENCE && p == 8'd2) || (op != CMD_FENCE && p == 8'd1))
						a1 <= in_data;
					if ((op == CMD_FENCE && p == 8'd3) || (op != CMD_FENCE && p == 8'd2))
						a2 <= in_data;
`endif
					p <= p_n;
					/* The last payload word reaches the blocks a cycle later
					 * (atg_cp registers the STATE broadcast), so the kick
					 * waits a cycle (settle). */
					if (p_n == n) begin
						st <= Q_EXEC;
						settle <= 1'b1;
					end
				end
			Q_EXEC:
				if (exec_go) begin
					if (fence_op)
						st <= Q_FREQ;
					else if (!vendor && op == OP_WAIT_VSYNC)
						st <= Q_VSYNC;
					else if (post != 9'd0) begin
						settle <= 1'b1;
						st <= Q_POST;
					end else
						st <= Q_IDLE;
				end
			Q_POST:
				if (!settle && !(|(post & busy_in)))
					st <= Q_IDLE;
			Q_FREQ:
				if (f_ready)
					st <= op == OP_WAIT_FENCE ? Q_FWAIT : Q_IDLE;
			Q_FWAIT:
				if (!f_busy)
					st <= Q_IDLE;
			Q_VSYNC:
				if (vsync)
					st <= Q_IDLE;
			default:
				;
			endcase

`ifdef SYNTH_KINTEX7
			if (occ_we_b[0]) occ_q[19:0] <= occ_count[19:0];
			if (occ_we_b[1]) occ_q[39:20] <= occ_count[39:20];
`else
			if (st == Q_EXEC && exec_go && is_query)
				occ_q <= occ_count;
`endif
		end
	end

	wire unused_p = &{1'b0, p_co, ghci_sub_bo};
endmodule

`default_nettype wire
