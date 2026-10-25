/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_scene.vh: the scene harness of atg_top_raster_tb,
 * atg_top_shade_tb, atg_top_tex_tb and atg_top_msaa_tb: the GPU (HAS_RX,
 * HAS_ROP, and HAS_VF/NSU/HAS_TU/MS4 when given) driven only through its
 * host port runs the ring of a scene file (the I/R/E lines of
 * tools/rx-raster-scene.py, tools/rx-shade-scene.py, tools/rx-tex-scene.py
 * and tools/rx-msaa-scene.py) and the memory words of the E lines must
 * equal the model's.  A line "C NAME" among the E lines starts a case:
 * the harness prints "PASS TB(NAME).CASE" (or FAIL) for the E lines up to
 * the next C line.  CAPS[29] must be MS4 && HAS_VF && HAS_TU && NSU,
 * CAPS[30] and CAPS[9] (Vulkan 1.0 core rendering, the KC705's shape)
 * HAS_VF && HAS_TU && NSU && SU_VARY_WORDS >= 64.  Lines "F vkformat
 * optimal linear buffer limits" (before the first E line, CORE scenes)
 * are the FMT capability's words for that format, checked before the ring
 * starts (PASS TB(NAME).fmt).
 */

module atg_top_scene_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 64,
	parameter NAME = "dut",
	parameter TB = "atg_top_raster",
	parameter SCENE = "sim/vec/raster_scene.txt",
	parameter SEED = 1,
	/* the blocks (atg_top's parameters) */
	parameter HAS_VF = 0,
	parameter NSU = 0,
	parameter HAS_TU = 0,
	parameter SU_NPHYS = 8,
	parameter SU_GRP_W = 2,
	parameter SU_VARY_WORDS = 16,
	/* the rest of the SU shape and the ROP (atg_top's defaults; the KC705
	 * board top's values in atg_top_shade_tb's kc705 instance) */
	parameter SU_NREGS = 32,
	parameter SU_SB_ENTRIES = 4,
	parameter SU_SBE_W = 2,
	parameter SU_PACKED = 0,
	parameter SU_SUBGROUP = 0,
	parameter SU_FRAG_RESERVE = 1,
	parameter SU_LDS_BYTES = 4096,
	parameter ROP_STENCIL = 0,
	parameter MS4 = 0,
	/* where the ring is, log2 of its bytes (RING_SIZE), and how many
	 * FENCE_LAST reads to wait for the scene's end */
	parameter [31:0] RING = 32'h0005F000,
	parameter RING_LOG2 = 11,
	parameter WAIT_READS = 200000,
	/* the memory's bytes (log2) and the aperture's limit */
	parameter MEM_LOG2 = 19,
	parameter [31:0] APER_LIMIT = 32'h00060000
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
		.HAS_RX(1), .HAS_ROP(1), .HAS_VF(HAS_VF), .NSU(NSU), .HAS_TU(HAS_TU), .SU_NPHYS(SU_NPHYS),
		.SU_GRP_W(SU_GRP_W), .SU_VARY_WORDS(SU_VARY_WORDS), .SU_NREGS(SU_NREGS),
		.SU_SB_ENTRIES(SU_SB_ENTRIES), .SU_SBE_W(SU_SBE_W), .SU_PACKED(SU_PACKED),
		.SU_SUBGROUP(SU_SUBGROUP), .SU_FRAG_RESERVE(SU_FRAG_RESERVE),
		.SU_LDS_BYTES(SU_LDS_BYTES), .ROP_STENCIL(ROP_STENCIL), .MS4(MS4)) dut (
		.clk(clk), .rst_n(rst_n), .irq(irq), .mem_ready(1'b1),
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
		/* Nothing outside the GPU here. */
		.xr_wr(), .xr_waddr(), .xr_wdata(), .xr_wstrb(), .xr_rd(), .xr_raddr(),
		.xr_rdata(32'd0),
		.x_req_valid(1'b0), .x_req_ready(), .x_req_write(1'b0), .x_req_line({(32-LINE_SHIFT){1'b0}}),
		.x_req_be({LINE_BYTES{1'b0}}), .x_req_wdata({(LINE_BYTES*8){1'b0}}), .x_req_tag(8'd0),
		.x_rsp_valid(), .x_rsp_write(), .x_rsp_tag(), .x_rsp_rdata(), .x_rsp_error(),
		.x_vsync(1'b0),
		.j_wr(1'b0), .j_waddr(17'd0), .j_wdata(32'd0), .j_wstrb(4'd0), .j_rd(1'b0),
		.j_raddr(17'd0), .j_rdata(), .j_busy()
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << MEM_LOG2), .READ_EARLY(1), .SEED(SEED + 7)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	`include "axi_host.vh"

	task wait_reg;
		input [31:0] off;
		input [31:0] want;
		input [31:0] mask;
		reg [31:0] got;
		integer n;
		begin
			n = 0;
			host_read(off, got);
			while ((got & mask) != (want & mask) && n < WAIT_READS) begin
				host_read(off, got);
				n = n + 1;
			end
			if ((got & mask) != (want & mask)) begin
				errors = errors + 1;
				$display("FAIL %0s(%0s): reg %h stays %h, waiting for %h", TB, NAME,
					off, got, want);
			end
		end
	endtask

	integer fd, rc, nr, wp, bad, bad_rt, bad_ds, cbad, ncase, nfmt, fmt_bad, fk;
	reg [31:0] fmt_w [0:1279];	/* the F lines: 5 words each */
	reg [31:0] fmt_regs, xoff, xw, f0, f1, f2, f3, f4;
	reg [8*2-1:0] kind;
	reg [8*32-1:0] cname;
	reg [31:0] a, v, got;

	initial begin
		finished = 1'b0;
		errors = 0;
		bad = 0;
		bad_rt = 0;
		bad_ds = 0;
		cbad = 0;
		ncase = 0;
		nfmt = 0;
		fmt_bad = 0;
		wp = 0;
		@(posedge rst_n);
		repeat (8) @(posedge clk);

		host_read(GHCI_CAPS, got);
		if (got[29] !== (MS4 != 0 && HAS_VF != 0 && HAS_TU != 0 && NSU != 0)) begin
			errors = errors + 1;
			$display("FAIL %0s(%0s): CAPS %h, bit 29 (MS4) not as the shape", TB, NAME, got);
		end
		if (got[30] !== (HAS_VF != 0 && HAS_TU != 0 && NSU != 0 && SU_VARY_WORDS >= 64) ||
				got[9] !== got[30]) begin
			errors = errors + 1;
			$display("FAIL %0s(%0s): CAPS %h, bits 30 and 9 (core) not as the shape", TB, NAME, got);
		end
		host_write(GHCI_APERTURE_BASE, 32'h00020000);
		host_write(GHCI_APERTURE_LIMIT, APER_LIMIT);
		fd = $fopen(SCENE, "r");
		if (fd == 0) begin
			errors = errors + 1;
			$display("FAIL %0s(%0s): no %0s", TB, NAME, SCENE);
		end else begin
			rc = $fscanf(fd, "%s %d\n", kind, nr);
			/* Initial memory and the ring's words, up to the first E or C line. */
			while (!$feof(fd) && kind != "E" && kind != "C") begin
				rc = $fscanf(fd, "%s", kind);
				if (kind == "I") begin
					rc = $fscanf(fd, " %h %h\n", a, v);
					mem.poke32(a, v);
				end else if (kind == "R") begin
					rc = $fscanf(fd, " %h\n", v);
					mem.poke32(RING + wp * 4, v);
					wp = wp + 1;
				end else if (kind == "F") begin
					rc = $fscanf(fd, " %h %h %h %h %h\n", f0, f1, f2, f3, f4);
					fmt_w[5 * nfmt] = f0;
					fmt_w[5 * nfmt + 1] = f1;
					fmt_w[5 * nfmt + 2] = f2;
					fmt_w[5 * nfmt + 3] = f3;
					fmt_w[5 * nfmt + 4] = f4;
					nfmt = nfmt + 1;
				end
			end
			if (nfmt != 0)
				check_fmt;
			host_write(GHCI_RING_BASE, RING);
			host_write(GHCI_RING_SIZE, RING_LOG2);	/* 11: 512 words */
			host_write(GHCI_FENCE_LAST, 32'd0);
			host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);
			host_write(GHCI_RING_WPTR, wp);
			wait_reg(GHCI_FENCE_LAST, 32'd1, 32'hFFFFFFFF);
			expect_status;
			/* The first E or C line's kind was read already. */
			rc = 1;
			while (rc == 1) begin
				if (kind == "E") begin
					rc = $fscanf(fd, " %h %h\n", a, v);
					if (rc == 2)
						check(a, v);
				end else if (kind == "C") begin
					end_case;
					rc = $fscanf(fd, " %s\n", cname);
					ncase = ncase + 1;
				end
				rc = $feof(fd) ? 0 : $fscanf(fd, "%s", kind);
			end
			end_case;
			$fclose(fd);
		end
		if (bad != 0) begin
			errors = errors + 1;
			if (ncase != 0)
				$display("FAIL %0s(%0s): %0d words differ from the model", TB, NAME, bad);
			else
				$display("FAIL %0s(%0s): %0d words differ from the model (colour %0d, depth %0d)",
					TB, NAME, bad, bad_rt, bad_ds);
		end else
			$display("PASS %0s(%0s).scene: %0d ring words", TB, NAME, wp);
		finished = 1'b1;
	end


	/* Assert: DRAW_RAW kicks the clip only after all nine payload words have
	 * reached it (the CP registers the STATE broadcast; without that the
	 * kick came a cycle early, the third vertex's z still unwritten). */
	integer k9;
	always @(posedge clk)
		if (dut.g_rx.rx.clip.raw_kick)
			for (k9 = 0; k9 < 9; k9 = k9 + 1)
				if (^dut.g_rx.rx.clip.rw[k9] === 1'bx) begin
					errors = errors + 1;
					$display("FAIL %0s(%0s): DRAW_RAW kicked with word %0d unwritten", TB, NAME, k9);
				end

	/* The end of a case (C line): its words against the model. */
	task end_case;
		begin
			if (ncase != 0) begin
				if (cbad != 0)
					$display("FAIL %0s(%0s).%0s: %0d words differ from the model", TB, NAME,
						cname, cbad);
				else
					$display("PASS %0s(%0s).%0s", TB, NAME, cname);
			end
			cbad = 0;
		end
	endtask

	task check;
		input [31:0] addr;
		input [31:0] want;
		begin
			got = mem.peek32(addr);
			if (got !== want) begin
				if (cbad < 4 || bad < 8)
					$display("FAIL %0s(%0s): mem %h = %h, model %h", TB, NAME, addr, got, want);
				bad = bad + 1;
				cbad = cbad + 1;
				if (addr < 32'h00030000)
					bad_rt = bad_rt + 1;
				else
					bad_ds = bad_ds + 1;
			end
		end
	endtask

	/* The FMT capability (from the extended capability list) against the F lines. */
	task check_fmt;
		integer n;
		begin
			fmt_regs = 0;
			host_read(GHCI_EXTCAP, xoff);
			for (n = 0; n < 16 && xoff != 0; n = n + 1) begin
				host_read(xoff, xw);
				if (xw[7:0] == GHCI_XCAP_FMT)
					host_read(xoff + 4, fmt_regs);
				xoff = xw[31:16] == 16'd0 ? 32'd0 : xoff + {14'd0, xw[31:16], 2'd0};
			end
			if (fmt_regs == 0) begin
				errors = errors + 1;
				$display("FAIL %0s(%0s): no FMT capability", TB, NAME);
			end else begin
				for (n = 0; n < nfmt; n = n + 1) begin
					host_write(fmt_regs + GHCI_FMT_INDEX, fmt_w[5 * n]);
					for (fk = 1; fk < 5; fk = fk + 1) begin
						host_read(fmt_regs + 4 * (fk - 1) + GHCI_FMT_OPTIMAL, xw);
						if (xw !== fmt_w[5 * n + fk]) begin
							if (fmt_bad < 8)
								$display("FAIL %0s(%0s): FMT %0d word %0d = %h, model %h", TB,
									NAME, fmt_w[5 * n], fk, xw, fmt_w[5 * n + fk]);
							fmt_bad = fmt_bad + 1;
						end
					end
				end
				if (fmt_bad != 0)
					errors = errors + 1;
				else
					$display("PASS %0s(%0s).fmt: %0d formats", TB, NAME, nfmt);
			end
		end
	endtask

	task expect_status;
		reg [31:0] st;
		begin
			host_read(GHCI_STATUS, st);
			if ((st >> GHCI_STATUS_STATE & 32'hF) != 32'd1) begin
				errors = errors + 1;
				$display("FAIL %0s(%0s): STATUS %h, not RUNNING (a fault?)", TB, NAME, st);
			end
		end
	endtask
endmodule

