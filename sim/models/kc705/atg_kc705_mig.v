/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_mig (simulation model): stands in for
 * boards/kc705/lib/atg_kc705_mig.v (same name and ports) in the KC705
 * board testbench.  The DDR3 behind the MIG and the clock converter is an
 * axi_mem (sim/models/axi_mem.v, 512-bit, MEM_BYTES, random ready and
 * latency, its protocol checker) in gclk; mem_ready (init_calib_complete)
 * rises CALIB_CYCLES gclk cycles after rst_n.  The DDR3 pins are idle.
 * The BAR2 port (s2_*, s2_clk) reads and writes the same bytes (offset
 * modulo MEM_BYTES, as the GPU's LOCAL_BASE + offset): one burst at a
 * time, INCR, 16-byte beats, OKAY.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_mig #(
	parameter integer MEM_BYTES = 1 << 20,
	parameter integer CALIB_CYCLES = 200,
	parameter integer SEED = 11
) (
	input wire clk,
	input wire rst_n,
	input wire sys_clk,
	input wire sys_rst_n,
	output wire mem_ready,
	input wire [31:0] s_awaddr,
	input wire [7:0] s_awlen,
	input wire [2:0] s_awsize,
	input wire [1:0] s_awburst,
	input wire [3:0] s_awcache,
	input wire [2:0] s_awprot,
	input wire s_awvalid,
	output wire s_awready,
	input wire [511:0] s_wdata,
	input wire [63:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [31:0] s_araddr,
	input wire [7:0] s_arlen,
	input wire [2:0] s_arsize,
	input wire [1:0] s_arburst,
	input wire [3:0] s_arcache,
	input wire [2:0] s_arprot,
	input wire s_arvalid,
	output wire s_arready,
	output wire [511:0] s_rdata,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,
	/* AXI4 slave (s2_clk), the PCIe BAR2 window: 128-bit, the DDR3 offset */
	input wire s2_clk,
	input wire s2_rst_n,
	input wire [25:0] s2_awaddr,
	input wire [3:0] s2_awid,
	input wire [7:0] s2_awlen,
	input wire [2:0] s2_awsize,
	input wire [1:0] s2_awburst,
	input wire s2_awvalid,
	output wire s2_awready,
	input wire [127:0] s2_wdata,
	input wire [15:0] s2_wstrb,
	input wire s2_wlast,
	input wire s2_wvalid,
	output wire s2_wready,
	output wire [3:0] s2_bid,
	output wire [1:0] s2_bresp,
	output wire s2_bvalid,
	input wire s2_bready,
	input wire [25:0] s2_araddr,
	input wire [3:0] s2_arid,
	input wire [7:0] s2_arlen,
	input wire [2:0] s2_arsize,
	input wire [1:0] s2_arburst,
	input wire s2_arvalid,
	output wire s2_arready,
	output wire [127:0] s2_rdata,
	output wire [3:0] s2_rid,
	output wire [1:0] s2_rresp,
	output wire s2_rlast,
	output wire s2_rvalid,
	input wire s2_rready,
	inout wire [63:0] ddr3_dq,
	inout wire [7:0] ddr3_dqs_p,
	inout wire [7:0] ddr3_dqs_n,
	output wire [13:0] ddr3_addr,
	output wire [2:0] ddr3_ba,
	output wire ddr3_ras_n,
	output wire ddr3_cas_n,
	output wire ddr3_we_n,
	output wire ddr3_reset_n,
	output wire ddr3_ck_p,
	output wire ddr3_ck_n,
	output wire ddr3_cke,
	output wire ddr3_cs_n,
	output wire [7:0] ddr3_dm,
	output wire ddr3_odt
);
	integer calib = 0;

	always @(posedge clk)
		if (!rst_n)
			calib <= 0;
		else if (calib < CALIB_CYCLES)
			calib <= calib + 1;

	assign mem_ready = calib == CALIB_CYCLES;

	axi_mem #(.DATA_W(512), .MEM_BYTES(MEM_BYTES), .SEED(SEED)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(s_awaddr), .awlen(s_awlen), .awsize(s_awsize), .awburst(s_awburst),
		.awvalid(s_awvalid), .awready(s_awready), .wdata(s_wdata), .wstrb(s_wstrb),
		.wlast(s_wlast), .wvalid(s_wvalid), .wready(s_wready), .bresp(s_bresp),
		.bvalid(s_bvalid), .bready(s_bready), .araddr(s_araddr), .arlen(s_arlen),
		.arsize(s_arsize), .arburst(s_arburst), .arvalid(s_arvalid), .arready(s_arready),
		.rdata(s_rdata), .rresp(s_rresp), .rlast(s_rlast), .rvalid(s_rvalid),
		.rready(s_rready)
	);

	/* ---- The BAR2 port: the same memory (axi_mem's bytes) ---- */
	reg [1:0] s2_st = 2'd0;	/* 0 idle, 1 write data, 2 write response, 3 read data */
	reg [25:0] s2_a = 26'd0;
	reg [7:0] s2_n = 8'd0;
	reg [3:0] s2_id = 4'd0;
	reg [127:0] s2_rd = 128'd0;
	integer s2_i;
	assign s2_awready = s2_st == 2'd0 && !s2_arvalid;
	assign s2_arready = s2_st == 2'd0;
	assign s2_wready = s2_st == 2'd1;
	assign s2_bvalid = s2_st == 2'd2;
	assign s2_bid = s2_id;
	assign s2_bresp = 2'b00;
	assign s2_rvalid = s2_st == 2'd3;
	assign s2_rid = s2_id;
	assign s2_rresp = 2'b00;
	assign s2_rlast = s2_n == 8'd0;
	assign s2_rdata = s2_rd;
	/* The 16 bytes of the beat at address a. */
	function [127:0] rd16;
		input [25:0] a;
		integer j;
		begin
			for (j = 0; j < 16; j = j + 1)
				rd16[j*8 +: 8] = mem.mem[({a[25:4], 4'd0} + j) % MEM_BYTES];
		end
	endfunction
	always @(posedge s2_clk)
		if (!s2_rst_n)
			s2_st <= 2'd0;
		else
			case (s2_st)
			2'd0: if (s2_arvalid) begin
				s2_a <= s2_araddr;
				s2_rd <= rd16(s2_araddr);
				s2_n <= s2_arlen;
				s2_id <= s2_arid;
				s2_st <= 2'd3;
			end else if (s2_awvalid) begin
				s2_a <= s2_awaddr;
				s2_n <= s2_awlen;
				s2_id <= s2_awid;
				s2_st <= 2'd1;
			end
			2'd1: if (s2_wvalid) begin
				for (s2_i = 0; s2_i < 16; s2_i = s2_i + 1)
					if (s2_wstrb[s2_i])
						mem.mem[({s2_a[25:4], 4'd0} + s2_i) % MEM_BYTES] = s2_wdata[s2_i*8 +: 8];
				s2_a <= s2_a + 26'd16;
				if (s2_wlast)
					s2_st <= 2'd2;
			end
			2'd2: if (s2_bready)
				s2_st <= 2'd0;
			default: if (s2_rready) begin
				s2_a <= s2_a + 26'd16;
				s2_rd <= rd16(s2_a + 26'd16);
				s2_n <= s2_n - 8'd1;
				if (s2_n == 8'd0)
					s2_st <= 2'd0;
			end
			endcase

	assign ddr3_dq = {64{1'bz}};
	assign ddr3_dqs_p = {8{1'bz}};
	assign ddr3_dqs_n = {8{1'bz}};
	assign ddr3_addr = 14'd0;
	assign ddr3_ba = 3'd0;
	assign ddr3_ras_n = 1'b1;
	assign ddr3_cas_n = 1'b1;
	assign ddr3_we_n = 1'b1;
	assign ddr3_reset_n = 1'b0;
	assign ddr3_ck_p = 1'b0;
	assign ddr3_ck_n = 1'b1;
	assign ddr3_cke = 1'b0;
	assign ddr3_cs_n = 1'b1;
	assign ddr3_dm = 8'd0;
	assign ddr3_odt = 1'b0;

	wire unused_ok = &{1'b0, sys_clk, sys_rst_n, s_awcache, s_awprot, s_arcache, s_arprot,
		s2_awsize, s2_awburst, s2_arsize, s2_arburst};
endmodule

`default_nettype wire
