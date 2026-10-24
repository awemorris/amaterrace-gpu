/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_sa: The systolic array, reserved (design §3.9, Appendix A, deferred
 * until the SU implements GSI1): only the top ports exist so atg_top and
 * atg_su keep the place for it; every output is 0 and CAPS[25] stays 0.
 *
 * Deferred: a port-only placeholder (no logic).  The
 * intended behaviour: spec/gpu/sa/atg_sa.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_sa #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter NPHYS = 8	/* The SU's lane-group width (rq entry beat = NPHYS × 32 bits) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	/* To the SU's rq port (atg_su sa_*) */
	input wire push_valid,
	output wire push_ready,
	input wire [NPHYS*32-1:0] push_data,
	output wire pop_valid,
	input wire pop_ready,
	output wire [NPHYS*32-1:0] pop_data,
	input wire ctl_valid,
	input wire [31:0] ctl_data,
	output wire [31:0] qstat,
	output wire [31:0] sastat,
	output wire [31:0] qtag,
	output wire busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	/* spec/gpu/sa/atg_sa.md */
	assign hcr_rdata = 32'd0;
	assign push_ready = 1'd0;
	assign pop_valid = 1'd0;
	assign pop_data = {(NPHYS*32){1'b0}};
	assign qstat = 32'd0;
	assign sastat = 32'd0;
	assign qtag = 32'd0;
	assign busy = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, hcr_we, hcr_widx, hcr_wdata, hcr_wmask, hcr_ridx,
		push_valid, push_data, pop_ready, ctl_valid, ctl_data, req_ready, rsp_valid, rsp_write,
		rsp_tag, rsp_rdata, rsp_error};
endmodule

`default_nettype wire
