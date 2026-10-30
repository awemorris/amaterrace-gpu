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
	(* max_fanout = 16 *) reg [9:0] sidx;	/* SET_REG: the index of the pair */
	(* max_fanout = 16 *) reg [31:0] a0, a0_hi, a1, a2;	/* fence payload */
	(* max_fanout = 16 *) reg [39:0] occ_q;
	reg settle;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire seq_rst_high;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_seq_rst (.I0(rst_n), .O(seq_rst_high));

	wire [4:0] fw_act_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fwa0 (.I0(fw_active), .O(fw_act_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fwa1 (.I0(fw_active), .O(fw_act_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fwa2 (.I0(fw_active), .O(fw_act_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fwa3 (.I0(fw_active), .O(fw_act_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_fwa4 (.I0(fw_active), .O(fw_act_b[4]));

	wire [4:0] use_fw_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ufw0 (.I0(use_fw), .O(use_fw_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ufw1 (.I0(use_fw), .O(use_fw_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ufw2 (.I0(use_fw), .O(use_fw_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ufw3 (.I0(use_fw), .O(use_fw_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ufw4 (.I0(use_fw), .O(use_fw_b[4]));

	wire in_valid = use_fw_b[4] ? fw_valid : n_valid;
	(* keep = "true" *) wire [31:0] in_data = {
		use_fw_b[3] ? fw_data[31:24] : n_data[31:24],
		use_fw_b[2] ? fw_data[23:16] : n_data[23:16],
		use_fw_b[1] ? fw_data[15:8]  : n_data[15:8],
		use_fw_b[0] ? fw_data[7:0]   : n_data[7:0]
	};
	(* keep = "true" *) wire [31:0] hdr = {
		fw_act_b[3] ? fw_data[31:24] : n_data[31:24],
		fw_act_b[2] ? fw_data[23:16] : n_data[23:16],
		fw_act_b[1] ? fw_data[15:8]  : n_data[15:8],
		fw_act_b[0] ? fw_data[7:0]   : n_data[7:0]
	};
	wire hdr_valid = fw_act_b[4] ? fw_valid : n_valid;
`else
	wire in_valid = use_fw ? fw_valid : n_valid;
	wire [31:0] in_data = use_fw ? fw_data : n_data;
	wire [31:0] hdr = fw_active ? fw_data : n_data;
	wire hdr_valid = fw_active ? fw_valid : n_valid;
`endif

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
	wire [7:0] h_n_m1;
	wire n_m1_bo;
	am_sub #(.W(8)) sub_n_m1 (
		.a(h_n), .b(8'd1), .bi(1'b0), .d(h_n_m1), .bo(n_m1_bo)
	);

	wire dec_hdr_fault, dec_hdr_short, h_zero, pay_bad;
	atg_cp_seq_dec #(.UNITS(UNITS), .HAS_VSYNC(HAS_VSYNC), .HAS_DISP(HAS_DISP)) dec (
		.hdr(hdr_r), .hdr_fw(use_fw), .is_ghci_in(is_ghci_hdr_r), .h_known(), .h_absent(),
		.h_need(), .h_short(), .h_zero(h_zero),
		.hdr_fault(dec_hdr_fault), .hdr_short(dec_hdr_short),
		.vendor(vendor), .op(op), .p(p), .in_data(in_data),
		.pay_bad(pay_bad)
	);

	(* max_fanout = 16 *) reg is_set_r, is_dset_r, is_fence_cmd_r;
`ifdef SYNTH_KINTEX7
	(* DONT_TOUCH = "TRUE" *) reg is_set_r1, is_dset_r1;
`endif
	(* max_fanout = 16 *) reg is_dispatch_r, is_load_const_r, is_draw_raw_r;

	/* Payload: what this dword does; the waits (atg_cp_seq_wait). */
	wire is_set = !vendor && op == OP_SET_REG;
	wire is_dset = !vendor && op == OP_DISP_SET;
	wire set_val = (is_set_r || is_dset_r) && p[0];
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
		.is_draw_raw(is_draw_raw_r),
		.is_dispatch(is_dispatch_r),
		.is_load_const(is_load_const_r),
		.pay_we(pay_we),
		.pay_idx(pay_idx),
		.pay_wait(pay_wait),
		.pre(pre),
		.pre_f(pre_f),
		.post(post)
	);

`ifdef SYNTH_KINTEX7
	/* All s_wait boundaries (0x020, 0x050, 0x090, 0x190, 0x1B0, 0x1C0) are multiples of 0x010,
	 * so s_wait_in is a pure function of 6 bits in_data[9:4] (1 LUT6 per bit). */
	wire [5:0] s_hi = in_data[9:4];
	(* keep = "true" *) wire [7:0] s_wait_in =
		s_hi[5] ? 8'h6C : /* B_TUW (0x200..0x2FF) */
		(s_hi[4:0] < 5'h02) ? 8'h02 : /* B_BLT (0x000..0x01F) */
		(s_hi[4:0] < 5'h05) ? 8'h04 : /* B_VF (0x020..0x04F) */
		(s_hi[4:0] < 5'h09) ? 8'h5C : /* B_RXROP / B_ROPW (0x050..0x08F) */
		(s_hi[4:0] < 5'h19) ? 8'h6C : /* B_TUW (0x090..0x18F) */
		(s_hi[4:0] < 5'h1B) ? 8'h4C : /* B_PROGW (0x190..0x1AF) */
		(s_hi[4:1] == 4'hE) ? 8'h04 : 8'd0; /* B_VF (0x1C0..0x1DF) */
`endif

	wire [8:0] pay_wait_act;
	wire pay_hold = |(pay_wait_act & busy_in);
	wire pay_take = (st == Q_PAY) && in_valid && !pay_hold;
	wire hdr_take = (st == Q_IDLE) && !halt && hdr_valid;

`ifdef SYNTH_KINTEX7
	(* DONT_TOUCH = "TRUE" *) reg st_is_pay_r;
	reg [7:0] n_m1_r;
	reg p_is_0_r, p_is_1_r, p_is_2_r, p_is_3_r, p_is_last_r;

	wire [3:0] hdr_take_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_htk0 (.I0(hdr_take), .O(hdr_take_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_htk1 (.I0(hdr_take), .O(hdr_take_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_htk2 (.I0(hdr_take), .O(hdr_take_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_htk3 (.I0(hdr_take), .O(hdr_take_b[3]));

	(* max_fanout = 16 *) reg [8:0] pay_wait_r;
	wire pay_hold_0, pay_hold_1, pay_hold_2;
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_ph0 (
		.I0(pay_wait_r[0]), .I1(busy_in[0]), .I2(pay_wait_r[1]), .I3(busy_in[1]), .I4(pay_wait_r[2]), .I5(busy_in[2]),
		.O(pay_hold_0)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_ph1 (
		.I0(pay_wait_r[3]), .I1(busy_in[3]), .I2(pay_wait_r[4]), .I3(busy_in[4]), .I4(pay_wait_r[5]), .I5(busy_in[5]),
		.O(pay_hold_1)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_ph2 (
		.I0(pay_wait_r[6]), .I1(busy_in[6]), .I2(pay_wait_r[7]), .I3(busy_in[7]), .I4(pay_wait_r[8]), .I5(busy_in[8]),
		.O(pay_hold_2)
	);

	wire [3:0] pay_take_b;
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00000008)) u_ptk0 (
		.I0(st_is_pay_r), .I1(in_valid), .I2(pay_hold_0), .I3(pay_hold_1), .I4(pay_hold_2), .O(pay_take_b[0])
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00000008)) u_ptk1 (
		.I0(st_is_pay_r), .I1(in_valid), .I2(pay_hold_0), .I3(pay_hold_1), .I4(pay_hold_2), .O(pay_take_b[1])
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00000008)) u_ptk2 (
		.I0(st_is_pay_r), .I1(in_valid), .I2(pay_hold_0), .I3(pay_hold_1), .I4(pay_hold_2), .O(pay_take_b[2])
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00000008)) u_ptk3 (
		.I0(st_is_pay_r), .I1(in_valid), .I2(pay_hold_0), .I3(pay_hold_1), .I4(pay_hold_2), .O(pay_take_b[3])
	);

	wire [8:0] pw_d;
	assign pw_d[0] = 1'b0;
	assign pw_d[1] = st_is_pay_r && is_set_r && !p[0] && s_wait_in[1];
	assign pw_d[2] = st_is_pay_r && is_set_r && !p[0] && s_wait_in[2];
	assign pw_d[3] = is_draw_raw_r || (st_is_pay_r && is_set_r && !p[0] && s_wait_in[3]);
	assign pw_d[4] = st_is_pay_r && is_set_r && !p[0] && s_wait_in[4];
	assign pw_d[5] = st_is_pay_r && is_set_r && !p[0] && s_wait_in[5];
	assign pw_d[6] = ((is_dispatch_r || is_load_const_r) && p_is_0_r) || (st_is_pay_r && is_set_r && !p[0] && s_wait_in[6]);
	assign pw_d[7] = 1'b0;
	assign pw_d[8] = st_is_pay_r && is_dset_r && !p[0];

	wire pw_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pw_we (
		.I0(st == Q_DEC2), .I1(pay_take_b[3]), .O(pw_we_b)
	);
	always @(posedge clk) begin
		if (seq_rst_high) begin
			pay_wait_r <= 9'd0;
		end else if (pw_we_b) begin
			pay_wait_r <= pw_d;
		end
	end
	assign pay_wait_act = pay_wait_r;

	wire n_rdy_idle = (st == Q_IDLE) && !halt && !fw_act_b[4];
	wire fw_rdy_idle = (st == Q_IDLE) && !halt && fw_act_b[4];
	wire n_rdy_pay = st_is_pay_r && !halt && !use_fw_b[4];
	wire fw_rdy_pay = st_is_pay_r && !halt && use_fw_b[4];
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'hAAAAAAAE)) u_nrdy_lut (
		.I0(n_rdy_idle), .I1(n_rdy_pay), .I2(pay_hold_0), .I3(pay_hold_1), .I4(pay_hold_2), .O(n_ready)
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'hAAAAAAAE)) u_fwrdy_lut (
		.I0(fw_rdy_idle), .I1(fw_rdy_pay), .I2(pay_hold_0), .I3(pay_hold_1), .I4(pay_hold_2), .O(fw_ready)
	);

	/* 2-stage payload bad check to keep in_data -> FF <= 3 LUTs */
	reg pay_chk_v_r;
	reg pay_hi16_nz_r;
	reg [7:0] pay_mid_r;
	reg pay_off_ok_r;
	wire [7:0] off_in = in_data[7:0];
	wire off_in_ok = (off_in[1:0] == 2'd0) &&
		(off_in == 8'h10 || off_in == 8'h28 || off_in == 8'h2C ||
		 (off_in >= 8'h30 && off_in <= 8'h50) ||
		 off_in == 8'h58 || off_in == 8'hA4 || off_in == 8'hA8);

	wire bad_idx_comb = pay_chk_v_r && (
		(is_set_r1 && (pay_hi16_nz_r || (pay_mid_r[7:2] != 6'd0) || (pay_mid_r[1:0] == 2'b11))) ||
		(is_dset_r1 && (pay_hi16_nz_r || (pay_mid_r != 8'd0) || !pay_off_ok_r))
	);

	(* max_fanout = 16 *) reg uop_we_r;
	(* max_fanout = 16 *) reg [9:0] uop_idx_r;
	(* max_fanout = 16 *) reg [31:0] uop_wdata_r;
	always @(posedge clk) begin
		if (seq_rst_high) begin
			uop_we_r <= 1'b0;
			uop_idx_r <= 10'd0;
			uop_wdata_r <= 32'd0;
			pay_chk_v_r <= 1'b0;
			pay_hi16_nz_r <= 1'b0;
			pay_mid_r <= 8'd0;
			pay_off_ok_r <= 1'b0;
		end else begin
			uop_we_r <= pay_take_b[0] && pay_we && !bad_idx_comb;
			uop_idx_r <= pay_idx;
			uop_wdata_r <= in_data;
			pay_chk_v_r <= pay_take_b[0] && !p[0];
			pay_hi16_nz_r <= (in_data[31:16] != 16'd0);
			pay_mid_r <= in_data[15:8];
			pay_off_ok_r <= off_in_ok;
		end
	end
	assign uop_we = uop_we_r;
	assign uop_idx = uop_idx_r;
	assign uop_wdata = uop_wdata_r;
`else
	assign pay_wait_act = pay_wait;
	assign n_ready = !halt && ((st == Q_IDLE && !fw_active) || (st == Q_PAY && !use_fw && !pay_hold));
	assign fw_ready = !halt && ((st == Q_IDLE && fw_active) || (st == Q_PAY && use_fw && !pay_hold));
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

`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg unit_op_r;
	(* max_fanout = 16 *) reg fence_op_r;
	(* max_fanout = 16 *) reg is_wait_vsync_r;
	(* max_fanout = 16 *) reg [8:0] pre_r;
	(* max_fanout = 16 *) reg pre_f_r;
	(* max_fanout = 16 *) reg [8:0] post_r;
	(* max_fanout = 16 *) reg post_nz_r;
	reg st_exec_rdy_r;
	reg [3:0] exec_done_st_r;
	reg exec_settle_r;
	reg k_valid_r;
	reg [2:0] k_code_r;
	reg [3:0] inv_code_r;

	wire exec_unit_op = unit_op_r;
	wire exec_fence_op = fence_op_r;
	wire exec_vsync_op = is_wait_vsync_r;
	wire [8:0] exec_pre = pre_r;
	wire exec_pre_f = pre_f_r;
	wire [8:0] exec_post = post_r;
	wire exec_post_nz = post_nz_r;

	wire pre_busy_0, pre_busy_1, pre_busy_2, ego_ok;
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_pb0 (
		.I0(exec_pre[0]), .I1(busy_in[0]), .I2(exec_pre[1]), .I3(busy_in[1]), .I4(exec_pre[2]), .I5(busy_in[2]),
		.O(pre_busy_0)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_pb1 (
		.I0(exec_pre[3]), .I1(busy_in[3]), .I2(exec_pre[4]), .I3(busy_in[4]), .I4(exec_pre[5]), .I5(busy_in[5]),
		.O(pre_busy_1)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_pb2 (
		.I0(exec_pre[6]), .I1(busy_in[6]), .I2(exec_pre[7]), .I3(busy_in[7]), .I4(exec_pre[8]), .I5(busy_in[8]),
		.O(pre_busy_2)
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h2A2A002A)) u_ego_ok (
		.I0(st_exec_rdy_r), .I1(exec_pre_f), .I2(f_busy), .I3(exec_unit_op), .I4(u_ok),
		.O(ego_ok)
	);
	wire [1:0] exec_go_b;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0002)) u_ego0 (
		.I0(ego_ok), .I1(pre_busy_0), .I2(pre_busy_1), .I3(pre_busy_2),
		.O(exec_go_b[0])
	);
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0002)) u_ego1 (
		.I0(ego_ok), .I1(pre_busy_0), .I2(pre_busy_1), .I3(pre_busy_2),
		.O(exec_go_b[1])
	);
	wire exec_go = exec_go_b[0];
	wire is_op_std = !vendor && exec_go_b[1];
`else
	wire exec_unit_op = unit_op;
	wire exec_fence_op = fence_op;
	wire exec_vsync_op = !vendor && op == OP_WAIT_VSYNC;
	wire [8:0] exec_pre = pre;
	wire exec_pre_f = pre_f;
	wire [8:0] exec_post = post;
	wire exec_post_nz = (post != 9'd0);
	wire exec_go_raw = st == Q_EXEC && !settle && !(|(exec_pre & busy_in)) && !(exec_pre_f && f_busy) &&
		(u_ok || !exec_unit_op);
	wire exec_go = exec_go_raw;
	wire is_op_std = !vendor && exec_go;
`endif

	reg k_on_dec;
	reg [2:0] k_code_dec;
	always @(*) begin
		k_on_dec = 1'b1;
		k_code_dec = K_BLT;
		if (vendor)
			{k_on_dec, k_code_dec} = {op == VOP_DRAW_RAW, K_RAW};
		else case (op)
		OP_BLIT: k_code_dec = K_BLT;
		OP_DRAW, CMD_DRAW, CMD_DRAW_INDEXED, CMD_DRAW_INDIRECT: k_code_dec = K_DRAW;
		OP_DISPATCH, CMD_DISPATCH, CMD_DRAW_MESH_TASKS: k_code_dec = K_CS;
		OP_LOAD_CONST: k_code_dec = K_LC;
		OP_PERF_RESET: k_code_dec = K_PERF;
		OP_FLIP: k_code_dec = K_FLIP;
		OP_DISP_SET: {k_on_dec, k_code_dec} = {flags[0], K_DISP_IDLE};
		default: k_on_dec = 1'b0;
		endcase
	end
	wire [3:0] inv_code_dec = vendor ? 4'd0 :
		(op == OP_DRAW || op == CMD_DRAW || op == CMD_DRAW_INDEXED || op == CMD_DRAW_INDIRECT || op == CMD_DRAW_MESH_TASKS) ? 4'b0011 :
		op == OP_LOAD_PROGRAM ? 4'b1000 : op == OP_INVALIDATE ? flags[3:0] : 4'd0;

`ifdef SYNTH_KINTEX7
	assign kick = exec_go_b[1] && k_valid_r;
	assign kick_code = k_code_r;
	assign inv = exec_go_b[1] ? inv_code_r : 4'd0;
`else
	assign kick = exec_go && k_on_dec;
	assign kick_code = k_code_dec;
	assign inv = exec_go ? inv_code_dec : 4'd0;
`endif

	wire is_query = !vendor && op == OP_QUERY;
	wire fence_op = !vendor && (op == OP_FENCE || op == OP_WAIT_FENCE || op == OP_RESULT ||
		(op == OP_QUERY && !flags[0]) || op == CMD_FENCE);
`ifdef SYNTH_KINTEX7
	wire [3:0] is_q_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_iq0 (.I0(is_query_r), .O(is_q_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_iq1 (.I0(is_query_r), .O(is_q_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_iq2 (.I0(is_query_r), .O(is_q_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_iq3 (.I0(is_query_r), .O(is_q_b[3]));

	wire [1:0] is_fc_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ifc0 (.I0(is_fence_cmd_r), .O(is_fc_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ifc1 (.I0(is_fence_cmd_r), .O(is_fc_b[1]));

	assign occ_clear = (is_op_std && is_query_r && flags[0]) ||
		(st == Q_FREQ && f_ready && is_query_r && flags[1]);
	assign f_valid = st == Q_FREQ;
	assign f_op = (op == OP_FENCE || is_fence_cmd_r) ? 2'd0 : (op == OP_RESULT || is_query_r) ? 2'd1 : 2'd2;
	assign f_addr = {
		is_fc_b[1] ? a0_hi[31:16] : 16'd0,
		is_fc_b[0] ? a0_hi[15:0]  : 16'd0,
		a0
	};
	(* keep = "true" *) wire [31:0] f_value_w = {
		is_q_b[1] ? occ_q[31:16] : a1[31:16],
		is_q_b[0] ? occ_q[15:0]  : a1[15:0]
	};
	assign f_value = f_value_w;
	assign f_aux = {
		is_q_b[3] ? 16'd0                : a2[31:16],
		is_q_b[2] ? {8'd0, occ_q[39:32]} : a2[15:0]
	};
`else
	assign occ_clear = (is_op_std && op == OP_QUERY && flags[0]) ||
		(st == Q_FREQ && f_ready && is_query && flags[1]);
	assign f_valid = st == Q_FREQ;
	assign f_op = (op == OP_FENCE || op == CMD_FENCE) ? 2'd0 : op == OP_RESULT || op == OP_QUERY ? 2'd1 : 2'd2;
	assign f_addr = (op == CMD_FENCE) ? {a0_hi, a0} : {32'd0, a0};
	assign f_value = (op == OP_QUERY) ? occ_q[31:0] : a1;
	assign f_aux = (op == OP_QUERY) ? {24'd0, occ_q[39:32]} : a2;
`endif
	assign f_irq = flags[0];

	reg f_pulse;
	reg [3:0] f_kind;
	reg [31:0] f_faddr;

`ifdef SYNTH_KINTEX7
	/* Pipelined header decode (Q_DEC -> Q_DEC2) so hdr_r -> FF is <= 3 LUTs */
	reg ghci_fault_op;
	reg [3:0] ghci_min_n;
	always @(*) begin
		ghci_fault_op = 1'b0;
		ghci_min_n = 4'd0;
		case (hdr_r[7:0])
		8'h10: ghci_min_n = 4'd10;
		8'h11: ghci_min_n = 4'd8;
		8'h12: ghci_min_n = 4'd4;
		8'h13: ghci_min_n = 4'd2;
		8'h14: ghci_min_n = 4'd2;
		8'h20: ghci_min_n = 4'd3;
		8'h21: ghci_min_n = 4'd0;
		8'h22: ghci_min_n = 4'd4;
		8'h23: ghci_min_n = 4'd4;
		8'h24: ghci_min_n = 4'd7;
		8'h25: ghci_min_n = 4'd5;
		8'h26: ghci_min_n = 4'd6;
		8'h27: begin ghci_min_n = 4'd5; ghci_fault_op = !UNITS[2]; end
		8'h28: begin ghci_min_n = 4'd6; ghci_fault_op = !UNITS[2]; end
		8'h29: begin ghci_min_n = 4'd0; ghci_fault_op = !UNITS[2]; end
		8'h2a: begin ghci_min_n = 4'd4; ghci_fault_op = !UNITS[6]; end
		8'h2b: ghci_min_n = 4'd10;
		8'h2c: ghci_min_n = 4'd0;
		8'h2d: begin ghci_min_n = 4'd0; ghci_fault_op = !UNITS[6]; end
		8'h2e: begin ghci_min_n = 4'd6; ghci_fault_op = !UNITS[6]; end
		8'h30: begin ghci_min_n = 4'd4; ghci_fault_op = !UNITS[6]; end
		8'h31: ghci_min_n = 4'd4;
		8'h32: ghci_min_n = 4'd4;
		8'h33: ghci_min_n = 4'd6;
		8'h34: ghci_min_n = 4'd5;
		8'h35: ghci_min_n = 4'd4;
		8'h36: begin ghci_min_n = 4'd4; ghci_fault_op = !UNITS[4]; end
		8'h37: begin ghci_min_n = 4'd4; ghci_fault_op = !UNITS[4]; end
		8'h40: begin ghci_min_n = 4'd8; ghci_fault_op = !UNITS[1]; end
		8'h41: begin ghci_min_n = 4'd11; ghci_fault_op = !UNITS[1]; end
		8'h42: begin ghci_min_n = 4'd12; ghci_fault_op = !UNITS[1]; end
		8'h43: begin ghci_min_n = 4'd5; ghci_fault_op = !UNITS[1]; end
		8'h44: begin ghci_min_n = 4'd11; ghci_fault_op = !UNITS[1]; end
		8'h45: begin ghci_min_n = 4'd10; ghci_fault_op = !UNITS[1]; end
		8'h46: begin ghci_min_n = 4'd10; ghci_fault_op = !UNITS[1]; end
		8'h50: begin ghci_min_n = 4'd0; ghci_fault_op = (HAS_DISP == 0) || use_fw_b[4]; end
		8'h51: begin ghci_min_n = 4'd8; ghci_fault_op = (HAS_DISP == 0) || use_fw_b[4]; end
		default: ghci_fault_op = 1'b1;
		endcase
	end

	reg std_fault_op;
	reg [3:0] std_min_n;
	always @(*) begin
		std_fault_op = 1'b0;
		std_min_n = 4'd0;
		if (hdr_r[31]) begin
			std_fault_op = 1'b1;
		end else if (hdr_r[30]) begin
			case (hdr_r[29:24])
			6'd0: begin std_min_n = 4'd9; std_fault_op = !UNITS[3]; end
			6'd1: std_min_n = 4'd1;
			default: std_fault_op = 1'b1;
			endcase
		end else begin
			case (hdr_r[29:24])
			6'd0, 6'd1, 6'd6, 6'd10, 6'd12: ;
			6'd2: std_fault_op = !UNITS[1];
			6'd3: std_fault_op = !UNITS[2];
			6'd4, 6'd7: begin std_min_n = 4'd3; std_fault_op = !UNITS[6]; end
			6'd5, 6'd9: std_min_n = 4'd2;
			6'd8, 6'd20: std_min_n = 4'd1;
			6'd11: std_fault_op = (HAS_VSYNC == 0);
			6'd13: std_min_n = 4'd3;
			6'd14: begin std_min_n = 4'd1; std_fault_op = !UNITS[4]; end
			6'd15: std_fault_op = (HAS_DISP == 0) || use_fw_b[4];
			6'd16: begin std_min_n = 4'd4; std_fault_op = (HAS_DISP == 0) || use_fw_b[4]; end
			6'd21, 6'd22: std_min_n = 4'd4;
			default: std_fault_op = 1'b1;
			endcase
		end
	end

	reg h_early_fault_r, h_early_short_r, h_nhi_z_r;
	reg [3:0] h_min_r, h_nlo_r;
	wire dec_short_s = h_early_short_r || (h_nhi_z_r && (h_nlo_r < h_min_r));
	wire dec_fault_s = h_early_fault_r || dec_short_s;

	wire st_is_dec_raw = (st == Q_DEC);
	wire [5:0] st_dec_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sdec0 (.I0(st_is_dec_raw), .O(st_dec_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sdec1 (.I0(st_is_dec_raw), .O(st_dec_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sdec2 (.I0(st_is_dec_raw), .O(st_dec_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sdec3 (.I0(st_is_dec_raw), .O(st_dec_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sdec4 (.I0(st_is_dec_raw), .O(st_dec_b[4]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sdec5 (.I0(st_is_dec_raw), .O(st_dec_b[5]));

	wire st_is_dec2_raw = (st == Q_DEC2);
	wire [1:0] st_dec2_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sd2_0 (.I0(st_is_dec2_raw), .O(st_dec2_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sd2_1 (.I0(st_is_dec2_raw), .O(st_dec2_b[1]));

	wire [7:0] h_op_a, h_op_b;
	genvar g_hop;
	generate
		for (g_hop = 0; g_hop < 8; g_hop = g_hop + 1) begin : gen_hop_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hopa (.I0(h_op[g_hop]), .O(h_op_a[g_hop]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hopb (.I0(h_op[g_hop]), .O(h_op_b[g_hop]));
		end
	endgenerate

	wire [1:0] sidx_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h2220)) u_swe0 (
		.I0(pay_take_b[1]), .I1(p[0]), .I2(is_set_r), .I3(is_dset_r), .O(sidx_we_b[0])
	);
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h2220)) u_swe1 (
		.I0(pay_take_b[1]), .I1(p[0]), .I2(is_set_r), .I3(is_dset_r), .O(sidx_we_b[1])
	);

	wire [1:0] f_fa_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h2)) u_fawe0 (.I0(pay_take_b[1]), .I1(p[0]), .O(f_fa_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h2)) u_fawe1 (.I0(pay_take_b[1]), .I1(p[0]), .O(f_fa_we_b[1]));

	wire [1:0] a0_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_a0we0 (.I0(pay_take_b[2]), .I1(p_is_0_r), .O(a0_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_a0we1 (.I0(pay_take_b[2]), .I1(p_is_0_r), .O(a0_we_b[1]));

	wire [1:0] a0_hi_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'h80)) u_a0hwe0 (.I0(pay_take_b[2]), .I1(is_fence_cmd_r), .I2(p_is_1_r), .O(a0_hi_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'h80)) u_a0hwe1 (.I0(pay_take_b[2]), .I1(is_fence_cmd_r), .I2(p_is_1_r), .O(a0_hi_we_b[1]));

	wire [1:0] a1_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hA280)) u_a1we0 (.I0(pay_take_b[2]), .I1(is_fence_cmd_r), .I2(p_is_2_r), .I3(p_is_1_r), .O(a1_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hA280)) u_a1we1 (.I0(pay_take_b[2]), .I1(is_fence_cmd_r), .I2(p_is_2_r), .I3(p_is_1_r), .O(a1_we_b[1]));

	wire [1:0] a2_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hA280)) u_a2we0 (.I0(pay_take_b[2]), .I1(is_fence_cmd_r), .I2(p_is_3_r), .I3(p_is_2_r), .O(a2_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hA280)) u_a2we1 (.I0(pay_take_b[2]), .I1(is_fence_cmd_r), .I2(p_is_3_r), .I3(p_is_2_r), .O(a2_we_b[1]));

	always @(posedge clk) begin
		if (seq_rst_high) begin
			a0 <= 32'd0;
			a0_hi <= 32'd0;
			a1 <= 32'd0;
			a2 <= 32'd0;
			sidx <= 10'd0;
			f_faddr <= 32'd0;
		end else begin
			if (a0_we_b[0]) a0[15:0] <= in_data[15:0];
			if (a0_we_b[1]) a0[31:16] <= in_data[31:16];
			if (a0_hi_we_b[0]) a0_hi[15:0] <= in_data[15:0];
			if (a0_hi_we_b[1]) a0_hi[31:16] <= in_data[31:16];
			if (a1_we_b[0]) a1[15:0] <= in_data[15:0];
			if (a1_we_b[1]) a1[31:16] <= in_data[31:16];
			if (a2_we_b[0]) a2[15:0] <= in_data[15:0];
			if (a2_we_b[1]) a2[31:16] <= in_data[31:16];
			if (sidx_we_b[0]) sidx[4:0] <= is_dset_r ? in_data[6:2] : in_data[4:0];
			if (sidx_we_b[1]) sidx[9:5] <= is_dset_r ? {4'b1111, in_data[7]} : in_data[9:5];
			if (f_fa_we_b[0]) f_faddr[15:0] <= in_data[15:0];
			if (f_fa_we_b[1]) f_faddr[31:16] <= in_data[31:16];
		end
	end

	wire occ_we_raw = (st == Q_EXEC) && is_query_r;
	wire [2:0] occ_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_occwe0 (.I0(occ_we_raw), .O(occ_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_occwe1 (.I0(occ_we_raw), .O(occ_we_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_occwe2 (.I0(occ_we_raw), .O(occ_we_b[2]));
`endif

	assign fault = f_pulse;
	assign fault_kind = f_kind;
	assign fault_addr = f_faddr;
	assign fault_tag = tag;
	assign busy = st != Q_IDLE && st != Q_DEAD;
	assign cmd_active = busy && !(st == Q_PAY && use_fw && !fw_valid);

	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (seq_rst_high) begin
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
`ifdef SYNTH_KINTEX7
			st_is_pay_r <= 1'b0;
			n_m1_r <= 8'd0;
			p_is_0_r <= 1'b0;
			p_is_1_r <= 1'b0;
			p_is_2_r <= 1'b0;
			p_is_3_r <= 1'b0;
			p_is_last_r <= 1'b0;
			is_set_r1 <= 1'b0;
			is_dset_r1 <= 1'b0;
			h_early_fault_r <= 1'b0;
			h_early_short_r <= 1'b0;
			h_nhi_z_r <= 1'b0;
			h_min_r <= 4'd0;
			h_nlo_r <= 4'd0;
`endif
			is_fence_cmd_r <= 1'b0;
			vendor <= 1'b0;
			op <= 8'd0;
			flags <= 8'd0;
			tag <= 8'd0;
			side <= 7'd0;
			n <= 8'd0;
			p <= 8'd0;
`ifndef SYNTH_KINTEX7
			sidx <= 10'd0;
			a0 <= 32'd0;
			a0_hi <= 32'd0;
			a1 <= 32'd0;
			a2 <= 32'd0;
			f_faddr <= 32'd0;
`endif
			settle <= 1'b0;
			f_pulse <= 1'b0;
			f_kind <= 4'd0;
			dec_fault_r <= 1'b0;
			dec_short_r <= 1'b0;
			h_zero_r <= 1'b0;
			is_query_r <= 1'b0;
			is_dispatch_r <= 1'b0;
			is_load_const_r <= 1'b0;
			is_draw_raw_r <= 1'b0;
`ifdef SYNTH_KINTEX7
			unit_op_r <= 1'b0;
			fence_op_r <= 1'b0;
			is_wait_vsync_r <= 1'b0;
			pre_r <= 9'd0;
			pre_f_r <= 1'b0;
			post_r <= 9'd0;
			post_nz_r <= 1'b0;
			st_exec_rdy_r <= 1'b0;
			exec_done_st_r <= Q_IDLE;
			exec_settle_r <= 1'b0;
			k_valid_r <= 1'b0;
			k_code_r <= 3'd0;
			inv_code_r <= 4'd0;
`endif
			occ_q <= 40'd0;
		end else begin
			f_pulse <= 1'b0;
			settle <= 1'b0;
`ifdef SYNTH_KINTEX7
			if (hdr_take_b[0]) hdr_r[15:0] <= hdr[15:0];
			if (hdr_take_b[1]) hdr_r[31:16] <= hdr[31:16];
			if (hdr_take_b[2]) begin
				use_fw <= fw_act_b[4];
				side <= fw_act_b[4] ? fw_side : 7'd0;
				is_ghci_hdr_r <= is_ghci_hdr_comb;
				ghci_n_r <= ghci_n_comb;
			end
			if (st_dec_b[0]) begin
				vendor <= h_vendor;
				op <= h_op_a;
			end
			if (st_dec_b[1]) begin
				flags <= is_ghci_hdr_r ? hdr_r[31:24] : hdr_r[15:8];
				tag <= hdr_r[23:16];
			end
			if (st_dec_b[2]) begin
				n <= h_n;
				n_m1_r <= h_n_m1;
				h_zero_r <= h_zero;
			end
			if (st_dec_b[3]) begin
				is_set_r <= !h_vendor && (h_op_b == OP_SET_REG);
				is_dset_r <= !h_vendor && (h_op_b == OP_DISP_SET);
				is_set_r1 <= !h_vendor && (h_op_b == OP_SET_REG);
				is_dset_r1 <= !h_vendor && (h_op_b == OP_DISP_SET);
				is_fence_cmd_r <= (h_op_b == CMD_FENCE);
				is_query_r <= !h_vendor && (h_op_b == OP_QUERY);
				is_dispatch_r <= !h_vendor && (h_op_b == OP_DISPATCH || h_op_b == CMD_DISPATCH || h_op_b == CMD_DRAW_MESH_TASKS);
				is_load_const_r <= !h_vendor && (h_op_b == OP_LOAD_CONST);
				is_draw_raw_r <= h_vendor && (h_op_b == VOP_DRAW_RAW);
			end
			if (st_dec_b[4]) begin
				h_early_fault_r <= is_ghci_hdr_r ? ghci_fault_op : std_fault_op;
				h_early_short_r <= !is_ghci_hdr_r && !hdr_r[30] && (hdr_r[29:24] == 6'd1 || hdr_r[29:24] == 6'd15) && hdr_r[0];
				h_min_r <= is_ghci_hdr_r ? ghci_min_n : std_min_n;
				h_nhi_z_r <= is_ghci_hdr_r ? (hdr_r[15:12] == 4'd0) : (hdr_r[7:4] == 4'd0);
				h_nlo_r <= is_ghci_hdr_r ? hdr_r[11:8] : hdr_r[3:0];
			end
			if (st_dec_b[5]) begin
				p <= 8'd0;
				p_is_0_r <= 1'b1;
				p_is_1_r <= 1'b0;
				p_is_2_r <= 1'b0;
				p_is_3_r <= 1'b0;
				p_is_last_r <= (h_n == 8'd1);
			end else if (pay_take_b[0]) begin
				p <= p_n;
				p_is_0_r <= 1'b0;
				p_is_1_r <= p_is_0_r;
				p_is_2_r <= p_is_1_r;
				p_is_3_r <= p_is_2_r;
				p_is_last_r <= (p_n == n_m1_r);
			end
			if (st_dec2_b[0]) begin
				unit_op_r <= unit_op;
				fence_op_r <= fence_op;
				is_wait_vsync_r <= !vendor && (op == OP_WAIT_VSYNC);
				pre_r <= pre;
				pre_f_r <= pre_f;
			end
			if (st_dec2_b[1]) begin
				post_r <= post;
				post_nz_r <= (post != 9'd0);
				exec_done_st_r <= fence_op ? Q_FREQ :
					(!vendor && (op == OP_WAIT_VSYNC)) ? Q_VSYNC :
					(post != 9'd0) ? Q_POST : Q_IDLE;
				exec_settle_r <= !fence_op && !(!vendor && (op == OP_WAIT_VSYNC)) && (post != 9'd0);
				k_valid_r <= k_on_dec;
				k_code_r <= k_code_dec;
				inv_code_r <= inv_code_dec;
			end
			st_exec_rdy_r <= ((st == Q_DEC2) && !dec_fault_s && h_zero_r) || ((st == Q_EXEC) && !exec_go_b[0]);
`endif
			case (st)
			Q_IDLE:
`ifdef SYNTH_KINTEX7
				if (hdr_take_b[3]) begin
					st <= Q_DEC;
					st_is_pay_r <= 1'b0;
				end
`else
				if (hdr_take) begin
					use_fw <= fw_active;
					side <= fw_active ? fw_side : 7'd0;
					hdr_r <= hdr;
					is_ghci_hdr_r <= is_ghci_hdr_comb;
					ghci_n_r <= ghci_n_comb;
					st <= Q_DEC;
				end
`endif
			Q_DEC: begin
`ifndef SYNTH_KINTEX7
				vendor <= h_vendor;
				op <= h_op;
				is_set_r <= !h_vendor && (h_op == OP_SET_REG);
				is_dset_r <= !h_vendor && (h_op == OP_DISP_SET);
				is_fence_cmd_r <= (h_op == CMD_FENCE);
				is_query_r <= !h_vendor && (h_op == OP_QUERY);
				is_dispatch_r <= !h_vendor && (h_op == OP_DISPATCH || h_op == CMD_DISPATCH || h_op == CMD_DRAW_MESH_TASKS);
				is_load_const_r <= !h_vendor && (h_op == OP_LOAD_CONST);
				is_draw_raw_r <= h_vendor && (h_op == VOP_DRAW_RAW);
				flags <= is_ghci_hdr ? hdr_r[31:24] : hdr_r[15:8];
				tag <= hdr_r[23:16];
				n <= h_n;
				f_faddr <= 32'd0;
				dec_fault_r <= dec_hdr_fault;
				dec_short_r <= dec_hdr_short;
				h_zero_r <= h_zero;
				p <= 8'd0;
`endif
				st <= Q_DEC2;
`ifdef SYNTH_KINTEX7
				st_is_pay_r <= 1'b0;
`endif
			end
			Q_DEC2: begin
`ifdef SYNTH_KINTEX7
				if (dec_fault_s) begin
					f_pulse <= 1'b1;
					f_kind <= dec_short_s ? GHCI_FAULT_RING : GHCI_FAULT_OPCODE;
					st <= Q_DEAD;
					st_is_pay_r <= 1'b0;
				end else begin
					st <= h_zero_r ? Q_EXEC : Q_PAY;
					st_is_pay_r <= !h_zero_r;
				end
`else
				if (dec_fault_r) begin
					f_pulse <= 1'b1;
					f_kind <= dec_short_r ? GHCI_FAULT_RING : GHCI_FAULT_OPCODE;
					st <= Q_DEAD;
				end else begin
					st <= h_zero_r ? Q_EXEC : Q_PAY;
				end
`endif
			end
			Q_PAY:
`ifdef SYNTH_KINTEX7
				if (bad_idx_comb) begin
					f_pulse <= 1'b1;
					f_kind <= GHCI_FAULT_RING;
					st <= Q_DEAD;
					st_is_pay_r <= 1'b0;
				end else if (pay_take_b[3] && p_is_last_r) begin
					st <= Q_EXEC;
					st_is_pay_r <= 1'b0;
					settle <= 1'b1;
				end
`else
				if (pay_take && set_bad) begin
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
					if (op == CMD_FENCE && p == 8'd1)
						a0_hi <= in_data;
					if ((op == CMD_FENCE && p == 8'd2) || (op != CMD_FENCE && p == 8'd1))
						a1 <= in_data;
					if ((op == CMD_FENCE && p == 8'd3) || (op != CMD_FENCE && p == 8'd2))
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
`endif
			Q_EXEC: begin
				if (exec_go) begin
`ifdef SYNTH_KINTEX7
					if (exec_settle_r)
						settle <= 1'b1;
					st <= exec_done_st_r;
`else
					if (exec_fence_op)
						st <= Q_FREQ;
					else if (exec_vsync_op)
						st <= Q_VSYNC;
					else if (exec_post_nz) begin
						settle <= 1'b1;
						st <= Q_POST;
					end else
						st <= Q_IDLE;
`endif
				end
			end
			Q_POST:
				if (!settle && !(|(exec_post & busy_in)))
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
			if (occ_we_b[0]) occ_q[13:0] <= occ_count[13:0];
			if (occ_we_b[1]) occ_q[27:14] <= occ_count[27:14];
			if (occ_we_b[2]) occ_q[39:28] <= occ_count[39:28];
`else
			if (st == Q_EXEC && exec_go && is_query)
				occ_q <= occ_count;
`endif
		end
	end

`ifdef SYNTH_KINTEX7
	wire unused_p = &{1'b0, p_co, ghci_sub_bo, n_m1_bo, is_ghci_hdr, dec_hdr_fault, dec_hdr_short, dec_fault_r, dec_short_r, set_bad, pay_take, s_wait_in[0], s_wait_in[7], pay_wait};
`else
	wire unused_p = &{1'b0, p_co, ghci_sub_bo, n_m1_bo, is_ghci_hdr, dec_hdr_fault, dec_hdr_short, dec_fault_r, dec_short_r, set_bad, pay_take};
`endif
endmodule

`default_nettype wire
