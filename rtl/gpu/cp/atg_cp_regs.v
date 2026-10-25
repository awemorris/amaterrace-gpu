/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_regs: the GHCI register bus decoder of the CP: identification,
 * CAPS, the extended capability list, VEND, SCRATCH, COUNTER and the PERF
 * registers, plus the HCR snoop bus and the STATE alias that the other CP
 * modules (and atg_cpu) use for their own registers.
 *
 * Writes to 0x000-0xFFC go out on hcr_* in the cycle of reg_wr (every
 * module takes the writes of its own word indices); whole-word writes to
 * 0x1000-0x1BFC go out on alias_* (a partial-strobe alias write is
 * dropped here).  Reads: the answer is due the cycle after reg_rd; the
 * index is registered (hcr_ridx) and every module answers its own
 * registers combinationally from it, this module ORs them with its own,
 * or returns the state RAM's word for the alias, or 0 elsewhere
 * (0x1800-0x1FFFF).
 *
 * The extended capability list at 0x100: one two-word entry per set bit
 * of XCAP_MASK in id order; the first two entries at 0x100 and 0x108, the
 * rest from 0x180 (0x110-0x17F hold the PERF, CPFW, SA and FMT registers).
 * The PROT capability's registers (atg_cp_prot's, through x_rdata) are at
 * 0x1D0, after the room of a full list; the MEM capability's five words
 * (LOCAL_BASE, LOCAL_SIZE, WINDOW_SIZE, HOST_LIMIT, WINDOW_CTRL) at 0x1E0.
 * DISP2 points to its window at 0x200 (atg_cp_disp answers it through
 * x_rdata).  At most ten entries fit in the list (0x100-0x10F and
 * 0x180-0x1BF): DISP and DISP2 are not listed together.
 * WINDOW_CTRL.ENABLE (win_en, docs/ghci.md section 11.1) is 1 after rst_n
 * (the board's reset, not CTRL.RESET) and takes host writes only when the
 * GPU has a local window (WINDOW_BYTES != 0); without one it reads 0 and
 * win_en stays 0.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_regs #(
	parameter GCLK_HZ = 32'd100000000,	/* GCLK_HZ register */
	parameter VENDOR_ID = 32'h414D4154,	/* "AMAT" */
	parameter DEVICE_ID = 32'h41544731,	/* "ATG1" */
	parameter DEVICE_VERSION = 32'h00000002,	/* Implementation version */
	parameter ISA_ID = 32'h47534931,	/* "GSI1"; 0 when there is no SU */
	parameter NATIVE_ISA_ID = 32'h47534931,	/* NATIVE_ISA_ID (0x048) */
	parameter [15:0] RESIDENT_WARPS = 16'd0,	/* RESIDENT_WARPS (0x04C) [15:0]: warps run at once over the SUs */
	parameter [7:0] NREGS = 8'd0,	/* RESIDENT_WARPS [23:16]: general registers per lane (0: no SU) */
	parameter [31:0] LOCAL_BASE = 32'd0,	/* MEM: GPU address of local memory */
	parameter [31:0] LOCAL_BYTES = 32'd0,	/* MEM: bytes of local memory */
	parameter [31:0] WINDOW_BYTES = 32'd0,	/* MEM: bytes the local window shows */
	parameter [31:0] HOST_LIMIT = 32'd0,	/* MEM: host addresses below it (0: all) */
	parameter CAPS = 32'h00500002,	/* CAPS value (design §2.2), set by atg_top from its parameters */
	parameter CAPS2 = 32'h00000001,	/* CAPS2 value */
	parameter VEND = 256'd0,	/* The 8 VEND words (0x0C0-0x0DF), word 0 in bits 31:0 */
	parameter [10:0] XCAP_MASK = 11'h004,	/* Which extended capabilities are listed: bit id-1 (DISP 1, DBG 2, PERF 3, VEND 4, CPFW 6, SA 7, MEM 8, PROT 9, FMT 10, DISP2 11) */
	parameter DISP_OFFSET = 32'h00010000,	/* Where the DISP entry points (KC705 +0x10000) */
	parameter PERF_SRC = 32'hFFFFFFFF	/* PERF_SRC0..3 (byte n = PERF_SRCn) */
) (
	input wire clk,
	input wire rst_n,
	/* Register bus (from am_axi_regs or am_jtag_regs) */
	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output wire [31:0] reg_rdata,
	/* HCR snoop bus (to the other CP modules and atg_cpu) */
	output wire hcr_we,
	output wire [9:0] hcr_widx,
	output wire [31:0] hcr_wdata,
	output wire [31:0] hcr_wmask,
	output wire [9:0] hcr_ridx,
	/* STATE alias (0x1000-0x1BFC, to atg_cp_state) */
	output wire alias_we,
	output wire [9:0] alias_idx,
	output wire [9:0] alias_ridx,
	/* Read data of the other modules (0 outside their registers) */
	input wire [31:0] ctl_rdata,
	input wire [31:0] irq_rdata,
	input wire [31:0] ring_rdata,
	input wire [31:0] fence_rdata,
	input wire [31:0] dbg_rdata,
	input wire [31:0] state_rdata,
	input wire [31:0] x_rdata,
	/* PERF */
	input wire [3:0] perf_busy,
	input wire perf_reset,
	/* MEM: WINDOW_CTRL.ENABLE, the local window is open (to the board's window path) */
	output wire win_en
);
	`include "ghci_regs.vh"

	localparam [9:0] I_SCRATCH = GHCI_SCRATCH[11:2];
	localparam [9:0] I_PERF_CTRL = GHCI_PERF_CTRL[11:2];
	localparam [11:0] MEM_OFF = 12'h1E0;	/* the MEM capability's registers */
	localparam [11:0] A_LOCAL_BASE = MEM_OFF + GHCI_MEM_LOCAL_BASE[11:0];
	localparam [11:0] A_LOCAL_SIZE = MEM_OFF + GHCI_MEM_LOCAL_SIZE[11:0];
	localparam [11:0] A_WINDOW_SIZE = MEM_OFF + GHCI_MEM_WINDOW_SIZE[11:0];
	localparam [11:0] A_HOST_LIMIT = MEM_OFF + GHCI_MEM_HOST_LIMIT[11:0];
	localparam [11:0] A_WINDOW_CTRL = MEM_OFF + GHCI_MEM_WINDOW_CTRL[11:0];
	localparam [9:0] I_WINDOW_CTRL = A_WINDOW_CTRL[11:2];
	localparam [0:0] HAS_WINDOW = XCAP_MASK[7] && WINDOW_BYTES != 32'd0;

	/* Writes. */
	assign hcr_we = reg_wr && reg_waddr[16:12] == 5'd0;
	assign hcr_widx = reg_waddr[11:2];
	assign hcr_wdata = reg_wdata;
	assign hcr_wmask = {{8{reg_wstrb[3]}}, {8{reg_wstrb[2]}}, {8{reg_wstrb[1]}}, {8{reg_wstrb[0]}}};
	/* 0x1000-0x1BFC: STATE[0..0x2FF]. */
	assign alias_we = reg_wr && reg_waddr[16:12] == 5'b00001 && reg_waddr[11:10] != 2'b11 &&
		reg_wstrb == 4'hF;
	assign alias_idx = reg_waddr[11:2];
	assign alias_ridx = reg_raddr[11:2];

	reg [31:0] scratch;
	reg win_q;
	reg [31:0] counter;
	reg [127:0] perf;	/* PERF0..3, PERFn in bits 32n+31:32n */
	wire perf_clear = perf_reset ||
		(hcr_we && hcr_widx == I_PERF_CTRL && hcr_wmask[0] && hcr_wdata[0]);
	integer i;

	always @(posedge clk) begin
		if (!rst_n) begin
			scratch <= 32'd0;
			counter <= 32'd0;
			win_q <= HAS_WINDOW;
		end else begin
			counter <= counter + 32'd1;
			if (hcr_we && hcr_widx == I_SCRATCH)
				scratch <= (scratch & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			if (HAS_WINDOW && hcr_we && hcr_widx == I_WINDOW_CTRL && hcr_wmask[0])
				win_q <= hcr_wdata[0];
		end
		for (i = 0; i < 4; i = i + 1)
			if (!rst_n || perf_clear)
				perf[i * 32 +: 32] <= 32'd0;
			else
				perf[i * 32 +: 32] <= perf[i * 32 +: 32] + {31'd0, perf_busy[i]};
	end

	/* Reads: the registered index, answered the next cycle. */
	reg [9:0] ridx_q;
	reg rd_hcr_q;
	reg rd_state_q;

	always @(posedge clk) begin
		if (!rst_n) begin
			ridx_q <= 10'd0;
			rd_hcr_q <= 1'b0;
			rd_state_q <= 1'b0;
		end else if (reg_rd) begin
			ridx_q <= reg_raddr[11:2];
			rd_hcr_q <= reg_raddr[16:12] == 5'd0;
			rd_state_q <= reg_raddr[16:12] == 5'b00001 && reg_raddr[11:10] != 2'b11;
		end
	end

	assign hcr_ridx = ridx_q;
	assign win_en = win_q;

	/* The extended capability list: entry k's byte offset. */
	function integer xcap_off;
		input integer k;
		xcap_off = k < 2 ? 256 + k * 8 : 384 + (k - 2) * 8;
	endfunction

	function [31:0] xcap_ptr;
		input integer id;
		case (id)
		1: xcap_ptr = DISP_OFFSET;
		3: xcap_ptr = {15'd0, GHCI_PERF_SRC0};
		4: xcap_ptr = 32'h000000C0;
		6: xcap_ptr = 32'h00000120;
		7: xcap_ptr = 32'h00000140;
		8: xcap_ptr = {20'd0, MEM_OFF};
		9: xcap_ptr = 32'h000001D0;	/* PROT: atg_cp_prot answers its registers */
		10: xcap_ptr = 32'h00000160;
		11: xcap_ptr = {15'd0, GHCI_DISP2_BASE};
		default: xcap_ptr = 32'd0;
		endcase
	endfunction

	/* The list word at byte offset off (0 if none). */
	function [31:0] xcap_word;
		input [11:0] off;
		integer id, id2, k, k2, o;
		reg [15:0] nxt;
		begin
			xcap_word = 32'd0;
			o = {20'd0, off};
			k = 0;
			for (id = 1; id <= 11; id = id + 1)
				if (XCAP_MASK[id - 1]) begin
					/* The next entry, in dwords from this one. */
					nxt = 16'd0;
					k2 = k + 1;
					for (id2 = 11; id2 > id; id2 = id2 - 1)
						if (XCAP_MASK[id2 - 1])
							/* verilator lint_off WIDTHTRUNC */
							nxt = (xcap_off(k2) - xcap_off(k)) / 4;	/* < 2^16 */
							/* verilator lint_on WIDTHTRUNC */
					if (o == xcap_off(k))
						xcap_word = {nxt, 8'd1, id[7:0]};
					if (o == xcap_off(k) + 4)
						xcap_word = xcap_ptr(id);
					k = k + 1;
				end
		end
	endfunction

	reg [31:0] own;
	wire [11:0] roff = {ridx_q, 2'b00};

	always @(*) begin
		own = xcap_word(roff);
		case (roff)
		GHCI_MAGIC[11:0]: own = GHCI_MAGIC_VALUE;
		GHCI_VERSION[11:0]: own = {GHCI_VERSION_MAJOR, GHCI_VERSION_MINOR};
		GHCI_VENDOR_ID[11:0]: own = VENDOR_ID;
		GHCI_DEVICE_ID[11:0]: own = DEVICE_ID;
		GHCI_ISA_ID[11:0]: own = ISA_ID;
		GHCI_DEVICE_VERSION[11:0]: own = DEVICE_VERSION;
		GHCI_EXTCAP[11:0]: own = XCAP_MASK != 11'd0 ? {15'd0, GHCI_EXTCAP_LIST} : 32'd0;
		GHCI_GCLK_HZ[11:0]: own = GCLK_HZ;
		GHCI_CAPS[11:0]: own = CAPS;
		GHCI_CAPS2[11:0]: own = CAPS2;
		GHCI_SCRATCH[11:0]: own = scratch;
		GHCI_COUNTER[11:0]: own = counter;
		12'h048: own = NATIVE_ISA_ID;
		GHCI_RESIDENT_WARPS[11:0]: own = {8'd0, NREGS, RESIDENT_WARPS};
		A_LOCAL_BASE: if (XCAP_MASK[7]) own = LOCAL_BASE;
		A_LOCAL_SIZE: if (XCAP_MASK[7]) own = LOCAL_BYTES;
		A_WINDOW_SIZE: if (XCAP_MASK[7]) own = WINDOW_BYTES;
		A_HOST_LIMIT: if (XCAP_MASK[7]) own = HOST_LIMIT;
		A_WINDOW_CTRL: if (XCAP_MASK[7]) own = {31'd0, win_q};
		default: ;
		endcase
		if (roff[11:5] == 7'h06)	/* VEND 0x0C0-0x0DF */
			own = VEND[roff[4:2] * 32 +: 32];
		if (roff[11:4] == GHCI_PERF0[11:4])	/* PERF0..3 0x080-0x08C */
			own = perf[roff[3:2] * 32 +: 32];
		if (XCAP_MASK[2] && roff[11:4] == GHCI_PERF_SRC0[11:4])	/* PERF_SRC0..3 */
			own = {24'd0, PERF_SRC[roff[3:2] * 8 +: 8]};
	end

	assign reg_rdata = rd_state_q ? state_rdata :
		rd_hcr_q ? (own | ctl_rdata | irq_rdata | ring_rdata | fence_rdata | dbg_rdata | x_rdata) :
		32'd0;

	wire unused_ok = &{1'b0, reg_waddr[1:0], reg_raddr[1:0]};

endmodule

`default_nettype wire
