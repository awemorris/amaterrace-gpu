/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_mode: the DC's registers of the DISP2 window that are not the
 * scan-out's (docs/ghci.md section 13.2): MODE_INDEX and the mode table,
 * CONNECTED (and HOTPLUG), CURSOR_POS, CURSOR_CTRL and CURSOR_BASE.  See
 * spec/gpu/dc/atg_dc_mode.md.
 *
 * The bus is the DC's internal one, as atg_dc_regs': a write takes effect
 * in its cycle, the read data is combinational from d_ridx (0 for the
 * other words).  The mode table is Amaterrace's two modes (CTA-861
 * formats 1 and 4): 640 x 480 at 60 Hz (25.2 MHz, PCLK_SEL 0, negative
 * syncs) and 1280 x 720 at 60 Hz (74.25 MHz, PCLK_SEL 1, positive syncs).
 * TEST_MODE 1 (a simulation's, as the Verilator link's) replaces the table
 * with one small mode, 320 x 240 (vkdemo's frame) at 25 MHz, PCLK_SEL 0,
 * negative syncs, so that a frame takes about 85,000 pixel clocks instead
 * of 720p's 1.24 million; atg_dc_regs then names one mode.  CONNECTED is
 * 1 after the board reset and after the DC's reset (dc_reset); a write
 * that changes it pulses ev_hotplug.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_mode #(
	parameter TEST_MODE = 0	/* 1: the one small mode of a simulation (above), not a board's */
) (
	input wire clk,
	input wire rst_n,
	input wire dc_reset,
	/* The DC's register bus */
	input wire d_we,
	input wire [5:0] d_idx,
	input wire [31:0] d_wdata,
	input wire [31:0] d_wmask,
	input wire [5:0] d_ridx,
	output reg [31:0] d_rdata,
	/* CONNECTED and its event */
	output wire connected,
	output reg ev_hotplug,
	/* The cursor's registers (to and from atg_dc_cursor) */
	output wire [31:0] cur_pos,
	output wire cur_show,
	input wire [31:0] cursor_base
);
	`include "ghci_regs.vh"

	localparam [5:0] I_CONNECTED = GHCI_DC_CONNECTED[7:2];
	localparam [5:0] I_MODE_INDEX = GHCI_DC_MODE_INDEX[7:2];
	localparam [5:0] I_CURSOR_BASE = GHCI_DC_CURSOR_BASE[7:2];
	localparam [5:0] I_CURSOR_POS = GHCI_DC_CURSOR_POS[7:2];
	localparam [5:0] I_CURSOR_CTRL = GHCI_DC_CURSOR_CTRL[7:2];

	reg r_connected;
	reg [2:0] r_mode;
	reg [31:0] r_pos;
	reg r_show;

	assign connected = r_connected;
	assign cur_pos = r_pos;
	assign cur_show = r_show;

	wire [31:0] wbits = d_wdata & d_wmask;
	wire w_conn = d_we && d_idx == I_CONNECTED && d_wmask[0];

	always @(posedge clk) begin
		ev_hotplug <= 1'b0;
		if (!rst_n) begin
			r_connected <= 1'b1;
			r_mode <= 3'd0;
			r_pos <= 32'd0;
			r_show <= 1'b0;
		end else begin
			if (dc_reset) begin
				r_connected <= 1'b1;
			end else if (w_conn) begin
				r_connected <= d_wdata[0];
				ev_hotplug <= d_wdata[0] != r_connected;
			end
			if (d_we && d_idx == I_MODE_INDEX)
				r_mode <= (r_mode & ~d_wmask[2:0]) | wbits[2:0];
			if (d_we && d_idx == I_CURSOR_POS)
				r_pos <= (r_pos & ~d_wmask) | wbits;
			if (d_we && d_idx == I_CURSOR_CTRL && d_wmask[0])
				r_show <= d_wdata[0];
		end
	end

	/* The mode table: H0, H1, V0, V1, CLOCK (kHz), FLAGS. */
	reg [31:0] m_h0, m_h1, m_v0, m_v1, m_clock, m_flags;

	/* The table's row: TEST_MODE's one mode, or the board's two. */
	wire is_test = TEST_MODE != 0;

	always @(*) begin
		case ({is_test, r_mode})
		4'b1000: begin
			/* 320 x 240: H 320/8/8/8, V 240/2/2/2, 344 x 246 at 25,000 kHz. */
			m_h0 = {16'd8, 16'd320};
			m_h1 = {16'd8, 16'd8};
			m_v0 = {16'd2, 16'd240};
			m_v1 = {16'd2, 16'd2};
			m_clock = 32'd25000;
			m_flags = 32'h00000000;
		end
		4'b0000: begin
			m_h0 = {16'd96, 16'd640};
			m_h1 = {16'd48, 16'd16};
			m_v0 = {16'd2, 16'd480};
			m_v1 = {16'd33, 16'd10};
			m_clock = 32'd25200;
			m_flags = 32'h00000000;
		end
		4'b0001: begin
			m_h0 = {16'd40, 16'd1280};
			m_h1 = {16'd220, 16'd110};
			m_v0 = {16'd5, 16'd720};
			m_v1 = {16'd20, 16'd5};
			m_clock = 32'd74250;
			m_flags = 32'h00000013;
		end
		default: begin
			m_h0 = 32'd0;
			m_h1 = 32'd0;
			m_v0 = 32'd0;
			m_v1 = 32'd0;
			m_clock = 32'd0;
			m_flags = 32'd0;
		end
		endcase
	end

	always @(*) begin
		case (d_ridx)
		I_CONNECTED: d_rdata = {31'd0, r_connected};
		I_MODE_INDEX: d_rdata = {29'd0, r_mode};
		GHCI_DC_MODE_H0[7:2]: d_rdata = m_h0;
		GHCI_DC_MODE_H1[7:2]: d_rdata = m_h1;
		GHCI_DC_MODE_V0[7:2]: d_rdata = m_v0;
		GHCI_DC_MODE_V1[7:2]: d_rdata = m_v1;
		GHCI_DC_MODE_CLOCK[7:2]: d_rdata = m_clock;
		GHCI_DC_MODE_FLAGS[7:2]: d_rdata = m_flags;
		I_CURSOR_BASE: d_rdata = cursor_base;
		I_CURSOR_POS: d_rdata = r_pos;
		I_CURSOR_CTRL: d_rdata = {31'd0, r_show};
		default: d_rdata = 32'd0;
		endcase
	end
endmodule

`default_nettype wire
