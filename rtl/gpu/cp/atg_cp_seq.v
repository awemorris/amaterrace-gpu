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
	output wire [31:0] f_addr,
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
	localparam [5:0] OP_SET_REG = 6'd1;
	localparam [5:0] OP_BLIT = 6'd2;
	localparam [5:0] OP_DRAW = 6'd3;
	localparam [5:0] OP_DISPATCH = 6'd4;
	localparam [5:0] OP_FENCE = 6'd5;
	localparam [5:0] OP_LOAD_CONST = 6'd7;
	localparam [5:0] OP_LOAD_PROGRAM = 6'd8;
	localparam [5:0] OP_WAIT_FENCE = 6'd9;
	localparam [5:0] OP_PERF_RESET = 6'd10;
	localparam [5:0] OP_WAIT_VSYNC = 6'd11;
	localparam [5:0] OP_INVALIDATE = 6'd12;
	localparam [5:0] OP_RESULT = 6'd13;
	localparam [5:0] OP_QUERY = 6'd14;
	localparam [5:0] OP_DISP_SET = 6'd15;
	localparam [5:0] OP_FLIP = 6'd16;
	localparam [5:0] VOP_DRAW_RAW = 6'd0;

	localparam [2:0] K_BLT = 3'd0;
	localparam [2:0] K_DRAW = 3'd1;
	localparam [2:0] K_CS = 3'd2;
	localparam [2:0] K_LC = 3'd3;
	localparam [2:0] K_RAW = 3'd4;
	localparam [2:0] K_PERF = 3'd5;
	localparam [2:0] K_FLIP = 3'd6;
	localparam [2:0] K_DISP_IDLE = 3'd7;

	localparam [2:0] Q_IDLE = 3'd0;
	localparam [2:0] Q_PAY = 3'd1;	/* take the payload */
	localparam [2:0] Q_EXEC = 3'd2;	/* wait for pre, then act */
	localparam [2:0] Q_POST = 3'd3;	/* after a kick: wait for post */
	localparam [2:0] Q_FREQ = 3'd4;	/* fence request */
	localparam [2:0] Q_FWAIT = 3'd5;	/* WAIT_FENCE: wait for !f_busy */
	localparam [2:0] Q_VSYNC = 3'd6;
	localparam [2:0] Q_DEAD = 3'd7;

	reg [2:0] st;
	reg use_fw;
	reg vendor;
	reg [5:0] op;
	reg [7:0] flags;
	reg [7:0] tag;
	reg [6:0] side;
	reg [7:0] n;
	reg [7:0] p;	/* payload dwords taken */
	wire [7:0] p_n;	/* p + 1 */
	wire p_co;

	am_add #(.W(8)) p_add (.a(p), .b(8'd0), .ci(1'b1), .s(p_n), .co(p_co));
	reg [9:0] sidx;	/* SET_REG: the index of the pair */
	reg [31:0] a0, a1, a2;	/* fence payload */
	reg settle;

	wire in_valid = use_fw ? fw_valid : n_valid;
	wire [31:0] in_data = use_fw ? fw_data : n_data;
	wire [31:0] hdr = fw_active ? fw_data : n_data;
	wire hdr_valid = fw_active ? fw_valid : n_valid;

	/* Header and payload decode (combinational). */
	wire h_vendor = hdr[30];
	wire [5:0] h_op = hdr[29:24];
	wire [7:0] h_n = hdr[7:0];
	wire h_known, h_absent, pay_bad;
	wire [7:0] h_need;

	atg_cp_seq_dec #(.UNITS(UNITS), .HAS_VSYNC(HAS_VSYNC), .HAS_DISP(HAS_DISP)) dec (
		.hdr(hdr), .hdr_fw(fw_active), .h_known(h_known), .h_absent(h_absent),
		.h_need(h_need), .vendor(vendor), .op(op), .p(p), .in_data(in_data),
		.pay_bad(pay_bad)
	);

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
	wire pay_take = st == Q_PAY && in_valid && !pay_hold && !set_bad;
	wire hdr_take = st == Q_IDLE && !halt && hdr_valid;

	assign n_ready = (hdr_take && !fw_active) || (pay_take && !use_fw);
	assign fw_ready = (hdr_take && fw_active) || (pay_take && use_fw);
	assign uop_we = pay_take && pay_we;
	assign uop_idx = pay_idx;
	assign uop_wdata = in_data;

	/* A µop that starts a unit: BLIT, DRAW, DISPATCH, LOAD_CONST and class 1. */
	wire unit_op = vendor || op == OP_BLIT || op == OP_DRAW || op == OP_DISPATCH ||
		op == OP_LOAD_CONST;
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
		OP_DRAW: k_code = K_DRAW;
		OP_DISPATCH: k_code = K_CS;
		OP_LOAD_CONST: k_code = K_LC;
		OP_PERF_RESET: k_code = K_PERF;
		OP_FLIP: k_code = K_FLIP;
		OP_DISP_SET: {k_on, k_code} = {is_op_std && flags[0], K_DISP_IDLE};
		default: k_on = 1'b0;
		endcase
	end

	assign kick = k_on;
	assign kick_code = k_code;
	assign inv = !is_op_std ? 4'd0 : op == OP_DRAW ? 4'b0011 :
		op == OP_LOAD_PROGRAM ? 4'b1000 : op == OP_INVALIDATE ? flags[3:0] : 4'd0;

	wire is_query = !vendor && op == OP_QUERY;
	wire fence_op = !vendor && (op == OP_FENCE || op == OP_WAIT_FENCE || op == OP_RESULT ||
		(op == OP_QUERY && !flags[0]));
	assign occ_clear = (is_op_std && op == OP_QUERY && flags[0]) ||
		(st == Q_FREQ && f_ready && is_query && flags[1]);
	assign f_valid = st == Q_FREQ;
	assign f_op = op == OP_FENCE ? 2'd0 : op == OP_RESULT || op == OP_QUERY ? 2'd1 : 2'd2;
	assign f_addr = a0;
	assign f_value = a1;
	assign f_aux = a2;
	assign f_irq = flags[0];

	reg f_pulse;
	reg [3:0] f_kind;
	reg [31:0] f_faddr;

	assign fault = f_pulse;
	assign fault_kind = f_kind;
	assign fault_addr = f_faddr;
	assign fault_tag = tag;
	assign busy = st != Q_IDLE && st != Q_DEAD;
	assign cmd_active = busy && !(st == Q_PAY && use_fw && !fw_valid);

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= Q_IDLE;
			use_fw <= 1'b0;
			vendor <= 1'b0;
			op <= 6'd0;
			flags <= 8'd0;
			tag <= 8'd0;
			side <= 7'd0;
			n <= 8'd0;
			p <= 8'd0;
			sidx <= 10'd0;
			a0 <= 32'd0;
			a1 <= 32'd0;
			a2 <= 32'd0;
			settle <= 1'b0;
			f_pulse <= 1'b0;
			f_kind <= 4'd0;
			f_faddr <= 32'd0;
		end else begin
			f_pulse <= 1'b0;
			settle <= 1'b0;
			case (st)
			Q_IDLE:
				if (hdr_take) begin
					use_fw <= fw_active;
					vendor <= h_vendor;
					op <= h_op;
					flags <= hdr[15:8];
					tag <= hdr[23:16];
					side <= fw_active ? fw_side : 7'd0;
					n <= h_n;
					p <= 8'd0;
					f_faddr <= 32'd0;
					if (!h_known || h_absent) begin
						f_pulse <= 1'b1;
						f_kind <= GHCI_FAULT_OPCODE;
						st <= Q_DEAD;
					end else if (h_n < h_need) begin
						f_pulse <= 1'b1;
						f_kind <= GHCI_FAULT_RING;
						st <= Q_DEAD;
					end else begin
						st <= h_n == 8'd0 ? Q_EXEC : Q_PAY;
					end
				end
			Q_PAY:
				if (st == Q_PAY && in_valid && set_bad) begin
					f_pulse <= 1'b1;
					f_kind <= GHCI_FAULT_RING;
					f_faddr <= in_data;
					st <= Q_DEAD;
				end else if (pay_take) begin
					if (is_set && !p[0])
						sidx <= in_data[9:0];
					if (is_dset && !p[0])
						sidx <= {4'b1111, in_data[7:2]};	/* 0x3C0 + offset / 4 */
					if (p == 8'd0)
						a0 <= in_data;
					if (p == 8'd1)
						a1 <= in_data;
					if (p == 8'd2)
						a2 <= in_data;
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
					if (is_query) begin
						a1 <= occ_count[31:0];
						a2 <= {24'd0, occ_count[39:32]};
					end
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
		end
	end

	wire unused_p = &{1'b0, p_co};
endmodule

`default_nettype wire
