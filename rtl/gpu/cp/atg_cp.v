/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp: the command processor, version 0 (WS288 p003): the host side
 * of GHCI without the ring.  It holds the GHCI host control registers
 * (docs/ghci.md) on the register bus of am_axi_regs, the state register
 * file, and the controls of the other blocks.  There is no ring yet (it
 * comes with the command set of design v3): RUN is kept and moves the
 * state to RUNNING, but nothing is fetched, CAPS[0] is 0 and STEP does
 * nothing.  What it does:
 *
 *   - the identification registers, SCRATCH, COUNTER, CAPS, GCLK_HZ;
 *   - the extended capability list at 0x100 with one entry, PERF: PERF0
 *     counts the blitter's busy cycles, PERF1 the cycles with memory
 *     accesses outstanding; PERF_CTRL[0] clears them;
 *   - STATE[0..511] in a block RAM, written through the alias at 0x1000
 *     (whole words; a write with a partial WSTRB is ignored) and passed on
 *     to the blocks (st_we), read back through the alias;
 *   - KICK.BLIT: starts the blitter (atg_blt) on its STATE range; KICK.DRAW
 *     and KICK.DISPATCH, for units this GPU does not have, are a fault of
 *     kind OPCODE;
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
	parameter [31:0] DEVICE_VERSION = 32'h00000002	/* 0.2: p003, CP v0 */
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
	input wire rsp_error,

	/*
	 * WS288 p023: the ports of the full CP (design §7.6).  Today they are
	 * driven by the scaffold at the end of this file (stubs, all 0) and
	 * their inputs are not used; p004 and p017 connect them.
	 */
	output wire draw_kick,
	output wire cs_kick,
	output wire lc_kick,
	output wire raw_kick,
	output wire [3:0] inv,
	input wire [7:0] busy_ext,	/* STATUS[7:0] bits of VF, RX, ROP, TU, SU, SA */
	input wire vsync,
	input wire [1:0] x_fault,	/* fault sources: 0 the SUs (ISA), 1 the other blocks */
	input wire [7:0] x_fault_kind,
	input wire [63:0] x_fault_addr,
	input wire [15:0] x_fault_tag,

	output wire hcr_we,	/* the HCR snoop bus for atg_cpu */
	output wire [9:0] hcr_widx,
	output wire [31:0] hcr_wdata,
	output wire [31:0] hcr_wmask,
	output wire [9:0] hcr_ridx,
	input wire [31:0] x_rdata,
	output wire v_valid,	/* class V packets to atg_cpu */
	output wire [31:0] v_addr,
	output wire [15:0] v_dwords,
	output wire [7:0] v_tag,
	input wire v_done,
	input wire fw_valid,	/* µops from atg_cpu */
	output wire fw_ready,
	input wire [31:0] fw_data,
	input wire fw_last,
	input wire fw_active,
	input wire [8:0] cpu_st_ridx,
	output wire [31:0] cpu_st_rdata,
	output wire [31:0] cp_fence_last,
	output wire cp_fence_ev,
	output wire cp_halt,
	output wire cp_open,
	input wire cpu_fault,
	input wire [31:0] cpu_fault_addr,
	input wire cpu_stall,
	input wire cpu_result
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
	wire wr_kick_absent = wr_hcr && wa == GHCI_KICK[11:0] && reg_wstrb[0] &&
		(reg_wdata[GHCI_KICK_DRAW] || reg_wdata[GHCI_KICK_DISPATCH]);
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
	wire any_fault = mc_fault_gpu || blt_error || kick_fault || wr_kick_absent || locked_fault;
	wire [31:0] new_fault_info =
		mc_fault_gpu ? {8'd0, mc_fault_client, GHCI_FAULT_APERTURE, 3'd0, mc_fault_write, mc_fault_client} :
		blt_error ? {8'd0, BLOCK_BLT, blt_error_kind, 3'd0, 1'b0, CLIENT_BLT} :
		kick_fault ? {16'd0, GHCI_FAULT_KICK, 12'd0} :
		wr_kick_absent ? {16'd0, GHCI_FAULT_OPCODE, 12'd0} :
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

	/* The performance counters (the PERF capability). */
	reg [31:0] perf0;
	reg [31:0] perf1;
	wire perf_clear = wr_hcr && wa == GHCI_PERF_CTRL[11:0] && reg_wstrb[0] && reg_wdata[0];

	always @(posedge clk) begin
		if (!rst_n || perf_clear) begin
			perf0 <= 32'd0;
			perf1 <= 32'd0;
		end else begin
			perf0 <= perf0 + {31'd0, blt_busy};
			perf1 <= perf1 + {31'd0, !mc_idle};
		end
	end

	/* Reads: the HCR word or the state RAM, in the next cycle. */
	reg [31:0] rd_q;
	reg rd_state;
	wire [11:0] ra = reg_raddr[11:0];
	wire rd_hcr = reg_raddr[16:12] == 5'd0;

	/* CAPS: BLT, 4x4 tiles, standard state version 1, the line size. */
	/* verilator lint_off WIDTHTRUNC */
	localparam [3:0] LS4 = LINE_SHIFT;
	/* verilator lint_on WIDTHTRUNC */
	wire [31:0] caps = {8'd0, LS4, 4'd0, 4'd1, 4'b1000, 4'd0, 4'b0010};
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
				GHCI_EXTCAP[11:0]: rd_q <= {15'd0, GHCI_EXTCAP_LIST};
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
				GHCI_PERF0[11:0]: rd_q <= perf0;
				GHCI_PERF0[11:0] + 12'd4: rd_q <= perf1;
				/* The capability list: PERF only, the last entry. */
				GHCI_EXTCAP_LIST[11:0]: rd_q <= {16'd0, 8'd1, GHCI_XCAP_PERF};
				GHCI_EXTCAP_LIST[11:0] + 12'd4: rd_q <= {15'd0, GHCI_PERF_SRC0};
				GHCI_PERF_SRC0[11:0]: rd_q <= {24'd0, 8'd1};	/* the BLT's busy bit */
				GHCI_PERF_SRC0[11:0] + 12'd4: rd_q <= {24'd0, GHCI_PERF_SRC_MEM};
				GHCI_PERF_SRC0[11:0] + 12'd8: rd_q <= {24'd0, GHCI_PERF_SRC_NONE};
				GHCI_PERF_SRC0[11:0] + 12'd12: rd_q <= {24'd0, GHCI_PERF_SRC_NONE};
				GHCI_DBG_ADDR[11:0]: rd_q <= dbg_addr;
				GHCI_DBG_DATA[11:0]: rd_q <= dbg_data;
				GHCI_DBG_STATUS[11:0]: rd_q <= {30'd0, dbg_err, dbg_busy};
				default: rd_q <= 32'd0;
				endcase
			end
		end
	end

	assign reg_rdata = rd_state ? state_q : rd_q;


	/*
	 * WS288 p023 scaffold: the CP of design §7.6 as its children
	 * (spec/gpu/cp/).  They are port-only stubs and run beside the inline
	 * CP above, which still does all of the work; their outputs only feed
	 * the new ports.  p004 moves the inline logic into them and deletes it
	 * (and this comment).  The children's AMB port (am_amb_mux) is not yet
	 * connected to the MC.
	 */
	localparam SLA_W = ADDR_W - LINE_SHIFT;
	localparam SLB = LINE_BYTES * 8;

	wire s_hcr_we;
	wire [9:0] s_hcr_widx, s_hcr_ridx;
	wire [31:0] s_hcr_wdata, s_hcr_wmask;
	wire s_alias_we;
	wire [8:0] s_alias_idx, s_alias_ridx;
	wire [31:0] s_ctl_rdata, s_irq_rdata, s_ring_rdata, s_fence_rdata, s_dbg_rdata;
	wire [31:0] s_state_rdata, s_reg_rdata;
	wire s_perf_reset;

	assign hcr_we = s_hcr_we;
	assign hcr_widx = s_hcr_widx;
	assign hcr_wdata = s_hcr_wdata;
	assign hcr_wmask = s_hcr_wmask;
	assign hcr_ridx = s_hcr_ridx;

	atg_cp_regs #(
		.GCLK_HZ(GCLK_HZ), .VENDOR_ID(VENDOR_ID), .DEVICE_ID(DEVICE_ID),
		.DEVICE_VERSION(DEVICE_VERSION)
	) s_regs (
		.clk(clk), .rst_n(rst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(s_reg_rdata),
		.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx),
		.alias_we(s_alias_we), .alias_idx(s_alias_idx), .alias_ridx(s_alias_ridx),
		.ctl_rdata(s_ctl_rdata), .irq_rdata(s_irq_rdata), .ring_rdata(s_ring_rdata),
		.fence_rdata(s_fence_rdata), .dbg_rdata(s_dbg_rdata), .state_rdata(s_state_rdata),
		.x_rdata(x_rdata), .perf_busy({3'd0, blt_busy}), .perf_reset(s_perf_reset)
	);

	/* The state register file. */
	wire s_uop_we;
	wire [8:0] s_uop_idx;
	wire [31:0] s_uop_wdata;
	wire s_open, s_lock_fault;
	wire s_st_we;
	wire [8:0] s_st_idx;
	wire [31:0] s_st_wdata;

	atg_cp_state s_state (
		.clk(clk), .rst_n(rst_n),
		.alias_we(s_alias_we), .alias_idx(s_alias_idx), .alias_wdata(s_hcr_wdata),
		.alias_ridx(s_alias_ridx), .alias_rdata(s_state_rdata),
		.uop_we(s_uop_we), .uop_idx(s_uop_idx), .uop_wdata(s_uop_wdata),
		.open(s_open), .blt_busy(blt_busy), .lock_fault(s_lock_fault),
		.st_we(s_st_we), .st_idx(s_st_idx), .st_wdata(s_st_wdata),
		.cpu_ridx(cpu_st_ridx), .cpu_rdata(cpu_st_rdata)
	);

	/* The CP's three memory users behind one AMB port: ring, fence, dbg. */
	wire [2:0] s_i_req_valid, s_i_req_ready, s_i_req_write, s_i_rsp_valid;
	wire [3*SLA_W-1:0] s_i_req_line;
	wire [3*LINE_BYTES-1:0] s_i_req_be;
	wire [3*SLB-1:0] s_i_req_wdata;
	wire [23:0] s_i_req_tag;
	wire s_i_rsp_write, s_i_rsp_error;
	wire [7:0] s_i_rsp_tag;
	wire [SLB-1:0] s_i_rsp_rdata;
	wire s_o_req_valid, s_o_req_write;
	wire [SLA_W-1:0] s_o_req_line;
	wire [LINE_BYTES-1:0] s_o_req_be;
	wire [SLB-1:0] s_o_req_wdata;
	wire [7:0] s_o_req_tag;

	am_amb_mux #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .N(3), .ID_W(2)
	) s_amb (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid(s_i_req_valid), .i_req_ready(s_i_req_ready),
		.i_req_write(s_i_req_write), .i_req_line(s_i_req_line), .i_req_be(s_i_req_be),
		.i_req_wdata(s_i_req_wdata), .i_req_tag(s_i_req_tag),
		.i_rsp_valid(s_i_rsp_valid), .i_rsp_write(s_i_rsp_write), .i_rsp_tag(s_i_rsp_tag),
		.i_rsp_rdata(s_i_rsp_rdata), .i_rsp_error(s_i_rsp_error),
		.o_req_valid(s_o_req_valid), .o_req_ready(1'b0), .o_req_write(s_o_req_write),
		.o_req_line(s_o_req_line), .o_req_be(s_o_req_be), .o_req_wdata(s_o_req_wdata),
		.o_req_tag(s_o_req_tag),
		.o_rsp_valid(1'b0), .o_rsp_write(1'b0), .o_rsp_tag(8'd0), .o_rsp_rdata({SLB{1'b0}}),
		.o_rsp_error(1'b0)
	);

	/* The ring. */
	wire s_run, s_halt, s_step;
	wire s_n_valid, s_n_ready, s_n_last;
	wire [31:0] s_n_data;
	wire s_ring_empty, s_retire, s_ring_busy;
	wire s_ring_fault;
	wire [3:0] s_ring_fault_kind;
	wire [31:0] s_ring_fault_addr;
	wire [7:0] s_ring_fault_tag;

	atg_cp_ring #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) s_ring (
		.clk(clk), .rst_n(core_rst_n),
		.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx), .hcr_rdata(s_ring_rdata),
		.run(s_run), .halt(s_halt), .step(s_step), .open(s_open),
		.n_valid(s_n_valid), .n_ready(s_n_ready), .n_data(s_n_data), .n_last(s_n_last),
		.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag),
		.v_done(v_done),
		.empty(s_ring_empty), .retire(s_retire), .busy(s_ring_busy),
		.fault(s_ring_fault), .fault_kind(s_ring_fault_kind), .fault_addr(s_ring_fault_addr),
		.fault_tag(s_ring_fault_tag),
		.req_valid(s_i_req_valid[0]), .req_ready(s_i_req_ready[0]),
		.req_write(s_i_req_write[0]), .req_line(s_i_req_line[0*SLA_W +: SLA_W]),
		.req_be(s_i_req_be[0*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(s_i_req_wdata[0*SLB +: SLB]), .req_tag(s_i_req_tag[0*8 +: 8]),
		.rsp_valid(s_i_rsp_valid[0]), .rsp_write(s_i_rsp_write), .rsp_tag(s_i_rsp_tag),
		.rsp_rdata(s_i_rsp_rdata), .rsp_error(s_i_rsp_error)
	);

	/* The sequencer. */
	wire s_blt_kick;
	wire s_f_valid, s_f_ready, s_f_irq, s_f_busy;
	wire [1:0] s_f_op;
	wire [31:0] s_f_addr, s_f_value, s_f_aux;
	wire s_seq_busy, s_cmd_active;
	wire s_seq_fault;
	wire [3:0] s_seq_fault_kind;
	wire [31:0] s_seq_fault_addr;
	wire [7:0] s_seq_fault_tag;

	atg_cp_seq s_seq (
		.clk(clk), .rst_n(core_rst_n),
		.n_valid(s_n_valid), .n_ready(s_n_ready), .n_data(s_n_data), .n_last(s_n_last),
		.fw_valid(fw_valid), .fw_ready(fw_ready), .fw_data(fw_data), .fw_last(fw_last),
		.fw_active(fw_active), .halt(s_halt),
		.uop_we(s_uop_we), .uop_idx(s_uop_idx), .uop_wdata(s_uop_wdata),
		.blt_kick(s_blt_kick), .draw_kick(draw_kick), .cs_kick(cs_kick), .lc_kick(lc_kick),
		.raw_kick(raw_kick), .inv(inv), .perf_reset(s_perf_reset),
		.busy_in({busy_ext[7:2], blt_busy, 1'b0}), .vsync(vsync),
		.f_valid(s_f_valid), .f_ready(s_f_ready), .f_op(s_f_op), .f_addr(s_f_addr),
		.f_value(s_f_value), .f_aux(s_f_aux), .f_irq(s_f_irq), .f_busy(s_f_busy),
		.busy(s_seq_busy), .cmd_active(s_cmd_active),
		.fault(s_seq_fault), .fault_kind(s_seq_fault_kind), .fault_addr(s_seq_fault_addr),
		.fault_tag(s_seq_fault_tag)
	);

	/* Fences. */
	wire s_fence_fault;
	wire [3:0] s_fence_fault_kind;
	wire [31:0] s_fence_fault_addr;
	wire [7:0] s_fence_fault_tag;

	atg_cp_fence #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) s_fence (
		.clk(clk), .rst_n(core_rst_n),
		.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx), .hcr_rdata(s_fence_rdata),
		.f_valid(s_f_valid), .f_ready(s_f_ready), .f_op(s_f_op), .f_addr(s_f_addr),
		.f_value(s_f_value), .f_aux(s_f_aux), .f_irq(s_f_irq), .f_busy(s_f_busy),
		.ev_fence(cp_fence_ev), .fence_last(cp_fence_last),
		.fault(s_fence_fault), .fault_kind(s_fence_fault_kind),
		.fault_addr(s_fence_fault_addr), .fault_tag(s_fence_fault_tag),
		.req_valid(s_i_req_valid[1]), .req_ready(s_i_req_ready[1]),
		.req_write(s_i_req_write[1]), .req_line(s_i_req_line[1*SLA_W +: SLA_W]),
		.req_be(s_i_req_be[1*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(s_i_req_wdata[1*SLB +: SLB]), .req_tag(s_i_req_tag[1*8 +: 8]),
		.rsp_valid(s_i_rsp_valid[1]), .rsp_write(s_i_rsp_write), .rsp_tag(s_i_rsp_tag),
		.rsp_rdata(s_i_rsp_rdata), .rsp_error(s_i_rsp_error)
	);

	/* Control: state machine, RESET order, watchdog, faults. */
	wire s_quiesce, s_mc_flush, s_core_rst_n;
	wire [3:0] s_cp_state;
	wire [2:0] s_host_kick;
	wire s_ev_halted, s_ev_fault, s_ev_wdt;

	atg_cp_ctl s_ctl (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx), .hcr_rdata(s_ctl_rdata),
		.mc_idle(mc_idle), .mem_ready(mem_ready),
		.busy_in({busy_ext[7:2], blt_busy, s_seq_busy || s_ring_busy}),
		.ring_empty(s_ring_empty), .cmd_active(s_cmd_active),
		.mc_fault(mc_fault), .mc_fault_client(mc_fault_client), .mc_fault_addr(mc_fault_addr),
		.mc_fault_write(mc_fault_write),
		.src_fault({x_fault[1], blt_error, cpu_fault, x_fault[0], s_fence_fault,
			s_lock_fault, s_seq_fault, s_ring_fault}),
		.src_kind({x_fault_kind[7:4], blt_error_kind, GHCI_FAULT_WATCHDOG, x_fault_kind[3:0],
			s_fence_fault_kind, GHCI_FAULT_LOCKED, s_seq_fault_kind, s_ring_fault_kind}),
		.src_addr({x_fault_addr[63:32], 32'd0, cpu_fault_addr, x_fault_addr[31:0],
			s_fence_fault_addr, 32'd0, s_seq_fault_addr, s_ring_fault_addr}),
		.src_tag({x_fault_tag[15:8], 8'd0, 8'd0, x_fault_tag[7:0], s_fence_fault_tag, 8'd0,
			s_seq_fault_tag, s_ring_fault_tag}),
		.run(s_run), .halt(s_halt), .quiesce(s_quiesce), .mc_flush(s_mc_flush),
		.core_rst_n(s_core_rst_n), .open(s_open), .cp_state(s_cp_state),
		.host_kick(s_host_kick), .step(s_step),
		.ev_halted(s_ev_halted), .ev_fault(s_ev_fault), .ev_wdt(s_ev_wdt)
	);

	assign cp_halt = s_halt;
	assign cp_open = s_open;

	/* Interrupts and the debug port. */
	wire s_irq, s_dbg_done;

	atg_cp_irq s_irqs (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx), .hcr_rdata(s_irq_rdata),
		.ev({s_retire, cpu_result, s_ev_halted, 1'b0, s_dbg_done, s_ev_wdt, s_ring_empty,
			s_ev_fault, cp_fence_ev}),
		.irq(s_irq)
	);

	atg_cp_dbg #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) s_dbg (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx), .hcr_rdata(s_dbg_rdata),
		.ev_done(s_dbg_done),
		.req_valid(s_i_req_valid[2]), .req_ready(s_i_req_ready[2]),
		.req_write(s_i_req_write[2]), .req_line(s_i_req_line[2*SLA_W +: SLA_W]),
		.req_be(s_i_req_be[2*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(s_i_req_wdata[2*SLB +: SLB]), .req_tag(s_i_req_tag[2*8 +: 8]),
		.rsp_valid(s_i_rsp_valid[2]), .rsp_write(s_i_rsp_write), .rsp_tag(s_i_rsp_tag),
		.rsp_rdata(s_i_rsp_rdata), .rsp_error(s_i_rsp_error)
	);

	/* What the scaffold produces and nothing uses yet. */
	wire unused_scaffold = &{1'b0, s_reg_rdata, s_st_we, s_st_idx, s_st_wdata, s_blt_kick,
		s_o_req_valid, s_o_req_write, s_o_req_line, s_o_req_be, s_o_req_wdata, s_o_req_tag,
		s_quiesce, s_mc_flush, s_core_rst_n, s_cp_state, s_host_kick, s_irq,
		cpu_stall, s_i_rsp_tag, busy_ext[1:0]};

	wire unused_ok = &{1'b0, reg_waddr[1:0], reg_raddr[1:0]};
endmodule

`default_nettype wire
