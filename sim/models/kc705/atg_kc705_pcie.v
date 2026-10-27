/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_pcie (simulation model): stands in for
 * boards/kc705/lib/atg_kc705_pcie.v (same name and ports) in the KC705
 * board testbenches: the host's side of the PCIe link as tasks.
 *
 *   user_clk 125 MHz; user_rst_n and link_up rise 20 cycles after
 *   pcie_perst_n.
 *   bar0_write(off, data), bar0_read(off, data): one 32-bit access on the
 *   BAR0 AXI4 master (m0_*: ID 0, single beats, as the bridge's register
 *   BAR); resp is left in bar0_resp.
 *   bar2_write(off, data, strb), bar2_read(off, data): one 128-bit beat
 *   on the BAR2 AXI4 master (m2_*); bar2_write4/bar2_read4: an INCR burst
 *   of 4 beats (64 bytes).  resp in bar2_resp.
 *   MSI (one vector): msi_ack answers msi_req after MSI_DELAY cycles (a
 *   pulse); msi_count counts the messages.
 *   The GPU -> host slave (s_*, 512-bit, in s_clk; ws288 p039) is the
 *   host's memory: bus addresses below 0x8000_0000 (the bridge's AXI BAR)
 *   are HOST_BYTES of memory (the address modulo HOST_BYTES; OKAY),
 *   others answer DECERR (writes not done).  One burst at a time each way,
 *   random ready (SEED).  host_write(addr, data) and host_read(addr, data)
 *   are 32-bit accesses of the testbench to that memory (no bus cycle);
 *   host_wr_n and host_rd_n count the GPU's write and read bursts,
 *   host_err_n those answered DECERR.
 * The PCIe pins are idle.  The payload of a master channel is stable from
 * valid to the handshake (docs/style.md).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_pcie #(
	parameter integer MSI_DELAY = 5,
	parameter integer HOST_BYTES = 1 << 20,
	parameter integer SEED = 5
) (
	input wire pcie_refclk_p,
	input wire pcie_refclk_n,
	input wire pcie_perst_n,
	output wire [3:0] pcie_txp,
	output wire [3:0] pcie_txn,
	input wire [3:0] pcie_rxp,
	input wire [3:0] pcie_rxn,
	output reg user_clk = 1'b0,
	output reg user_rst_n = 1'b0,
	output wire link_up,
	/* BAR0: the register window */
	output reg [16:0] m0_awaddr = 17'd0,
	output wire [3:0] m0_awid,
	output reg m0_awvalid = 1'b0,
	input wire m0_awready,
	output reg [63:0] m0_wdata = 64'd0,
	output reg [7:0] m0_wstrb = 8'd0,
	output wire m0_wlast,
	output reg m0_wvalid = 1'b0,
	input wire m0_wready,
	input wire [3:0] m0_bid,
	input wire [1:0] m0_bresp,
	input wire m0_bvalid,
	output wire m0_bready,
	output reg [16:0] m0_araddr = 17'd0,
	output wire [3:0] m0_arid,
	output wire [7:0] m0_arlen,
	output reg m0_arvalid = 1'b0,
	input wire m0_arready,
	input wire [63:0] m0_rdata,
	input wire [3:0] m0_rid,
	input wire [1:0] m0_rresp,
	input wire m0_rlast,
	input wire m0_rvalid,
	output wire m0_rready,
	/* BAR2: the local window */
	output reg [25:0] m2_awaddr = 26'd0,
	output wire [3:0] m2_awid,
	output reg [7:0] m2_awlen = 8'd0,
	output wire [2:0] m2_awsize,
	output wire [1:0] m2_awburst,
	output reg m2_awvalid = 1'b0,
	input wire m2_awready,
	output reg [127:0] m2_wdata = 128'd0,
	output reg [15:0] m2_wstrb = 16'd0,
	output reg m2_wlast = 1'b0,
	output reg m2_wvalid = 1'b0,
	input wire m2_wready,
	input wire [3:0] m2_bid,
	input wire [1:0] m2_bresp,
	input wire m2_bvalid,
	output wire m2_bready,
	output reg [25:0] m2_araddr = 26'd0,
	output wire [3:0] m2_arid,
	output reg [7:0] m2_arlen = 8'd0,
	output wire [2:0] m2_arsize,
	output wire [1:0] m2_arburst,
	output reg m2_arvalid = 1'b0,
	input wire m2_arready,
	input wire [127:0] m2_rdata,
	input wire [3:0] m2_rid,
	input wire [1:0] m2_rresp,
	input wire m2_rlast,
	input wire m2_rvalid,
	output wire m2_rready,
	/* GPU -> host memory (s_clk) */
	input wire s_clk,
	input wire s_rst_n,
	input wire [63:0] s_awaddr,
	input wire [3:0] s_awid,
	input wire [7:0] s_awlen,
	input wire [2:0] s_awsize,
	input wire [1:0] s_awburst,
	input wire s_awvalid,
	output wire s_awready,
	input wire [511:0] s_wdata,
	input wire [63:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output reg [3:0] s_bid = 4'd0,
	output reg [1:0] s_bresp = 2'b00,
	output reg s_bvalid = 1'b0,
	input wire s_bready,
	input wire [63:0] s_araddr,
	input wire [3:0] s_arid,
	input wire [7:0] s_arlen,
	input wire [2:0] s_arsize,
	input wire [1:0] s_arburst,
	input wire s_arvalid,
	output wire s_arready,
	output reg [511:0] s_rdata = 512'd0,
	output reg [3:0] s_rid = 4'd0,
	output reg [1:0] s_rresp = 2'b00,
	output reg s_rlast = 1'b0,
	output reg s_rvalid = 1'b0,
	input wire s_rready,
	/* MSI */
	input wire msi_req,
	output reg msi_ack = 1'b0
);
	always #4 user_clk = !user_clk;

	integer rcnt = 0;
	always @(posedge user_clk)
		if (!pcie_perst_n) begin
			rcnt <= 0;
			user_rst_n <= 1'b0;
		end else if (rcnt < 20)
			rcnt <= rcnt + 1;
		else
			user_rst_n <= 1'b1;
	assign link_up = user_rst_n;

	assign pcie_txp = 4'd0;
	assign pcie_txn = 4'hF;
	assign m0_awid = 4'd0;
	assign m0_wlast = 1'b1;
	assign m0_bready = 1'b1;
	assign m0_arid = 4'd0;
	assign m0_arlen = 8'd0;
	assign m0_rready = 1'b1;
	assign m2_awid = 4'd0;
	assign m2_awsize = 3'd4;
	assign m2_awburst = 2'b01;
	assign m2_bready = 1'b1;
	assign m2_arid = 4'd0;
	assign m2_arsize = 3'd4;
	assign m2_arburst = 2'b01;
	assign m2_rready = 1'b1;

	/* The responses (every ready is 1): counted and kept here. */
	integer b0_n = 0, r0_n = 0, b2_n = 0, r2_n = 0;
	reg [63:0] r0_data = 64'd0;
	reg [1:0] r0_resp = 2'b00, b0_resp = 2'b00, b2_resp = 2'b00, r2_resp = 2'b00;
	reg [511:0] r2_data = 512'd0;
	reg r2_last = 1'b0;
	always @(posedge user_clk) begin
		if (m0_bvalid) begin
			b0_n = b0_n + 1;
			b0_resp = m0_bresp;
		end
		if (m0_rvalid) begin
			r0_n = r0_n + 1;
			r0_data = m0_rdata;
			r0_resp = m0_rresp;
		end
		if (m2_bvalid) begin
			b2_n = b2_n + 1;
			b2_resp = m2_bresp;
		end
		if (m2_rvalid) begin
			r2_data[(r2_n % 4)*128 +: 128] = m2_rdata;
			if (m2_rresp != 2'b00)
				r2_resp = m2_rresp;
			r2_last = m2_rlast;
			r2_n = r2_n + 1;
		end
	end

	/* ---- BAR0 ---- */
	reg [1:0] bar0_resp = 2'b00;
	integer n0;
	task bar0_write;
		input [16:0] off;
		input [31:0] data;
		begin
			n0 = b0_n;
			@(posedge user_clk);
			m0_awaddr <= off;
			m0_awvalid <= 1'b1;
			if (off[2]) begin
				m0_wdata <= {data, 32'd0};
				m0_wstrb <= 8'hF0;
			end else begin
				m0_wdata <= {32'd0, data};
				m0_wstrb <= 8'h0F;
			end
			m0_wvalid <= 1'b1;
			@(posedge user_clk);
			while (m0_awvalid || m0_wvalid) begin
				if (m0_awready)
					m0_awvalid <= 1'b0;
				if (m0_wready)
					m0_wvalid <= 1'b0;
				@(posedge user_clk);
			end
			while (b0_n == n0)
				@(posedge user_clk);
			bar0_resp = b0_resp;
		end
	endtask
	task bar0_read;
		input [16:0] off;
		output [31:0] data;
		begin
			n0 = r0_n;
			@(posedge user_clk);
			m0_araddr <= off;
			m0_arvalid <= 1'b1;
			@(posedge user_clk);
			while (!m0_arready)
				@(posedge user_clk);
			m0_arvalid <= 1'b0;
			while (r0_n == n0)
				@(posedge user_clk);
			data = off[2] ? r0_data[63:32] : r0_data[31:0];
			bar0_resp = r0_resp;
		end
	endtask

	/* ---- BAR2 ---- */
	reg [1:0] bar2_resp = 2'b00;
	integer n2;
	task bar2_wr;
		input [25:0] off;
		input [511:0] data;
		input [63:0] strb;
		input integer beats;
		integer b;
		begin
			n2 = b2_n;
			@(posedge user_clk);
			m2_awaddr <= off;
			m2_awlen <= beats - 1;
			m2_awvalid <= 1'b1;
			@(posedge user_clk);
			while (!m2_awready)
				@(posedge user_clk);
			m2_awvalid <= 1'b0;
			for (b = 0; b < beats; b = b + 1) begin
				m2_wdata <= data[b*128 +: 128];
				m2_wstrb <= strb[b*16 +: 16];
				m2_wlast <= b == beats - 1;
				m2_wvalid <= 1'b1;
				@(posedge user_clk);
				while (!m2_wready)
					@(posedge user_clk);
			end
			m2_wvalid <= 1'b0;
			while (b2_n == n2)
				@(posedge user_clk);
			bar2_resp = b2_resp;
		end
	endtask
	task bar2_rd;
		input [25:0] off;
		output [511:0] data;
		input integer beats;
		begin
			r2_n = 0;
			r2_resp = 2'b00;
			r2_data = 512'd0;
			@(posedge user_clk);
			m2_araddr <= off;
			m2_arlen <= beats - 1;
			m2_arvalid <= 1'b1;
			@(posedge user_clk);
			while (!m2_arready)
				@(posedge user_clk);
			m2_arvalid <= 1'b0;
			while (r2_n < beats)
				@(posedge user_clk);
			if (!r2_last)
				$display("atg_kc705_pcie: ERROR no rlast on the last beat");
			data = r2_data;
			bar2_resp = r2_resp;
		end
	endtask
	task bar2_write;
		input [25:0] off;
		input [127:0] data;
		input [15:0] strb;
		bar2_wr(off, {384'd0, data}, {48'd0, strb}, 1);
	endtask
	task bar2_read;
		input [25:0] off;
		output [127:0] data;
		reg [511:0] d;
		begin
			bar2_rd(off, d, 1);
			data = d[127:0];
		end
	endtask
	task bar2_write4;
		input [25:0] off;
		input [511:0] data;
		bar2_wr(off, data, {64{1'b1}}, 4);
	endtask
	task bar2_read4;
		input [25:0] off;
		output [511:0] data;
		bar2_rd(off, data, 4);
	endtask

	/* ---- MSI ---- */
	integer msi_count = 0;
	integer md0 = 0;
	always @(posedge user_clk) begin
		msi_ack <= 1'b0;
		if (msi_req && !msi_ack) begin
			md0 = md0 + 1;
			if (md0 == MSI_DELAY) begin
				md0 = 0;
				msi_ack <= 1'b1;
				msi_count = msi_count + 1;
			end
		end
	end

	/* ---- GPU -> host: the host's memory ---- */
	reg [7:0] host_mem [0:HOST_BYTES-1];
	integer host_wr_n = 0, host_rd_n = 0, host_err_n = 0, hs = SEED, hi;
	reg aw_busy = 1'b0, ar_busy = 1'b0, w_err = 1'b0, r_err = 1'b0;
	reg [63:0] w_addr = 64'd0, r_addr = 64'd0;
	reg [7:0] r_left = 8'd0;
	reg aw_rdy = 1'b0, w_rdy = 1'b0, ar_rdy = 1'b0;

	initial
		for (hi = 0; hi < HOST_BYTES; hi = hi + 1)
			host_mem[hi] = 8'd0;

	task host_write;
		input [63:0] addr;
		input [31:0] data;
		for (hi = 0; hi < 4; hi = hi + 1)
			host_mem[(addr + hi) % HOST_BYTES] = data[hi*8 +: 8];
	endtask
	task host_read;
		input [63:0] addr;
		output [31:0] data;
		for (hi = 0; hi < 4; hi = hi + 1)
			data[hi*8 +: 8] = host_mem[(addr + hi) % HOST_BYTES];
	endtask

	function [511:0] host_line;
		input [63:0] a;
		integer j;
		for (j = 0; j < 64; j = j + 1)
			host_line[j*8 +: 8] = host_mem[(a + j) % HOST_BYTES];
	endfunction

	assign s_awready = aw_rdy;
	assign s_wready = w_rdy;
	assign s_arready = ar_rdy;
	always @(posedge s_clk) begin
		aw_rdy <= !aw_busy && !(s_awvalid && s_awready) && {$random(hs)} % 4 != 0;
		ar_rdy <= !ar_busy && !(s_arvalid && s_arready) && {$random(hs)} % 4 != 0;
		w_rdy <= aw_busy && !s_bvalid && !(s_wvalid && s_wready && s_wlast) &&
			{$random(hs)} % 4 != 0;
		if (s_awvalid && s_awready) begin
			aw_busy <= 1'b1;
			s_bid <= s_awid;
			w_addr <= s_awaddr;
			w_err <= (s_awaddr >= 64'h80000000) && (s_awaddr[63:32] == 32'd0);
		end
		if (s_wvalid && s_wready) begin
			if (!w_err)
				for (hi = 0; hi < 64; hi = hi + 1)
					if (s_wstrb[hi])
						host_mem[(w_addr + hi) % HOST_BYTES] = s_wdata[hi*8 +: 8];
			w_addr <= w_addr + 64'd64;
			if (s_wlast) begin
				s_bvalid <= 1'b1;
				s_bresp <= w_err ? 2'b11 : 2'b00;
				host_wr_n = host_wr_n + 1;
				if (w_err)
					host_err_n = host_err_n + 1;
			end
		end
		if (s_bvalid && s_bready) begin
			s_bvalid <= 1'b0;
			aw_busy <= 1'b0;
		end
		if (s_arvalid && s_arready) begin
			ar_busy <= 1'b1;
			s_rid <= s_arid;
			r_err = (s_araddr >= 64'h80000000) && (s_araddr[63:32] == 32'd0);
			r_addr <= s_araddr + 64'd64;
			r_left <= s_arlen;
			s_rvalid <= 1'b1;
			s_rlast <= s_arlen == 8'd0;
			s_rdata <= r_err ? 512'd0 : host_line(s_araddr);
			s_rresp <= r_err ? 2'b11 : 2'b00;
			host_rd_n = host_rd_n + 1;
			if (r_err)
				host_err_n = host_err_n + 1;
		end else if (s_rvalid && s_rready) begin
			if (s_rlast) begin
				s_rvalid <= 1'b0;
				ar_busy <= 1'b0;
			end else begin
				r_left <= r_left - 8'd1;
				s_rlast <= r_left == 8'd1;
				s_rdata <= r_err ? 512'd0 : host_line(r_addr);
				r_addr <= r_addr + 64'd64;
			end
		end
	end

	wire unused_ok = &{1'b0, pcie_refclk_p, pcie_refclk_n, pcie_rxp, pcie_rxn, m0_bid, m0_rid,
		m0_rlast, m2_bid, m2_rid, s_awlen, s_awsize, s_awburst, s_arsize, s_arburst, s_rst_n};
endmodule

`default_nettype wire
