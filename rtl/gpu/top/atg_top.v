/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top: the GPU IP.  An AXI slave for the GHCI registers (s_*, the low
 * 17 address bits of the window), one AXI master to memory (m_*) and a
 * level interrupt.  The CP, the blitter and the MC are always present; the
 * other blocks come with the HAS_* and NSU parameters (design §7.6).
 *
 * One clock (gclk = mclk; the KC705's MIG clock is crossed outside, in its
 * board top) and one synchronous active-low reset, already synchronised to clk.
 * S_ID_W/S_LEN_W fit the host port (12/4 for the Zynq GP0, AXI3); the
 * master is AXI4-shaped (see am_axi_master for an AXI3 port).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top #(
	parameter [31:0] GCLK_HZ = 32'd100000000,
	parameter S_ID_W = 12,
	parameter S_LEN_W = 4,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DATA_W = 64,
	/* Which blocks are present (design §7.6; 0 = absent). */
	parameter HAS_CPU = 0,	/* atg_cpu, the CP's firmware processor */
	parameter CPU_IMEM_INIT = "",	/* its IMEM image ($readmemh) */
	parameter CPU_DMEM_INIT = "",	/* its DMEM image */
	parameter NSU = 0,	/* shader units */
	parameter HAS_VF = 0,	/* vertex fetcher */
	parameter HAS_RX = 0,	/* rasterizer */
	parameter HAS_TU = 0,	/* texture unit */
	parameter HAS_ROP = 0,	/* buffer writer */
	parameter HAS_SA = 0,	/* systolic array: reserved, 0 in v1 (design §3.9) */
	parameter EXT_CLIENT = 0,	/* one more MC client outside (the KC705's DC), high priority */
	parameter HAS_JTAG = 0,	/* a second register-bus master (am_jtag_regs, KC705) */
	parameter HAS_DISP = 0,	/* a display controller's registers are next to the GPU at +0x10000 (KC705) */
	parameter ROP_STENCIL = 0,
	/* The SUs' shape (design §3.7). */
	parameter SU_NPHYS = 8,
	parameter SU_NWARPS = 4,
	parameter SU_WARP_W = 2,	/* log2(SU_NWARPS) */
	parameter SU_GRP_W = 2,	/* log2(32/SU_NPHYS), 1 for SU_NPHYS 32 */
	parameter SU_NREGS = 32,
	parameter SU_SB_ENTRIES = 4,
	parameter SU_SBE_W = 2,	/* log2(SU_SB_ENTRIES) */
	parameter SU_PACKED = 0,
	parameter SU_SUBGROUP = 0,
	parameter SU_FRAG_RESERVE = 1,	/* slots kept for fragment warps (design §3.8; KC705 2) */
	parameter SU_LDS_BYTES = 4096,
	parameter SU_VARY_WORDS = 16
) (
	input wire clk,
	input wire rst_n,
	output wire irq,
	input wire mem_ready,

	input wire [16:0] s_awaddr,
	input wire [S_ID_W-1:0] s_awid,
	input wire s_awvalid,
	output wire s_awready,
	input wire [31:0] s_wdata,
	input wire [3:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [S_ID_W-1:0] s_bid,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [16:0] s_araddr,
	input wire [S_ID_W-1:0] s_arid,
	input wire [S_LEN_W-1:0] s_arlen,
	input wire s_arvalid,
	output wire s_arready,
	output wire [31:0] s_rdata,
	output wire [S_ID_W-1:0] s_rid,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,

	output wire [31:0] m_awaddr,
	output wire [7:0] m_awlen,
	output wire [2:0] m_awsize,
	output wire [1:0] m_awburst,
	output wire [3:0] m_awcache,
	output wire [2:0] m_awprot,
	output wire m_awvalid,
	input wire m_awready,
	output wire [DATA_W-1:0] m_wdata,
	output wire [DATA_W/8-1:0] m_wstrb,
	output wire m_wlast,
	output wire m_wvalid,
	input wire m_wready,
	input wire [1:0] m_bresp,
	input wire m_bvalid,
	output wire m_bready,
	output wire [31:0] m_araddr,
	output wire [7:0] m_arlen,
	output wire [2:0] m_arsize,
	output wire [1:0] m_arburst,
	output wire [3:0] m_arcache,
	output wire [2:0] m_arprot,
	output wire m_arvalid,
	input wire m_arready,
	input wire [DATA_W-1:0] m_rdata,
	input wire [1:0] m_rresp,
	input wire m_rlast,
	input wire m_rvalid,
	output wire m_rready,

	/*
	 * What lives next to the GPU (the KC705's DC): the register
	 * bus for the window above 0x10000 (the other module returns 0 outside
	 * its registers; the read data is ORed), one MC client (EXT_CLIENT) and
	 * the display's vsync pulse.
	 */
	output wire xr_wr,
	output wire [16:0] xr_waddr,
	output wire [31:0] xr_wdata,
	output wire [3:0] xr_wstrb,
	output wire xr_rd,
	output wire [16:0] xr_raddr,
	input wire [31:0] xr_rdata,
	input wire x_req_valid,
	output wire x_req_ready,
	input wire x_req_write,
	input wire [31-LINE_SHIFT:0] x_req_line,
	input wire [LINE_BYTES-1:0] x_req_be,
	input wire [LINE_BYTES*8-1:0] x_req_wdata,
	input wire [7:0] x_req_tag,
	output wire x_rsp_valid,
	output wire x_rsp_write,
	output wire [7:0] x_rsp_tag,
	output wire [LINE_BYTES*8-1:0] x_rsp_rdata,
	output wire x_rsp_error,
	input wire x_vsync,
	/* The second register-bus master (HAS_JTAG): served when the AXI slave is idle. */
	input wire j_wr,
	input wire [16:0] j_waddr,
	input wire [31:0] j_wdata,
	input wire [3:0] j_wstrb,
	input wire j_rd,
	input wire [16:0] j_raddr,
	output wire [31:0] j_rdata,
	output wire j_busy
);
	/*
	 * MC clients: 0 CP, 1 BLT, then the present blocks in this order: CPU,
	 * VF, TU, ROP, the atomic unit (with any SU), SA, EXT, and two per SU.
	 */
	localparam HAS_ATOM = NSU > 0 ? 1 : 0;
	localparam C_CPU = 2;
	localparam C_VF = C_CPU + (HAS_CPU != 0 ? 1 : 0);
	localparam C_TU = C_VF + (HAS_VF != 0 ? 1 : 0);
	localparam C_ROP = C_TU + (HAS_TU != 0 ? 1 : 0);
	localparam C_ATOM = C_ROP + (HAS_ROP != 0 ? 1 : 0);
	localparam C_SA = C_ATOM + HAS_ATOM;
	localparam C_EXT = C_SA + (HAS_SA != 0 ? 1 : 0);
	localparam C_SU = C_EXT + (EXT_CLIENT != 0 ? 1 : 0);	/* SU k: C_SU+2k (D$), C_SU+2k+1 (I$) */
	localparam NCLIENT = C_SU + 2 * NSU;
	localparam [NCLIENT-1:0] HIGH = {{(NCLIENT-1){1'b0}}, 1'b1} |
		({{(NCLIENT-1){1'b0}}, EXT_CLIENT != 0} << C_EXT);
	localparam LA_W = 32 - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;

	/* The register bus. */
	wire reg_wr;
	wire [16:0] reg_waddr;
	wire [31:0] reg_wdata;
	wire [3:0] reg_wstrb;
	wire reg_rd;
	wire [16:0] reg_raddr;
	wire [31:0] reg_rdata;
	wire [31:0] cp_reg_rdata;

	/* The AXI slave's bus (a_*) and the JTAG master (j_*, HAS_JTAG) share it. */
	wire a_reg_wr, a_reg_rd;
	wire [16:0] a_reg_waddr, a_reg_raddr;
	wire [31:0] a_reg_wdata;
	wire [3:0] a_reg_wstrb;
	wire a_busy = a_reg_wr || a_reg_rd;
	wire j_go = HAS_JTAG != 0 && !a_busy;

	assign reg_wr = a_reg_wr || (j_go && j_wr);
	assign reg_waddr = a_busy ? a_reg_waddr : j_waddr;
	assign reg_wdata = a_busy ? a_reg_wdata : j_wdata;
	assign reg_wstrb = a_busy ? a_reg_wstrb : j_wstrb;
	assign reg_rd = a_reg_rd || (j_go && j_rd);
	assign reg_raddr = a_busy ? a_reg_raddr : j_raddr;
	assign j_rdata = reg_rdata;
	assign j_busy = a_busy;

	assign reg_rdata = cp_reg_rdata | xr_rdata;
	assign xr_wr = reg_wr;
	assign xr_waddr = reg_waddr;
	assign xr_wdata = reg_wdata;
	assign xr_wstrb = reg_wstrb;
	assign xr_rd = reg_rd;
	assign xr_raddr = reg_raddr;

	am_axi_regs #(.ADDR_BITS(17), .ID_W(S_ID_W), .LEN_W(S_LEN_W)) regs (
		.clk(clk),
		.rst_n(rst_n),
		.s_awaddr(s_awaddr),
		.s_awid(s_awid),
		.s_awvalid(s_awvalid),
		.s_awready(s_awready),
		.s_wdata(s_wdata),
		.s_wstrb(s_wstrb),
		.s_wlast(s_wlast),
		.s_wvalid(s_wvalid),
		.s_wready(s_wready),
		.s_bid(s_bid),
		.s_bresp(s_bresp),
		.s_bvalid(s_bvalid),
		.s_bready(s_bready),
		.s_araddr(s_araddr),
		.s_arid(s_arid),
		.s_arlen(s_arlen),
		.s_arvalid(s_arvalid),
		.s_arready(s_arready),
		.s_rdata(s_rdata),
		.s_rid(s_rid),
		.s_rresp(s_rresp),
		.s_rlast(s_rlast),
		.s_rvalid(s_rvalid),
		.s_rready(s_rready),
		.reg_wr(a_reg_wr),
		.reg_waddr(a_reg_waddr),
		.reg_wdata(a_reg_wdata),
		.reg_wstrb(a_reg_wstrb),
		.reg_rd(a_reg_rd),
		.reg_raddr(a_reg_raddr),
		.reg_rdata(reg_rdata)
	);

	/* The CP's controls. */
	wire core_rst_n;
	wire mc_quiesce;
	wire mc_flush;
	wire [31:0] aperture_base;
	wire [31:0] aperture_limit;
	wire mc_idle;
	wire mc_fault;
	wire [7:0] mc_fault_client;
	wire [31:0] mc_fault_addr;
	wire mc_fault_write;
	wire st_we;
	wire [8:0] st_idx;
	wire [31:0] st_wdata;
	wire blt_kick;
	wire blt_busy;
	wire blt_done;
	wire blt_error;
	wire [3:0] blt_error_kind;

	/* The AMB: one request port per client, the responses shared. */
	wire [NCLIENT-1:0] c_req_valid;
	wire [NCLIENT-1:0] c_req_ready;
	wire [NCLIENT-1:0] c_req_write;
	wire [NCLIENT*LA_W-1:0] c_req_line;
	wire [NCLIENT*LINE_BYTES-1:0] c_req_be;
	wire [NCLIENT*LINE_BITS-1:0] c_req_wdata;
	wire [NCLIENT*8-1:0] c_req_tag;
	wire [NCLIENT-1:0] rsp_valid;
	wire [NCLIENT-1:0] rsp_write_v;
	wire [NCLIENT*8-1:0] rsp_tag_v;
	wire [NCLIENT*LINE_BITS-1:0] rsp_rdata_v;
	wire [NCLIENT-1:0] rsp_error_v;

	/* The CP's links to the blocks of design §7.6. */
	wire draw_kick, cs_kick, lc_kick, raw_kick;
	wire [3:0] inv;
	wire hcr_we;
	wire [9:0] hcr_widx, hcr_ridx;
	wire [31:0] hcr_wdata, hcr_wmask;
	wire v_valid, v_done;
	wire [31:0] v_addr;
	wire [15:0] v_dwords;
	wire [7:0] v_tag;
	wire fw_valid, fw_ready, fw_last, fw_active;
	wire [31:0] fw_data;
	wire [8:0] cpu_st_ridx;
	wire [31:0] cpu_st_rdata, cp_fence_last, cpu_hcr_rdata, cpu_fault_addr;
	wire cp_fence_ev, cp_halt, cp_open, cpu_fault, cpu_stall, cpu_result;

	atg_cp #(
		.ADDR_W(32),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.GCLK_HZ(GCLK_HZ),
		.UNITS({HAS_SA != 0, NSU != 0, HAS_TU != 0, HAS_ROP != 0, HAS_RX != 0, HAS_VF != 0,
			2'b11}),
		.HAS_CPU(HAS_CPU),
		.HAS_DISP(HAS_DISP),
		.HAS_DBG(HAS_JTAG),
		.PACKED(NSU != 0 && SU_PACKED != 0),
		.SUBGROUP(NSU != 0 && SU_SUBGROUP != 0)
	) cp (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(reg_wr),
		.reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata),
		.reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd),
		.reg_raddr(reg_raddr),
		.reg_rdata(cp_reg_rdata),
		.irq(irq),
		.mem_ready(mem_ready),
		.core_rst_n(core_rst_n),
		.mc_quiesce(mc_quiesce),
		.mc_flush(mc_flush),
		.aperture_base(aperture_base),
		.aperture_limit(aperture_limit),
		.mc_idle(mc_idle),
		.mc_fault(mc_fault),
		.mc_fault_client(mc_fault_client),
		.mc_fault_addr(mc_fault_addr),
		.mc_fault_write(mc_fault_write),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.blt_kick(blt_kick),
		.blt_busy(blt_busy),
		.blt_error(blt_error),
		.blt_error_kind(blt_error_kind),
		.req_valid(c_req_valid[0]),
		.req_ready(c_req_ready[0]),
		.req_write(c_req_write[0]),
		.req_line(c_req_line[0*LA_W +: LA_W]),
		.req_be(c_req_be[0*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(c_req_wdata[0*LINE_BITS +: LINE_BITS]),
		.req_tag(c_req_tag[0*8 +: 8]),
		.rsp_valid(rsp_valid[0]),
		.rsp_write(rsp_write_v[0]),
		.rsp_tag(rsp_tag_v[0*8 +: 8]),
		.rsp_rdata(rsp_rdata_v[0*LINE_BITS +: LINE_BITS]),
		.rsp_error(rsp_error_v[0]),
		.draw_kick(draw_kick),
		.cs_kick(cs_kick),
		.lc_kick(lc_kick),
		.raw_kick(raw_kick),
		.inv(inv),
		.busy_ext({sa_busy, su_busy, tu_busy, rop_busy, rx_busy, vf_busy, 2'b00}),
		.vsync(x_vsync),
		.x_fault({1'b0, su_fault}),
		.x_fault_kind(8'h08),
		.x_fault_addr({32'd0, su_fault_addr}),
		.x_fault_tag(16'd0),
		.hcr_we(hcr_we),
		.hcr_widx(hcr_widx),
		.hcr_wdata(hcr_wdata),
		.hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx),
		.x_rdata(cpu_hcr_rdata | sa_hcr_rdata),
		.v_valid(v_valid),
		.v_addr(v_addr),
		.v_dwords(v_dwords),
		.v_tag(v_tag),
		.v_done(v_done),
		.fw_valid(fw_valid),
		.fw_ready(fw_ready),
		.fw_data(fw_data),
		.fw_last(fw_last),
		.fw_active(fw_active),
		.cpu_st_ridx(cpu_st_ridx),
		.cpu_st_rdata(cpu_st_rdata),
		.cp_fence_last(cp_fence_last),
		.cp_fence_ev(cp_fence_ev),
		.cp_halt(cp_halt),
		.cp_open(cp_open),
		.cpu_fault(cpu_fault),
		.cpu_fault_addr(cpu_fault_addr),
		.cpu_stall(cpu_stall),
		.cpu_result(cpu_result)
	);

	atg_blt #(
		.ADDR_W(32),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT)
	) blt (
		.clk(clk),
		.rst_n(core_rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.kick(blt_kick),
		.busy(blt_busy),
		.done(blt_done),
		.error(blt_error),
		.error_kind(blt_error_kind),
		.req_valid(c_req_valid[1]),
		.req_ready(c_req_ready[1]),
		.req_write(c_req_write[1]),
		.req_line(c_req_line[1*LA_W +: LA_W]),
		.req_be(c_req_be[1*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(c_req_wdata[1*LINE_BITS +: LINE_BITS]),
		.req_tag(c_req_tag[1*8 +: 8]),
		.rsp_valid(rsp_valid[1]),
		.rsp_write(rsp_write_v[1]),
		.rsp_tag(rsp_tag_v[1*8 +: 8]),
		.rsp_rdata(rsp_rdata_v[1*LINE_BITS +: LINE_BITS]),
		.rsp_error(rsp_error_v[1])
	);

	atg_mc #(
		.NCLIENT(NCLIENT),
		.HIGH_MASK(HIGH),
		.QUIESCE_EXEMPT({{(NCLIENT-1){1'b0}}, 1'b1}),	/* the CP (its debug port) */
		.ROOT_CLIENT(EXT_CLIENT != 0 ? C_EXT : -1),
		.ADDR_W(32),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.OUTSTANDING_LOG2(2)
	) mc (
		.clk(clk),
		.rst_n(rst_n),
		.c_req_valid(c_req_valid),
		.c_req_ready(c_req_ready),
		.c_req_write(c_req_write),
		.c_req_line(c_req_line),
		.c_req_be(c_req_be),
		.c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag),
		.rsp_valid(rsp_valid),
		.rsp_write(rsp_write_v),
		.rsp_tag(rsp_tag_v),
		.rsp_rdata(rsp_rdata_v),
		.rsp_error(rsp_error_v),
		.quiesce(mc_quiesce),
		.flush(mc_flush),
		.aperture_base(aperture_base),
		.aperture_limit(aperture_limit),
		.axi_idle(mc_idle),
		.fault(mc_fault),
		.fault_client(mc_fault_client),
		.fault_addr(mc_fault_addr),
		.fault_write(mc_fault_write),
		.m_awaddr(m_awaddr),
		.m_awlen(m_awlen),
		.m_awsize(m_awsize),
		.m_awburst(m_awburst),
		.m_awcache(m_awcache),
		.m_awprot(m_awprot),
		.m_awvalid(m_awvalid),
		.m_awready(m_awready),
		.m_wdata(m_wdata),
		.m_wstrb(m_wstrb),
		.m_wlast(m_wlast),
		.m_wvalid(m_wvalid),
		.m_wready(m_wready),
		.m_bresp(m_bresp),
		.m_bvalid(m_bvalid),
		.m_bready(m_bready),
		.m_araddr(m_araddr),
		.m_arlen(m_arlen),
		.m_arsize(m_arsize),
		.m_arburst(m_arburst),
		.m_arcache(m_arcache),
		.m_arprot(m_arprot),
		.m_arvalid(m_arvalid),
		.m_arready(m_arready),
		.m_rdata(m_rdata),
		.m_rresp(m_rresp),
		.m_rlast(m_rlast),
		.m_rvalid(m_rvalid),
		.m_rready(m_rready)
	);

	/* The CP's firmware processor. */
	generate
	if (HAS_CPU != 0) begin : g_cpu
		atg_cpu #(
			.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.IMEM_INIT(CPU_IMEM_INIT), .DMEM_INIT(CPU_DMEM_INIT)
		) cpu (
			.clk(clk), .rst_n(core_rst_n),
			.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata),
			.hcr_wmask(hcr_wmask), .hcr_ridx(hcr_ridx), .hcr_rdata(cpu_hcr_rdata),
			.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag),
			.v_done(v_done),
			.fw_valid(fw_valid), .fw_ready(fw_ready), .fw_data(fw_data), .fw_last(fw_last),
			.fw_active(fw_active),
			.st_ridx(cpu_st_ridx), .st_rdata(cpu_st_rdata), .fence_last(cp_fence_last),
			.fence_ev(cp_fence_ev), .halt_req(cp_halt), .open(cp_open),
			.ev_result(cpu_result), .stall(cpu_stall), .fault(cpu_fault),
			.fault_addr(cpu_fault_addr),
			.req_valid(c_req_valid[C_CPU]), .req_ready(c_req_ready[C_CPU]),
			.req_write(c_req_write[C_CPU]), .req_line(c_req_line[C_CPU*LA_W +: LA_W]),
			.req_be(c_req_be[C_CPU*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_CPU*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_CPU*8 +: 8]),
			.rsp_valid(rsp_valid[C_CPU]), .rsp_write(rsp_write_v[C_CPU]), .rsp_tag(rsp_tag_v[C_CPU*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_CPU*LINE_BITS +: LINE_BITS]), .rsp_error(rsp_error_v[C_CPU])
		);
	end else begin : g_no_cpu
		assign cpu_hcr_rdata = 32'd0;
		assign v_done = 1'b0;
		assign fw_valid = 1'b0;
		assign fw_data = 32'd0;
		assign fw_last = 1'b0;
		assign fw_active = 1'b0;
		assign cpu_st_ridx = 9'd0;
		assign cpu_result = 1'b0;
		assign cpu_stall = 1'b0;
		assign cpu_fault = 1'b0;
		assign cpu_fault_addr = 32'd0;
		wire unused_cpu = &{1'b0, hcr_we, hcr_widx, hcr_wdata, hcr_wmask, hcr_ridx, v_valid,
			v_addr, v_dwords, v_tag, fw_ready, cpu_st_rdata, cp_fence_last, cp_fence_ev,
			cp_halt, cp_open};
	end
	endgenerate

	/*
	 * The blocks of design §7.6 behind their parameters.  The graphics
	 * links (VF, RX, TU, ROP, SA) go to SU 0 only; the other SUs run
	 * compute (the work is not yet distributed over the SUs).
	 */
	localparam DW = SU_NPHYS * 32;

	wire vf_busy, rx_busy, tu_busy, rop_busy, sa_busy, su_busy;
	wire su_fault;
	wire [31:0] su_fault_addr, sa_hcr_rdata;

	/* VF ↔ SU 0. */
	wire vl_req, vl_gnt, vl_we, vl_go;
	wire [7:0] vl_ptbase;
	wire [5:0] vl_reg;
	wire [4:0] vl_lane;
	wire [31:0] vl_data, vl_mask;
	/* VF → RX (a primitive waits until SU 0's vertex warp of its PT block has
	 * ended: pt_done, atg_su_pt). */
	wire prim_valid, prim_ready, prim_last, rx_prim_ready;
	wire [7:0] pt_done;
	wire prim_ok = pt_done[prim_vtx[7:5]];
	wire [23:0] prim_vtx;
	wire [2:0] prim_free;
	/* RX ↔ SU 0. */
	wire pt_rd, pt_free;
	wire [7:0] pt_idx, pt_free_idx;
	wire [5:0] pt_word;
	wire [31:0] pt_rdata;
	wire fl_req, fl_gnt, fl_we, fl_pw_we, fl_go;
	wire [5:0] fl_reg;
	wire [4:0] fl_lane;
	wire [31:0] fl_data, fl_pw_data, fl_mask;
	wire [11:0] fl_pw_addr;
	wire [63:0] fl_info;
	/* RX → ROP. */
	wire dx_valid, dx_ready, dx_last, ord_valid;
	wire [15:0] dx_seq, ord_seq;
	wire [31:0] dx_xy;
	wire [3:0] dx_mask;
	wire [127:0] dx_depth;
	/* SU 0 ↔ TU. */
	wire tx_valid, tx_ready, tx_last, tr_valid, tr_ready, tr_last;
	wire [7:0] tx_op;
	wire [3:0] tx_slot, tx_mask;
	wire [639:0] tx_coord;
	wire [11:0] tx_off;
	wire [15:0] tx_tag, tr_tag;
	wire [511:0] tr_data;
	/* SU 0 → ROP. */
	wire ex_valid, ex_ready, ex_last;
	wire [15:0] ex_seq, ex_next;
	wire [31:0] ex_xy;
	wire [3:0] ex_mask;
	wire [511:0] ex_color;
	wire [127:0] ex_depth;
	/* SU 0 ↔ SA. */
	wire sa_push_valid, sa_push_ready, sa_pop_valid, sa_pop_ready, sa_ctl_valid;
	wire [DW-1:0] sa_push_data, sa_pop_data;
	wire [31:0] sa_ctl_data, sa_qstat, sa_stat, sa_qtag;
	/* SUs ↔ the atomic unit. */
	wire [(NSU > 0 ? NSU : 1)-1:0] at_valid, at_ready, at_rsp_valid;
	wire [(NSU > 0 ? NSU : 1)*4-1:0] at_op;
	wire [(NSU > 0 ? NSU : 1)*30-1:0] at_addr;
	wire [(NSU > 0 ? NSU : 1)*32-1:0] at_a, at_b;
	wire [31:0] at_old;
	wire at_error;
	wire [(NSU > 0 ? NSU : 1)-1:0] su_busy_v, su_fault_v;
	wire [(NSU > 0 ? NSU : 1)*32-1:0] su_fault_addr_v;	/* each SU's fault PC */

	generate
	if (HAS_VF != 0) begin : g_vf
		atg_vf #(.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) vf (
			.clk(clk), .rst_n(core_rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
			.draw_kick(draw_kick), .busy(vf_busy),
			.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_go(vl_go),
			.vl_mask(vl_mask), .vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane),
			.vl_data(vl_data),
			.prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
			.prim_free(prim_free), .prim_last(prim_last),
			.req_valid(c_req_valid[C_VF]), .req_ready(c_req_ready[C_VF]),
			.req_write(c_req_write[C_VF]), .req_line(c_req_line[C_VF*LA_W +: LA_W]),
			.req_be(c_req_be[C_VF*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_VF*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_VF*8 +: 8]),
			.rsp_valid(rsp_valid[C_VF]), .rsp_write(rsp_write_v[C_VF]), .rsp_tag(rsp_tag_v[C_VF*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_VF*LINE_BITS +: LINE_BITS]), .rsp_error(rsp_error_v[C_VF])
		);
	end else begin : g_no_vf
		assign vf_busy = 1'b0;
		assign vl_req = 1'b0;
		assign vl_go = 1'b0;
		assign vl_mask = 32'd0;
		assign vl_we = 1'b0;
		assign vl_reg = 6'd0;
		assign vl_lane = 5'd0;
		assign vl_data = 32'd0;
		assign prim_valid = 1'b0;
		assign prim_vtx = 24'd0;
		assign prim_free = 3'd0;
		assign prim_last = 1'b0;
		wire unused_vf = &{1'b0, draw_kick, vl_gnt, vl_ptbase, prim_ready};
	end

	if (HAS_RX != 0) begin : g_rx
		atg_rx #(.HAS_SU(NSU > 0 ? 1 : 0)) rx (
			.clk(clk), .rst_n(core_rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
			.raw_kick(raw_kick), .busy(rx_busy),
			.prim_valid(prim_valid && prim_ok), .prim_ready(rx_prim_ready),
			.prim_vtx(prim_vtx), .prim_free(prim_free), .prim_last(prim_last),
			.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
			.pt_free(pt_free), .pt_free_idx(pt_free_idx),
			.fl_req(fl_req), .fl_gnt(fl_gnt), .fl_we(fl_we), .fl_reg(fl_reg), .fl_lane(fl_lane),
			.fl_data(fl_data), .fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr),
			.fl_pw_data(fl_pw_data), .fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
			.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
			.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
			.ord_valid(ord_valid), .ord_seq(ord_seq)
		);
		assign prim_ready = rx_prim_ready && prim_ok;
	end else begin : g_no_rx
		assign rx_busy = 1'b0;
		assign prim_ready = 1'b0;
		assign rx_prim_ready = 1'b0;
		assign pt_rd = 1'b0;
		assign pt_idx = 8'd0;
		assign pt_word = 6'd0;
		assign pt_free = 1'b0;
		assign pt_free_idx = 8'd0;
		assign fl_req = 1'b0;
		assign fl_we = 1'b0;
		assign fl_reg = 6'd0;
		assign fl_lane = 5'd0;
		assign fl_data = 32'd0;
		assign fl_pw_we = 1'b0;
		assign fl_pw_addr = 12'd0;
		assign fl_pw_data = 32'd0;
		assign fl_go = 1'b0;
		assign fl_mask = 32'd0;
		assign fl_info = 64'd0;
		assign dx_valid = 1'b0;
		assign dx_seq = 16'd0;
		assign dx_xy = 32'd0;
		assign dx_mask = 4'd0;
		assign dx_depth = 128'd0;
		assign dx_last = 1'b0;
		assign ord_valid = 1'b0;
		assign ord_seq = 16'd0;
		wire unused_rx = &{1'b0, raw_kick, prim_valid, prim_vtx, prim_free, prim_last,
			pt_rdata, fl_gnt, dx_ready, prim_ok, rx_prim_ready};
	end

	if (HAS_TU != 0) begin : g_tu
		atg_tu #(.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) tu (
			.clk(clk), .rst_n(core_rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
			.inv(inv[1]), .busy(tu_busy),
			.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
			.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
			.tx_last(tx_last),
			.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
			.tr_last(tr_last),
			.req_valid(c_req_valid[C_TU]), .req_ready(c_req_ready[C_TU]),
			.req_write(c_req_write[C_TU]), .req_line(c_req_line[C_TU*LA_W +: LA_W]),
			.req_be(c_req_be[C_TU*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_TU*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_TU*8 +: 8]),
			.rsp_valid(rsp_valid[C_TU]), .rsp_write(rsp_write_v[C_TU]), .rsp_tag(rsp_tag_v[C_TU*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_TU*LINE_BITS +: LINE_BITS]), .rsp_error(rsp_error_v[C_TU])
		);
	end else begin : g_no_tu
		assign tu_busy = 1'b0;
		assign tx_ready = 1'b0;
		assign tr_valid = 1'b0;
		assign tr_tag = 16'd0;
		assign tr_data = 512'd0;
		assign tr_last = 1'b0;
		wire unused_tu = &{1'b0, tx_valid, tx_op, tx_slot, tx_mask, tx_coord, tx_off, tx_tag, tx_last,
			tr_ready};
	end

	if (HAS_ROP != 0) begin : g_rop
		atg_rop #(
			.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.STENCIL(ROP_STENCIL)
		) rop (
			.clk(clk), .rst_n(core_rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
			.busy(rop_busy),
			.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
			.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
			.ex_next(ex_next),
			.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
			.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
			.ord_valid(ord_valid), .ord_seq(ord_seq),
			.req_valid(c_req_valid[C_ROP]), .req_ready(c_req_ready[C_ROP]),
			.req_write(c_req_write[C_ROP]), .req_line(c_req_line[C_ROP*LA_W +: LA_W]),
			.req_be(c_req_be[C_ROP*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_ROP*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_ROP*8 +: 8]),
			.rsp_valid(rsp_valid[C_ROP]), .rsp_write(rsp_write_v[C_ROP]), .rsp_tag(rsp_tag_v[C_ROP*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_ROP*LINE_BITS +: LINE_BITS]), .rsp_error(rsp_error_v[C_ROP])
		);
	end else begin : g_no_rop
		assign rop_busy = 1'b0;
		assign ex_ready = 1'b0;
		assign ex_next = 16'd0;
		assign dx_ready = 1'b0;
		wire unused_rop = &{1'b0, ex_valid, ex_seq, ex_xy, ex_mask, ex_color, ex_depth, ex_last,
			dx_valid, dx_seq, dx_xy, dx_mask, dx_depth, dx_last, ord_valid, ord_seq};
	end

	if (HAS_SA != 0) begin : g_sa
		atg_sa #(.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .NPHYS(SU_NPHYS)) sa (
			.clk(clk), .rst_n(core_rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
			.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
			.hcr_ridx(hcr_ridx), .hcr_rdata(sa_hcr_rdata),
			.push_valid(sa_push_valid), .push_ready(sa_push_ready), .push_data(sa_push_data),
			.pop_valid(sa_pop_valid), .pop_ready(sa_pop_ready), .pop_data(sa_pop_data),
			.ctl_valid(sa_ctl_valid), .ctl_data(sa_ctl_data),
			.qstat(sa_qstat), .sastat(sa_stat), .qtag(sa_qtag), .busy(sa_busy),
			.req_valid(c_req_valid[C_SA]), .req_ready(c_req_ready[C_SA]),
			.req_write(c_req_write[C_SA]), .req_line(c_req_line[C_SA*LA_W +: LA_W]),
			.req_be(c_req_be[C_SA*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_SA*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_SA*8 +: 8]),
			.rsp_valid(rsp_valid[C_SA]), .rsp_write(rsp_write_v[C_SA]), .rsp_tag(rsp_tag_v[C_SA*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_SA*LINE_BITS +: LINE_BITS]), .rsp_error(rsp_error_v[C_SA])
		);
	end else begin : g_no_sa
		assign sa_busy = 1'b0;
		assign sa_hcr_rdata = 32'd0;
		assign sa_push_ready = 1'b0;
		assign sa_pop_valid = 1'b0;
		assign sa_pop_data = {DW{1'b0}};
		assign sa_qstat = 32'd0;
		assign sa_stat = 32'd0;
		assign sa_qtag = 32'd0;
		wire unused_sa = &{1'b0, sa_push_valid, sa_push_data, sa_pop_ready, sa_ctl_valid,
			sa_ctl_data};
	end

	if (EXT_CLIENT != 0) begin : g_ext
		assign c_req_valid[C_EXT] = x_req_valid;
		assign x_req_ready = c_req_ready[C_EXT];
		assign c_req_write[C_EXT] = x_req_write;
		assign c_req_line[C_EXT*LA_W +: LA_W] = x_req_line;
		assign c_req_be[C_EXT*LINE_BYTES +: LINE_BYTES] = x_req_be;
		assign c_req_wdata[C_EXT*LINE_BITS +: LINE_BITS] = x_req_wdata;
		assign c_req_tag[C_EXT*8 +: 8] = x_req_tag;
		assign x_rsp_valid = rsp_valid[C_EXT];
		assign x_rsp_write = rsp_write_v[C_EXT];
		assign x_rsp_tag = rsp_tag_v[C_EXT*8 +: 8];
		assign x_rsp_rdata = rsp_rdata_v[C_EXT*LINE_BITS +: LINE_BITS];
		assign x_rsp_error = rsp_error_v[C_EXT];
	end else begin : g_no_ext
		assign x_req_ready = 1'b0;
		assign x_rsp_valid = 1'b0;
		assign x_rsp_write = 1'b0;
		assign x_rsp_tag = 8'd0;
		assign x_rsp_rdata = {LINE_BITS{1'b0}};
		assign x_rsp_error = 1'b0;
		wire unused_ext = &{1'b0, x_req_valid, x_req_write, x_req_line, x_req_be, x_req_wdata,
			x_req_tag};
	end
	endgenerate


	/* The SUs, and the MC's atomic unit they share. */
	genvar k;
	generate
	for (k = 0; k < NSU; k = k + 1) begin : g_su
		localparam CD = C_SU + 2 * k;
		localparam CI = C_SU + 2 * k + 1;
		wire s_vl_gnt, s_fl_gnt, s_tx_valid, s_tx_last, s_tr_ready, s_ex_valid, s_ex_last;
		wire s_sa_push_valid, s_sa_pop_ready, s_sa_ctl_valid;
		wire [SU_WARP_W-1:0] s_vl_slot, s_fl_slot;
		wire [7:0] s_vl_ptbase, s_pt_done;
		wire [31:0] s_pt_rdata, s_ex_xy, s_sa_ctl_data;
		wire [7:0] s_tx_op;
		wire [3:0] s_tx_slot, s_tx_mask, s_ex_mask;
		wire [639:0] s_tx_coord;
		wire [11:0] s_tx_off;
		wire [15:0] s_tx_tag, s_ex_seq;
		wire [511:0] s_ex_color;
		wire [127:0] s_ex_depth;
		wire [DW-1:0] s_sa_push_data;
		wire g0 = k == 0;

		atg_su #(
			.NPHYS(SU_NPHYS), .NWARPS(SU_NWARPS), .WARP_W(SU_WARP_W), .GRP_W(SU_GRP_W),
			.NREGS(SU_NREGS), .SB_ENTRIES(SU_SB_ENTRIES), .SBE_W(SU_SBE_W), .NSU(NSU),
			.SU_INDEX(k), .FRAG_RESERVE(SU_FRAG_RESERVE), .PACKED(SU_PACKED),
			.SUBGROUP(SU_SUBGROUP), .HAS_SA(0),
			.LDS_BYTES(SU_LDS_BYTES), .VARY_WORDS(SU_VARY_WORDS),
			.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)
		) su (
			.clk(clk), .rst_n(core_rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
			.cs_kick(cs_kick), .lc_kick(lc_kick), .inv(inv),
			.vl_req(g0 && vl_req), .vl_gnt(s_vl_gnt), .vl_slot(s_vl_slot),
			.vl_ptbase(s_vl_ptbase), .vl_we(g0 && vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane),
			.vl_data(vl_data), .vl_go(g0 && vl_go), .vl_mask(vl_mask),
			.fl_req(g0 && fl_req), .fl_gnt(s_fl_gnt), .fl_slot(s_fl_slot),
			.fl_we(g0 && fl_we), .fl_reg(fl_reg), .fl_lane(fl_lane), .fl_data(fl_data),
			.fl_pw_we(g0 && fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data),
			.fl_go(g0 && fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
			.pt_rd(g0 && pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(s_pt_rdata),
			.pt_free(g0 && pt_free), .pt_free_idx(pt_free_idx), .pt_done(s_pt_done),
			.tx_valid(s_tx_valid), .tx_ready(g0 && tx_ready), .tx_op(s_tx_op),
			.tx_slot(s_tx_slot), .tx_mask(s_tx_mask), .tx_coord(s_tx_coord), .tx_off(s_tx_off),
			.tx_tag(s_tx_tag),
			.tx_last(s_tx_last),
			.tr_valid(g0 && tr_valid), .tr_ready(s_tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
			.tr_last(tr_last),
			.ex_valid(s_ex_valid), .ex_ready(g0 && ex_ready), .ex_seq(s_ex_seq), .ex_xy(s_ex_xy),
			.ex_mask(s_ex_mask), .ex_color(s_ex_color), .ex_depth(s_ex_depth),
			.ex_last(s_ex_last), .ex_next(ex_next),
			.d_req_valid(c_req_valid[CD]), .d_req_ready(c_req_ready[CD]),
			.d_req_write(c_req_write[CD]), .d_req_line(c_req_line[CD*LA_W +: LA_W]),
			.d_req_be(c_req_be[CD*LINE_BYTES +: LINE_BYTES]),
			.d_req_wdata(c_req_wdata[CD*LINE_BITS +: LINE_BITS]),
			.d_req_tag(c_req_tag[CD*8 +: 8]),
			.d_rsp_valid(rsp_valid[CD]), .d_rsp_write(rsp_write_v[CD]), .d_rsp_tag(rsp_tag_v[CD*8 +: 8]),
			.d_rsp_rdata(rsp_rdata_v[CD*LINE_BITS +: LINE_BITS]), .d_rsp_error(rsp_error_v[CD]),
			.i_req_valid(c_req_valid[CI]), .i_req_ready(c_req_ready[CI]),
			.i_req_write(c_req_write[CI]), .i_req_line(c_req_line[CI*LA_W +: LA_W]),
			.i_req_be(c_req_be[CI*LINE_BYTES +: LINE_BYTES]),
			.i_req_wdata(c_req_wdata[CI*LINE_BITS +: LINE_BITS]),
			.i_req_tag(c_req_tag[CI*8 +: 8]),
			.i_rsp_valid(rsp_valid[CI]), .i_rsp_write(rsp_write_v[CI]), .i_rsp_tag(rsp_tag_v[CI*8 +: 8]),
			.i_rsp_rdata(rsp_rdata_v[CI*LINE_BITS +: LINE_BITS]), .i_rsp_error(rsp_error_v[CI]),
			.at_valid(at_valid[k]), .at_ready(at_ready[k]), .at_op(at_op[k*4 +: 4]),
			.at_addr(at_addr[k*30 +: 30]), .at_a(at_a[k*32 +: 32]), .at_b(at_b[k*32 +: 32]),
			.at_rsp_valid(at_rsp_valid[k]), .at_old(at_old), .at_error(at_error),
			.sa_push_valid(s_sa_push_valid), .sa_push_ready(g0 && sa_push_ready),
			.sa_push_data(s_sa_push_data), .sa_pop_valid(g0 && sa_pop_valid),
			.sa_pop_ready(s_sa_pop_ready), .sa_pop_data(sa_pop_data),
			.sa_ctl_valid(s_sa_ctl_valid), .sa_ctl_data(s_sa_ctl_data),
			.sa_qstat(sa_qstat), .sa_stat(sa_stat), .sa_qtag(sa_qtag),
			.busy(su_busy_v[k]), .fault(su_fault_v[k]),
			.fault_addr(su_fault_addr_v[k*32 +: 32])
		);

		if (k == 0) begin : g_su0
			assign vl_gnt = s_vl_gnt;
			assign vl_ptbase = s_vl_ptbase;
			assign fl_gnt = s_fl_gnt;
			assign pt_rdata = s_pt_rdata;
			assign pt_done = s_pt_done;
			assign tx_valid = s_tx_valid;
			assign tx_op = s_tx_op;
			assign tx_slot = s_tx_slot;
			assign tx_mask = s_tx_mask;
			assign tx_coord = s_tx_coord;
			assign tx_off = s_tx_off;
			assign tx_tag = s_tx_tag;
			assign tx_last = s_tx_last;
			assign tr_ready = s_tr_ready;
			assign ex_valid = s_ex_valid;
			assign ex_seq = s_ex_seq;
			assign ex_xy = s_ex_xy;
			assign ex_mask = s_ex_mask;
			assign ex_color = s_ex_color;
			assign ex_depth = s_ex_depth;
			assign ex_last = s_ex_last;
			assign sa_push_valid = s_sa_push_valid;
			assign sa_push_data = s_sa_push_data;
			assign sa_pop_ready = s_sa_pop_ready;
			assign sa_ctl_valid = s_sa_ctl_valid;
			assign sa_ctl_data = s_sa_ctl_data;
		end else begin : g_sun
			wire unused_sun = &{1'b0, s_vl_gnt, s_vl_ptbase, s_pt_done, s_fl_gnt, s_pt_rdata, s_tx_valid,
				s_tx_op, s_tx_slot, s_tx_mask, s_tx_coord, s_tx_off, s_tx_tag, s_tx_last, s_tr_ready,
				s_ex_valid, s_ex_seq, s_ex_xy, s_ex_mask, s_ex_color, s_ex_depth, s_ex_last,
				s_sa_push_valid, s_sa_push_data, s_sa_pop_ready, s_sa_ctl_valid, s_sa_ctl_data};
		end
		wire unused_slots = &{1'b0, s_vl_slot, s_fl_slot};
	end

	if (NSU > 0) begin : g_atom
		/*
		 * The SUs' ISA fault: the OR, and FAULT_ADDR = the PC of the
		 * lowest-numbered SU that faults in that cycle (ghci §12.6).
		 */
		wire atom_busy;
		reg [31:0] fault_pc;
		integer j;

		always @(*) begin
			fault_pc = 32'd0;
			for (j = NSU - 1; j >= 0; j = j - 1)
				if (su_fault_v[j])
					fault_pc = su_fault_addr_v[j*32 +: 32];
		end
		assign su_busy = |su_busy_v || atom_busy;
		assign su_fault = |su_fault_v;
		assign su_fault_addr = fault_pc;

		atg_mc_atom #(
			.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .NATOM(NSU),
			.AW(NSU > 1 ? $clog2(NSU) : 1)
		) atom (
			.clk(clk), .rst_n(core_rst_n),
			.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
			.at_a(at_a), .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
			.at_error(at_error), .busy(atom_busy),
			.req_valid(c_req_valid[C_ATOM]), .req_ready(c_req_ready[C_ATOM]),
			.req_write(c_req_write[C_ATOM]), .req_line(c_req_line[C_ATOM*LA_W +: LA_W]),
			.req_be(c_req_be[C_ATOM*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[C_ATOM*LINE_BITS +: LINE_BITS]),
			.req_tag(c_req_tag[C_ATOM*8 +: 8]),
			.rsp_valid(rsp_valid[C_ATOM]), .rsp_write(rsp_write_v[C_ATOM]), .rsp_tag(rsp_tag_v[C_ATOM*8 +: 8]),
			.rsp_rdata(rsp_rdata_v[C_ATOM*LINE_BITS +: LINE_BITS]), .rsp_error(rsp_error_v[C_ATOM])
		);
	end else begin : g_no_su
		assign su_busy = 1'b0;
		assign su_fault = 1'b0;
		assign su_fault_addr = 32'd0;
		assign vl_gnt = 1'b0;
		assign vl_ptbase = 8'd0;
		assign fl_gnt = 1'b0;
		assign pt_rdata = 32'd0;
		assign pt_done = 8'd0;
		assign tx_valid = 1'b0;
		assign tx_op = 8'd0;
		assign tx_slot = 4'd0;
		assign tx_mask = 4'd0;
		assign tx_coord = 640'd0;
		assign tx_off = 12'd0;
		assign tx_tag = 16'd0;
		assign tx_last = 1'b0;
		assign tr_ready = 1'b0;
		assign ex_valid = 1'b0;
		assign ex_seq = 16'd0;
		assign ex_xy = 32'd0;
		assign ex_mask = 4'd0;
		assign ex_color = 512'd0;
		assign ex_depth = 128'd0;
		assign ex_last = 1'b0;
		assign sa_push_valid = 1'b0;
		assign sa_push_data = {DW{1'b0}};
		assign sa_pop_ready = 1'b0;
		assign sa_ctl_valid = 1'b0;
		assign sa_ctl_data = 32'd0;
		assign at_valid = 1'b0;
		assign at_op = 4'd0;
		assign at_addr = 30'd0;
		assign at_a = 32'd0;
		assign at_b = 32'd0;
		assign at_ready = 1'b0;
		assign at_rsp_valid = 1'b0;
		assign at_old = 32'd0;
		assign at_error = 1'b0;
		assign su_busy_v = 1'b0;
		assign su_fault_v = 1'b0;
		assign su_fault_addr_v = 32'd0;
		wire unused_su = &{1'b0, cs_kick, lc_kick, inv, vl_req, vl_we, vl_reg, vl_lane, vl_data,
			vl_go, vl_mask, fl_req, fl_we, fl_reg, fl_lane, fl_data, fl_pw_we, fl_pw_addr,
			fl_pw_data, fl_go, fl_mask, fl_info, pt_rd, pt_idx, pt_word, pt_free, pt_free_idx,
			tx_ready, tr_valid, tr_tag, tr_data, tr_last, ex_ready, ex_next, sa_push_ready,
			sa_pop_valid, sa_pop_data, sa_qstat, sa_stat, sa_qtag, at_ready, at_rsp_valid,
			at_old, at_error, su_busy_v, su_fault_v, su_fault_addr_v, at_valid, at_op, at_addr,
			at_a, at_b};
	end
	endgenerate

	wire unused_ok = &{1'b0, blt_done};
endmodule

`default_nettype wire
