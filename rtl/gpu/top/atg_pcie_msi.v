/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_pcie_msi: the MSI rule of GHCI's PCIe binding (docs/ghci.md section
 * 15.2) for the KC705: vector v's message goes out when irq[v] goes from
 * 0 to 1, and again after a write through the host's register port (BAR0)
 * to that vector's IRQ_STATUS or IRQ_ENABLE that leaves irq[v] 1.  Vector
 * 0 is the GPU's (GHCI_IRQ_STATUS, GHCI_IRQ_ENABLE), vector 1 the display
 * controller's at +0x10000 (GHCI_DC_IRQ_STATUS, GHCI_DC_IRQ_ENABLE).
 *
 * gclk side (clk): irq levels; the register port's write address taken
 * (aw_take, aw_addr) and its response taken (b_take), in order (up to 8
 * writes outstanding).  2 cycles after a matching write's response the
 * line is looked at.  The events of a vector are gathered and handed to
 * the PCIe user clock (uclk) by a 4-phase handshake through am_sync;
 * events that come meanwhile are gathered for the next round, so no event
 * is lost and close ones give one message.
 *
 * uclk side: msi_req[v] rises for a message and stays 1 until msi_ack[v]
 * (one cycle; the PCIe IP's grant or ack), then falls; a message waiting
 * meanwhile is sent next.
 * See spec/gpu/top/atg_pcie_msi.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_pcie_msi (
	input wire clk,
	input wire rst_n,
	input wire [1:0] irq,
	input wire aw_take,
	input wire [16:0] aw_addr,
	input wire b_take,
	input wire uclk,
	input wire urst_n,
	output reg [1:0] msi_req,
	input wire [1:0] msi_ack
);
	`include "ghci_regs.vh"

	/* The writes' vectors, in order. */
	wire [1:0] hit = {aw_addr == (17'h10000 | GHCI_DC_IRQ_STATUS) ||
		aw_addr == (17'h10000 | GHCI_DC_IRQ_ENABLE),
		aw_addr == GHCI_IRQ_STATUS || aw_addr == GHCI_IRQ_ENABLE};
	wire [1:0] whit;
	wire wq_ready, wq_valid;
	wire [3:0] wq_count;

	am_fifo #(.W(2), .DEPTH_LOG2(3)) wq (
		.clk(clk), .rst_n(rst_n), .in_valid(aw_take), .in_ready(wq_ready), .in_data(hit),
		.out_valid(wq_valid), .out_ready(b_take), .out_data(whit), .count(wq_count)
	);

	reg [1:0] irq_q, re1, re2;
	always @(posedge clk) begin
		if (!rst_n) begin
			irq_q <= 2'b00;
			re1 <= 2'b00;
			re2 <= 2'b00;
		end else begin
			irq_q <= irq;
			re1 <= b_take && wq_valid ? whit : 2'b00;
			re2 <= re1;
		end
	end
	wire [1:0] ev = (irq & ~irq_q) | (re2 & irq);

	/* The handshake, a vector each. */
	reg [1:0] pend, hreq, hack;
	wire [1:0] hack_g, hreq_u;

	am_sync #(.W(2)) s_ack (.clk(clk), .rst_n(rst_n), .d(hack), .q(hack_g));
	am_sync #(.W(2)) s_req (.clk(uclk), .rst_n(urst_n), .d(hreq), .q(hreq_u));

	integer v;
	always @(posedge clk) begin
		if (!rst_n) begin
			pend <= 2'b00;
			hreq <= 2'b00;
		end else
			for (v = 0; v < 2; v = v + 1) begin
				if (!hreq[v] && !hack_g[v] && (pend[v] || ev[v])) begin
					hreq[v] <= 1'b1;
					pend[v] <= 1'b0;
				end else begin
					if (hreq[v] && hack_g[v])
						hreq[v] <= 1'b0;
					if (ev[v])
						pend[v] <= 1'b1;
				end
			end
	end

	/* uclk: a message for each handshake. */
	reg [1:0] mpend;
	always @(posedge uclk) begin
		if (!urst_n) begin
			hack <= 2'b00;
			mpend <= 2'b00;
			msi_req <= 2'b00;
		end else
			for (v = 0; v < 2; v = v + 1) begin
				hack[v] <= hreq_u[v];
				if (msi_req[v]) begin
					if (msi_ack[v])
						msi_req[v] <= 1'b0;
					if (hreq_u[v] && !hack[v])
						mpend[v] <= 1'b1;
				end else if (mpend[v] || (hreq_u[v] && !hack[v])) begin
					msi_req[v] <= 1'b1;
					mpend[v] <= 1'b0;
				end
			end
	end

	wire unused_ok = &{1'b0, wq_ready, wq_count};
endmodule

`default_nettype wire
