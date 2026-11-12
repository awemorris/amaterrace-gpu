/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ctl: the CP's state machine (design §2.6): CTRL (RUN, RESET,
 * HALT, STEP, WDT_EN), STATUS, HALT and quiesce, the
 * RESET order of design §1.3 (with the STATE replay), the watchdog,
 * AXI_STUCK, and FAULT_ADDR/FAULT_INFO from all
 * fault sources.
 *
 * One state register st:
 *   IDLE     →(RUN, !HALT)→ RUNNING; →(HALT)→ HALTING
 *   RUNNING  →(HALT)→ HALTING; →(!RUN and the CP not busy)→ IDLE
 *   HALTING  →(mc_idle and the ring at a packet boundary)→ HALTED (ev_halted);
 *            →(!HALT)→ RUNNING/IDLE
 *   HALTED   →(!HALT)→ RUNNING (RUN) or IDLE; STEP pulses step
 *   any but RESETTING →(a fault)→ FAULTED (first fault recorded, ev_fault)
 *   any →(CTRL.RESET)→ RS_WAIT →(mc_idle)→ RS_PULSE (core_rst_n 0, mc_flush,
 *            RUN/HALT/FAULT cleared) → RS_REPLAY →(!replay_busy)→ IDLE
 * HALT quiesces at once (the blocks freeze at their next memory
 * access): HALTED waits only for memory idle and the ring's
 * packet boundary.  quiesce is 1 in HALTING, HALTED, FAULTED and the RESET
 * order.  The watchdog counts cycles with cmd_active while WDT_EN, except
 * those with wdt_hold (the count pauses); at WDT_CYCLES it is a fault of
 * kind 4 (and ev_wdt).  The hardware never
 * resets itself.
 *
 * Faults, first one wins (priority in one cycle: the MC, this module's own
 * (locked write, watchdog), then src 0..NSRC-1):
 *   MC refusal of client c != 0: FAULT_INFO {0, c, 1, 0, write, c}
 *   src k: {tag, SRC_BLOCK[k], kind, 0, 0, SRC_CLIENT[k]}, FAULT_ADDR addr
 *   watchdog: kind 4, [31:24] wdt_tag (session protection: the session whose
 *   work the units are draining, else 0);
 *   RING_BASE_LO/HI, RING_SIZE, CP_HEAP_* written when running (not IDLE): kind 7 (LOCKED_REG).
 * MC refusals of client 0 (the CP's own port) are reported by the ring,
 * the fence unit or the debug port themselves; those of DC_CLIENT (a
 * DISP2 controller's scan-out reads) are not a device fault: the DC shows
 * black and reports them itself (design §18.2).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_ctl #(
	parameter NSRC = 8,	/* Number of fault sources (0 ring, 1 seq, 2 state, 3 fence, 4 SU, 5 CPU, 6 BLT, 7 other blocks, 8 DISP) */
	parameter WDT_RESET = 32'h10000000,	/* WDT_CYCLES after reset (2^28) */
	parameter LINE_SHIFT = 5,	/* log2 of the line size */
	parameter [7:0] UNITS = 8'h03,	/* Present blocks, STATUS busy-bit order (DRAW: 2, DISPATCH: 6) */
	parameter [NSRC*8-1:0] SRC_BLOCK = 64'h00_01_00_06_00_00_00_00,	/* FAULT_INFO[23:16] per source */
	parameter [NSRC*8-1:0] SRC_CLIENT = 64'h00_01_00_00_00_00_00_00,	/* FAULT_INFO[7:0] per source */
	parameter [7:0] DC_CLIENT = 8'hFF	/* the DC's MC client, whose refusals are not faults (0xFF: none) */
) (
	input wire clk,
	input wire rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	/* Inputs */
	input wire mc_idle,
	input wire mem_ready,
	input wire [7:0] busy_in,
	input wire ring_empty,
	input wire ring_busy,
	input wire cmd_active,
	input wire wdt_hold,	/* the count pauses (the CPU waits on its FIFO or memory) */
	input wire replay_busy,
	input wire [3:0] seq_st,
	input wire f_busy,
	input wire mc_fault,
	input wire [7:0] mc_fault_client,
	input wire [31:0] mc_fault_addr,
	input wire mc_fault_write,
	input wire mc_fault_prot,	/* refused for session protection: FAULT_INFO[9] */
	input wire mc_fault_mem,	/* a protection table read failed: kind 5 */
	input wire [7:0] mc_fault_tag,
	input wire [7:0] wdt_tag,	/* the job tag of a watchdog fault */
	input wire [NSRC-1:0] src_fault,
	input wire [NSRC*4-1:0] src_kind,
	input wire [NSRC*32-1:0] src_addr,
	input wire [NSRC*8-1:0] src_tag,
	/* Outputs */
	output wire run,
	output wire halt,
	output wire quiesce,
	output wire mc_flush,
	output wire core_rst_n,
	output wire open,
	output wire [3:0] cp_state,
	output wire [2:0] host_kick,
	output wire step,
	output wire ev_halted,
	output wire ev_fault,
	output wire ev_wdt,
	output wire [31:0] aperture_base,
	output wire [31:0] aperture_limit
);
	`include "ghci_regs.vh"

	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_RUN = 3'd1;
	localparam [2:0] S_HALTING = 3'd2;
	localparam [2:0] S_HALTED = 3'd3;
	localparam [2:0] S_FAULTED = 3'd4;
	localparam [2:0] S_RS_WAIT = 3'd5;
	localparam [2:0] S_RS_PULSE = 3'd6;
	localparam [2:0] S_RS_REPLAY = 3'd7;

	localparam [9:0] I_STATUS       = HCR_IDX_STATUS;
	localparam [9:0] I_CTRL         = HCR_IDX_CTRL;
	localparam [9:0] I_FAULT_INFO   = HCR_IDX_FAULT_INFO;
	localparam [9:0] I_FAULT_ADDR   = HCR_IDX_FAULT_ADDR_LO;
	localparam [9:0] I_FAULT_ADDR_HI= HCR_IDX_FAULT_ADDR_HI;
	localparam [9:0] I_WDT          = HCR_IDX_WDT_CYCLES;
	localparam [9:0] I_HEAP_BASE    = HCR_IDX_CP_HEAP_BASE;
	localparam [9:0] I_HEAP_LIMIT   = HCR_IDX_CP_HEAP_LIMIT;
	localparam [9:0] I_RING_BASE_LO = HCR_IDX_RING_BASE_LO;
	localparam [9:0] I_RING_BASE_HI = HCR_IDX_RING_BASE_HI;
	localparam [9:0] I_RING_SIZE    = HCR_IDX_RING_SIZE;
	localparam [31:0] AP_MASK = ~((32'd1 << LINE_SHIFT) - 32'd1);

	(* max_fanout = 16 *) reg [2:0] st;
	reg ctrl_run;
	reg ctrl_halt;
	reg ctrl_wdt_en;
	reg [31:0] wdt_cycles;
	reg [31:0] ap_base;
	reg [31:0] ap_limit;
	reg [31:0] heap_base;
	reg [31:0] heap_limit;
	(* max_fanout = 16 *) reg [31:0] fault_addr;
	(* max_fanout = 16 *) reg [31:0] fault_info;
	reg [31:0] wdt_count;
	reg [33:0] stuck_count;
	/* The watchdog's and AXI_STUCK's counts + 1. */
	wire [31:0] wdt_count_n;
	wire [33:0] stuck_count_n;
	wire wdt_co, stuck_co;

	am_add #(.W(32)) wdt_add (.a(wdt_count), .b(32'd0), .ci(1'b1), .s(wdt_count_n), .co(wdt_co));
	am_add #(.W(34)) stuck_add (
		.a(stuck_count), .b(34'd0), .ci(1'b1), .s(stuck_count_n), .co(stuck_co)
	);
	reg axi_stuck;

	wire resetting = st == S_RS_WAIT || st == S_RS_PULSE || st == S_RS_REPLAY;
	wire faulted = st == S_FAULTED;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire rst_ctl_int;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_rst_ctl_inv (.I0(rst_n), .O(rst_ctl_int));

	(* keep = "true", dont_touch = "true" *) wire core_rst_n_sig;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h8AAA)) u_core_rst_n_lut (
		.I0(rst_n), .I1(st[0]), .I2(st[1]), .I3(st[2]), .O(core_rst_n_sig)
	);
	assign core_rst_n = core_rst_n_sig;
`else
	wire rst_ctl_int = ~rst_n;
	assign core_rst_n = rst_n && st != S_RS_PULSE;
`endif

	(* max_fanout = 16 *) reg [3:0] open_r;
	(* max_fanout = 16 *) reg [3:0] can_fault_r;
	(* DONT_TOUCH = "TRUE" *) reg [2:0] halt_r;
	(* DONT_TOUCH = "TRUE" *) reg st_is_run_r;
	assign open = open_r[0];
	wire halt_raw = st == S_HALTING || st == S_HALTED || faulted || resetting;
`ifdef SYNTH_KINTEX7
	assign run = st_is_run_r && ctrl_run;
	wire halt_int = halt_r[0];
	assign halt = halt_r[1];
	assign quiesce = halt_r[2];
`else
	assign run = st == S_RUN && ctrl_run;
	wire halt_int = halt_raw;
	assign halt = halt_raw;
	assign quiesce = halt_raw;
`endif
	assign mc_flush = st == S_RS_PULSE;
	/* Micro-architectural CP_STATE (§3.3) */
	wire cp_is_fault = faulted;
	wire cp_is_wait_mem = resetting || (st == S_HALTING && !mc_idle);
	wire cp_is_blit = busy_in[1]; /* blt_busy */
	wire cp_is_wait_fence = (seq_st == 4'd4 || seq_st == 4'd5 || f_busy); /* Q_FREQ, Q_FWAIT */
	wire cp_is_exec = (seq_st == 4'd1 || seq_st == 4'd2 || seq_st == 4'd3 || seq_st == 4'd6); /* Q_PAY, Q_EXEC, Q_POST, Q_VSYNC */
	wire cp_is_decode = (seq_st == 4'd8 || seq_st == 4'd9); /* Q_DEC, Q_DEC2 */
	wire cp_is_fetch = ring_busy || (!ring_empty && cmd_active);

	assign cp_state = cp_is_fault ? GHCI_ST_FAULT :
	                  cp_is_wait_mem ? GHCI_ST_WAIT_MEM :
	                  cp_is_blit ? GHCI_ST_BLIT :
	                  cp_is_wait_fence ? GHCI_ST_WAIT_FENCE :
	                  cp_is_exec ? GHCI_ST_EXEC :
	                  cp_is_decode ? GHCI_ST_DECODE :
	                  cp_is_fetch ? GHCI_ST_FETCH :
	                  GHCI_ST_IDLE;
	assign aperture_base = ap_base;
	assign aperture_limit = ap_limit;

	/* Host writes. */
	wire w0 = hcr_we && hcr_wmask[0];
	wire wr_ctrl = w0 && (hcr_widx == I_CTRL);
	wire wr_reset = wr_ctrl && hcr_wdata[GHCI_CTRL_RESET];
	assign step = wr_ctrl && hcr_wdata[GHCI_CTRL_STEP] && st == S_HALTED;

	assign host_kick = 3'd0;
	wire kick_absent = 1'b0;
	wire kick_bad = 1'b0;

	wire wr_locked = hcr_we && (
		hcr_widx == I_HEAP_BASE ||
		hcr_widx == I_HEAP_LIMIT ||
		hcr_widx == I_RING_BASE_LO ||
		hcr_widx == I_RING_BASE_HI ||
		hcr_widx == I_RING_SIZE
	);
	wire locked_bad = wr_locked && !open;
	wire wr_fault_info = hcr_we && (hcr_widx == I_FAULT_INFO);

`ifdef SYNTH_KINTEX7
	reg wdt_fire_r;
	always @(posedge clk) begin
		if (rst_ctl_int)
			wdt_fire_r <= 1'b0;
		else
			wdt_fire_r <= ctrl_wdt_en && cmd_active && (wdt_count >= wdt_cycles) && (st != S_FAULTED);
	end
	wire wdt_fire = wdt_fire_r;
`else
	wire wdt_fire = ctrl_wdt_en && cmd_active && wdt_count >= wdt_cycles && st != S_FAULTED;
`endif

	/* The first fault of this cycle. */
	/* The MC's refusals of client 0 (the CP) are its own units' faults, except
	 * those of session protection (a firmware µop's fence or result). */
	wire mc_gpu = mc_fault && (mc_fault_client != 8'd0 || mc_fault_prot || mc_fault_mem) &&
		!(mc_fault_client == DC_CLIENT && !mc_fault_prot && !mc_fault_mem);
	reg any;
	reg [31:0] n_info;
	reg [31:0] n_addr;
	integer k;

`ifdef SYNTH_KINTEX7
	wire [NSRC-1:0] sf_lo, sf_hi, sf_alo, sf_ahi;
	genvar g_sf;
	generate
		for (g_sf = 0; g_sf < NSRC; g_sf = g_sf + 1) begin : g_sf_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sflo  (.I0(src_fault[g_sf]), .O(sf_lo[g_sf]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sfhi  (.I0(src_fault[g_sf]), .O(sf_hi[g_sf]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sfalo (.I0(src_fault[g_sf]), .O(sf_alo[g_sf]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sfahi (.I0(src_fault[g_sf]), .O(sf_ahi[g_sf]));
		end
	endgenerate

	reg f_s0_v_c, f_s1_v_c, f_s2_v_c;
	reg [31:0] f_s0_info_c, f_s1_info_c, f_s2_info_c;
	reg [15:0] f_s0_addr_lo_c, f_s2_addr_lo_c;
	reg [15:0] f_s0_addr_hi_c, f_s2_addr_hi_c;
	wire [15:0] f_s1_addr_lo_c, f_s1_addr_hi_c;
	genvar g_s1a;
	generate
		for (g_s1a = 0; g_s1a < 16; g_s1a = g_s1a + 1) begin : g_s1_addr_mux
			(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'hF0F0CCAA)) u_s1_alo (
				.I0(src_addr[5*32 + g_s1a]),
				.I1(src_addr[4*32 + g_s1a]),
				.I2(src_addr[3*32 + g_s1a]),
				.I3(sf_alo[4]),
				.I4(sf_alo[3]),
				.O(f_s1_addr_lo_c[g_s1a])
			);
			(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'hF0F0CCAA)) u_s1_ahi (
				.I0(src_addr[5*32 + 16 + g_s1a]),
				.I1(src_addr[4*32 + 16 + g_s1a]),
				.I2(src_addr[3*32 + 16 + g_s1a]),
				.I3(sf_ahi[4]),
				.I4(sf_ahi[3]),
				.O(f_s1_addr_hi_c[g_s1a])
			);
		end
	endgenerate

	always @(*) begin
		f_s0_v_c = 1'b0;
		f_s0_info_c = 32'd0;
		f_s0_addr_lo_c = 16'd0;
		f_s0_addr_hi_c = 16'd0;
		for (k = 2; k >= 0; k = k - 1) begin
			if (sf_lo[k]) begin
				f_s0_v_c = 1'b1;
				f_s0_info_c[15:0] = {src_tag[k * 8 +: 8], SRC_BLOCK[k * 8 +: 4], src_kind[k * 4 +: 4]};
			end
			if (sf_alo[k]) begin
				f_s0_addr_lo_c = src_addr[k * 32 +: 16];
			end
			if (sf_hi[k]) begin
				f_s0_info_c[31:16] = 16'd0;
			end
			if (sf_ahi[k]) begin
				f_s0_addr_hi_c = src_addr[k * 32 + 16 +: 16];
			end
		end

		f_s1_v_c = 1'b0;
		f_s1_info_c = 32'd0;
		for (k = 5; k >= 3; k = k - 1) begin
			if (sf_lo[k]) begin
				f_s1_v_c = 1'b1;
				f_s1_info_c[15:0] = {src_tag[k * 8 +: 8], SRC_BLOCK[k * 8 +: 4], src_kind[k * 4 +: 4]};
			end
			if (sf_hi[k]) begin
				f_s1_info_c[31:16] = 16'd0;
			end
		end

		f_s2_v_c = 1'b0;
		f_s2_info_c = 32'd0;
		f_s2_addr_lo_c = 16'd0;
		f_s2_addr_hi_c = 16'd0;
		for (k = NSRC - 1; k >= 6; k = k - 1) begin
			if (sf_lo[k]) begin
				f_s2_v_c = 1'b1;
				f_s2_info_c[15:0] = {src_tag[k * 8 +: 8], SRC_BLOCK[k * 8 +: 4], src_kind[k * 4 +: 4]};
			end
			if (sf_alo[k]) begin
				f_s2_addr_lo_c = src_addr[k * 32 +: 16];
			end
			if (sf_hi[k]) begin
				f_s2_info_c[31:16] = 16'd0;
			end
			if (sf_ahi[k]) begin
				f_s2_addr_hi_c = src_addr[k * 32 + 16 +: 16];
			end
		end
	end

	(* DONT_TOUCH = "TRUE" *) reg [7:0] f_mc_v_r, f_host_v_r, f_s0_v_r, f_s1_v_r, f_s2_v_r;
	reg f_wdt_only_r;
	reg [31:0] f_mc_info_r, f_mc_addr_r;
	reg [3:0] f_host_kind_r;
	reg [7:0] f_host_tag_r;
	reg [31:0] f_s0_info_r, f_s1_info_r, f_s2_info_r;
	reg [31:0] f_s0_addr_r, f_s1_addr_r, f_s2_addr_r;

	always @(posedge clk) begin
		if (rst_ctl_int) begin
			f_mc_v_r <= 8'd0;
			f_host_v_r <= 8'd0;
			f_s0_v_r <= 8'd0;
			f_s1_v_r <= 8'd0;
			f_s2_v_r <= 8'd0;
			f_wdt_only_r <= 1'b0;
			f_mc_info_r <= 32'd0;
			f_mc_addr_r <= 32'd0;
			f_host_kind_r <= 4'd0;
			f_host_tag_r <= 8'd0;
			f_s0_info_r <= 32'd0;
			f_s1_info_r <= 32'd0;
			f_s2_info_r <= 32'd0;
			f_s0_addr_r <= 32'd0;
			f_s1_addr_r <= 32'd0;
			f_s2_addr_r <= 32'd0;
		end else begin
			f_mc_v_r <= {8{mc_gpu}};
			f_mc_info_r <= {11'd0, mc_fault_write, 4'd0, mc_fault_tag, mc_fault_client[3:0],
				mc_fault_mem ? GHCI_FAULT_KIND_AXI_ERROR :
				(mc_fault_prot ? GHCI_FAULT_KIND_PERM_FAULT : GHCI_FAULT_KIND_PAGE_FAULT)};
			f_mc_addr_r <= mc_fault_addr;

			f_host_v_r <= {8{kick_bad || kick_absent || locked_bad || wdt_fire}};
			f_wdt_only_r <= wdt_fire && !mc_gpu && !kick_bad && !kick_absent && !locked_bad;
			f_host_kind_r <= kick_bad ? GHCI_FAULT_KIND_KICK_ABSENT :
				kick_absent ? GHCI_FAULT_KIND_INVALID_OP :
				locked_bad ? GHCI_FAULT_KIND_LOCKED_REG : GHCI_FAULT_KIND_WATCHDOG;
			f_host_tag_r <= (kick_bad || kick_absent || locked_bad) ? 8'd0 : wdt_tag;

			f_s0_v_r <= {8{f_s0_v_c}};
			f_s0_info_r <= f_s0_info_c;
			f_s0_addr_r <= {f_s0_addr_hi_c, f_s0_addr_lo_c};

			f_s1_v_r <= {8{f_s1_v_c}};
			f_s1_info_r <= f_s1_info_c;
			f_s1_addr_r <= {f_s1_addr_hi_c, f_s1_addr_lo_c};

			f_s2_v_r <= {8{f_s2_v_c}};
			f_s2_info_r <= f_s2_info_c;
			f_s2_addr_r <= {f_s2_addr_hi_c, f_s2_addr_lo_c};
		end
	end

	wire [31:0] f_host_info_w = {12'd0, 4'd0, f_host_tag_r, GHCI_FAULT_UNIT_CP, f_host_kind_r};

	always @(*) begin
		any = f_mc_v_r[0] || f_host_v_r[0] || f_s0_v_r[0] || f_s1_v_r[0] || f_s2_v_r[0];
		n_info[7:0] =
			f_mc_v_r[0]   ? f_mc_info_r[7:0] :
			f_host_v_r[0] ? f_host_info_w[7:0] :
			f_s0_v_r[0]   ? f_s0_info_r[7:0] :
			f_s1_v_r[0]   ? f_s1_info_r[7:0] : f_s2_info_r[7:0];
		n_info[15:8] =
			f_mc_v_r[1]   ? f_mc_info_r[15:8] :
			f_host_v_r[1] ? f_host_info_w[15:8] :
			f_s0_v_r[1]   ? f_s0_info_r[15:8] :
			f_s1_v_r[1]   ? f_s1_info_r[15:8] : f_s2_info_r[15:8];
		n_info[23:16] =
			f_mc_v_r[2]   ? f_mc_info_r[23:16] :
			f_host_v_r[2] ? f_host_info_w[23:16] :
			f_s0_v_r[2]   ? f_s0_info_r[23:16] :
			f_s1_v_r[2]   ? f_s1_info_r[23:16] : f_s2_info_r[23:16];
		n_info[31:24] =
			f_mc_v_r[3]   ? f_mc_info_r[31:24] :
			f_host_v_r[3] ? f_host_info_w[31:24] :
			f_s0_v_r[3]   ? f_s0_info_r[31:24] :
			f_s1_v_r[3]   ? f_s1_info_r[31:24] : f_s2_info_r[31:24];
		n_addr[7:0] =
			f_mc_v_r[4]   ? f_mc_addr_r[7:0] :
			f_host_v_r[4] ? 8'd0 :
			f_s0_v_r[4]   ? f_s0_addr_r[7:0] :
			f_s1_v_r[4]   ? f_s1_addr_r[7:0] : f_s2_addr_r[7:0];
		n_addr[15:8] =
			f_mc_v_r[5]   ? f_mc_addr_r[15:8] :
			f_host_v_r[5] ? 8'd0 :
			f_s0_v_r[5]   ? f_s0_addr_r[15:8] :
			f_s1_v_r[5]   ? f_s1_addr_r[15:8] : f_s2_addr_r[15:8];
		n_addr[23:16] =
			f_mc_v_r[6]   ? f_mc_addr_r[23:16] :
			f_host_v_r[6] ? 8'd0 :
			f_s0_v_r[6]   ? f_s0_addr_r[23:16] :
			f_s1_v_r[6]   ? f_s1_addr_r[23:16] : f_s2_addr_r[23:16];
		n_addr[31:24] =
			f_mc_v_r[7]   ? f_mc_addr_r[31:24] :
			f_host_v_r[7] ? 8'd0 :
			f_s0_v_r[7]   ? f_s0_addr_r[31:24] :
			f_s1_v_r[7]   ? f_s1_addr_r[31:24] : f_s2_addr_r[31:24];
	end

	wire take_fault = any && can_fault_r[0];
	wire take_fault_st = any && can_fault_r[1];
	wire take_fault_info = any && can_fault_r[2];
	wire take_fault_addr = any && can_fault_r[3];
	assign ev_fault = take_fault;
	assign ev_wdt = f_wdt_only_r && take_fault;
	assign ev_halted = st == S_HALTING && ctrl_halt && mc_idle && !ring_busy && !take_fault &&
		!wr_reset;
`else
	always @(*) begin
		any = 1'b1;
		n_addr = 32'd0;
		n_info = 32'd0;
		if (mc_gpu) begin
			n_info = {11'd0, mc_fault_write, 4'd0, mc_fault_tag, mc_fault_client[3:0],
				mc_fault_mem ? GHCI_FAULT_KIND_AXI_ERROR :
				(mc_fault_prot ? GHCI_FAULT_KIND_PERM_FAULT : GHCI_FAULT_KIND_PAGE_FAULT)};
			n_addr = mc_fault_addr;
		end else if (kick_bad) begin
			n_info = {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_KICK_ABSENT};
		end else if (kick_absent) begin
			n_info = {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_INVALID_OP};
		end else if (locked_bad) begin
			n_info = {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_LOCKED_REG};
		end else if (wdt_fire) begin
			n_info = {12'd0, 4'd0, wdt_tag, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_WATCHDOG};
		end else begin
			any = 1'b0;
			for (k = NSRC - 1; k >= 0; k = k - 1)
				if (src_fault[k]) begin
					any = 1'b1;
					n_info = {12'd0, 4'd0, src_tag[k * 8 +: 8], SRC_BLOCK[k * 8 +: 4],
						src_kind[k * 4 +: 4]};
					n_addr = src_addr[k * 32 +: 32];
				end
		end
	end

	wire take_fault = any && can_fault_r[0];
	wire take_fault_st = any && can_fault_r[1];
	wire take_fault_info = any && can_fault_r[2];
	wire take_fault_addr = any && can_fault_r[3];
	assign ev_fault = take_fault;
	assign ev_wdt = wdt_fire && take_fault && !mc_gpu && !kick_bad && !kick_absent && !locked_bad;
	assign ev_halted = st == S_HALTING && ctrl_halt && mc_idle && !ring_busy && !take_fault &&
		!wr_reset;
`endif

`ifdef SYNTH_KINTEX7
	wire [5:0] tf_buf;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tf0 (.I0(take_fault_info), .O(tf_buf[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tf1 (.I0(take_fault_info), .O(tf_buf[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tf2 (.I0(take_fault_info), .O(tf_buf[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tf3 (.I0(take_fault_info), .O(tf_buf[3]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tf4 (.I0(take_fault_addr), .O(tf_buf[4]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_tf5 (.I0(take_fault_addr), .O(tf_buf[5]));

	(* keep = "true", dont_touch = "true" *) wire [5:0] fault_rst_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_frst0 (.I0(rst_ctl_int), .I1(st == S_RS_PULSE), .O(fault_rst_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_frst1 (.I0(rst_ctl_int), .I1(st == S_RS_PULSE), .O(fault_rst_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_frst2 (.I0(rst_ctl_int), .I1(st == S_RS_PULSE), .O(fault_rst_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_frst3 (.I0(rst_ctl_int), .I1(st == S_RS_PULSE), .O(fault_rst_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_frst4 (.I0(rst_ctl_int), .I1(st == S_RS_PULSE), .O(fault_rst_b[4]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_frst5 (.I0(rst_ctl_int), .I1(st == S_RS_PULSE), .O(fault_rst_b[5]));

	(* keep = "true", dont_touch = "true" *) wire [1:0] wdt_cnt_rst_b;
	wire wdt_cnt_clr = !(ctrl_wdt_en && cmd_active && !faulted);
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_wcr0 (.I0(rst_ctl_int), .I1(wdt_cnt_clr), .O(wdt_cnt_rst_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_wcr1 (.I0(rst_ctl_int), .I1(wdt_cnt_clr), .O(wdt_cnt_rst_b[1]));

	(* keep = "true", dont_touch = "true" *) wire [1:0] stuck_cnt_rst_b;
	reg mc_idle_stuck_r;
	always @(posedge clk) begin
		if (rst_ctl_int)
			mc_idle_stuck_r <= 1'b1;
		else
			mc_idle_stuck_r <= mc_idle;
	end
	(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hFB)) u_scr0 (.I0(rst_ctl_int), .I1(halt_int), .I2(mc_idle_stuck_r), .O(stuck_cnt_rst_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hFB)) u_scr1 (.I0(rst_ctl_int), .I1(halt_int), .I2(mc_idle_stuck_r), .O(stuck_cnt_rst_b[1]));

	wire wr_wdt = hcr_we && (hcr_widx == I_WDT);
	wire [1:0] wr_wdt_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ww0 (.I0(wr_wdt), .O(wr_wdt_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ww1 (.I0(wr_wdt), .O(wr_wdt_b[1]));

	wire wr_heap_b = hcr_we && open_r[1] && (hcr_widx == I_HEAP_BASE);
	wire [1:0] wr_heap_b_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_whpb0 (.I0(wr_heap_b), .O(wr_heap_b_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_whpb1 (.I0(wr_heap_b), .O(wr_heap_b_b[1]));

	wire wr_heap_l = hcr_we && open_r[2] && (hcr_widx == I_HEAP_LIMIT);
	wire [1:0] wr_heap_l_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_whpl0 (.I0(wr_heap_l), .O(wr_heap_l_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_whpl1 (.I0(wr_heap_l), .O(wr_heap_l_b[1]));

	wire stuck_en = halt_int && !mc_idle_stuck_r && !(stuck_count >= {wdt_cycles, 2'b00});
	wire [1:0] stuck_en_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_stuck0 (.I0(stuck_en), .O(stuck_en_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_stuck1 (.I0(stuck_en), .O(stuck_en_b[1]));

	wire wdt_cnt_en = ctrl_wdt_en && cmd_active && !faulted && !wdt_hold;
	wire [1:0] wdt_cnt_en_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wce0 (.I0(wdt_cnt_en), .O(wdt_cnt_en_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wce1 (.I0(wdt_cnt_en), .O(wdt_cnt_en_b[1]));

	always @(posedge clk) begin
		if (fault_rst_b[0]) fault_info[7:0] <= 8'd0;
		else if (tf_buf[0]) fault_info[7:0] <= n_info[7:0];
		else if (wr_fault_info) fault_info[7:0] <= fault_info[7:0] & ~(hcr_wdata[7:0] & hcr_wmask[7:0]);

		if (fault_rst_b[1]) fault_info[15:8] <= 8'd0;
		else if (tf_buf[1]) fault_info[15:8] <= n_info[15:8];
		else if (wr_fault_info) fault_info[15:8] <= fault_info[15:8] & ~(hcr_wdata[15:8] & hcr_wmask[15:8]);

		if (fault_rst_b[2]) fault_info[23:16] <= 8'd0;
		else if (tf_buf[2]) fault_info[23:16] <= n_info[23:16];
		else if (wr_fault_info) fault_info[23:16] <= fault_info[23:16] & ~(hcr_wdata[23:16] & hcr_wmask[23:16]);

		if (fault_rst_b[3]) fault_info[31:24] <= 8'd0;
		else if (tf_buf[3]) fault_info[31:24] <= n_info[31:24];
		else if (wr_fault_info) fault_info[31:24] <= fault_info[31:24] & ~(hcr_wdata[31:24] & hcr_wmask[31:24]);

		if (fault_rst_b[4]) fault_addr[15:0] <= 16'd0;
		else if (tf_buf[4]) fault_addr[15:0] <= n_addr[15:0];

		if (fault_rst_b[5]) fault_addr[31:16] <= 16'd0;
		else if (tf_buf[5]) fault_addr[31:16] <= n_addr[31:16];

		if (wdt_cnt_rst_b[0]) wdt_count[15:0] <= 16'd0;
		else if (wdt_cnt_en_b[0]) wdt_count[15:0] <= wdt_count_n[15:0];

		if (wdt_cnt_rst_b[1]) wdt_count[31:16] <= 16'd0;
		else if (wdt_cnt_en_b[1]) wdt_count[31:16] <= wdt_count_n[31:16];

		if (stuck_cnt_rst_b[0]) stuck_count[16:0] <= 17'd0;
		else if (stuck_en_b[0]) stuck_count[16:0] <= stuck_count_n[16:0];

		if (stuck_cnt_rst_b[1]) stuck_count[33:17] <= 17'd0;
		else if (stuck_en_b[1]) stuck_count[33:17] <= stuck_count_n[33:17];
	end
`endif

	always @(posedge clk) begin
		if (rst_ctl_int) begin
			st <= S_IDLE;
			open_r <= 4'b1111;
			can_fault_r <= 4'b1111;
			halt_r <= 3'b000;
			st_is_run_r <= 1'b0;
			ctrl_run <= 1'b0;
			ctrl_halt <= 1'b0;
			ctrl_wdt_en <= 1'b0;
			wdt_cycles <= WDT_RESET;
			ap_base <= 32'd0;
			ap_limit <= 32'hFFFFFFFF;
			heap_base <= 32'd0;
			heap_limit <= 32'd0;
`ifndef SYNTH_KINTEX7
			fault_addr <= 32'd0;
			fault_info <= 32'd0;
			wdt_count <= 32'd0;
			stuck_count <= 34'd0;
`endif
			axi_stuck <= 1'b0;
		end else begin
			/* Registers. */
			if (wr_ctrl) begin
				ctrl_run <= hcr_wdata[GHCI_CTRL_RUN];
				ctrl_halt <= hcr_wdata[GHCI_CTRL_HALT];
				ctrl_wdt_en <= hcr_wdata[GHCI_CTRL_WDT_EN];
			end
`ifdef SYNTH_KINTEX7
			if (wr_wdt_b[0]) wdt_cycles[15:0] <= (wdt_cycles[15:0] & ~hcr_wmask[15:0]) | (hcr_wdata[15:0] & hcr_wmask[15:0]);
			if (wr_wdt_b[1]) wdt_cycles[31:16] <= (wdt_cycles[31:16] & ~hcr_wmask[31:16]) | (hcr_wdata[31:16] & hcr_wmask[31:16]);
			if (wr_heap_b_b[0]) heap_base[15:0] <= (heap_base[15:0] & ~hcr_wmask[15:0]) | (hcr_wdata[15:0] & hcr_wmask[15:0]);
			if (wr_heap_b_b[1]) heap_base[31:16] <= (heap_base[31:16] & ~hcr_wmask[31:16]) | (hcr_wdata[31:16] & hcr_wmask[31:16]);
			if (wr_heap_l_b[0]) heap_limit[15:0] <= (heap_limit[15:0] & ~hcr_wmask[15:0]) | (hcr_wdata[15:0] & hcr_wmask[15:0]);
			if (wr_heap_l_b[1]) heap_limit[31:16] <= (heap_limit[31:16] & ~hcr_wmask[31:16]) | (hcr_wdata[31:16] & hcr_wmask[31:16]);
			if (halt_int && !mc_idle_stuck_r && (stuck_count >= {wdt_cycles, 2'b00}))
				axi_stuck <= 1'b1;
`else
			if (hcr_we && hcr_widx == I_WDT)
				wdt_cycles <= (wdt_cycles & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			if (hcr_we && open && hcr_widx == I_HEAP_BASE)
				heap_base <= (heap_base & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			if (hcr_we && open && hcr_widx == I_HEAP_LIMIT)
				heap_limit <= (heap_limit & ~hcr_wmask) | (hcr_wdata & hcr_wmask);

			/* The watchdog. */
			if (ctrl_wdt_en && cmd_active && !faulted) begin
				if (!wdt_hold)
					wdt_count <= wdt_count_n;
			end else begin
				wdt_count <= 32'd0;
			end

			/* AXI_STUCK: quiesced for 4 * WDT_CYCLES without AXI_IDLE. */
			if (quiesce && !mc_idle) begin
				if (stuck_count >= {wdt_cycles, 2'b00})
					axi_stuck <= 1'b1;
				else
					stuck_count <= stuck_count_n;
			end else begin
				stuck_count <= 34'd0;
			end

			if (take_fault) begin
				fault_info <= n_info;
				fault_addr <= n_addr;
			end else if (wr_fault_info) begin
				fault_info <= fault_info & ~(hcr_wdata & hcr_wmask);
			end
`endif

			/* The state. */
			if (wr_reset && !resetting) begin
				st <= S_RS_WAIT;
				open_r <= 4'b0000;
				can_fault_r <= 4'b0000;
				halt_r <= 3'b111;
				st_is_run_r <= 1'b0;
			end else if (take_fault_st) begin
				st <= S_FAULTED;
				open_r <= 4'b0000;
				can_fault_r <= 4'b0000;
				halt_r <= 3'b111;
				st_is_run_r <= 1'b0;
			end else begin
				case (st)
				S_IDLE:
					if (ctrl_halt) begin
						st <= S_HALTING;
						open_r <= 4'b0000;
						halt_r <= 3'b111;
						st_is_run_r <= 1'b0;
					end else if (ctrl_run) begin
						st <= S_RUN;
						open_r <= 4'b0000;
						halt_r <= 3'b000;
						st_is_run_r <= 1'b1;
					end else begin
						open_r <= 4'b1111;
						can_fault_r <= 4'b1111;
						halt_r <= 3'b000;
						st_is_run_r <= 1'b0;
					end
				S_RUN:
					if (ctrl_halt) begin
						st <= S_HALTING;
						open_r <= 4'b0000;
						halt_r <= 3'b111;
						st_is_run_r <= 1'b0;
					end else if (!ctrl_run && !busy_in[0]) begin
						st <= S_IDLE;
						open_r <= 4'b1111;
						halt_r <= 3'b000;
						st_is_run_r <= 1'b0;
					end else begin
						open_r <= 4'b0000;
						can_fault_r <= 4'b1111;
						halt_r <= 3'b000;
						st_is_run_r <= 1'b1;
					end
				S_HALTING:
					if (!ctrl_halt) begin
						st <= ctrl_run ? S_RUN : S_IDLE;
						open_r <= {4{!ctrl_run}};
						halt_r <= 3'b000;
						st_is_run_r <= ctrl_run;
					end else if (mc_idle && !ring_busy) begin
						st <= S_HALTED;
						open_r <= 4'b1111;
						halt_r <= 3'b111;
						st_is_run_r <= 1'b0;
					end else begin
						open_r <= 4'b0000;
						can_fault_r <= 4'b1111;
						halt_r <= 3'b111;
						st_is_run_r <= 1'b0;
					end
				S_HALTED:
					if (!ctrl_halt) begin
						st <= ctrl_run ? S_RUN : S_IDLE;
						open_r <= {4{!ctrl_run}};
						halt_r <= 3'b000;
						st_is_run_r <= ctrl_run;
					end else begin
						open_r <= 4'b1111;
						can_fault_r <= 4'b1111;
						halt_r <= 3'b111;
						st_is_run_r <= 1'b0;
					end
				S_RS_WAIT: begin
					open_r <= 4'b0000;
					can_fault_r <= 4'b0000;
					halt_r <= 3'b111;
					st_is_run_r <= 1'b0;
					if (mc_idle)
						st <= S_RS_PULSE;
				end
				S_RS_PULSE: begin
					open_r <= 4'b0000;
					can_fault_r <= 4'b0000;
					halt_r <= 3'b111;
					st_is_run_r <= 1'b0;
					st <= S_RS_REPLAY;
					ctrl_run <= 1'b0;
					ctrl_halt <= 1'b0;
`ifndef SYNTH_KINTEX7
					fault_addr <= 32'd0;
					fault_info <= 32'd0;
`endif
					axi_stuck <= 1'b0;
				end
				S_RS_REPLAY: begin
					if (!replay_busy) begin
						st <= S_IDLE;
						open_r <= 4'b1111;
						can_fault_r <= 4'b1111;
						halt_r <= 3'b000;
						st_is_run_r <= 1'b0;
					end else begin
						open_r <= 4'b0000;
						can_fault_r <= 4'b0000;
						halt_r <= 3'b111;
						st_is_run_r <= 1'b0;
					end
				end
				default: begin
					open_r <= 4'b0000;
					can_fault_r <= 4'b0000;
					halt_r <= 3'b111;
					st_is_run_r <= 1'b0;
				end
				endcase
			end
		end
	end

	/* Reads. */
	wire [31:0] status = {12'd0, cp_state, 1'b0, quiesce, axi_stuck, mem_ready, ring_empty,
		2'd0, mc_idle, 5'd0, faulted, st == S_HALTED, run && !halt};

	reg [31:0] rd;

	always @(*) begin
		case (hcr_ridx)
		I_STATUS:        rd = status;
		I_CTRL:          rd = {25'd0, 1'b0, ctrl_wdt_en, 1'b0, 1'b0, ctrl_halt, ctrl_run, resetting};
		I_FAULT_INFO:    rd = fault_info;
		I_FAULT_ADDR:    rd = fault_addr;
		I_FAULT_ADDR_HI: rd = 32'd0;
		I_WDT:           rd = wdt_cycles;
		I_HEAP_BASE:     rd = heap_base;
		I_HEAP_LIMIT:    rd = heap_limit;
		default:         rd = 32'd0;
		endcase
	end

	assign hcr_rdata = rd;
	wire unused_co = &{1'b0, wdt_co, stuck_co, hcr_ridx[9:6]};
endmodule

`default_nettype wire
