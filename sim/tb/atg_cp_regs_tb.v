/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_regs_tb: the register decoder with its parameters set to
 * recognisable values: the identification and capability words, the
 * extended capability list walked from EXTCAP for three XCAP_MASK values,
 * the snoop and alias outputs of a write, the OR of the modules' read
 * data, COUNTER and the PERF counters; with atg_cp_fmt beside it (a fourth
 * bench, FMT in the list), the FMT capability's words for every VkFormat
 * value against sim/vec/fmt_info.txt (and DISP2, id 11, pointing to 0x200).
 */

`timescale 1ns / 1ps
`default_nettype none

module regs_bench #(
	parameter [10:0] XCAP = 11'h004,
	parameter [31:0] TAG = 32'd0,
	parameter FMT = 0	/* atg_cp_fmt beside it */
) (
	input wire clk,
	input wire rst_n,
	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output wire [31:0] reg_rdata,
	output wire hcr_we,
	output wire [9:0] hcr_widx,
	output wire [31:0] hcr_wdata,
	output wire [31:0] hcr_wmask,
	output wire [9:0] hcr_ridx,
	output wire alias_we,
	output wire [9:0] alias_idx,
	output wire [9:0] alias_ridx,
	input wire [31:0] ctl_rdata,
	input wire [31:0] state_rdata,
	input wire [3:0] perf_busy,
	input wire perf_reset,
	output wire win_en
);
	wire [31:0] fmt_rdata;
	generate
	if (FMT != 0) begin : g_fmt
		atg_cp_fmt fmt (.clk(clk), .rst_n(rst_n), .hcr_we(hcr_we), .hcr_widx(hcr_widx),
			.hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask), .hcr_ridx(hcr_ridx),
			.hcr_rdata(fmt_rdata));
	end else begin : g_no_fmt
		assign fmt_rdata = 32'd0;
	end
	endgenerate
	atg_cp_regs #(
		.GCLK_HZ(32'd12345678), .VENDOR_ID(32'h56454E44), .DEVICE_ID(32'h44455631),
		.DEVICE_VERSION(32'h00070009), .ISA_ID(32'h49534131), .NATIVE_ISA_ID(32'h4E415431),
		.CAPS(32'hCA950000 | TAG), .CAPS2(32'h0C0C0002),
		.VEND({32'h77, 32'h66, 32'h55, 32'h44, 32'h33, 32'h22, 32'h11, 32'h00}),
		.XCAP_MASK(XCAP), .DISP_OFFSET(32'h00010000), .PERF_SRC(32'hFFFF0801),
		.RESIDENT_WARPS(16'd24), .NREGS(8'd64), .LOCAL_BASE(32'h80000000),
		.LOCAL_BYTES(32'h40000000), .WINDOW_BYTES(32'h04000000), .HOST_LIMIT(32'h80000000)
	) dut (
		.clk(clk), .rst_n(rst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .alias_we(alias_we), .alias_idx(alias_idx),
		.alias_ridx(alias_ridx),
		.ctl_rdata(ctl_rdata), .irq_rdata(32'd0), .ring_rdata(32'd0), .fence_rdata(32'd0),
		.dbg_rdata(32'd0), .state_rdata(state_rdata), .x_rdata(fmt_rdata),
		.perf_busy(perf_busy), .perf_reset(perf_reset), .win_en(win_en)
	);
endmodule

module atg_cp_regs_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg reg_wr = 0, reg_rd = 0, perf_reset = 0;
	reg [16:0] reg_waddr = 0, reg_raddr = 0;
	reg [31:0] reg_wdata = 0;
	reg [3:0] reg_wstrb = 0;
	reg [3:0] perf_busy = 0;
	reg [31:0] ctl_rdata = 0, state_rdata = 0;
	wire [31:0] rd0, rd1, rd2, rd3, hcr_wdata, hcr_wmask;
	wire hcr_we, alias_we;
	wire [9:0] hcr_widx, hcr_ridx;
	wire [9:0] alias_idx, alias_ridx;
	wire win0, win2;

	/* PERF only; PERF, VEND, CPFW; every capability (more than two entries, MEM among them). */
	regs_bench #(.XCAP(8'h04)) b0 (
		.clk(clk), .rst_n(rst_n), .reg_wr(reg_wr), .reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb), .reg_rd(reg_rd), .reg_raddr(reg_raddr),
		.reg_rdata(rd0), .hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata),
		.hcr_wmask(hcr_wmask), .hcr_ridx(hcr_ridx), .alias_we(alias_we),
		.alias_idx(alias_idx), .alias_ridx(alias_ridx), .ctl_rdata(ctl_rdata),
		.state_rdata(state_rdata), .perf_busy(perf_busy), .perf_reset(perf_reset),
		.win_en(win0)
	);
	regs_bench #(.XCAP(8'h2C)) b1 (
		.clk(clk), .rst_n(rst_n), .reg_wr(reg_wr), .reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb), .reg_rd(reg_rd), .reg_raddr(reg_raddr),
		.reg_rdata(rd1), .hcr_we(), .hcr_widx(), .hcr_wdata(), .hcr_wmask(), .hcr_ridx(),
		.alias_we(), .alias_idx(), .alias_ridx(), .ctl_rdata(32'd0), .state_rdata(32'd0),
		.perf_busy(4'd0), .perf_reset(1'b0)
	);
	regs_bench #(.XCAP(10'h0EF)) b2 (
		.clk(clk), .rst_n(rst_n), .reg_wr(reg_wr), .reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb), .reg_rd(reg_rd), .reg_raddr(reg_raddr),
		.reg_rdata(rd2), .hcr_we(), .hcr_widx(), .hcr_wdata(), .hcr_wmask(), .hcr_ridx(),
		.alias_we(), .alias_idx(), .alias_ridx(), .ctl_rdata(32'd0), .state_rdata(32'd0),
		.perf_busy(4'd0), .perf_reset(1'b0), .win_en(win2)
	);
	regs_bench #(.XCAP(11'h604), .FMT(1)) b3 (
		.clk(clk), .rst_n(rst_n), .reg_wr(reg_wr), .reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb), .reg_rd(reg_rd), .reg_raddr(reg_raddr),
		.reg_rdata(rd3), .hcr_we(), .hcr_widx(), .hcr_wdata(), .hcr_wmask(), .hcr_ridx(),
		.alias_we(), .alias_idx(), .alias_ridx(), .ctl_rdata(32'd0), .state_rdata(32'd0),
		.perf_busy(4'd0), .perf_reset(1'b0)
	);

	integer errors = 0;
	integer e0;
	reg [31:0] v0, v1, v2, v3, c0;
	integer fd, code, fi;
	reg [67:0] finfo;
	reg [15:0] xo, xb, xo0, xb0;
	reg [7:0] fv;

	task rd;
		input [16:0] a;
		begin
			@(negedge clk);
			reg_rd = 1;
			reg_raddr = a;
			@(negedge clk);
			reg_rd = 0;
			reg_raddr = 17'h1FFFC;	/* the answer must not follow the address */
			#1;
			v0 = rd0;
			v1 = rd1;
			v2 = rd2;
			v3 = rd3;
		end
	endtask

	task expect0;
		input [8*30-1:0] what;
		input [16:0] a;
		input [31:0] want;
		begin
			rd(a);
			if (v0 !== want) begin
				errors = errors + 1;
				$display("FAIL atg_cp_regs.%0s: [%h] = %h, expected %h", what, a, v0, want);
			end
		end
	endtask

	/* Walk the capability list of bench k: ids and pointers, in order. */
	task walk;
		input integer k;
		input [63:0] ids;	/* expected ids, low byte first, 0 ends */
		input [255:0] ptrs;
		reg [31:0] off, w0, w1;
		integer n;
		begin
			rd(GHCI_EXTCAP);
			off = k == 0 ? v0 : k == 1 ? v1 : k == 2 ? v2 : v3;
			n = 0;
			while (off != 0 && n < 8) begin
				rd(off[16:0]);
				w0 = k == 0 ? v0 : k == 1 ? v1 : k == 2 ? v2 : v3;
				rd(off[16:0] + 17'd4);
				w1 = k == 0 ? v0 : k == 1 ? v1 : k == 2 ? v2 : v3;
				if (w0[7:0] !== ids[n * 8 +: 8] || w0[15:8] !== 8'd1 ||
				    w1 !== ptrs[n * 32 +: 32]) begin
					errors = errors + 1;
					$display("FAIL atg_cp_regs.extcap: bench %0d entry %0d at %h: %h %h", k, n,
						off, w0, w1);
				end
				off = w0[31:16] == 0 ? 0 : off + {w0[31:16], 2'b00};
				n = n + 1;
			end
			if (ids[n * 8 +: 8] !== 8'd0) begin
				errors = errors + 1;
				$display("FAIL atg_cp_regs.extcap: bench %0d list ends after %0d", k, n);
			end
		end
	endtask

	task wr;
		input [16:0] a;
		input [31:0] d;
		input [3:0] s;
		begin
			@(negedge clk);
			reg_wr = 1;
			reg_waddr = a;
			reg_wdata = d;
			reg_wstrb = s;
			#1;
		end
	endtask

	integer i;
	initial begin
		repeat (3) @(posedge clk);
		@(negedge clk);
		rst_n = 1;
		/* id */
		expect0("id", GHCI_MAGIC, GHCI_MAGIC_VALUE);
		expect0("id", GHCI_VERSION, 32'h00010000);
		expect0("id", GHCI_VENDOR_ID, 32'h56454E44);
		expect0("id", GHCI_DEVICE_ID, 32'h44455631);
		expect0("id", GHCI_ISA_ID, 32'h49534131);
		expect0("id", GHCI_DEVICE_VERSION, 32'h00070009);
		expect0("id", GHCI_GCLK_HZ, 32'd12345678);
		expect0("id", GHCI_CAPS, 32'hCA950000);
		expect0("id", GHCI_CAPS2, 32'h0C0C0002);
		expect0("id", 17'h048, 32'h4E415431);
		expect0("id", GHCI_RESIDENT_WARPS, 32'h00400018);
		for (i = 0; i < 8; i = i + 1)
			expect0("id", 17'h0C0 + i * 4, 32'h11 * i);
		expect0("id", 17'h0E0, 32'd0);
		expect0("id", 17'h01C00, 32'd0);
		expect0("id", 17'h10000, 32'd0);
		if (errors == 0)
			$display("PASS atg_cp_regs.id");
		e0 = errors;
		/* extcap */
		walk(0, 64'h03, 256'h110);
		walk(1, 64'h060403, {32'h120, 32'h0C0, 32'h110});
		walk(2, 64'h08_07_06_04_03_02_01, {32'h1E0, 32'h140, 32'h120, 32'h0C0, 32'h110, 32'h0,
			32'h10000});
		/* MEM's words where it is listed; 0 where it is not. */
		rd(17'h001E0);
		if (v2 !== 32'h80000000 || v0 !== 32'd0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.extcap: LOCAL_BASE %h, without MEM %h", v2, v0);
		end
		rd(17'h001E4);
		if (v2 !== 32'h40000000 || v0 !== 32'd0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.extcap: LOCAL_SIZE %h, without MEM %h", v2, v0);
		end
		rd(17'h001E8);
		if (v2 !== 32'h04000000 || v0 !== 32'd0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.extcap: WINDOW_SIZE %h, without MEM %h", v2, v0);
		end
		rd(17'h001EC);
		if (v2 !== 32'h80000000 || v0 !== 32'd0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.extcap: HOST_LIMIT %h, without MEM %h", v2, v0);
		end
		rd(17'h001C0);
		if (v2 !== 32'd0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.extcap: %h at MEM's old offset 0x1C0", v2);
		end
		rd(GHCI_PERF_SRC0);
		if (v0 !== 32'd1 || v2 !== 32'd1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.extcap: PERF_SRC0 %h", v0);
		end
		expect0("extcap", GHCI_PERF_SRC0 + 17'd4, 32'd8);
		expect0("extcap", GHCI_PERF_SRC0 + 17'd8, 32'hFF);
		if (errors == e0)
			$display("PASS atg_cp_regs.extcap");
		e0 = errors;
		/* snoop */
		wr(17'h00F00, 32'hA5A5A5A5, 4'b0101);
		if (!hcr_we || hcr_widx !== 10'h3C0 || hcr_wdata !== 32'hA5A5A5A5 ||
		    hcr_wmask !== 32'h00FF00FF || alias_we) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.snoop: HCR write");
		end
		wr(17'h01004, 32'h1, 4'b0111);
		if (hcr_we || alias_we) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.snoop: partial alias write");
		end
		wr(17'h017FC, 32'h1, 4'b1111);
		if (hcr_we || !alias_we || alias_idx !== 10'h1FF) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.snoop: alias write");
		end
		wr(17'h01BFC, 32'h1, 4'b1111);
		if (hcr_we || !alias_we || alias_idx !== 10'h2FF) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.snoop: alias write of the vertex stage's slots");
		end
		wr(17'h01C00, 32'h1, 4'b1111);
		if (hcr_we || alias_we) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.snoop: a write above STATE");
		end
		wr(17'h10000, 32'h1, 4'b1111);
		if (hcr_we || alias_we) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.snoop: a write above the CP");
		end
		wr(GHCI_SCRATCH, 32'h12345678, 4'b1111);
		wr(GHCI_SCRATCH, 32'hAABBCCDD, 4'b0010);
		@(negedge clk);
		reg_wr = 0;
		expect0("snoop", GHCI_SCRATCH, 32'h1234CC78);
		if (errors == e0)
			$display("PASS atg_cp_regs.snoop");
		e0 = errors;
		/* window: WINDOW_CTRL.ENABLE (MEM +0x10), 1 after the reset; 0 without MEM. */
		rd(17'h001F0);
		if (v2 !== 32'd1 || !win2 || v0 !== 32'd0 || win0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.window: after reset %h/%b, without MEM %h/%b", v2, win2, v0, win0);
		end
		wr(17'h001F0, 32'h0, 4'b1111);
		@(negedge clk);
		reg_wr = 0;
		rd(17'h001F0);
		if (v2 !== 32'd0 || win2 || v0 !== 32'd0 || win0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.window: closed %h/%b, without MEM %h/%b", v2, win2, v0, win0);
		end
		wr(17'h001F0, 32'h1, 4'b1110);	/* bit 0's byte not written */
		@(negedge clk);
		reg_wr = 0;
		rd(17'h001F0);
		if (v2 !== 32'd0 || win2) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.window: a write without byte 0 opened it");
		end
		wr(17'h001F0, 32'hFFFFFFFF, 4'b1111);
		@(negedge clk);
		reg_wr = 0;
		rd(17'h001F0);
		if (v2 !== 32'd1 || !win2 || v0 !== 32'd0 || win0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.window: reopened %h/%b, without MEM %h/%b", v2, win2, v0, win0);
		end
		wr(17'h001F0, 32'h0, 4'b1111);
		@(negedge clk);
		reg_wr = 0;
		rst_n = 0;
		@(negedge clk);
		rst_n = 1;
		rd(17'h001F0);
		if (v2 !== 32'd1 || !win2) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.window: not open again after the reset");
		end
		wr(GHCI_SCRATCH, 32'h1234CC78, 4'b1111);	/* the reset cleared it; ormux reads it */
		@(negedge clk);
		reg_wr = 0;
		if (errors == e0)
			$display("PASS atg_cp_regs.window");
		e0 = errors;
		/* ormux: a module's data at its registered index, the alias. */
		ctl_rdata = 32'h00F00000;
		expect0("ormux", GHCI_SCRATCH, 32'h12F4CC78);
		ctl_rdata = 0;
		state_rdata = 32'h5555AAAA;
		expect0("ormux", 17'h01234, 32'h5555AAAA);
		state_rdata = 0;
		@(negedge clk);
		reg_rd = 1;
		reg_raddr = 17'h00034;
		@(negedge clk);
		reg_rd = 0;
		if (hcr_ridx !== 10'h00D) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.ormux: hcr_ridx %h", hcr_ridx);
		end
		rd(GHCI_COUNTER);
		c0 = v0;
		repeat (10) @(negedge clk);
		rd(GHCI_COUNTER);
		if (v0 - c0 != 12) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.ormux: COUNTER advanced %0d", v0 - c0);
		end
		wr(GHCI_PERF_CTRL, 32'd1, 4'b0001);
		@(negedge clk);
		reg_wr = 0;
		perf_busy = 4'b0101;
		repeat (20) @(negedge clk);
		perf_busy = 0;
		expect0("ormux", GHCI_PERF0, 32'd20);
		expect0("ormux", GHCI_PERF0 + 17'd4, 32'd0);
		expect0("ormux", GHCI_PERF0 + 17'd8, 32'd20);
		@(negedge clk);
		perf_reset = 1;
		@(negedge clk);
		perf_reset = 0;
		expect0("ormux", GHCI_PERF0, 32'd0);
		if (errors == e0)
			$display("PASS atg_cp_regs.ormux");
		e0 = errors;
		/* fmt: the list entry, FMT_INDEX, the features of every value, LIMITS */
		walk(3, 64'h0B0A03, {32'h200, 32'h160, 32'h110});
		fd = $fopen("sim/vec/fmt_info.txt", "r");
		if (fd == 0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.fmt: no sim/vec/fmt_info.txt");
		end
		for (fi = 0; fi < 256; fi = fi + 1) begin
			code = $fscanf(fd, "%h %h %h %h %h %h\n", fv, finfo, xo, xb, xo0, xb0);
			wr(17'h00160, {24'hFFFFFF, fv}, 4'b1111);
			@(negedge clk);
			reg_wr = 0;
			rd(17'h00160);
			if (v3 !== {24'd0, fv}) begin
				errors = errors + 1;
				$display("FAIL atg_cp_regs.fmt: FMT_INDEX %h, wrote %h", v3, fv);
			end
			rd(17'h00164);
			if (v3 !== {16'd0, xo0} || v0 !== 32'd0) begin
				errors = errors + 1;
				$display("FAIL atg_cp_regs.fmt: format %0d OPTIMAL %h, want %h", fv, v3, xo0);
			end
			rd(17'h00168);
			if (v3 !== {16'd0, xo0}) begin
				errors = errors + 1;
				$display("FAIL atg_cp_regs.fmt: format %0d LINEAR %h, want %h", fv, v3, xo0);
			end
			rd(17'h0016C);
			if (v3 !== {16'd0, xb0}) begin
				errors = errors + 1;
				$display("FAIL atg_cp_regs.fmt: format %0d BUFFER %h, want %h", fv, v3, xb0);
			end
		end
		$fclose(fd);
		/* a partial write changes the written byte only */
		wr(17'h00160, 32'h00000025, 4'b0001);
		wr(17'h00160, 32'h00000011, 4'b0010);
		@(negedge clk);
		reg_wr = 0;
		expect0("fmt", 17'h00160, 32'h0);	/* bench 0 has no FMT */
		rd(17'h00160);
		if (v3 !== 32'h25) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.fmt: FMT_INDEX %h after a partial write", v3);
		end
		rd(17'h00170);
		if (v3 !== 32'd4) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.fmt: FMT_LIMITS %h", v3);
		end
		rd(17'h00174);
		if (v3 !== 32'd0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_regs.fmt: +0x14 reads %h", v3);
		end
		if (errors == e0)
			$display("PASS atg_cp_regs.fmt");
		if (errors == 0)
			$display("PASS atg_cp_regs");
		else
			$display("FAIL atg_cp_regs: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
