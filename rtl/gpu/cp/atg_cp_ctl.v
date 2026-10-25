/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ctl: the CP's state machine (design §2.6): CTRL (RUN, RESET,
 * HALT, STEP, WDT_EN), STATUS, KICK from the host, HALT and quiesce, the
 * RESET order of design §1.3 (with the STATE replay), the watchdog,
 * AXI_STUCK, the aperture registers and FAULT_ADDR/FAULT_INFO from all
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
 * (KICK, locked write, watchdog), then src 0..NSRC-1):
 *   MC refusal of client c != 0: FAULT_INFO {0, c, 1, 0, write, c}
 *   src k: {tag, SRC_BLOCK[k], kind, 0, 0, SRC_CLIENT[k]}, FAULT_ADDR addr
 *   KICK not open or unit busy: kind 6; KICK of an absent unit: kind 2;
 *   RING_BASE/SIZE, APERTURE_*, CP_HEAP_* written when not open: kind 7.
 * MC refusals of client 0 (the CP's own port) are reported by the ring,
 * the fence unit or the debug port themselves.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_ctl #(
	parameter NSRC = 8,	/* Number of fault sources (0 ring, 1 seq, 2 state, 3 fence, 4 SU, 5 CPU, 6 BLT, 7 other blocks) */
	parameter WDT_RESET = 32'h10000000,	/* WDT_CYCLES after reset (2^28) */
	parameter LINE_SHIFT = 5,	/* log2 of the line size: the aperture's alignment */
	parameter [7:0] UNITS = 8'h03,	/* Present blocks, STATUS busy-bit order (KICK.DRAW: 2, DISPATCH: 6) */
	parameter [NSRC*8-1:0] SRC_BLOCK = 64'h00_01_00_06_00_00_00_00,	/* FAULT_INFO[23:16] per source */
	parameter [NSRC*8-1:0] SRC_CLIENT = 64'h00_01_00_00_00_00_00_00	/* FAULT_INFO[7:0] per source */
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
	input wire mc_fault,
	input wire [7:0] mc_fault_client,
	input wire [31:0] mc_fault_addr,
	input wire mc_fault_write,
	input wire mc_fault_prot,	/* refused for session protection: FAULT_INFO[9] */
	input wire mc_fault_mem,	/* a protection table read failed: kind 5 */
	input wire [7:0] mc_fault_tag,
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

	localparam [9:0] I_CTRL = GHCI_CTRL[11:2];
	localparam [9:0] I_STATUS = GHCI_STATUS[11:2];
	localparam [9:0] I_WDT = GHCI_WDT_CYCLES[11:2];
	localparam [9:0] I_RING_BASE = GHCI_RING_BASE[11:2];
	localparam [9:0] I_RING_SIZE = GHCI_RING_SIZE[11:2];
	localparam [9:0] I_AP_BASE = GHCI_APERTURE_BASE[11:2];
	localparam [9:0] I_AP_LIMIT = GHCI_APERTURE_LIMIT[11:2];
	localparam [9:0] I_FAULT_ADDR = GHCI_FAULT_ADDR[11:2];
	localparam [9:0] I_FAULT_INFO = GHCI_FAULT_INFO[11:2];
	localparam [9:0] I_HEAP_BASE = 10'h02C;	/* CP_HEAP_BASE 0x0B0 */
	localparam [9:0] I_HEAP_LIMIT = 10'h02D;	/* CP_HEAP_LIMIT 0x0B4 */
	localparam [9:0] I_KICK = GHCI_KICK[11:2];
	localparam [31:0] AP_MASK = ~((32'd1 << LINE_SHIFT) - 32'd1);

	reg [2:0] st;
	reg ctrl_run;
	reg ctrl_halt;
	reg ctrl_wdt_en;
	reg [31:0] wdt_cycles;
	reg [31:0] ap_base;
	reg [31:0] ap_limit;
	reg [31:0] fault_addr;
	reg [31:0] fault_info;
	reg [31:0] wdt_count;
	reg [33:0] stuck_count;
	reg axi_stuck;

	wire resetting = st == S_RS_WAIT || st == S_RS_PULSE || st == S_RS_REPLAY;
	wire faulted = st == S_FAULTED;
	assign open = st == S_IDLE || st == S_HALTED;
	assign run = st == S_RUN && ctrl_run;
	assign halt = st == S_HALTING || st == S_HALTED || faulted || resetting;
	assign quiesce = halt;
	assign mc_flush = st == S_RS_PULSE;
	assign core_rst_n = rst_n && st != S_RS_PULSE;
	assign cp_state = resetting ? GHCI_ST_RESETTING : faulted ? GHCI_ST_FAULTED :
		st == S_HALTED ? GHCI_ST_HALTED : st == S_HALTING ? GHCI_ST_HALTING :
		st == S_RUN ? GHCI_ST_RUNNING : GHCI_ST_IDLE;
	assign aperture_base = ap_base;
	assign aperture_limit = ap_limit;

	/* Host writes. */
	wire w0 = hcr_we && hcr_wmask[0];
	wire wr_ctrl = w0 && hcr_widx == I_CTRL;
	wire wr_reset = wr_ctrl && hcr_wdata[GHCI_CTRL_RESET];
	assign step = wr_ctrl && hcr_wdata[GHCI_CTRL_STEP] && st == S_HALTED;

	wire wr_kick = w0 && hcr_widx == I_KICK;
	wire [2:0] kick_bits = wr_kick ? {hcr_wdata[GHCI_KICK_DISPATCH], hcr_wdata[GHCI_KICK_DRAW],
		hcr_wdata[GHCI_KICK_BLIT]} : 3'd0;
	wire [2:0] kick_present = {UNITS[6], UNITS[2], UNITS[1]};
	wire [2:0] kick_busy = {busy_in[6], busy_in[2], busy_in[1]};
	wire [2:0] kick_ok = kick_bits & kick_present & ~kick_busy & {3{open}};
	assign host_kick = kick_ok;
	wire kick_absent = |(kick_bits & ~kick_present);
	wire kick_bad = |(kick_bits & kick_present & ~kick_ok);

	wire wr_locked = hcr_we && (hcr_widx == I_RING_BASE || hcr_widx == I_RING_SIZE ||
		hcr_widx == I_AP_BASE || hcr_widx == I_AP_LIMIT || hcr_widx == I_HEAP_BASE ||
		hcr_widx == I_HEAP_LIMIT);
	wire locked_bad = wr_locked && !open;

	wire wdt_fire = ctrl_wdt_en && cmd_active && wdt_count >= wdt_cycles && st != S_FAULTED;

	/* The first fault of this cycle. */
	/* The MC's refusals of client 0 (the CP) are its own units' faults, except
	 * those of session protection (a firmware µop's fence or result). */
	wire mc_gpu = mc_fault && (mc_fault_client != 8'd0 || mc_fault_prot || mc_fault_mem);
	reg any;
	reg [31:0] n_info;
	reg [31:0] n_addr;
	integer k;

	always @(*) begin
		any = 1'b1;
		n_addr = 32'd0;
		n_info = 32'd0;
		if (mc_gpu) begin
			n_info = {mc_fault_tag, mc_fault_client,
				mc_fault_mem ? GHCI_FAULT_AXI : GHCI_FAULT_APERTURE, 2'd0, mc_fault_prot,
				mc_fault_write, mc_fault_client};
			n_addr = mc_fault_addr;
		end else if (kick_bad) begin
			n_info = {16'd0, GHCI_FAULT_KICK, 12'd0};
		end else if (kick_absent) begin
			n_info = {16'd0, GHCI_FAULT_OPCODE, 12'd0};
		end else if (locked_bad) begin
			n_info = {16'd0, GHCI_FAULT_LOCKED, 12'd0};
		end else if (wdt_fire) begin
			n_info = {16'd0, GHCI_FAULT_WATCHDOG, 12'd0};
		end else begin
			any = 1'b0;
			for (k = NSRC - 1; k >= 0; k = k - 1)
				if (src_fault[k]) begin
					any = 1'b1;
					n_info = {src_tag[k * 8 +: 8], SRC_BLOCK[k * 8 +: 8], src_kind[k * 4 +: 4],
						4'd0, SRC_CLIENT[k * 8 +: 8]};
					n_addr = src_addr[k * 32 +: 32];
				end
		end
	end

	wire take_fault = any && !faulted && !resetting;
	assign ev_fault = take_fault;
	assign ev_wdt = wdt_fire && take_fault && !mc_gpu && !kick_bad && !kick_absent && !locked_bad;
	assign ev_halted = st == S_HALTING && ctrl_halt && mc_idle && !ring_busy && !take_fault &&
		!wr_reset;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			ctrl_run <= 1'b0;
			ctrl_halt <= 1'b0;
			ctrl_wdt_en <= 1'b0;
			wdt_cycles <= WDT_RESET;
			ap_base <= 32'd0;
			ap_limit <= 32'd0;
			fault_addr <= 32'd0;
			fault_info <= 32'd0;
			wdt_count <= 32'd0;
			stuck_count <= 34'd0;
			axi_stuck <= 1'b0;
		end else begin
			/* Registers. */
			if (wr_ctrl) begin
				ctrl_run <= hcr_wdata[GHCI_CTRL_RUN];
				ctrl_halt <= hcr_wdata[GHCI_CTRL_HALT];
				ctrl_wdt_en <= hcr_wdata[GHCI_CTRL_WDT_EN];
			end
			if (hcr_we && hcr_widx == I_WDT)
				wdt_cycles <= (wdt_cycles & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			if (hcr_we && open && hcr_widx == I_AP_BASE)
				ap_base <= ((ap_base & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & AP_MASK;
			if (hcr_we && open && hcr_widx == I_AP_LIMIT)
				ap_limit <= ((ap_limit & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & AP_MASK;

			/* The watchdog. */
			if (ctrl_wdt_en && cmd_active && !faulted) begin
				if (!wdt_hold)
					wdt_count <= wdt_count + 32'd1;
			end else begin
				wdt_count <= 32'd0;
			end

			/* AXI_STUCK: quiesced for 4 * WDT_CYCLES without AXI_IDLE. */
			if (quiesce && !mc_idle) begin
				if (stuck_count >= {wdt_cycles, 2'b00})
					axi_stuck <= 1'b1;
				else
					stuck_count <= stuck_count + 34'd1;
			end else begin
				stuck_count <= 34'd0;
			end

			if (take_fault) begin
				fault_info <= n_info;
				fault_addr <= n_addr;
			end

			/* The state. */
			if (wr_reset && !resetting) begin
				st <= S_RS_WAIT;
			end else if (take_fault) begin
				st <= S_FAULTED;
			end else begin
				case (st)
				S_IDLE:
					if (ctrl_halt)
						st <= S_HALTING;
					else if (ctrl_run)
						st <= S_RUN;
				S_RUN:
					if (ctrl_halt)
						st <= S_HALTING;
					else if (!ctrl_run && !busy_in[0])
						st <= S_IDLE;
				S_HALTING:
					if (!ctrl_halt)
						st <= ctrl_run ? S_RUN : S_IDLE;
					else if (mc_idle && !ring_busy)
						st <= S_HALTED;
				S_HALTED:
					if (!ctrl_halt)
						st <= ctrl_run ? S_RUN : S_IDLE;
				S_RS_WAIT:
					if (mc_idle)
						st <= S_RS_PULSE;
				S_RS_PULSE: begin
					st <= S_RS_REPLAY;
					ctrl_run <= 1'b0;
					ctrl_halt <= 1'b0;
					fault_addr <= 32'd0;
					fault_info <= 32'd0;
					axi_stuck <= 1'b0;
				end
				S_RS_REPLAY:
					if (!replay_busy)
						st <= S_IDLE;
				default:
					;
				endcase
			end
		end
	end

	/* Reads. */
	wire [31:0] status = {12'd0, cp_state, 1'b0, quiesce, axi_stuck, mem_ready, ring_empty,
		st == S_HALTED, faulted, mc_idle, busy_in[7:1], busy_in[0] || resetting};

	reg [31:0] rd;

	always @(*) begin
		case (hcr_ridx)
		I_CTRL: rd = {27'd0, ctrl_wdt_en, 1'b0, ctrl_halt, resetting, ctrl_run};
		I_STATUS: rd = status;
		I_WDT: rd = wdt_cycles;
		I_AP_BASE: rd = ap_base;
		I_AP_LIMIT: rd = ap_limit;
		I_FAULT_ADDR: rd = fault_addr;
		I_FAULT_INFO: rd = fault_info;
		default: rd = 32'd0;
		endcase
	end

	assign hcr_rdata = rd;
endmodule

`default_nettype wire
