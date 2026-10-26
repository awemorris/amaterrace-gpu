/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_pcie_msi: the MSI rule of GHCI's PCIe binding (docs/ghci.md section
 * 15.2) for FPGA board tops, one vector: the message goes out when irq
 * (GHCI's interrupt line, OR(IRQ_STATUS & IRQ_ENABLE)) goes from 0 to 1, and
 * again after a write through the host's register port (BAR0) to
 * IRQ_STATUS or IRQ_ENABLE that leaves irq 1.  The display controller's
 * events are bits of IRQ_STATUS (DISP2), so the one vector covers them.
 *
 * gclk side (clk): the irq level; the register port's write address taken
 * (aw_take, aw_addr) and its response taken (b_take), in order (up to 8
 * writes outstanding).  2 cycles after a matching write's response the
 * line is looked at.  The events are gathered and handed to the PCIe user
 * clock (uclk) by a 4-phase handshake through am_sync; events that come
 * meanwhile are gathered for the next round, so no event is lost and
 * close ones give one message.
 *
 * uclk side: msi_req rises for a message and stays 1 until msi_ack (one
 * cycle; the PCIe IP's grant or ack), then falls; a message waiting
 * meanwhile is sent next.
 * See spec/bsp/pcie/atg_pcie_msi.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_pcie_msi #(
	parameter [16:0] IRQ_STATUS_ADDR = 17'h00038, // GHCI_IRQ_STATUS
	parameter [16:0] IRQ_ENABLE_ADDR = 17'h0003C  // GHCI_IRQ_ENABLE
) (
	input wire clk,
	input wire rst_n,
	input wire irq,
	input wire aw_take,
	input wire [16:0] aw_addr,
	input wire b_take,
	input wire uclk,
	input wire urst_n,
	output reg msi_req,
	input wire msi_ack
);
	/* The writes, in order: does each re-arm the message? */
	wire hit = (aw_addr == IRQ_STATUS_ADDR) || (aw_addr == IRQ_ENABLE_ADDR);
	wire whit;
	wire wq_ready, wq_valid;
	wire [3:0] wq_count;

	am_fifo #(.W(1), .DEPTH_LOG2(3)) wq (
		.clk(clk), .rst_n(rst_n), .in_valid(aw_take), .in_ready(wq_ready), .in_data(hit),
		.out_valid(wq_valid), .out_ready(b_take), .out_data(whit), .count(wq_count)
	);

	reg irq_q, re1, re2;
	always @(posedge clk) begin
		if (!rst_n) begin
			irq_q <= 1'b0;
			re1 <= 1'b0;
			re2 <= 1'b0;
		end else begin
			irq_q <= irq;
			re1 <= b_take && wq_valid && whit;
			re2 <= re1;
		end
	end
	wire ev = (irq && !irq_q) || (re2 && irq);

	/* The handshake. */
	reg pend, hreq, hack;
	wire hack_g, hreq_u;

	am_sync #(.W(1)) s_ack (.clk(clk), .rst_n(rst_n), .d(hack), .q(hack_g));
	am_sync #(.W(1)) s_req (.clk(uclk), .rst_n(urst_n), .d(hreq), .q(hreq_u));

	always @(posedge clk) begin
		if (!rst_n) begin
			pend <= 1'b0;
			hreq <= 1'b0;
		end else if (!hreq && !hack_g && (pend || ev)) begin
			hreq <= 1'b1;
			pend <= 1'b0;
		end else begin
			if (hreq && hack_g)
				hreq <= 1'b0;
			if (ev)
				pend <= 1'b1;
		end
	end

	/* uclk: a message for each handshake. */
	reg mpend;
	always @(posedge uclk) begin
		if (!urst_n) begin
			hack <= 1'b0;
			mpend <= 1'b0;
			msi_req <= 1'b0;
		end else begin
			hack <= hreq_u;
			if (msi_req) begin
				if (msi_ack)
					msi_req <= 1'b0;
				if (hreq_u && !hack)
					mpend <= 1'b1;
			end else if (mpend || (hreq_u && !hack)) begin
				msi_req <= 1'b1;
				mpend <= 1'b0;
			end
		end
	end

	wire unused_ok = &{1'b0, wq_ready, wq_count};
endmodule

`default_nettype wire
