/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_win: The CPU's data-bus decoder and control window: routes
 * loads/stores to DMEM or to the window registers (class V packet,
 * UOP_FIFO, STATE read, FENCE_LAST, cycle counter, RESULT, interrupt), and
 * the sub-bus to atg_cpu_dma and atg_cpu_fw.
 *
 * Decode of d_addr: 0x0001_xxxx DMEM (a load answers the next cycle with
 * m_rdata, a store at once); 0xF000_00xx the window, word index d_addr[7:2]
 * (whole words; d_be is ignored): 0x00-0x0F this module's registers
 * (answer at once, except STATE_DATA one cycle later and UOP/UOP_LAST
 * while the FIFO is full: wait, stall = 1), 0x10-0x3F the sub-bus
 * (one-cycle sb_we/sb_re, read data at once); anything else answers at
 * once with 0 and drops a store.
 *
 * Class V packet: PKT_INFO[31] = v_valid until DONE (then 0 until v_valid
 * falls); reading PKT_INFO with [31] = 1 takes the packet (its interrupt
 * cause goes away).  DONE pulses v_done once the UOP_FIFO is empty.
 * fw_active is PKT_INFO[31]: the sequencer takes µops only while a packet
 * is open.  irq = |(IRQ & IRQ_EN): [0] packet waiting and not taken,
 * [1] fence event (sticky, W1C), [2] halt_req.
 * See spec/gpu/cp/atg_cpu_win.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_win #(
	parameter UOP_DEPTH_LOG2 = 4	/* UOP_FIFO depth log2 (16 dwords) */
) (
	input wire clk,
	input wire rst_n,
	/* Core data port */
	input wire d_valid,
	input wire d_write,
	input wire [31:0] d_addr,
	input wire [31:0] d_wdata,
	input wire [3:0] d_be,
	output wire d_ready,
	output reg [31:0] d_rdata,
	/* DMEM data port (atg_cpu_mem) */
	output wire m_en,
	output wire [3:0] m_we,
	output wire [31:0] m_addr,
	output wire [31:0] m_wdata,
	input wire [31:0] m_rdata,
	/* Sub-bus to atg_cpu_dma and atg_cpu_fw */
	output wire sb_we,
	output wire sb_re,
	output wire [5:0] sb_idx,
	output wire [31:0] sb_wdata,
	input wire [31:0] dma_rdata,
	input wire [31:0] fw_rdata,
	/* Class V packet (from atg_cp_ring) */
	input wire v_valid,
	input wire [31:0] v_addr,
	input wire [15:0] v_dwords,
	input wire [7:0] v_tag,
	output reg v_done,
	/* µops to atg_cp_seq */
	output wire fw_valid,
	input wire fw_ready,
	output wire [31:0] fw_data,
	output wire fw_last,
	output wire fw_active,
	/* Other */
	output wire [8:0] st_ridx,
	input wire [31:0] st_rdata,
	input wire [31:0] fence_last,
	input wire fence_ev,
	input wire halt_req,
	output wire irq,
	output reg ev_result,
	output wire stall
);
	/* Window word indices. */
	localparam [5:0] W_PKT_ADDR = 6'h00;
	localparam [5:0] W_PKT_DWORDS = 6'h01;
	localparam [5:0] W_PKT_INFO = 6'h02;
	localparam [5:0] W_DONE = 6'h03;
	localparam [5:0] W_UOP = 6'h04;
	localparam [5:0] W_UOP_LAST = 6'h05;
	localparam [5:0] W_UOP_FREE = 6'h06;
	localparam [5:0] W_STATE_IDX = 6'h07;
	localparam [5:0] W_STATE_DATA = 6'h08;
	localparam [5:0] W_FENCE_LAST = 6'h09;
	localparam [5:0] W_CYCLE = 6'h0A;
	localparam [5:0] W_RESULT = 6'h0B;
	localparam [5:0] W_IRQ = 6'h0C;
	localparam [5:0] W_IRQ_EN = 6'h0D;

	localparam [UOP_DEPTH_LOG2:0] DEPTH = 1 << UOP_DEPTH_LOG2;

	/* Access FSM: IDLE, or one wait cycle for a DMEM load or STATE_DATA. */
	localparam S_IDLE = 1'b0;
	localparam S_WAIT1 = 1'b1;

	reg state;
	reg w_state;	/* the waiting read is STATE_DATA (else DMEM) */

	wire in_dmem = d_addr[31:16] == 16'h0001;
	wire in_win = d_addr[31:8] == 24'hF0_0000;
	wire [5:0] idx = d_addr[7:2];
	wire own = in_win && !idx[5] && !idx[4];
	wire sub = in_win && (idx[5] || idx[4]);
	wire acc = d_valid && state == S_IDLE;

	/* Registers. */
	reg [8:0] st_idx;
	reg [31:0] cycle;
	reg [2:0] irq_en;
	reg fence_pend;
	reg taken;	/* PKT_INFO read while the packet waited */
	reg done_pend;	/* DONE written, waiting for the FIFO to drain */
	reg done_sent;	/* v_done given, v_valid not yet fallen */

	wire pkt = v_valid && !done_sent;
	wire [2:0] cause = {halt_req, fence_pend, pkt && !taken};

	/* UOP_FIFO. */
	wire uop_wr = acc && own && d_write && (idx == W_UOP || idx == W_UOP_LAST);
	wire f_ready;
	wire f_valid;
	wire [UOP_DEPTH_LOG2:0] f_count;

	am_fifo #(.W(33), .DEPTH_LOG2(UOP_DEPTH_LOG2)) uop_fifo (
		.clk(clk), .rst_n(rst_n),
		.in_valid(uop_wr), .in_ready(f_ready), .in_data({idx == W_UOP_LAST, d_wdata}),
		.out_valid(f_valid), .out_ready(fw_ready), .out_data({fw_last, fw_data}),
		.count(f_count)
	);

	assign fw_valid = f_valid;
	assign fw_active = pkt;
	assign stall = uop_wr && !f_ready;
	assign irq = |(cause & irq_en);
	assign st_ridx = st_idx;

	/* DMEM. */
	assign m_en = acc && in_dmem;
	assign m_we = d_write ? d_be : 4'd0;
	assign m_addr = {16'd0, d_addr[15:0]};
	assign m_wdata = d_wdata;

	/* Sub-bus. */
	assign sb_we = acc && sub && d_write;
	assign sb_re = acc && sub && !d_write;
	assign sb_idx = idx;
	assign sb_wdata = d_wdata;

	/* Ready: one wait for DMEM loads and STATE_DATA, UOP waits while full. */
	wire need_wait = !d_write && (in_dmem || (own && idx == W_STATE_DATA));

	assign d_ready = d_valid && (state == S_WAIT1 || (!need_wait && !stall));

	always @(*) begin
		d_rdata = 32'd0;
		if (state == S_WAIT1)
			d_rdata = w_state ? st_rdata : m_rdata;
		else if (sub)
			d_rdata = dma_rdata | fw_rdata;
		else if (own)
			case (idx)
			W_PKT_ADDR: d_rdata = v_addr;
			W_PKT_DWORDS: d_rdata = {16'd0, v_dwords};
			W_PKT_INFO: d_rdata = {pkt, 23'd0, v_tag};
			W_UOP_FREE: d_rdata = {{(31 - UOP_DEPTH_LOG2){1'b0}}, DEPTH - f_count};
			W_STATE_IDX: d_rdata = {23'd0, st_idx};
			W_FENCE_LAST: d_rdata = fence_last;
			W_CYCLE: d_rdata = cycle;
			W_IRQ: d_rdata = {29'd0, cause};
			W_IRQ_EN: d_rdata = {29'd0, irq_en};
			default: d_rdata = 32'd0;
			endcase
	end

	wire own_wr = acc && own && d_write;
	wire own_rd = acc && own && !d_write;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			w_state <= 1'b0;
			st_idx <= 9'd0;
			cycle <= 32'd0;
			irq_en <= 3'd0;
			fence_pend <= 1'b0;
			taken <= 1'b0;
			done_pend <= 1'b0;
			done_sent <= 1'b0;
			v_done <= 1'b0;
			ev_result <= 1'b0;
		end else begin
			cycle <= cycle + 32'd1;
			v_done <= 1'b0;
			ev_result <= 1'b0;
			case (state)
			S_IDLE:
				if (acc && need_wait) begin
					state <= S_WAIT1;
					w_state <= !in_dmem;
				end
			default:
				state <= S_IDLE;
			endcase
			if (own_wr && idx == W_STATE_IDX)
				st_idx <= d_wdata[8:0];
			if (own_wr && idx == W_IRQ_EN)
				irq_en <= d_wdata[2:0];
			if (own_wr && idx == W_RESULT)
				ev_result <= 1'b1;
			if (fence_ev)
				fence_pend <= 1'b1;
			else if (own_wr && idx == W_IRQ && d_wdata[1])
				fence_pend <= 1'b0;
			if (own_rd && idx == W_PKT_INFO && pkt)
				taken <= 1'b1;
			if (own_wr && idx == W_DONE && pkt)
				done_pend <= 1'b1;
			if (done_pend && !f_valid) begin
				v_done <= 1'b1;
				done_pend <= 1'b0;
				taken <= 1'b0;
				done_sent <= 1'b1;
			end
			if (!v_valid)
				done_sent <= 1'b0;
		end
	end

	wire unused_ok = &{1'b0, d_addr[1:0]};
endmodule

`default_nettype wire
