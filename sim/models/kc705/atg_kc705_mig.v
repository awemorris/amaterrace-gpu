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

	wire unused_ok = &{1'b0, sys_clk, sys_rst_n, s_awcache, s_awprot, s_arcache, s_arprot};
endmodule

`default_nettype wire
