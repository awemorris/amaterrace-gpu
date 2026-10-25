/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_cs_tb: compute through the ring, end to end: the GPU
 * driven only through its host port runs sim/vec/cs_scene.txt
 * (tools/cs-scene.py): per GSI1 program of sim/tb/su (vadd over 2
 * workgroups, reduce with LDS, bar and atom.add, mem with lw/sw/atom/fence,
 * lwc and the c operands) the host writes the program binary and the data
 * image to memory, then the ring's SET_REG (CS_BASE, CS_WORDS, WG_SIZE),
 * INVALIDATE (D$), LOAD_PROGRAM (compute), LOAD_CONST, DISPATCH and FENCE
 * (with IRQ_STATUS.FENCE).  After FENCE_LAST reaches the segment's value
 * the data image must equal tools/gsi1model.py's word for word, the fence
 * word must be written, RING_RPTR must equal RING_WPTR, the CP must still
 * be RUNNING and IRQ_STATUS.FENCE must be set.  The last segment's warp
 * stores, then reaches an undefined instruction: the CP must be FAULTED with
 * FAULT_ADDR = the PC, FAULT_INFO kind 8 block 6 and IRQ_STATUS.FAULT, the
 * stores must be in memory and the FENCE after the DISPATCH unwritten.
 * In the KC705's shape: 64-byte lines, 512-bit AXI, the CPU with the CP
 * firmware (not started: the ring carries class 0 micro-ops only), NPHYS
 * 16, NREGS 64, 8 scoreboard entries, PACKED, 16 KiB LDS.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_top_cs_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 64,
	parameter NAME = "dut",
	parameter SCENE = "sim/vec/cs_scene.txt",
	parameter SEED = 1,
	parameter HAS_CPU = 0,
	parameter CPU_IMEM_INIT = "",
	parameter CPU_IMEM_WORDS = 8192,
	parameter CPU_DMEM_WORDS = 4096,
	parameter CPU_DMEM_INIT = "",
	parameter SU_NPHYS = 8,
	parameter SU_GRP_W = 2,
	parameter SU_NREGS = 32,
	parameter SU_SB_ENTRIES = 4,
	parameter SU_SBE_W = 2,
	parameter SU_PACKED = 0,
	parameter SU_LDS_BYTES = 4096
) (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	`include "ghci_regs.vh"

	integer seed = SEED;

	reg [16:0] h_awaddr = 0;
	reg [11:0] h_awid = 0;
	reg h_awvalid = 1'b0;
	wire h_awready;
	reg [31:0] h_wdata = 0;
	reg [3:0] h_wstrb = 0;
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
	wire [31:0] h_rdata;
	wire [11:0] h_rid;
	wire [1:0] h_rresp;
	wire h_rlast;
	wire h_rvalid;
	reg h_rready = 1'b0;
	wire irq;

	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;

	atg_top #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W),
		.HAS_CPU(HAS_CPU), .CPU_IMEM_INIT(CPU_IMEM_INIT), .CPU_DMEM_INIT(CPU_DMEM_INIT),
		.CPU_IMEM_WORDS(CPU_IMEM_WORDS), .CPU_DMEM_WORDS(CPU_DMEM_WORDS),
		.NSU(1), .SU_NPHYS(SU_NPHYS), .SU_GRP_W(SU_GRP_W), .SU_NREGS(SU_NREGS),
		.SU_SB_ENTRIES(SU_SB_ENTRIES), .SU_SBE_W(SU_SBE_W), .SU_PACKED(SU_PACKED),
		.SU_LDS_BYTES(SU_LDS_BYTES)) dut (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1),
		.s_awaddr(h_awaddr), .s_awid(h_awid), .s_awvalid(h_awvalid), .s_awready(h_awready),
		.s_wdata(h_wdata), .s_wstrb(h_wstrb), .s_wlast(h_wlast), .s_wvalid(h_wvalid),
		.s_wready(h_wready), .s_bid(h_bid), .s_bresp(h_bresp), .s_bvalid(h_bvalid),
		.s_bready(h_bready), .s_araddr(h_araddr), .s_arid(h_arid), .s_arlen(h_arlen),
		.s_arvalid(h_arvalid), .s_arready(h_arready), .s_rdata(h_rdata), .s_rid(h_rid),
		.s_rresp(h_rresp), .s_rlast(h_rlast), .s_rvalid(h_rvalid), .s_rready(h_rready),
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
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line({(32-LINE_SHIFT){1'b0}}),
		.x_req_be({LINE_BYTES{1'b0}}), .x_req_wdata({(LINE_BYTES*8){1'b0}}), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 19), .READ_EARLY(1), .SEED(SEED + 7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	`include "axi_host.vh"

	localparam [31:0] RING = 32'h0005F000;

	/* The SU's busy level was seen during the segment (the dispatch ran). */
	reg su_seen = 1'b0;
	always @(posedge clk)
		if (dut.su_busy)
			su_seen <= 1'b1;

	task wait_reg;
		input [31:0] off;
		input [31:0] want;
		reg [31:0] got;
		integer n;
		begin
			n = 0;
			host_read(off, got);
			while (got != want && n < 400000) begin
				host_read(off, got);
				n = n + 1;
			end
			if (got != want) begin
				errors = errors + 1;
				$display("FAIL atg_top_cs(%0s) %0s: reg %h stays %h, waiting for %h", NAME,
					sname, off, got, want);
			end
		end
	endtask

	task wait_reg_mask;
		input [31:0] off;
		input [31:0] want;
		input [31:0] mask;
		reg [31:0] got;
		integer n;
		begin
			n = 0;
			host_read(off, got);
			while ((got & mask) != want && n < 400000) begin
				host_read(off, got);
				n = n + 1;
			end
			if ((got & mask) != want) begin
				errors = errors + 1;
				$display("FAIL atg_top_cs(%0s) %0s: reg %h stays %h, waiting for %h", NAME,
					sname, off, got, want);
			end
		end
	endtask

	task expect_reg;
		input [31:0] off;
		input [31:0] want;
		input [31:0] mask;
		input [8*24-1:0] what;
		reg [31:0] got;
		begin
			host_read(off, got);
			if ((got & mask) != (want & mask)) begin
				errors = errors + 1;
				$display("FAIL atg_top_cs(%0s) %0s: %0s: reg %h = %h, want %h", NAME, sname,
					what, off, got, want);
			end
		end
	endtask

	integer fd, rc, nseg, wp, bad, seg_err, t0;
	reg [31:0] nfence;
	reg [8*2-1:0] kind;
	reg [8*16-1:0] sname;
	reg [31:0] a, v, got;

	task seg_end;
		begin
			if (sname != 0) begin
				if (bad != 0) begin
					errors = errors + 1;
					$display("FAIL atg_top_cs(%0s) %0s: %0d words differ from the model",
						NAME, sname, bad);
				end
				if (errors == seg_err)
					$display("PASS atg_top_cs(%0s).%0s: %0d cycles", NAME, sname,
						($time - t0) / 10);
			end
			bad = 0;
			seg_err = errors;
		end
	endtask

	initial begin
		finished = 1'b0;
		errors = 0;
		bad = 0;
		seg_err = 0;
		wp = 0;
		sname = 0;
		nfence = 0;
		@(posedge rst_n);
		repeat (8) @(posedge clk);

		host_write(GHCI_APERTURE_BASE, 32'h00001000);
		host_write(GHCI_APERTURE_LIMIT, 32'h00060000);
		host_write(GHCI_RING_BASE, RING);
		host_write(GHCI_RING_SIZE, 32'd10);
		host_write(GHCI_FENCE_LAST, 32'd0);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);
		fd = $fopen(SCENE, "r");
		if (fd == 0) begin
			errors = errors + 1;
			$display("FAIL atg_top_cs(%0s): no %0s", NAME, SCENE);
		end else begin
			rc = $fscanf(fd, "%s %d\n", kind, nseg);
			while (!$feof(fd)) begin
				rc = $fscanf(fd, "%s", kind);
				if (rc != 1) begin
				end else if (kind == "S") begin
					seg_end;
					rc = $fscanf(fd, " %s\n", sname);
					t0 = $time;
				end else if (kind == "I") begin
					rc = $fscanf(fd, " %h %h\n", a, v);
					mem.poke32(a, v);
				end else if (kind == "R") begin
					rc = $fscanf(fd, " %h\n", v);
					mem.poke32(RING + wp * 4, v);
					wp = wp + 1;
				end else if (kind == "F") begin
					rc = $fscanf(fd, " %h\n", v);
					expect_reg(GHCI_IRQ_STATUS, 0, 32'd1 << GHCI_IRQ_FENCE, "FENCE before");
					su_seen = 1'b0;
					host_write(GHCI_RING_WPTR, wp);
					wait_reg(GHCI_FENCE_LAST, v);
					nfence = v;
					if (!su_seen) begin
						errors = errors + 1;
						$display("FAIL atg_top_cs(%0s) %0s: the SU was never busy", NAME, sname);
					end
					expect_reg(GHCI_STATUS, 32'd1 << GHCI_STATUS_STATE,
						32'hF << GHCI_STATUS_STATE, "RUNNING");
					expect_reg(GHCI_RING_RPTR, wp, 32'hFFFFFFFF, "RPTR = WPTR");
					expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_FENCE,
						32'd1 << GHCI_IRQ_FENCE, "IRQ_STATUS.FENCE");
					host_write(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_FENCE);
				end else if (kind == "X") begin
					rc = $fscanf(fd, " %h %h\n", a, v);
					host_write(GHCI_RING_WPTR, wp);
					wait_reg_mask(GHCI_STATUS, 32'd4 << GHCI_STATUS_STATE,
						32'hF << GHCI_STATUS_STATE);
					expect_reg(GHCI_FAULT_ADDR, a, 32'hFFFFFFFF, "FAULT_ADDR (the PC)");
					expect_reg(GHCI_FAULT_INFO, v, 32'hFFFFFFFF, "FAULT_INFO");
					expect_reg(GHCI_IRQ_STATUS, 32'd1 << GHCI_IRQ_FAULT,
						32'd1 << GHCI_IRQ_FAULT | 32'd1 << GHCI_IRQ_FENCE, "IRQ FAULT, no FENCE");
					/* nothing after the fault: the FENCE stays unwritten */
					repeat (2000) @(posedge clk);
					expect_reg(GHCI_FENCE_LAST, nfence, 32'hFFFFFFFF, "FENCE_LAST kept");
				end else if (kind == "E") begin
					rc = $fscanf(fd, " %h %h\n", a, v);
					got = mem.peek32(a);
					if (got !== v) begin
						if (bad < 6)
							$display("FAIL atg_top_cs(%0s) %0s: mem %h = %h, model %h", NAME,
								sname, a, got, v);
						bad = bad + 1;
					end
				end else begin
					errors = errors + 1;
					$display("FAIL atg_top_cs(%0s): bad line kind %0s", NAME, kind);
				end
			end
			seg_end;
			$fclose(fd);
		end
		finished = 1'b1;
	end
endmodule

module atg_top_cs_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_kc705;
	wire [31:0] err_kc705;

	always #5 clk = !clk;

	atg_top_cs_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .NAME("kc705"),
		.SEED(12), .HAS_CPU(1), .CPU_IMEM_WORDS(16384), .CPU_DMEM_WORDS(8192),
		.CPU_IMEM_INIT("fw/cp/images/atg1-cp-kc705.imem.hex"),
		.CPU_DMEM_INIT("fw/cp/images/atg1-cp-kc705.dmem.hex"), .SU_NPHYS(8), .SU_GRP_W(2),
		.SU_NREGS(64), .SU_SB_ENTRIES(8), .SU_SBE_W(3), .SU_PACKED(1),
		.SU_LDS_BYTES(16384)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_kc705);
		if (err_kc705 == 0)
			$display("PASS atg_top_cs");
		else
			$display("FAIL atg_top_cs: %0d errors", err_kc705);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_top_cs: timeout");
		$finish;
	end
endmodule

`default_nettype wire
