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
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cp_irq.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_irq (
	input wire clk,
	input wire rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	input wire [8:0] ev,
	output wire irq
);
	/* spec/gpu/cp/atg_cp_irq.md */
	assign hcr_rdata = 32'd0;
	assign irq = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, hcr_we, hcr_widx, hcr_wdata, hcr_wmask, hcr_ridx, ev};
endmodule

`default_nettype wire
