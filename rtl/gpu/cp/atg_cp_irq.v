/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_irq: IRQ_STATUS (W1C), IRQ_ENABLE, IRQ_SET and the level
 * interrupt line.
 *
 * Canonical bit mapping (docs/ghci.md §3.4):
 *   [0] IRQ_FENCE (CMD_FENCE completed)
 *   [1] IRQ_FAULT (hardware / execution fault)
 *   [2] IRQ_WATCHDOG (watchdog cycle limit expired)
 *   [3] IRQ_DISPLAY (Display Controller summary event from DISP2)
 *   [4] Reserved (reads 0)
 *   [5] IRQ_SOFT (software interrupt from IRQ_SET[5])
 *   [6] IRQ_HALTED (execution halted following CTRL.HALT)
 *   Others: Reserved (reads 0)
 *
 * ev[k] sets IRQ_STATUS[k] (one-cycle pulses). Writing 1 to a bit of
 * IRQ_STATUS clears it; a set and a clear in the same cycle leave it set.
 * IRQ_SET[5] sets SOFT. irq = OR(IRQ_STATUS & IRQ_ENABLE), registered (it
 * follows a change one cycle later). IRQ_STATUS is cleared by the core
 * reset (CTRL.RESET), IRQ_ENABLE only by rst_n.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_irq (
	input wire clk,
	input wire rst_n,
	input wire core_rst_n,
	input wire ctrl_irq_global,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	input wire [6:0] ev,
	output wire irq
);
	`include "ghci_regs.vh"

	localparam [9:0] I_STATUS = HCR_IDX_IRQ_STATUS;
	localparam [9:0] I_ENABLE = HCR_IDX_IRQ_ENABLE;
	localparam [9:0] I_SET = HCR_IDX_IRQ_SET;

	reg [6:0] status;
	reg [6:0] enable;

	wire [6:0] wd = hcr_wdata[6:0] & hcr_wmask[6:0];
	wire [6:0] clr = (hcr_we && hcr_widx == I_STATUS) ? wd : 7'd0;
	wire [6:0] set = {ev[6], 1'b0, 1'b0, ev[3:0]} |
		((hcr_we && hcr_widx == I_SET) ? (wd & (7'd1 << GHCI_IRQ_SOFT)) : 7'd0);

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire irq_rst_high;
	(* keep = "true", dont_touch = "true" *) wire irq_crst_high;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_irq_rst  (.I0(rst_n),      .O(irq_rst_high));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_irq_crst (.I0(core_rst_n), .O(irq_crst_high));
`endif

	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (irq_rst_high) begin
`else
		if (!rst_n) begin
`endif
			enable <= 7'd0;
		end else begin
			if (hcr_we && hcr_widx == I_ENABLE)
				enable <= (enable & ~hcr_wmask[6:0]) | (wd & 7'b1101111);
		end
`ifdef SYNTH_KINTEX7
		if (irq_crst_high) begin
`else
		if (!core_rst_n) begin
`endif
			status <= 7'd0;
		end else begin
			status <= ((status & ~clr) | set) & 7'b1101111;
		end
	end

	assign irq = ctrl_irq_global && (| (status & enable));
	assign hcr_rdata = hcr_ridx == I_STATUS ? {25'd0, status[6:5], 1'b0, status[3:0]} :
		hcr_ridx == I_ENABLE ? {25'd0, enable[6:5], 1'b0, enable[3:0]} : 32'd0;

	wire unused_ok = &{1'b0, hcr_wdata[31:7], hcr_wmask[31:7], hcr_ridx[9:6], ev[5:4]};
endmodule

`default_nettype wire
