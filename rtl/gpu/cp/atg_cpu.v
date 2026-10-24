/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu: The CP's control processor (design §2.4.7): RV32IM core,
 * IMEM/DMEM, control window, line DMA and the CPFW capability; the
 * firmware decodes class V packets into µops.
 *
 * Wiring of its children; see spec/gpu/cp/atg_cpu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter IMEM_WORDS = 8192,	/* IMEM size in 32-bit words (32 KiB) */
	parameter DMEM_WORDS = 4096,	/* DMEM size in words (16 KiB) */
	parameter IMEM_INIT = "",	/* IMEM image file */
	parameter DMEM_INIT = ""	/* DMEM image file */
) (
	input wire clk,
	input wire rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	/* Class V packet (atg_cp_ring) */
	input wire v_valid,
	input wire [31:0] v_addr,
	input wire [15:0] v_dwords,
	input wire [7:0] v_tag,
	output wire v_done,
	/* µops (atg_cp_seq) */
	output wire fw_valid,
	input wire fw_ready,
	output wire [31:0] fw_data,
	output wire fw_last,
	output wire fw_active,
	/* CP state */
	output wire [8:0] st_ridx,
	input wire [31:0] st_rdata,
	input wire [31:0] fence_last,
	input wire fence_ev,
	input wire halt_req,
	input wire open,
	output wire ev_result,
	output wire stall,
	output wire fault,
	output wire [31:0] fault_addr,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	/* Core. */
	wire fw_core_rst_n, core_run, core_stopped, core_irq;
	wire core_fault;
	wire [31:0] core_fault_pc;
	wire i_en;
	wire [31:0] i_addr, i_rdata;
	wire d_valid, d_write, d_ready;
	wire [31:0] d_addr, d_wdata, d_rdata;
	wire [3:0] d_be;
	/* DMEM data port. */
	wire m_en;
	wire [3:0] m_we;
	wire [31:0] m_addr, m_wdata, m_rdata;
	/* Window sub-bus. */
	wire sb_we, sb_re;
	wire [5:0] sb_idx;
	wire [31:0] sb_wdata, dma_rdata, fw_rdata;
	/* Image load and DMA memory port. */
	wire ld_start, ld_imem, ld_done, ld_error;
	wire [31:0] ld_addr, ld_words;
	wire x_en, x_we, x_imem;
	wire [31:0] x_addr, x_wdata, x_rdata;
	wire dma_wait;
	wire stall_win;

	wire core_rst = rst_n && fw_core_rst_n;

	atg_cpu_core core (
		.clk(clk), .rst_n(core_rst), .run(core_run), .stopped(core_stopped), .irq(core_irq),
		.i_en(i_en), .i_addr(i_addr), .i_rdata(i_rdata),
		.d_valid(d_valid), .d_write(d_write), .d_addr(d_addr), .d_wdata(d_wdata),
		.d_be(d_be), .d_ready(d_ready), .d_rdata(d_rdata),
		.fault(core_fault), .fault_pc(core_fault_pc)
	);

	atg_cpu_mem #(
		.IMEM_WORDS(IMEM_WORDS), .DMEM_WORDS(DMEM_WORDS),
		.IMEM_INIT(IMEM_INIT), .DMEM_INIT(DMEM_INIT)
	) mem (
		.clk(clk),
		.i_en(i_en), .i_addr(i_addr), .i_rdata(i_rdata),
		.d_en(m_en), .d_we(m_we), .d_addr(m_addr), .d_wdata(m_wdata), .d_rdata(m_rdata),
		.x_en(x_en), .x_we(x_we), .x_imem(x_imem), .x_addr(x_addr), .x_wdata(x_wdata),
		.x_rdata(x_rdata)
	);

	atg_cpu_win win (
		.clk(clk), .rst_n(rst_n),
		.d_valid(d_valid), .d_write(d_write), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be),
		.d_ready(d_ready), .d_rdata(d_rdata),
		.m_en(m_en), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_rdata(m_rdata),
		.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata),
		.dma_rdata(dma_rdata), .fw_rdata(fw_rdata),
		.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag), .v_done(v_done),
		.fw_valid(fw_valid), .fw_ready(fw_ready), .fw_data(fw_data), .fw_last(fw_last),
		.fw_active(fw_active),
		.st_ridx(st_ridx), .st_rdata(st_rdata), .fence_last(fence_last), .fence_ev(fence_ev),
		.halt_req(halt_req), .irq(core_irq), .ev_result(ev_result), .stall(stall_win)
	);

	assign stall = stall_win || dma_wait;

	atg_cpu_dma #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dma (
		.clk(clk), .rst_n(rst_n),
		.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata), .sb_rdata(dma_rdata),
		.ld_start(ld_start), .ld_imem(ld_imem), .ld_addr(ld_addr), .ld_words(ld_words),
		.ld_done(ld_done), .ld_error(ld_error),
		.x_en(x_en), .x_we(x_we), .x_imem(x_imem), .x_addr(x_addr), .x_wdata(x_wdata),
		.x_rdata(x_rdata), .wait_amb(dma_wait),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
		.req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	atg_cpu_fw fw (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata), .sb_rdata(fw_rdata),
		.ld_start(ld_start), .ld_imem(ld_imem), .ld_addr(ld_addr), .ld_words(ld_words),
		.ld_done(ld_done), .ld_error(ld_error),
		.core_rst_n(fw_core_rst_n), .core_run(core_run), .core_stopped(core_stopped),
		.core_fault(core_fault), .core_fault_pc(core_fault_pc),
		.halt_req(halt_req), .open(open), .fault(fault), .fault_addr(fault_addr)
	);
endmodule

`default_nettype wire
