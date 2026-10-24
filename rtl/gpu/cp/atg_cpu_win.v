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
 * Every access is taken in one cycle and answered (d_ready) the next; a
 * UOP/UOP_LAST write waits there while the FIFO is full (stall = 1).
 * Decode of d_addr: 0x0001_xxxx DMEM (m_* in the cycle it is taken, the
 * load data is m_rdata in the answer cycle); 0xF000_00xx the window, word
 * index d_addr[7:2] (whole words; d_be is ignored), acted on in the
 * answer cycle from registered copies: 0x00-0x0F this module's registers,
 * 0x10-0x3F the sub-bus (one-cycle sb_we/sb_re, read data in that cycle);
 * anything else answers with 0 and drops a store.
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
	output wire [9:0] st_ridx,
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

	/* Access FSM: IDLE takes the access (DMEM is accessed there, so its
	 * data is ready a cycle later) and registers its address and data; ACK
	 * does the window's work from those registers and answers (d_ready),
	 * or waits while a UOP write finds the FIFO full.  Nothing in the
	 * answer path depends on d_addr in the same cycle (timing). */
	localparam S_IDLE = 1'b0;
	localparam S_ACK = 1'b1;

	reg state;
	reg q_dmem, q_own, q_sub, q_write;
	reg [5:0] q_idx;
	reg [31:0] q_wdata;

	wire in_dmem = d_addr[31:16] == 16'h0001;
	wire in_win = d_addr[31:8] == 24'hF0_0000;
	wire [5:0] idx = d_addr[7:2];
	wire take = d_valid && state == S_IDLE;
	wire ack = state == S_ACK;

	/* Registers. */
	reg [9:0] st_idx;
	reg [31:0] cycle;
	reg [2:0] irq_en;
	reg fence_pend;
	reg taken;	/* PKT_INFO read while the packet waited */
	reg done_pend;	/* DONE written, waiting for the FIFO to drain */
	reg done_sent;	/* v_done given, v_valid not yet fallen */

	wire pkt = v_valid && !done_sent;
	wire [2:0] cause = {halt_req, fence_pend, pkt && !taken};

	wire own_wr = ack && q_own && q_write;
	wire own_rd = ack && q_own && !q_write;

	/* UOP_FIFO. */
	wire q_uop = q_own && q_write && (q_idx == W_UOP || q_idx == W_UOP_LAST);
	wire f_ready;
	wire f_valid;
	wire [UOP_DEPTH_LOG2:0] f_count;

	am_fifo #(.W(33), .DEPTH_LOG2(UOP_DEPTH_LOG2)) uop_fifo (
		.clk(clk), .rst_n(rst_n),
		.in_valid(ack && q_uop), .in_ready(f_ready),
		.in_data({q_idx == W_UOP_LAST, q_wdata}),
		.out_valid(f_valid), .out_ready(fw_ready), .out_data({fw_last, fw_data}),
		.count(f_count)
	);

	assign fw_valid = f_valid;
	assign fw_active = pkt;
	assign stall = ack && q_uop && !f_ready;
	assign irq = |(cause & irq_en);
	assign st_ridx = st_idx;
	assign d_ready = ack && !stall;

	/* DMEM: accessed in the cycle the access is taken. */
	assign m_en = take && in_dmem;
	assign m_we = d_write ? d_be : 4'd0;
	assign m_addr = {16'd0, d_addr[15:0]};
	assign m_wdata = d_wdata;

	/* Sub-bus: in the answer cycle. */
	assign sb_we = ack && q_sub && q_write;
	assign sb_re = ack && q_sub && !q_write;
	assign sb_idx = q_idx;
	assign sb_wdata = q_wdata;

	always @(*) begin
		d_rdata = 32'd0;
		if (q_dmem)
			d_rdata = m_rdata;
		else if (q_sub)
			d_rdata = dma_rdata | fw_rdata;
		else if (q_own)
			case (q_idx)
			W_PKT_ADDR: d_rdata = v_addr;
			W_PKT_DWORDS: d_rdata = {16'd0, v_dwords};
			W_PKT_INFO: d_rdata = {pkt, 23'd0, v_tag};
			W_UOP_FREE: d_rdata = {{(31 - UOP_DEPTH_LOG2){1'b0}}, DEPTH - f_count};
			W_STATE_IDX: d_rdata = {22'd0, st_idx};
			W_STATE_DATA: d_rdata = st_rdata;
			W_FENCE_LAST: d_rdata = fence_last;
			W_CYCLE: d_rdata = cycle;
			W_IRQ: d_rdata = {29'd0, cause};
			W_IRQ_EN: d_rdata = {29'd0, irq_en};
			default: d_rdata = 32'd0;
			endcase
		if (q_write)
			d_rdata = 32'd0;
	end

	always @(posedge clk) begin
		if (take) begin
			q_idx <= idx;
			q_wdata <= d_wdata;
			q_write <= d_write;
		end
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			q_dmem <= 1'b0;
			q_own <= 1'b0;
			q_sub <= 1'b0;
			st_idx <= 10'd0;
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
			if (take) begin
				state <= S_ACK;
				q_dmem <= in_dmem;
				q_own <= in_win && !idx[5] && !idx[4];
				q_sub <= in_win && (idx[5] || idx[4]);
			end else if (ack && !stall) begin
				state <= S_IDLE;
			end
			if (own_wr && q_idx == W_STATE_IDX)
				st_idx <= q_wdata[9:0];
			if (own_wr && q_idx == W_IRQ_EN)
				irq_en <= q_wdata[2:0];
			if (own_wr && q_idx == W_RESULT)
				ev_result <= 1'b1;
			if (fence_ev)
				fence_pend <= 1'b1;
			else if (own_wr && q_idx == W_IRQ && q_wdata[1])
				fence_pend <= 1'b0;
			if (own_rd && q_idx == W_PKT_INFO && pkt)
				taken <= 1'b1;
			if (own_wr && q_idx == W_DONE && pkt)
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
