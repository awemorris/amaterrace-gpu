/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp: the command processor, stub (WS288 p002).  It holds the GHCI
 * host control registers (docs/ghci.md) on the register bus of
 * am_axi_regs, the state register file, and the controls of the other
 * blocks.  The stub has no ring: RUN is kept but nothing is fetched,
 * CAPS[0] is 0 and EXTCAP is 0.  What it does:
 *
 *   - the identification registers, SCRATCH, COUNTER, CAPS, GCLK_HZ;
 *   - STATE[0..511] in a block RAM, written through the alias at 0x1000
 *     (whole words; a write with a partial WSTRB is ignored) and passed on
 *     to the blocks (st_we), read back through the alias;
 *   - KICK.BLIT: starts the blitter (atg_blt) on its STATE range;
 *   - HALT and quiesce: the MC stops granting; HALTED when it is idle;
 *   - RESET in the order of design §1.3: quiesce, wait for AXI_IDLE, one
 *     cycle of core reset (core_rst_n, also the CP's own run state), MC
 *     flush, the bit falls; AXI_STUCK after 4 * WDT_CYCLES of waiting;
 *   - FAULT: the first of an aperture fault (MC), a blitter error, a KICK
 *     or a locked write in the wrong state; it is kept in FAULT_ADDR/INFO,
 *     sets IRQ_STATUS.FAULT and quiesces until RESET;
 *   - the asynchronous debug port DBG_ADDR/DATA/STATUS through the CP's own
 *     AMB port (MC client 0); its errors set DBG_STATUS.error only;
 *   - IRQ_STATUS/ENABLE/SET and the level interrupt;
 *   - RING_BASE/SIZE/WPTR, APERTURE_*, WDT_CYCLES, FENCE_LAST as plain
 *     registers (the ring and the fence come in p004).
 *
 * Writes honour WSTRB except where noted.  Register reads are answered in
 * the cycle after reg_rd.  rst_n is the board reset of the whole GPU.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter [31:0] GCLK_HZ = 32'd100000000,
	parameter [31:0] VENDOR_ID = 32'h414D4154,	/* "AMAT" */
	parameter [31:0] DEVICE_ID = 32'h41544731,	/* "ATG1" */
	parameter [31:0] DEVICE_VERSION = 32'h00000001	/* 0.1: p002 stub */
) (
	input wire clk,
	input wire rst_n,

	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output wire [31:0] reg_rdata,

	output wire irq,
	input wire mem_ready,

	output wire core_rst_n,

	output wire mc_quiesce,
	output wire mc_flush,
	output wire [ADDR_W-1:0] aperture_base,
	output wire [ADDR_W-1:0] aperture_limit,
	input wire mc_idle,
	input wire mc_fault,
	input wire [7:0] mc_fault_client,
	input wire [ADDR_W-1:0] mc_fault_addr,
	input wire mc_fault_write,

	output wire st_we,
	output wire [8:0] st_idx,
	output wire [31:0] st_wdata,

	output wire blt_kick,
	input wire blt_busy,
	input wire blt_error,
	input wire [3:0] blt_error_kind,

	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"

	localparam WS = LINE_SHIFT - 2;	/* log2(words per line) */
	localparam [7:0] BLOCK_BLT = 8'd1;	/* = the STATUS busy bit */
	localparam [7:0] CLIENT_BLT = 8'd1;

	/* Write decoding. */
	wire [31:0] wmask = {{8{reg_wstrb[3]}}, {8{reg_wstrb[2]}}, {8{reg_wstrb[1]}}, {8{reg_wstrb[0]}}};
	wire wr_hcr = reg_wr && reg_waddr[16:12] == 5'd0;
	wire wr_state = reg_wr && reg_waddr[16:11] == 6'b000010;
	wire [11:0] wa = reg_waddr[11:0];

	function [31:0] merge;
		input [31:0] old;
		input [31:0] data;
		input [31:0] mask;
		merge = (old & ~mask) | (data & mask);
	endfunction

	/* Registers. */
	reg [31:0] scratch;
	reg [31:0] counter;
	reg ctrl_run;
	reg ctrl_halt;
	reg ctrl_wdt_en;
	reg [6:0] irq_status;
	reg [6:0] irq_enable;
	reg [31:0] wdt_cycles;
	reg [31:0] ring_base;
	reg [4:0] ring_size;
	reg [31:0] ring_wptr;
	reg [31:0] ap_base;
	reg [31:0] ap_limit;
	reg [31:0] fault_addr;
	reg [31:0] fault_info;
	reg faulted;
	reg [31:0] fence_last;

	/* RESET sequencing. */
	localparam [1:0] RS_NONE = 2'd0;
	localparam [1:0] RS_QUIESCE = 2'd1;	/* wait for AXI_IDLE */
	localparam [1:0] RS_PULSE = 2'd2;	/* core reset, MC flush */
	reg [1:0] rs;
	reg [33:0] stuck_count;
	reg axi_stuck;

	wire resetting = rs != RS_NONE;
	wire quiesce = ctrl_halt || faulted || resetting;
	wire halted = ctrl_halt && mc_idle && !faulted && !resetting;
	reg halted_q;

	wire [3:0] cp_state = resetting ? GHCI_ST_RESETTING :
		faulted ? GHCI_ST_FAULTED :
		ctrl_halt ? (halted ? GHCI_ST_HALTED : GHCI_ST_HALTING) :
		ctrl_run ? GHCI_ST_RUNNING : GHCI_ST_IDLE;
	wire open_state = cp_state == GHCI_ST_IDLE || cp_state == GHCI_ST_HALTED;

	assign mc_quiesce = quiesce;
	assign mc_flush = rs == RS_PULSE;
	assign core_rst_n = rst_n && rs != RS_PULSE;
	assign aperture_base = ap_base;
	assign aperture_limit = ap_limit;

	/* The state register file. */
	reg [31:0] state_mem [0:511];
	reg [31:0] state_q;
	wire state_full = reg_wstrb == 4'hF;
	wire state_blt = reg_waddr[10:2] < 9'h020;
	wire state_locked = !open_state || (state_blt && blt_busy);
	wire state_take = wr_state && state_full && !state_locked;

	assign st_we = state_take;
	assign st_idx = reg_waddr[10:2];
	assign st_wdata = reg_wdata;

	always @(posedge clk) begin
		if (state_take)
			state_mem[reg_waddr[10:2]] <= reg_wdata;
		state_q <= state_mem[reg_raddr[10:2]];
	end

	/* KICK. */
	wire wr_kick = wr_hcr && wa == GHCI_KICK[11:0] && reg_wstrb[0] &&
		reg_wdata[GHCI_KICK_BLIT];
	wire kick_ok = open_state && !blt_busy;
	assign blt_kick = wr_kick && kick_ok;

	/* Locked HCR writes: the ring and the aperture outside IDLE/HALTED. */
	wire wr_locked_reg = wr_hcr && (wa == GHCI_RING_BASE[11:0] ||
		wa == GHCI_RING_SIZE[11:0] || wa == GHCI_APERTURE_BASE[11:0] ||
		wa == GHCI_APERTURE_LIMIT[11:0]);
	wire locked_fault = (wr_locked_reg && !open_state) ||
		(wr_state && state_full && state_locked);

	/* The debug port. */
	reg dbg_busy;
	reg dbg_err;
	reg [31:0] dbg_addr;
	reg [31:0] dbg_data;
	reg q_valid;
	reg q_write;
	reg [31:0] q_word;
	reg [3:0] q_strb;

	wire wr_dbg_addr = wr_hcr && wa == GHCI_DBG_ADDR[11:0];
	wire wr_dbg_data = wr_hcr && wa == GHCI_DBG_DATA[11:0];
	wire [WS-1:0] dbg_word = dbg_addr[LINE_SHIFT-1:2];

	assign req_valid = q_valid;
	assign req_write = q_write;
	assign req_line = dbg_addr[ADDR_W-1:LINE_SHIFT];
	assign req_wdata = {(LINE_BYTES / 4){q_word}};
	assign req_be = {{(LINE_BYTES - 4){1'b0}}, q_strb} << {dbg_word, 2'd0};
	assign req_tag = 8'd0;

	wire [31:0] rsp_word = rsp_rdata[{dbg_word, 5'd0} +: 32];

	/* Faults. */
	wire mc_fault_gpu = mc_fault && mc_fault_client != 8'd0;
	wire kick_fault = wr_kick && !kick_ok;
	wire any_fault = mc_fault_gpu || blt_error || kick_fault || locked_fault;
	wire [31:0] new_fault_info =
		mc_fault_gpu ? {8'd0, mc_fault_client, GHCI_FAULT_APERTURE, 3'd0, mc_fault_write, mc_fault_client} :
		blt_error ? {8'd0, BLOCK_BLT, blt_error_kind, 3'd0, 1'b0, CLIENT_BLT} :
		kick_fault ? {16'd0, GHCI_FAULT_KICK, 12'd0} :
		{16'd0, GHCI_FAULT_LOCKED, 12'd0};
	wire [31:0] new_fault_addr = mc_fault_gpu ? mc_fault_addr : 32'd0;

	assign irq = |(irq_status & irq_enable);

	/* Interrupt sources this cycle. */
	wire dbg_done = rsp_valid && dbg_busy;
	wire [6:0] irq_raise = {halted && !halted_q, 1'b0, dbg_done, 3'd0, 1'b0} |
		{5'd0, any_fault && !faulted, 1'b0} |
		((wr_hcr && wa == GHCI_IRQ_SET[11:0] && reg_wstrb[0] && reg_wdata[GHCI_IRQ_SOFT]) ?
			7'b0100000 : 7'd0);
	wire [6:0] irq_clear = (wr_hcr && wa == GHCI_IRQ_STATUS[11:0] && reg_wstrb[0]) ?
		reg_wdata[6:0] : 7'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			scratch <= 32'd0;
			counter <= 32'd0;
			ctrl_wdt_en <= 1'b0;
			irq_enable <= 7'd0;
			wdt_cycles <= 32'h10000000;
			ring_base <= 32'd0;
			ring_size <= 5'd12;
			ap_base <= 32'd0;
			ap_limit <= 32'd0;
			rs <= RS_NONE;
			stuck_count <= 34'd0;
			axi_stuck <= 1'b0;
		end else begin
			counter <= counter + 32'd1;
			if (wr_hcr) begin
				case (wa)
				GHCI_SCRATCH[11:0]: scratch <= merge(scratch, reg_wdata, wmask);
				GHCI_CTRL[11:0]:
					if (reg_wstrb[0])
						ctrl_wdt_en <= reg_wdata[GHCI_CTRL_WDT_EN];
				GHCI_IRQ_ENABLE[11:0]:
					if (reg_wstrb[0])
						irq_enable <= reg_wdata[6:0];
				GHCI_WDT_CYCLES[11:0]: wdt_cycles <= merge(wdt_cycles, reg_wdata, wmask);
				default: ;
				endcase
				if (open_state) begin
					case (wa)
					GHCI_RING_BASE[11:0]:
						ring_base <= merge(ring_base, reg_wdata, wmask) & 32'hFFFFFFE0;
					GHCI_RING_SIZE[11:0]:
						if (reg_wstrb[0])
							ring_size <= reg_wdata[4:0] < 5'd10 ? 5'd10 :
								reg_wdata[4:0] > 5'd20 ? 5'd20 : reg_wdata[4:0];
					GHCI_APERTURE_BASE[11:0]:
						ap_base <= merge(ap_base, reg_wdata, wmask) &
							~{{(32 - LINE_SHIFT){1'b0}}, {LINE_SHIFT{1'b1}}};
					GHCI_APERTURE_LIMIT[11:0]:
						ap_limit <= merge(ap_limit, reg_wdata, wmask) &
							~{{(32 - LINE_SHIFT){1'b0}}, {LINE_SHIFT{1'b1}}};
					default: ;
					endcase
				end
			end

			/* RESET: W1S; from any state. */
			case (rs)
			RS_NONE:
				if (wr_hcr && wa == GHCI_CTRL[11:0] && reg_wstrb[0] &&
				    reg_wdata[GHCI_CTRL_RESET])
					rs <= RS_QUIESCE;
			RS_QUIESCE:
				if (mc_idle)
					rs <= RS_PULSE;
			RS_PULSE:
				rs <= RS_NONE;
			default:
				rs <= RS_NONE;
			endcase

			/* AXI_STUCK: quiesced for 4 * WDT_CYCLES without AXI_IDLE. */
			if (quiesce && !mc_idle) begin
				if (stuck_count >= {wdt_cycles, 2'b00})
					axi_stuck <= 1'b1;
				else
					stuck_count <= stuck_count + 34'd1;
			end else begin
				stuck_count <= 34'd0;
			end
			if (rs == RS_PULSE)
				axi_stuck <= 1'b0;
		end
	end

	/* The core part: cleared by RESET as well (design §2.6). */
	always @(posedge clk) begin
		if (!core_rst_n) begin
			ctrl_run <= 1'b0;
			ctrl_halt <= 1'b0;
			irq_status <= 7'd0;
			ring_wptr <= 32'd0;
			fault_addr <= 32'd0;
			fault_info <= 32'd0;
			faulted <= 1'b0;
			fence_last <= 32'd0;
			halted_q <= 1'b0;
		end else begin
			halted_q <= halted;
			irq_status <= (irq_status & ~irq_clear) | irq_raise;
			if (wr_hcr) begin
				case (wa)
				GHCI_CTRL[11:0]:
					if (reg_wstrb[0]) begin
						ctrl_run <= reg_wdata[GHCI_CTRL_RUN];
						ctrl_halt <= reg_wdata[GHCI_CTRL_HALT];
					end
				GHCI_RING_WPTR[11:0]: ring_wptr <= merge(ring_wptr, reg_wdata, wmask);
				GHCI_FENCE_LAST[11:0]: fence_last <= merge(fence_last, reg_wdata, wmask);
				default: ;
				endcase
			end
			if (any_fault && !faulted) begin
				faulted <= 1'b1;
				fault_addr <= new_fault_addr;
				fault_info <= new_fault_info;
			end
		end
	end

	/* The debug port's requests and responses. */
	always @(posedge clk) begin
		if (!core_rst_n) begin
			dbg_busy <= 1'b0;
			dbg_err <= 1'b0;
			dbg_addr <= 32'd0;
			dbg_data <= 32'd0;
			q_valid <= 1'b0;
			q_write <= 1'b0;
			q_word <= 32'd0;
			q_strb <= 4'd0;
		end else begin
			if (q_valid && req_ready)
				q_valid <= 1'b0;
			if (!dbg_busy && wr_dbg_addr) begin
				dbg_addr <= merge(dbg_addr, reg_wdata, wmask) & 32'hFFFFFFFC;
				dbg_busy <= 1'b1;
				dbg_err <= 1'b0;
				q_valid <= 1'b1;
				q_write <= 1'b0;
			end else if (!dbg_busy && wr_dbg_data) begin
				dbg_data <= merge(dbg_data, reg_wdata, wmask);
				dbg_busy <= 1'b1;
				dbg_err <= 1'b0;
				q_valid <= 1'b1;
				q_write <= 1'b1;
				q_word <= reg_wdata;
				q_strb <= reg_wstrb;
			end
			if (rsp_valid && dbg_busy) begin
				dbg_busy <= 1'b0;
				dbg_err <= rsp_error;
				if (!rsp_write && !rsp_error)
					dbg_data <= rsp_word;
			end
		end
	end

	/* Reads: the HCR word or the state RAM, in the next cycle. */
	reg [31:0] rd_q;
	reg rd_state;
	wire [11:0] ra = reg_raddr[11:0];
	wire rd_hcr = reg_raddr[16:12] == 5'd0;

	/* CAPS: BLT, standard state version 1, the line size. */
	/* verilator lint_off WIDTHTRUNC */
	localparam [3:0] LS4 = LINE_SHIFT;
	/* verilator lint_on WIDTHTRUNC */
	wire [31:0] caps = {8'd0, LS4, 4'd0, 4'd1, 4'd0, 4'd0, 4'b0010};
	wire [31:0] status = {12'd0, cp_state, 1'b0, quiesce, axi_stuck, mem_ready,
		ring_wptr == 32'd0, halted, faulted, mc_idle, 1'b0, 5'd0, blt_busy,
		dbg_busy || resetting};

	always @(posedge clk) begin
		if (!rst_n) begin
			rd_q <= 32'd0;
			rd_state <= 1'b0;
		end else if (reg_rd) begin
			rd_state <= reg_raddr[16:11] == 6'b000010;
			rd_q <= 32'd0;
			if (rd_hcr) begin
				case (ra)
				GHCI_MAGIC[11:0]: rd_q <= GHCI_MAGIC_VALUE;
				GHCI_VERSION[11:0]: rd_q <= {GHCI_VERSION_MAJOR, GHCI_VERSION_MINOR};
				GHCI_VENDOR_ID[11:0]: rd_q <= VENDOR_ID;
				GHCI_DEVICE_ID[11:0]: rd_q <= DEVICE_ID;
				GHCI_ISA_ID[11:0]: rd_q <= 32'd0;
				GHCI_DEVICE_VERSION[11:0]: rd_q <= DEVICE_VERSION;
				GHCI_EXTCAP[11:0]: rd_q <= 32'd0;
				GHCI_GCLK_HZ[11:0]: rd_q <= GCLK_HZ;
				GHCI_CAPS[11:0]: rd_q <= caps;
				GHCI_CAPS2[11:0]: rd_q <= 32'd0;
				GHCI_SCRATCH[11:0]: rd_q <= scratch;
				GHCI_COUNTER[11:0]: rd_q <= counter;
				GHCI_CTRL[11:0]: rd_q <= {27'd0, ctrl_wdt_en, 1'b0, ctrl_halt, resetting, ctrl_run};
				GHCI_STATUS[11:0]: rd_q <= status;
				GHCI_IRQ_STATUS[11:0]: rd_q <= {25'd0, irq_status};
				GHCI_IRQ_ENABLE[11:0]: rd_q <= {25'd0, irq_enable};
				GHCI_WDT_CYCLES[11:0]: rd_q <= wdt_cycles;
				GHCI_RING_BASE[11:0]: rd_q <= ring_base;
				GHCI_RING_SIZE[11:0]: rd_q <= {27'd0, ring_size};
				GHCI_RING_WPTR[11:0]: rd_q <= ring_wptr;
				GHCI_APERTURE_BASE[11:0]: rd_q <= ap_base;
				GHCI_APERTURE_LIMIT[11:0]: rd_q <= ap_limit;
				GHCI_FAULT_ADDR[11:0]: rd_q <= fault_addr;
				GHCI_FAULT_INFO[11:0]: rd_q <= fault_info;
				GHCI_FENCE_LAST[11:0]: rd_q <= fence_last;
				GHCI_DBG_ADDR[11:0]: rd_q <= dbg_addr;
				GHCI_DBG_DATA[11:0]: rd_q <= dbg_data;
				GHCI_DBG_STATUS[11:0]: rd_q <= {30'd0, dbg_err, dbg_busy};
				default: rd_q <= 32'd0;
				endcase
			end
		end
	end

	assign reg_rdata = rd_state ? state_q : rd_q;

	wire unused_ok = &{1'b0, reg_waddr[1:0], reg_raddr[1:0]};
endmodule

`default_nettype wire
