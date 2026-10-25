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
 * ev[k] sets IRQ_STATUS[k] (one-cycle pulses; [12:9] the DISP2 events
 * VBLANK, FLIP, DISP_ERROR, HOTPLUG), except ev[2], the
 * RING_EMPTY level, whose rising edge sets bit 2.  Writing 1 to a bit of
 * IRQ_STATUS clears it; a set and a clear in the same cycle leave it set.
 * IRQ_SET[5] sets SOFT.  irq = OR(IRQ_STATUS & IRQ_ENABLE), registered (it
 * follows a change one cycle later).  IRQ_STATUS is cleared by the core
 * reset (CTRL.RESET), IRQ_ENABLE only by rst_n.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_irq (
	input wire clk,
	input wire rst_n,
	input wire core_rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	input wire [12:0] ev,
	output wire irq
);
	`include "ghci_regs.vh"

	localparam [9:0] I_STATUS = GHCI_IRQ_STATUS[11:2];
	localparam [9:0] I_ENABLE = GHCI_IRQ_ENABLE[11:2];
	localparam [9:0] I_SET = GHCI_IRQ_SET[11:2];

	reg [12:0] status;
	reg [12:0] enable;
	reg empty_q;
	reg irq_q;

	wire [12:0] wd = hcr_wdata[12:0] & hcr_wmask[12:0];
	wire [12:0] clr = (hcr_we && hcr_widx == I_STATUS) ? wd : 13'd0;
	wire [12:0] set = {ev[12:3], ev[2] && !empty_q, ev[1:0]} |
		((hcr_we && hcr_widx == I_SET) ? (wd & (13'd1 << GHCI_IRQ_SOFT)) : 13'd0);

	always @(posedge clk) begin
		if (!rst_n) begin
			enable <= 13'd0;
			irq_q <= 1'b0;
		end else begin
			if (hcr_we && hcr_widx == I_ENABLE)
				enable <= (enable & ~hcr_wmask[12:0]) | wd;
			irq_q <= |(status & enable);
		end
		if (!core_rst_n) begin
			status <= 13'd0;
			empty_q <= 1'b1;
		end else begin
			status <= (status & ~clr) | set;
			empty_q <= ev[2];
		end
	end

	assign irq = irq_q;
	assign hcr_rdata = hcr_ridx == I_STATUS ? {19'd0, status} :
		hcr_ridx == I_ENABLE ? {19'd0, enable} : 32'd0;

	wire unused_ok = &{1'b0, hcr_wdata[31:13], hcr_wmask[31:13]};
endmodule

`default_nettype wire
