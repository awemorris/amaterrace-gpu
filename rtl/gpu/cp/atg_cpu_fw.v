/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_fw: The CPFW extended capability (design §2.4.10): CPFW_CTRL/
 * STATUS/IBASE/IWORDS/DBASE/DWORDS/VERSION (HCR 0x120-0x138) and
 * MBOX0-3 (0x150-0x15C), the image reload sequence, the core's run/reset,
 * and the firmware fault report.
 *
 * rst_n is the CP's core reset (CTRL.RESET).  IBASE/IWORDS/DBASE/DWORDS
 * and STATUS.READY are not reset (they survive RESET, design §2.6; READY
 * is 1 from configuration because the bitstream holds the image).
 * LOAD (CTRL[0], W1S) is taken only when open and the core is stopped or
 * held in reset: the core is held in reset, IMEM is loaded from
 * IBASE/IWORDS and DMEM from DBASE/DWORDS through atg_cpu_dma, then READY
 * (or, on an error, FAULT with READY 0 and the core kept in reset).
 * core_run = CTRL.RUN and not parked: with CTRL.HALT or halt_req, the
 * firmware finishes its packet and writes FW_STATUS with [16] PARK; the
 * core then stops, and runs on when the halt request is gone.  A core
 * fault sets FAULT, pulses fault with the PC and holds the core in reset
 * until RESET.  See spec/gpu/cp/atg_cpu_fw.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_fw (
	input wire clk,
	input wire rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output reg [31:0] hcr_rdata,
	/* Window sub-bus (from atg_cpu_win) */
	input wire sb_we,
	input wire sb_re,
	input wire [5:0] sb_idx,
	input wire [31:0] sb_wdata,
	output reg [31:0] sb_rdata,
	/* To atg_cpu_dma */
	output reg ld_start,
	output reg ld_imem,
	output reg [31:0] ld_addr,
	output reg [31:0] ld_words,
	input wire ld_done,
	input wire ld_error,
	/* Core control */
	output wire core_rst_n,
	output wire core_run,
	input wire core_stopped,
	input wire core_fault,
	input wire [31:0] core_fault_pc,
	input wire halt_req,
	input wire open,
	/* Fault (to atg_cp_ctl, source 5) */
	output reg fault,
	output reg [31:0] fault_addr,
	/* State (to diagnostics) */
	output wire [7:0] fw_curr_state
);
`include "ghci_regs.vh"

	localparam [9:0] R_CTRL = GHCI_CPFW_CTRL[11:2];
	localparam [9:0] R_STATUS = GHCI_CPFW_STATUS[11:2];
	localparam [9:0] R_IBASE = GHCI_CPFW_IBASE[11:2];
	localparam [9:0] R_IWORDS = GHCI_CPFW_IWORDS[11:2];
	localparam [9:0] R_DBASE = GHCI_CPFW_DBASE[11:2];
	localparam [9:0] R_DWORDS = GHCI_CPFW_DWORDS[11:2];
	localparam [9:0] R_VERSION = GHCI_CPFW_VERSION[11:2];
	localparam [9:0] R_MBOX0 = GHCI_CPFW_MBOX0[11:2];

	/* Window indices. */
	localparam [5:0] W_FW_STATUS = 6'h20;
	localparam [5:0] W_MBOX0 = 6'h21;
	localparam [5:0] W_FW_VERSION = 6'h25;

	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_LOAD_I = 2'd1;
	localparam [1:0] S_LOAD_D = 2'd2;

	reg [1:0] state;
	/* Kept over RESET: no reset, initial values from configuration. */
	reg [31:0] ibase = 32'd0;
	reg [31:0] iwords = 32'd0;
	reg [31:0] dbase = 32'd0;
	reg [31:0] dwords = 32'd0;
	reg ready = 1'b1;
	/* Cleared by RESET. */
	reg run, halt, park, fault_st, alive, held;
	reg [7:0] fw_state;
	reg [31:0] version;
	reg [31:0] mbox0, mbox1, mbox2, mbox3;

	wire halting = halt || halt_req;
	wire loading = state != S_IDLE;

	assign core_rst_n = !loading && !held;
	assign core_run = run && !(park && halting);
	assign fw_curr_state = fw_state;

	wire [31:0] status = {16'd0, fw_state, 3'd0, loading, core_stopped || !core_rst_n,
		alive, fault_st, ready};

	/* HCR. */
	wire hw_mbox = hcr_we && hcr_widx[9:2] == R_MBOX0[9:2];
	wire sw_mbox = sb_we && sb_idx >= W_MBOX0 && sb_idx < W_MBOX0 + 6'd4;
	wire [1:0] sw_mi;	/* the mailbox of a firmware write: sb_idx - W_MBOX0 */
	wire sw_mi_bo;

	am_sub #(.W(2)) sw_mi_sub (
		.a(sb_idx[1:0]), .b(W_MBOX0[1:0]), .bi(1'b0), .d(sw_mi), .bo(sw_mi_bo)
	);
	wire load_ok = open && (core_stopped || !core_rst_n) && !loading;
	wire load_go = hcr_we && hcr_widx == R_CTRL && hcr_wmask[GHCI_CPFW_CTRL_LOAD] &&
		hcr_wdata[GHCI_CPFW_CTRL_LOAD] && load_ok;

	/* Mailbox reads (a mux, not a function: @* must see the registers). */
	wire [1:0] hr_mi = hcr_ridx[1:0];
	wire [31:0] mbox_h = hr_mi == 2'd0 ? mbox0 : hr_mi == 2'd1 ? mbox1 :
		hr_mi == 2'd2 ? mbox2 : mbox3;
	wire [31:0] mbox_s = sw_mi == 2'd0 ? mbox0 : sw_mi == 2'd1 ? mbox1 :
		sw_mi == 2'd2 ? mbox2 : mbox3;

	/* A host write merged by WSTRB: (old & ~mask) | new (no function:
	 * Verilator 5.032's V3Gate stumbled on it in a board top). */
	wire [31:0] hw_keep = ~hcr_wmask;
	wire [31:0] hw_new = hcr_wdata & hcr_wmask;

	always @(*) begin
		case (hcr_ridx)
		R_CTRL: hcr_rdata = {29'd0, halt, run, loading};
		R_STATUS: hcr_rdata = status;
		R_IBASE: hcr_rdata = ibase;
		R_IWORDS: hcr_rdata = iwords;
		R_DBASE: hcr_rdata = dbase;
		R_DWORDS: hcr_rdata = dwords;
		R_VERSION: hcr_rdata = version;
		R_MBOX0, R_MBOX0 + 10'd1, R_MBOX0 + 10'd2, R_MBOX0 + 10'd3:
			hcr_rdata = mbox_h;
		default: hcr_rdata = 32'd0;
		endcase
	end

	always @(*) begin
		sb_rdata = 32'd0;
		if (sb_re) begin
			if (sb_idx == W_FW_STATUS)
				sb_rdata = status;
			else if (sb_idx >= W_MBOX0 && sb_idx < W_MBOX0 + 6'd4)
				sb_rdata = mbox_s;
			else if (sb_idx == W_FW_VERSION)
				sb_rdata = version;
		end
	end

	/* The kept registers: host writes only. */
	always @(posedge clk) begin
		if (hcr_we && hcr_widx == R_IBASE)
			ibase <= ((ibase & hw_keep) | hw_new);
		if (hcr_we && hcr_widx == R_IWORDS)
			iwords <= ((iwords & hw_keep) | hw_new);
		if (hcr_we && hcr_widx == R_DBASE)
			dbase <= ((dbase & hw_keep) | hw_new);
		if (hcr_we && hcr_widx == R_DWORDS)
			dwords <= ((dwords & hw_keep) | hw_new);
		if (load_go)
			ready <= 1'b0;
		else if (state == S_LOAD_D && ld_done && !ld_error)
			ready <= 1'b1;
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			run <= 1'b0;
			halt <= 1'b0;
			park <= 1'b0;
			fault_st <= 1'b0;
			alive <= 1'b0;
			held <= 1'b0;
			fw_state <= 8'd0;
			version <= 32'd0;
			mbox0 <= 32'd0;
			mbox1 <= 32'd0;
			mbox2 <= 32'd0;
			mbox3 <= 32'd0;
			ld_start <= 1'b0;
			ld_imem <= 1'b0;
			ld_addr <= 32'd0;
			ld_words <= 32'd0;
			fault <= 1'b0;
			fault_addr <= 32'd0;
		end else begin
			ld_start <= 1'b0;
			fault <= 1'b0;
			if (hcr_we && hcr_widx == R_CTRL) begin
				if (hcr_wmask[GHCI_CPFW_CTRL_RUN])
					run <= hcr_wdata[GHCI_CPFW_CTRL_RUN];
				if (hcr_wmask[GHCI_CPFW_CTRL_HALT])
					halt <= hcr_wdata[GHCI_CPFW_CTRL_HALT];
			end
			/* Mailboxes: the firmware's write wins a same-cycle collision. */
			if (hw_mbox && hcr_widx[1:0] == 2'd0)
				mbox0 <= ((mbox0 & hw_keep) | hw_new);
			if (hw_mbox && hcr_widx[1:0] == 2'd1)
				mbox1 <= ((mbox1 & hw_keep) | hw_new);
			if (hw_mbox && hcr_widx[1:0] == 2'd2)
				mbox2 <= ((mbox2 & hw_keep) | hw_new);
			if (hw_mbox && hcr_widx[1:0] == 2'd3)
				mbox3 <= ((mbox3 & hw_keep) | hw_new);
			if (sw_mbox && sw_mi == 2'd0)
				mbox0 <= sb_wdata;
			if (sw_mbox && sw_mi == 2'd1)
				mbox1 <= sb_wdata;
			if (sw_mbox && sw_mi == 2'd2)
				mbox2 <= sb_wdata;
			if (sw_mbox && sw_mi == 2'd3)
				mbox3 <= sb_wdata;
			if (sb_we && sb_idx == W_FW_STATUS) begin
				fw_state <= sb_wdata[15:8];
				park <= sb_wdata[16];
				alive <= !alive;
			end
			if (sb_we && sb_idx == W_FW_VERSION)
				version <= sb_wdata;
			if (!halting)
				park <= 1'b0;
			if (core_fault && core_rst_n) begin
				fault_st <= 1'b1;
				fault <= 1'b1;
				fault_addr <= core_fault_pc;
				held <= 1'b1;
			end
			case (state)
			S_IDLE:
				if (load_go) begin
					fault_st <= 1'b0;
					held <= 1'b0;
					park <= 1'b0;
					ld_start <= 1'b1;
					ld_imem <= 1'b1;
					ld_addr <= ibase;
					ld_words <= iwords;
					state <= S_LOAD_I;
				end
			S_LOAD_I:
				if (ld_done) begin
					if (ld_error) begin
						fault_st <= 1'b1;
						held <= 1'b1;
						state <= S_IDLE;
					end else begin
						ld_start <= 1'b1;
						ld_imem <= 1'b0;
						ld_addr <= dbase;
						ld_words <= dwords;
						state <= S_LOAD_D;
					end
				end
			default:	/* S_LOAD_D */
				if (ld_done) begin
					if (ld_error) begin
						fault_st <= 1'b1;
						held <= 1'b1;
					end
					state <= S_IDLE;
				end
			endcase
		end
	end

	wire unused_mi = &{1'b0, sw_mi_bo};
endmodule

`default_nettype wire
