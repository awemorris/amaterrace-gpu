/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_regs: The GHCI register bus decoder of the CP: identification,
 * CAPS, EXTCAP list, VEND, SCRATCH, COUNTER and PERF registers, plus the
 * HCR snoop bus and the STATE alias that the other CP modules (and
 * atg_cpu) use for their own registers.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cp_regs.md.
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
	parameter CAPS = 32'h00500002,	/* CAPS value (design §2.2), set by atg_top from its parameters */
	parameter CAPS2 = 32'h00000001,	/* CAPS2 value */
	parameter VEND = 256'd0,	/* The 8 VEND words (0x0C0-0x0DF), word 0 in bits 31:0 */
	parameter XCAP_MASK = 8'h04,	/* Which extended capabilities are listed: bit id-1 (DISP 1, DBG 2, PERF 3, VEND 4, CPFW 6, SA 7) */
	parameter DISP_OFFSET = 32'h00010000	/* Where the DISP entry points (KC705 +0x10000) */
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
	/* STATE alias (0x1000-0x17FC, to atg_cp_state) */
	output wire alias_we,
	output wire [8:0] alias_idx,
	output wire [8:0] alias_ridx,
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
	input wire perf_reset
);
	/* spec/gpu/cp/atg_cp_regs.md */
	assign reg_rdata = 32'd0;
	assign hcr_we = 1'd0;
	assign hcr_widx = 10'd0;
	assign hcr_wdata = 32'd0;
	assign hcr_wmask = 32'd0;
	assign hcr_ridx = 10'd0;
	assign alias_we = 1'd0;
	assign alias_idx = 9'd0;
	assign alias_ridx = 9'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, reg_wr, reg_waddr, reg_wdata, reg_wstrb, reg_rd, reg_raddr, ctl_rdata,
		irq_rdata, ring_rdata, fence_rdata, dbg_rdata, state_rdata, x_rdata, perf_busy,
		perf_reset, (GCLK_HZ != 0), (VENDOR_ID != 0), (DEVICE_ID != 0), (DEVICE_VERSION != 0),
		(ISA_ID != 0), (NATIVE_ISA_ID != 0), (CAPS != 0), (CAPS2 != 0), (VEND != 0),
		(XCAP_MASK != 0), (DISP_OFFSET != 0)};
endmodule

`default_nettype wire
