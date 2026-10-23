/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_state: The state register file STATE[0..511] (one BRAM): written
 * through the host alias and the SET_REG µop, broadcast to the blocks,
 * read back by the host and by the CP's CPU.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cp_state.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_state (
	input wire clk,
	input wire rst_n,
	/* Host alias (from atg_cp_regs) */
	input wire alias_we,
	input wire [8:0] alias_idx,
	input wire [31:0] alias_wdata,
	input wire [8:0] alias_ridx,
	output wire [31:0] alias_rdata,
	/* SET_REG and µop payloads (from atg_cp_seq) */
	input wire uop_we,
	input wire [8:0] uop_idx,
	input wire [31:0] uop_wdata,
	/* Locks (from atg_cp_ctl and the blocks) */
	input wire open,
	input wire blt_busy,
	output wire lock_fault,
	/* Broadcast to the blocks */
	output wire st_we,
	output wire [8:0] st_idx,
	output wire [31:0] st_wdata,
	/* CPU read port (atg_cpu window) */
	input wire [8:0] cpu_ridx,
	output wire [31:0] cpu_rdata
);
	/* spec/gpu/cp/atg_cp_state.md */
	assign alias_rdata = 32'd0;
	assign lock_fault = 1'd0;
	assign st_we = 1'd0;
	assign st_idx = 9'd0;
	assign st_wdata = 32'd0;
	assign cpu_rdata = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, alias_we, alias_idx, alias_wdata, alias_ridx, uop_we, uop_idx, uop_wdata,
		open, blt_busy, cpu_ridx};
endmodule

`default_nettype wire
