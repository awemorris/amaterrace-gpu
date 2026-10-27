/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_mesh_tb: End-to-end integration testbench for the Shader-Integrated
 * Mesh Shading pipeline (WS004 Phase 003).
 *
 * Pipeline flow:
 *   1. Host configures render state (viewport, RT, DS, depth test) and CS state.
 *   2. Host loads Mesh Shader program into memory.
 *   3. Host issues CMD_DRAW_MESH_TASKS (0x2A) command packet to the ring buffer.
 *   4. Command Processor (CP) decodes CMD_DRAW_MESH_TASKS and kicks Shader Unit (SU).
 *   5. SU executes Mesh Shader warp:
 *        - Writes vertex positions {X, Y, Z, W} into Local Data Share (LDS).
 *        - Writes primitive topology indices and flags into LDS.
 *        - Issues exp kick instruction (target 0x200).
 *   6. atg_su_exp_mesh autonomously reads LDS via Port B, formats triangles
 *      into 702-bit mesh_tri stream, and sends to atg_rx_setup.
 *   7. atg_rx_setup receives mesh_tri via static MUX, sets up edge equations.
 *   8. atg_rx_scan generates covered quads/pixels.
 *   9. atg_rop performs depth testing and writes color/depth to framebuffer.
 *  10. CMD_FENCE signals completion.
 *  11. Testbench verifies rendered framebuffer pixels and depth values in memory.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_mesh_tb;
	`include "ghci_regs.vh"

	localparam LINE_BYTES = 64;
	localparam LINE_SHIFT = 6;
	localparam DATA_W = 512;
	localparam MEM_LOG2 = 20;		/* 1 MiB memory */
	localparam RING = 32'h0005F000;
	localparam RING_LOG2 = 11;		/* 2048 bytes / 512 words */
	localparam FENCES = 32'h0005EF00;
	localparam PROG_BASE = 32'h00010000;
	localparam RT = 32'h00020000;
	localparam DS = 32'h00030000;
	localparam W = 64;
	localparam H = 48;
	localparam RT_STRIDE = W * 4;
	localparam DS_STRIDE = W * 4;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* Host AXI-Lite Interface */
	reg [16:0] h_awaddr = 17'd0;
	reg [11:0] h_awid = 12'd0;
	reg h_awvalid = 1'b0;
	wire h_awready;
	reg [63:0] h_wdata = 64'd0;
	reg [7:0] h_wstrb = 8'd0;
	reg h_wlast = 1'b0;
	reg h_wvalid = 1'b0;
	wire h_wready;
	wire [11:0] h_bid;
	wire [1:0] h_bresp;
	wire h_bvalid;
	reg h_bready = 1'b0;

	reg [16:0] h_araddr = 17'd0;
	reg [11:0] h_arid = 12'd0;
	reg [3:0] h_arlen = 4'd0;
	reg h_arvalid = 1'b0;
	wire h_arready;
	wire [63:0] h_rdata;
	wire [11:0] h_rid;
	wire [1:0] h_rresp;
	wire h_rlast;
	wire h_rvalid;
	reg h_rready = 1'b0;
	wire irq;

	/* GPU Memory AXI4 Interface */
	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;

	/* DUT: atg_top with SU, RX, ROP */
	atg_top #(
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DATA_W(DATA_W),
		.HAS_RX(1),
		.HAS_ROP(1),
		.HAS_VF(0),
		.NSU(1),
		.HAS_TU(0),
		.SU_NPHYS(8),
		.SU_GRP_W(2),
		.SU_NREGS(32),
		.SU_SB_ENTRIES(4),
		.SU_SBE_W(2),
		.SU_PACKED(0),
		.SU_SUBGROUP(1),
		.SU_FRAG_RESERVE(1),
		.SU_LDS_BYTES(4096),
		.SU_VARY_WORDS(16)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.irq(irq),
		.mem_ready(1'b1),
		.win_en(),
		.s_awaddr(h_awaddr),
		.s_awid(h_awid),
		.s_awvalid(h_awvalid),
		.s_awready(h_awready),
		.s_wdata(h_wdata),
		.s_wstrb(h_wstrb),
		.s_wlast(h_wlast),
		.s_wvalid(h_wvalid),
		.s_wready(h_wready),
		.s_bid(h_bid),
		.s_bresp(h_bresp),
		.s_bvalid(h_bvalid),
		.s_bready(h_bready),
		.s_araddr(h_araddr),
		.s_arid(h_arid),
		.s_arlen(h_arlen),
		.s_arvalid(h_arvalid),
		.s_arready(h_arready),
		.s_rdata(h_rdata),
		.s_rid(h_rid),
		.s_rresp(h_rresp),
		.s_rlast(h_rlast),
		.s_rvalid(h_rvalid),
		.s_rready(h_rready),
		.m_awid(),
		.m_bid(1'b0),
		.m_arid(),
		.m_rid(1'b0),
		.m_awaddr(awaddr),
		.m_awlen(awlen),
		.m_awsize(awsize),
		.m_awburst(awburst),
		.m_awcache(awcache),
		.m_awprot(awprot),
		.m_awvalid(awvalid),
		.m_awready(awready),
		.m_wdata(wdata),
		.m_wstrb(wstrb),
		.m_wlast(wlast),
		.m_wvalid(wvalid),
		.m_wready(wready),
		.m_bresp(bresp),
		.m_bvalid(bvalid),
		.m_bready(bready),
		.m_araddr(araddr),
		.m_arlen(arlen),
		.m_arsize(arsize),
		.m_arburst(arburst),
		.m_arcache(arcache),
		.m_arprot(arprot),
		.m_arvalid(arvalid),
		.m_arready(arready),
		.m_rdata(rdata),
		.m_rresp(rresp),
		.m_rlast(rlast),
		.m_rvalid(rvalid),
		.m_rready(rready),
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0),
		.x_req_line({(32-LINE_SHIFT){1'b0}}), .x_req_be({LINE_BYTES{1'b0}}),
		.x_req_wdata({(LINE_BYTES*8){1'b0}}), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.pclk(1'b0), .prst_n(1'b0), .scl_i(1'b1), .sda_i(1'b1),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	/* Memory Model */
	axi_mem #(
		.DATA_W(DATA_W),
		.MEM_BYTES(1 << MEM_LOG2),
		.READ_EARLY(1),
		.SEED(1)
	) mem (
		.clk(clk),
		.rst_n(rst_n),
		.awaddr(awaddr),
		.awlen(awlen),
		.awsize(awsize),
		.awburst(awburst),
		.awvalid(awvalid),
		.awready(awready),
		.wdata(wdata),
		.wstrb(wstrb),
		.wlast(wlast),
		.wvalid(wvalid),
		.wready(wready),
		.bresp(bresp),
		.bvalid(bvalid),
		.bready(bready),
		.araddr(araddr),
		.arlen(arlen),
		.arsize(arsize),
		.arburst(arburst),
		.arvalid(arvalid),
		.arready(arready),
		.rdata(rdata),
		.rresp(rresp),
		.rlast(rlast),
		.rvalid(rvalid),
		.rready(rready)
	);

	integer seed = 1;
	`include "axi_host.vh"

	task wait_reg;
		input [16:0] addr;
		input [31:0] want;
		input [31:0] mask;
		reg [31:0] val;
		integer timeout;
		begin
			timeout = 0;
			host_read(addr, val);
			while ((val & mask) != (want & mask) && timeout < 200000) begin
				host_read(addr, val);
				timeout = timeout + 1;
			end
			if ((val & mask) != (want & mask)) begin
				$display("FAIL atg_top_mesh: timeout waiting for reg %h == %h (got %h)", addr, want, val);
				$finish;
			end
		end
	endtask

	/* GSI1 Mesh Shader Program Words:
	 * Writes 3 vertices to LDS (0..11) and 1 primitive to LDS (512),
	 * then issues exp kick target 0x200 and end.
	 */
	localparam PROG_LEN = 44;
	reg [31:0] mesh_prog [0:PROG_LEN-1];
	initial begin
		mesh_prog[0]  = 32'h412000b7; mesh_prog[1]  = 32'h00000000; /* lui r1, 0x41200 (10.0) */
		mesh_prog[2]  = 32'h0010100b; mesh_prog[3]  = 32'h0000000c; /* sts r1, 0(zero)  V0.x */
		mesh_prog[4]  = 32'h0010120b; mesh_prog[5]  = 32'h0000000c; /* sts r1, 4(zero)  V0.y */
		mesh_prog[6]  = 32'h3e8001b7; mesh_prog[7]  = 32'h00000000; /* lui r3, 0x3E800 (0.25) */
		mesh_prog[8]  = 32'h0030140b; mesh_prog[9]  = 32'h0000000c; /* sts r3, 8(zero)  V0.z */
		mesh_prog[10] = 32'h3f800237; mesh_prog[11] = 32'h00000000; /* lui r4, 0x3F800 (1.0)  */
		mesh_prog[12] = 32'h0040160b; mesh_prog[13] = 32'h0000000c; /* sts r4, 12(zero) V0.w */
		mesh_prog[14] = 32'h41f00137; mesh_prog[15] = 32'h00000000; /* lui r2, 0x41F00 (30.0) */
		mesh_prog[16] = 32'h0020180b; mesh_prog[17] = 32'h0000000c; /* sts r2, 16(zero) V1.x */
		mesh_prog[18] = 32'h00101a0b; mesh_prog[19] = 32'h0000000c; /* sts r1, 20(zero) V1.y */
		mesh_prog[20] = 32'h00301c0b; mesh_prog[21] = 32'h0000000c; /* sts r3, 24(zero) V1.z */
		mesh_prog[22] = 32'h00401e0b; mesh_prog[23] = 32'h0000000c; /* sts r4, 28(zero) V1.w */
		mesh_prog[24] = 32'h0210100b; mesh_prog[25] = 32'h0000000c; /* sts r1, 32(zero) V2.x */
		mesh_prog[26] = 32'h0220120b; mesh_prog[27] = 32'h0000000c; /* sts r2, 36(zero) V2.y */
		mesh_prog[28] = 32'h0230140b; mesh_prog[29] = 32'h0000000c; /* sts r3, 40(zero) V2.z */
		mesh_prog[30] = 32'h0240160b; mesh_prog[31] = 32'h0000000c; /* sts r4, 44(zero) V2.w */
		mesh_prog[32] = 32'h080202b7; mesh_prog[33] = 32'h00000000; /* lui r5, 0x08020 */
		mesh_prog[34] = 32'h1002e293; mesh_prog[35] = 32'h00000000; /* ori r5, r5, 0x100 -> 0x08020100 */
		mesh_prog[36] = 32'h80000313; mesh_prog[37] = 32'h0040000c; /* addi r6, zero, 2048 */
		mesh_prog[38] = 32'h0053100b; mesh_prog[39] = 32'h00000000; /* sts r5, 0(r6) */
		mesh_prog[40] = 32'h30100113; mesh_prog[41] = 32'h0000000c; /* addi r2, zero, 0x301 (3 verts, 1 prim) */
		mesh_prog[42] = 32'h2020402b; mesh_prog[43] = 32'h00000000; /* exp r2, 0x200 */
	end

	integer i, x, y, wp, errors;
	reg [31:0] pxl_val, depth_val;

	initial begin
		errors = 0;
		wp = 0;
		@(negedge clk);
		rst_n <= 1'b0;
		repeat (5) @(posedge clk);
		rst_n <= 1'b1;
		repeat (10) @(posedge clk);

		$display("[TEST] Initializing Framebuffer and Depth buffer memory...");
		/* Clear Framebuffer (BGRA8 dark grey 0xFF202020) and Depth buffer (1.0 = 0x3F800000) */
		for (y = 0; y < H; y = y + 1) begin
			for (x = 0; x < W; x = x + 1) begin
				mem.poke32(RT + y * RT_STRIDE + x * 4, 32'hFF202020);
				mem.poke32(DS + y * DS_STRIDE + x * 4, 32'h3F800000);
			end
		end
		mem.poke32(FENCES, 32'd0);

		$display("[TEST] Loading Mesh Shader program into memory at %h...", PROG_BASE);
		for (i = 0; i < PROG_LEN; i = i + 1) begin
			mem.poke32(PROG_BASE + i * 4, mesh_prog[i]);
		end
		/* Append end instruction */
		mem.poke32(PROG_BASE + PROG_LEN * 4,     32'h0000700b);
		mem.poke32(PROG_BASE + PROG_LEN * 4 + 4, 32'h00000000);

		$display("[TEST] Building command ring packets...");
		/* 1. SET_REG: Configure Viewport, Framebuffer, Depth, and Shader state */
		/* Packet Header: Vendor=0, Op=OP_SET_REG(1), Tag=0x40, Flags=0, Length=32 dwords */
		mem.poke32(RING + wp * 4, 32'h01400020); wp = wp + 1;
		/* Viewport */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 0); mem.poke32(RING + (wp+1) * 4, 32'h42000000); wp = wp + 2; /* 32.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 1); mem.poke32(RING + (wp+1) * 4, 32'h41C00000); wp = wp + 2; /* 24.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 2); mem.poke32(RING + (wp+1) * 4, 32'h42000000); wp = wp + 2; /* 32.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 3); mem.poke32(RING + (wp+1) * 4, 32'h41C00000); wp = wp + 2; /* 24.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 4); mem.poke32(RING + (wp+1) * 4, 32'h3F800000); wp = wp + 2; /* 1.0 */
		mem.poke32(RING + wp * 4, GHCI_S_VIEWPORT + 5); mem.poke32(RING + (wp+1) * 4, 32'h00000000); wp = wp + 2; /* 0.0 */
		/* Render Target (RT) */
		mem.poke32(RING + wp * 4, GHCI_S_RT_BASE);      mem.poke32(RING + (wp+1) * 4, RT);            wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_STRIDE);    mem.poke32(RING + (wp+1) * 4, RT_STRIDE);     wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_RT_FORMAT);    mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2; /* BGRA8 */
		mem.poke32(RING + wp * 4, GHCI_S_RT_SIZE);      mem.poke32(RING + (wp+1) * 4, (H << 16) | W); wp = wp + 2;
		/* Depth/Stencil (DS) */
		mem.poke32(RING + wp * 4, GHCI_S_DS_BASE);      mem.poke32(RING + (wp+1) * 4, DS);            wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DS_STRIDE);    mem.poke32(RING + (wp+1) * 4, DS_STRIDE);     wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_DEPTH);        mem.poke32(RING + (wp+1) * 4, 32'h00000047);  wp = wp + 2; /* En, Less, Wr, D32F */
		mem.poke32(RING + wp * 4, GHCI_S_WRITE_MASK);   mem.poke32(RING + (wp+1) * 4, 32'h0000000F);  wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_CULL);         mem.poke32(RING + (wp+1) * 4, 32'd0);         wp = wp + 2; /* No cull */
		mem.poke32(RING + wp * 4, GHCI_S_DEBUG_COLOR);   mem.poke32(RING + (wp+1) * 4, 32'hFF00FF00);  wp = wp + 2; /* Green */

		/* 2. SET_REG: Configure Compute / Mesh Shader program base & Workgroup size */
		mem.poke32(RING + wp * 4, 32'h01410004); wp = wp + 1; /* length = 4 */
		mem.poke32(RING + wp * 4, GHCI_S_CS_BASE);      mem.poke32(RING + (wp+1) * 4, PROG_BASE);     wp = wp + 2;
		mem.poke32(RING + wp * 4, GHCI_S_WG_SIZE);      mem.poke32(RING + (wp+1) * 4, 32'h00010120);  wp = wp + 2; /* 1x1x32 */

		/* 3. CMD_DRAW_MESH_TASKS (0x2A): group_count_x=1, y=1, z=1 (4 dwords total: hdr + 3 payload) */
		mem.poke32(RING + wp * 4, 32'h0000042A); wp = wp + 1; /* Op=0x2A, len=4 */
		mem.poke32(RING + wp * 4, 32'd1);        wp = wp + 1; /* groups_x */
		mem.poke32(RING + wp * 4, 32'd1);        wp = wp + 1; /* groups_y */
		mem.poke32(RING + wp * 4, 32'd1);        wp = wp + 1; /* groups_z */

		/* 4. CMD_WAIT_IDLE: Op=6, wait for entire pipeline to become idle */
		mem.poke32(RING + wp * 4, 32'h06500000); wp = wp + 1; /* Op=0x06, tag=0x50, len=0 */

		/* 5. CMD_FENCE: write 1 to FENCES address */
		mem.poke32(RING + wp * 4, 32'h05600102); wp = wp + 1; /* Op=0x05, flags=1, length=2 */
		mem.poke32(RING + wp * 4, FENCES);       wp = wp + 1;
		mem.poke32(RING + wp * 4, 32'd1);        wp = wp + 1;

		$display("[TEST] Configuring GHCI host registers...");
		host_write(GHCI_APERTURE_BASE, 32'h00000000);
		host_write(GHCI_APERTURE_LIMIT, 32'h00100000);
		host_write(GHCI_RING_BASE, RING);
		host_write(GHCI_RING_SIZE, RING_LOG2);
		host_write(GHCI_FENCE_LAST, 32'd0);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);

		$display("[TEST] Launching Mesh Shader pipeline via RING_WPTR = %0d...", wp);
		host_write(GHCI_RING_WPTR, wp);

		$display("[TEST] Waiting for CMD_FENCE completion...");
		wait_reg(GHCI_FENCE_LAST, 32'd1, 32'hFFFFFFFF);

		/* Wait for in-flight rasterizer & ROP memory writeback */
		repeat (4000) @(posedge clk);

		$display("[TEST] Pipeline finished! Verifying rendered pixel outputs in memory...");

		/* Check pixel (14, 14) inside the triangle (10,10)-(30,10)-(10,30):
		 * Expected Color: 0xFF00FF00 (Green)
		 * Expected Depth: 0.25 (0x3E800000)
		 */
		pxl_val = mem.peek32(RT + 14 * RT_STRIDE + 14 * 4);
		depth_val = mem.peek32(DS + 14 * DS_STRIDE + 14 * 4);
		$display("[TEST] Pixel (14, 14): Color = %h (want FF00FF00), Depth = %h (want 3E800000)", pxl_val, depth_val);
		if (pxl_val !== 32'hFF00FF00) begin
			$display("FAIL atg_top_mesh: pixel (14, 14) color mismatch: %h != FF00FF00", pxl_val);
			errors = errors + 1;
		end
		if (depth_val !== 32'h3E800000) begin
			$display("FAIL atg_top_mesh: pixel (14, 14) depth mismatch: %h != 3E800000", depth_val);
			errors = errors + 1;
		end

		/* Check pixel (50, 40) outside the triangle:
		 * Expected Color: 0xFF202020 (Clear color)
		 * Expected Depth: 0x3F800000 (1.0, Clear depth)
		 */
		pxl_val = mem.peek32(RT + 40 * RT_STRIDE + 50 * 4);
		depth_val = mem.peek32(DS + 40 * DS_STRIDE + 50 * 4);
		$display("[TEST] Pixel (50, 40): Color = %h (want FF202020), Depth = %h (want 3F800000)", pxl_val, depth_val);
		if (pxl_val !== 32'hFF202020) begin
			$display("FAIL atg_top_mesh: pixel (50, 40) outside triangle was overwritten: %h", pxl_val);
			errors = errors + 1;
		end
		if (depth_val !== 32'h3F800000) begin
			$display("FAIL atg_top_mesh: pixel (50, 40) depth outside triangle was overwritten: %h", depth_val);
			errors = errors + 1;
		end

		if (errors == 0) begin
			$display("PASS atg_top_mesh");
		end else begin
			$display("FAIL atg_top_mesh: %0d total errors encountered", errors);
		end
		$finish;
	end

	initial begin
		#500000000;
		$display("FAIL atg_top_mesh: global simulation timeout reached");
		$finish;
	end

endmodule

`default_nettype wire
