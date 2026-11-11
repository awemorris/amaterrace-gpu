/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_ghci_top_tb: Full GPU top-level MMIO verification through atg_top
 * for minimal and balanced configurations (WS347 / W1-W6).
 *
 * Tests:
 *   - W1: CP_HEAP_BASE (0x050) & CP_HEAP_LIMIT (0x054) read/write,
 *         APERTURE_BASE (0x060) write ignored.
 *   - W2: EXT_CAP_FMT0[15:12] = MRT_COUNT, FMT_LIMITS[3:0] = MRT_COUNT.
 *   - W3: EXTCAP FMT capability listed at 0x140 in all configurations.
 *   - W4: DEVICE_CAPS[3] = 0, DEVICE_CAPS[4] = 0 in minimal/KC705.
 *   - W5: EXT_CAP_FEATURE[14] = 0, EXT_CAP_FEATURE[15] = (MRT >= 2).
 *   - W6: GCLK_HZ at 0x064 = 200000000, VEND at 0x190 = 200000000.
 */

`timescale 1ns / 1ps
`default_nettype none

module ghci_probe #(
	parameter NAME = "dut",
	parameter [3:0] EXP_MRT = 4'd1,
	parameter [31:0] EXP_DEV_CAPS = 32'h40010480,
	parameter [31:0] EXP_FMT0 = 32'h00001200,
	parameter [31:0] EXP_FEAT = 32'h00110000,
	parameter [31:0] EXP_GCLK = 32'd200000000,
	parameter [31:0] LOCAL_BYTES = 32'd0,
	parameter [31:0] WINDOW_BYTES = 32'd0,
	parameter SU_NPHYS = 4,
	parameter SU_PACKED = 0,
	parameter SU_SUBGROUP = 0,
	parameter SU_LDS_BYTES = 1024,
	parameter MS4 = 0,
	parameter ROP_STENCIL = 0,
	parameter HAS_BLT = 0,
	parameter HAS_JTAG = 0,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] err_count
);
	`include "ghci_regs.vh"

	localparam LINE_BYTES = 64;
	localparam LINE_SHIFT = 6;
	localparam DATA_W = 512;

	integer seed = SEED;

	reg [16:0] h_awaddr = 0;
	reg [11:0] h_awid = 0;
	reg h_awvalid = 1'b0;
	wire h_awready;
	reg [63:0] h_wdata = 0;
	reg [7:0] h_wstrb = 0;
	reg h_wlast = 1'b0;
	reg h_wvalid = 1'b0;
	wire h_wready;
	wire [11:0] h_bid;
	wire [1:0] h_bresp;
	wire h_bvalid;
	reg h_bready = 1'b0;
	reg [16:0] h_araddr = 0;
	reg [11:0] h_arid = 0;
	reg [3:0] h_arlen = 0;
	reg h_arvalid = 1'b0;
	wire h_arready;
	wire [63:0] h_rdata;
	wire [11:0] h_rid;
	wire [1:0] h_rresp;
	wire h_rlast;
	wire h_rvalid;
	reg h_rready = 1'b0;
	wire irq;

	wire [63:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;

	atg_top #(
		.S_ID_W(12),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.GCLK_HZ(EXP_GCLK),
		.MRT_COUNT(EXP_MRT),
		.DEVICE_CAPS(EXP_DEV_CAPS),
		.EXT_CAP_FMT0(EXP_FMT0),
		.EXT_CAP_FEATURE(EXP_FEAT),
		.SU_NPHYS(SU_NPHYS),
		.SU_NWARPS(4),
		.SU_WARP_W(2),
		.SU_GRP_W(SU_NPHYS == 4 ? 3 : 2),
		.SU_NREGS(32),
		.SU_PACKED(SU_PACKED),
		.SU_SUBGROUP(SU_SUBGROUP),
		.SU_LDS_BYTES(SU_LDS_BYTES),
		.MS4(MS4),
		.ROP_STENCIL(ROP_STENCIL),
		.HAS_CPU(0),
		.NSU(1),
		.HAS_VF(1),
		.HAS_RX(1),
		.HAS_TU(1),
		.HAS_ROP(1),
		.HAS_BLT(HAS_BLT),
		.HAS_DISP(1),
		.HAS_JTAG(HAS_JTAG),
		.LOCAL_BYTES(LOCAL_BYTES),
		.WINDOW_BYTES(WINDOW_BYTES)
	) dut (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1),
		.win_en(),
		.s_awaddr(h_awaddr), .s_awid(h_awid), .s_awvalid(h_awvalid), .s_awready(h_awready),
		.s_wdata(h_wdata), .s_wstrb(h_wstrb), .s_wlast(h_wlast), .s_wvalid(h_wvalid),
		.s_wready(h_wready), .s_bid(h_bid), .s_bresp(h_bresp), .s_bvalid(h_bvalid),
		.s_bready(h_bready), .s_araddr(h_araddr), .s_arid(h_arid), .s_arlen(h_arlen),
		.s_arvalid(h_arvalid), .s_arready(h_arready), .s_rdata(h_rdata), .s_rid(h_rid),
		.s_rresp(h_rresp), .s_rlast(h_rlast), .s_rvalid(h_rvalid), .s_rready(h_rready),
		.m_awid(), .m_bid(1'b0), .m_arid(), .m_rid(1'b0),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready),
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line(26'd0),
		.x_req_be(64'd0), .x_req_wdata(512'd0), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.pclk(1'b0), .prst_n(1'b0), .scl_i(1'b1), .sda_i(1'b1),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 19), .READ_EARLY(1), .SEED(SEED + 7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr[31:0]), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr[31:0]), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	`include "axi_host.vh"

	task check32;
		input [8*30-1:0] desc;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				err_count = err_count + 1;
				$display("FAIL [%0s] %0s: got %08h, expected %08h", NAME, desc, got, want);
			end else begin
				$display("PASS [%0s] %0s: %08h", NAME, desc, got);
			end
		end
	endtask

	reg [31:0] val;
	reg [31:0] xoff, w0, w1;
	integer found_fmt;

	initial begin
		done = 0;
		err_count = 0;
		@(posedge rst_n);
		repeat (10) @(posedge clk);

		$display("=== Running ghci_probe on %0s ===", NAME);

		/* 1. Identification */
		host_read(GHCI_REG_MAGIC, val);
		check32("GHCI_MAGIC", val, GHCI_MAGIC_VALUE);

		host_read(GHCI_REG_VERSION, val);
		check32("GHCI_VERSION", val, 32'h00010000);

		/* 2. DEVICE_CAPS */
		host_read(GHCI_REG_DEVICE_CAPS, val);
		check32("DEVICE_CAPS", val, EXP_DEV_CAPS);
		if (val[3] !== 1'b0 || val[4] !== 1'b0) begin
			err_count = err_count + 1;
			$display("FAIL [%0s] DEVICE_CAPS[4:3] must be 0", NAME);
		end

		/* 3. Scratchpad write/read */
		host_write(GHCI_REG_SCRATCH, 32'hDEADBEEF);
		host_read(GHCI_REG_SCRATCH, val);
		check32("SCRATCH", val, 32'hDEADBEEF);

		/* 4. W1: CP_HEAP_BASE / CP_HEAP_LIMIT write/read */
		host_write(GHCI_REG_CP_HEAP_BASE, 32'h80010000);
		host_read(GHCI_REG_CP_HEAP_BASE, val);
		check32("CP_HEAP_BASE", val, 32'h80010000);

		host_write(GHCI_REG_CP_HEAP_LIMIT, 32'h90010000);
		host_read(GHCI_REG_CP_HEAP_LIMIT, val);
		check32("CP_HEAP_LIMIT", val, 32'h90010000);

		/* W1: Write to legacy APERTURE_BASE (0x060) is ignored */
		host_write(17'h00060, 32'h12345678);
		host_read(17'h00060, val);
		check32("Legacy 0x060 write ignored (reads 0)", val, 32'h00000000);
		host_read(GHCI_REG_CP_HEAP_BASE, val);
		check32("CP_HEAP_BASE unchanged by 0x060 write", val, 32'h80010000);

		/* C1: Ring registers write / read */
		host_write(GHCI_REG_RING_BASE_LO, 32'h12345000);
		host_read(GHCI_REG_RING_BASE_LO, val);
		check32("RING_BASE_LO write/read", val, 32'h12345000);

		host_write(GHCI_REG_RING_BASE_HI, 32'h00000001);
		host_read(GHCI_REG_RING_BASE_HI, val);
		check32("RING_BASE_HI write/read", val, 32'h00000001);

		/* R1: RING_SIZE accepts byte size (power of 2, 4 KiB .. 16 MiB) */
		host_write(GHCI_REG_RING_SIZE, 32'h00010000); /* 64 KiB */
		host_read(GHCI_REG_RING_SIZE, val);
		check32("RING_SIZE write/read 64KiB", val, 32'h00010000);

		/* R1: Non-power-of-2 write should be ignored (preserves previous value) */
		host_write(GHCI_REG_RING_SIZE, 32'h00012345);
		host_read(GHCI_REG_RING_SIZE, val);
		check32("RING_SIZE non-power-of-2 ignored", val, 32'h00010000);

		/* R1: 16 MiB maximum size */
		host_write(GHCI_REG_RING_SIZE, 32'h01000000);
		host_read(GHCI_REG_RING_SIZE, val);
		check32("RING_SIZE write/read 16MiB", val, 32'h01000000);

		/* Restore to 64 KiB */
		host_write(GHCI_REG_RING_SIZE, 32'h00010000);

		host_write(GHCI_REG_RING_WPTR, 32'd4);
		host_read(GHCI_REG_RING_WPTR, val);
		check32("RING_WPTR write/read", val, 32'd4);

		/* C1: Writing CTRL does NOT corrupt RING_WPTR */
		host_write(GHCI_REG_CTRL, 32'd0);
		host_read(GHCI_REG_RING_WPTR, val);
		check32("RING_WPTR preserved after CTRL write", val, 32'd4);

		/* C1: Writing CP_HEAP_BASE does NOT corrupt RING_BASE_LO */
		host_read(GHCI_REG_RING_BASE_LO, val);
		check32("RING_BASE_LO preserved after HEAP write", val, 32'h12345000);

		/* C2: NATIVE_ISA_ID (0x068) */
		host_read(17'h00068, val);
		check32("NATIVE_ISA_ID (0x068)", val, 32'h47534931);

		/* C2: Unmapped registers in §3.1 return 0 */
		host_read(17'h0006C, val);
		check32("Unmapped 0x06C reads 0", val, 32'd0);
		host_read(17'h00070, val);
		check32("Unmapped 0x070 reads 0", val, 32'd0);
		host_read(17'h0007C, val);
		check32("Unmapped 0x07C reads 0", val, 32'd0);
		host_read(17'h00088, val);
		check32("Unmapped 0x088 reads 0", val, 32'd0);
		host_read(17'h00090, val);
		check32("Unmapped 0x090 reads 0", val, 32'd0);
		host_read(17'h000A0, val);
		check32("Unmapped 0x0A0 reads 0", val, 32'd0);
		host_read(17'h000B0, val);
		check32("Unmapped 0x0B0 reads 0", val, 32'd0);
		host_read(17'h000C0, val);
		check32("Unmapped 0x0C0 reads 0", val, 32'd0);
		host_read(17'h000F0, val);
		check32("Unmapped 0x0F0 reads 0", val, 32'd0);

		/* C2: Verify no OR-mixing on distinct patterns */
		host_read(GHCI_REG_SCRATCH, val);
		check32("SCRATCH distinct", val, 32'hDEADBEEF);
		host_read(GHCI_REG_CP_HEAP_BASE, val);
		check32("CP_HEAP_BASE distinct", val, 32'h80010000);
		host_read(GHCI_REG_CP_HEAP_LIMIT, val);
		check32("CP_HEAP_LIMIT distinct", val, 32'h90010000);

		/* 5. W6: GCLK_HZ */
		host_read(GHCI_REG_GCLK_HZ, val);
		check32("GCLK_HZ (0x064)", val, EXP_GCLK);

		/* 6. W2: EXT_CAP_FMT0 */
		host_read(GHCI_REG_EXT_CAP_FMT0, val);
		check32("EXT_CAP_FMT0 (0x080)", val, EXP_FMT0);
		if (val[15:12] !== EXP_MRT) begin
			err_count = err_count + 1;
			$display("FAIL [%0s] EXT_CAP_FMT0[15:12] = %0d, expected %0d", NAME, val[15:12], EXP_MRT);
		end

		/* 7. W5: EXT_CAP_FEATURE */
		host_read(GHCI_REG_EXT_CAP_FEATURE, val);
		check32("EXT_CAP_FEATURE (0x084)", val, EXP_FEAT);
		if (val[14] !== 1'b0) begin
			err_count = err_count + 1;
			$display("FAIL [%0s] EXT_CAP_FEATURE[14] COLOR_LUT must be 0", NAME);
		end
		if (val[15] !== (EXP_MRT >= 4'd2 ? 1'b1 : 1'b0)) begin
			err_count = err_count + 1;
			$display("FAIL [%0s] EXT_CAP_FEATURE[15] MRT_BLEND mismatch", NAME);
		end
		if (val[19:16] !== EXP_MRT) begin
			err_count = err_count + 1;
			$display("FAIL [%0s] EXT_CAP_FEATURE[19:16] MAX_MRT mismatch", NAME);
		end

		/* 8. W3: EXTCAP List traversal & FMT capability at 0x140 */
		host_read(GHCI_REG_EXTCAP_PTR, xoff);
		check32("EXTCAP_PTR", xoff, 32'h00000100);

		found_fmt = 0;
		while (xoff != 0 && xoff < 32'h00000140) begin
			host_read(xoff, w0);
			host_read(xoff + 4, w1);
			$display("  EXTCAP [%0s] entry @ %h: ID=%0d, ver=%0d, ptr=%08h",
				NAME, xoff, w0[7:0], w0[15:8], w1);
			if (w0[7:0] == 8'd10) begin /* FMT */
				found_fmt = 1;
				check32("FMT window ptr", w1, 32'h00000140);
			end
			xoff = (w0[31:16] == 0) ? 0 : xoff + {w0[31:16], 2'b00};
		end
		if (!found_fmt) begin
			err_count = err_count + 1;
			$display("FAIL [%0s] FMT capability (ID 10) not found in EXTCAP list!", NAME);
		end else begin
			$display("PASS [%0s] FMT capability found in EXTCAP list", NAME);
		end

		/* Test FMT registers at 0x140 */
		/* FMT_INDEX (+0x0): write VK_FORMAT_R8G8B8A8_UNORM (0x25 = 37, or 44) */
		host_write(17'h00140, 32'd44);
		host_read(17'h00144, val); /* FMT_OPTIMAL */
		if (val == 32'd0) begin
			err_count = err_count + 1;
			$display("FAIL [%0s] FMT_OPTIMAL returned 0 for valid format", NAME);
		end else begin
			$display("PASS [%0s] FMT_OPTIMAL = %08h", NAME, val);
		end

		/* FMT_LIMITS (+0x10): [3:0] must equal MRT_COUNT */
		host_read(17'h00150, val);
		check32("FMT_LIMITS[3:0]", {28'd0, val[3:0]}, {28'd0, EXP_MRT});

		/* VEND registers at 0x180 */
		host_read(17'h00180, val);
		check32("VEND VENDOR_ID", val, 32'h414D4154);
		host_read(17'h00184, val);
		check32("VEND DEVICE_ID", val, 32'h41544731);
		host_read(17'h00190, val);
		check32("VEND GCLK_HZ", val, EXP_GCLK);

		done = 1;
	end
endmodule

module atg_ghci_top_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	wire done_min, done_bal;
	wire [31:0] err_min, err_bal;

	/* 1. Minimal Configuration */
	ghci_probe #(
		.NAME("minimal"),
		.EXP_MRT(4'd1),
		.EXP_DEV_CAPS(32'h40010480),
		.EXP_FMT0(32'h00001200),
		.EXP_FEAT(32'h00110000),
		.EXP_GCLK(32'd200000000),
		.LOCAL_BYTES(32'd0),
		.WINDOW_BYTES(32'd0),
		.SU_NPHYS(4),
		.SU_PACKED(0),
		.SU_SUBGROUP(0),
		.SU_LDS_BYTES(1024),
		.MS4(0),
		.ROP_STENCIL(0),
		.HAS_BLT(0),
		.HAS_JTAG(0),
		.SEED(1)
	) probe_min (
		.clk(clk),
		.rst_n(rst_n),
		.done(done_min),
		.err_count(err_min)
	);

	/* 2. Balanced Configuration */
	ghci_probe #(
		.NAME("balanced"),
		.EXP_MRT(4'd4),
		.EXP_DEV_CAPS(32'hE70108E4),
		.EXP_FMT0(32'h0007425F),
		.EXP_FEAT(32'hF044BF02),
		.EXP_GCLK(32'd200000000),
		.LOCAL_BYTES(32'h40000000),
		.WINDOW_BYTES(32'h04000000),
		.SU_NPHYS(8),
		.SU_PACKED(1),
		.SU_SUBGROUP(1),
		.SU_LDS_BYTES(4096),
		.MS4(1),
		.ROP_STENCIL(1),
		.HAS_BLT(1),
		.HAS_JTAG(1),
		.SEED(2)
	) probe_bal (
		.clk(clk),
		.rst_n(rst_n),
		.done(done_bal),
		.err_count(err_bal)
	);

	initial begin
		#20;
		rst_n = 1'b1;

		wait (done_min && done_bal);
		#20;

		if (err_min == 0 && err_bal == 0) begin
			$display("PASS atg_ghci_top");
		end else begin
			$display("FAIL atg_ghci_top: min=%0d bal=%0d errors", err_min, err_bal);
		end
		$finish;
	end

endmodule
`default_nettype wire
