/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_fw_tb: atg_cpu_fw with a DMA model (ld_done some cycles after
 * ld_start, error on request) and a core model (stopped, fault).  regs:
 * reset values, host read/write with WSTRB masks, the window side
 * (FW_STATUS and ALIVE, MBOX shared both ways, FW_VERSION), what survives
 * RESET.  load: LOAD only when open and the core stopped, two loads in
 * order with the core held in reset, then READY; a load error gives FAULT
 * with READY 0.  fault: a core fault sets FAULT, pulses fault with the PC
 * and holds the core in reset until RESET; HALT parks the core.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_fw_tb;
`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg hcr_we = 1'b0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 0;
	wire [31:0] hcr_rdata;
	reg sb_we = 1'b0, sb_re = 1'b0;
	reg [5:0] sb_idx = 0;
	reg [31:0] sb_wdata = 0;
	wire [31:0] sb_rdata;
	wire ld_start, ld_imem;
	wire [31:0] ld_addr, ld_words;
	reg ld_done = 1'b0, ld_error = 1'b0;
	wire core_rst_n, core_run;
	reg core_stopped = 1'b1, core_fault = 1'b0;
	reg [31:0] core_fault_pc = 0;
	reg halt_req = 1'b0, open = 1'b1;
	wire fault;
	wire [31:0] fault_addr;

	integer errors = 0;
	integer e0, i;
	integer starts = 0;
	integer faults = 0;
	integer reset_low_bad = 0;
	integer seed = 1;
	reg fail_next = 1'b0;
	reg [31:0] r;
	reg [31:0] la [0:3], lw [0:3];
	reg li [0:3];

	always #5 clk = !clk;

	atg_cpu_fw dut (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata), .sb_rdata(sb_rdata),
		.ld_start(ld_start), .ld_imem(ld_imem), .ld_addr(ld_addr), .ld_words(ld_words),
		.ld_done(ld_done), .ld_error(ld_error),
		.core_rst_n(core_rst_n), .core_run(core_run), .core_stopped(core_stopped),
		.core_fault(core_fault), .core_fault_pc(core_fault_pc),
		.halt_req(halt_req), .open(open), .fault(fault), .fault_addr(fault_addr)
	);

	/* DMA model: records each load, answers 7 cycles later; the core must
	 * be in reset from the start to the answer. */
	integer ld_cnt = 0;

	always @(posedge clk) begin
		ld_done <= 1'b0;
		ld_error <= 1'b0;
		if (ld_start) begin
			la[starts % 4] = ld_addr;
			lw[starts % 4] = ld_words;
			li[starts % 4] = ld_imem;
			starts = starts + 1;
			ld_cnt = 8;
		end else if (ld_cnt > 0) begin
			if (core_rst_n)
				reset_low_bad = reset_low_bad + 1;
			ld_cnt = ld_cnt - 1;
			if (ld_cnt == 0) begin
				ld_done <= 1'b1;
				ld_error <= fail_next;
			end
		end
		if (fault)
			faults = faults + 1;
	end

	task hw;
		input [16:0] off;
		input [31:0] data;
		input [31:0] mask;
		begin
			@(negedge clk);
			hcr_we = 1'b1;
			hcr_widx = off[11:2];
			hcr_wdata = data;
			hcr_wmask = mask;
			@(negedge clk);
			hcr_we = 1'b0;
		end
	endtask

	task hr;
		input [16:0] off;
		begin
			@(negedge clk);
			hcr_ridx = off[11:2];
			#1;
			r = hcr_rdata;
		end
	endtask

	task sw;
		input [5:0] idx;
		input [31:0] data;
		begin
			@(negedge clk);
			sb_we = 1'b1;
			sb_idx = idx;
			sb_wdata = data;
			@(negedge clk);
			sb_we = 1'b0;
		end
	endtask

	task sr;
		input [5:0] idx;
		begin
			@(negedge clk);
			sb_re = 1'b1;
			sb_idx = idx;
			#1;
			r = sb_rdata;
			@(negedge clk);
			sb_re = 1'b0;
		end
	endtask

	task expect;
		input [8*24-1:0] what;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				$display("FAIL %0s: %h want %h", what, got, want);
				errors = errors + 1;
			end
		end
	endtask

	task do_reset;
		begin
			@(negedge clk);
			rst_n = 1'b0;
			repeat (2) @(negedge clk);
			rst_n = 1'b1;
		end
	endtask

	task wait_load;
		begin
			i = 0;
			hr(GHCI_CPFW_STATUS);
			while (r[4] && i < 100) begin
				hr(GHCI_CPFW_STATUS);
				i = i + 1;
			end
		end
	endtask

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;

		/* regs */
		e0 = errors;
		hr(GHCI_CPFW_STATUS);
		expect("STATUS reset", r, 32'h0000_0009);	/* READY, STOPPED */
		hr(GHCI_CPFW_CTRL);
		expect("CTRL reset", r, 0);
		expect("core_rst_n", core_rst_n, 1);
		expect("core_run", core_run, 0);
		hw(GHCI_CPFW_IBASE, 32'h0040_0000, 32'hFFFF_FFFF);
		hw(GHCI_CPFW_IWORDS, 32'd1000, 32'hFFFF_FFFF);
		hw(GHCI_CPFW_DBASE, 32'h0050_0000, 32'hFFFF_FFFF);
		hw(GHCI_CPFW_DWORDS, 32'hFFFF_1234, 32'h0000_FFFF);	/* WSTRB: low half */
		hr(GHCI_CPFW_DWORDS);
		expect("DWORDS masked", r, 32'h0000_1234);
		hw(GHCI_CPFW_MBOX0 + 8, 32'hCAFE_0002, 32'hFFFF_FFFF);
		sr(6'h23);
		expect("MBOX2 fw side", r, 32'hCAFE_0002);
		sw(6'h24, 32'hBEEF_0003);
		hr(GHCI_CPFW_MBOX0 + 12);
		expect("MBOX3 host side", r, 32'hBEEF_0003);
		sw(6'h25, 32'h0001_0007);
		hr(GHCI_CPFW_VERSION);
		expect("VERSION", r, 32'h0001_0007);
		sw(6'h20, 32'h0000_4200);
		hr(GHCI_CPFW_STATUS);
		expect("STATUS state+alive", r, 32'h0000_420D);
		sw(6'h20, 32'h0000_4300);
		hr(GHCI_CPFW_STATUS);
		expect("ALIVE toggles", r, 32'h0000_4309);
		hr(17'h0013C);
		expect("reserved", r, 0);
		hw(GHCI_CPFW_CTRL, 32'h2, 32'hFFFF_FFFF);
		expect("RUN", core_run, 1);
		hr(17'h0011C);
		expect("not ours", r, 0);
		/* RESET: the kept registers stay, the others clear. */
		do_reset;
		hr(GHCI_CPFW_IBASE);
		expect("IBASE kept", r, 32'h0040_0000);
		hr(GHCI_CPFW_DWORDS);
		expect("DWORDS kept", r, 32'h0000_1234);
		hr(GHCI_CPFW_MBOX0 + 8);
		expect("MBOX cleared", r, 0);
		hr(GHCI_CPFW_STATUS);
		expect("STATUS after RESET", r, 32'h0000_0009);
		expect("RUN cleared", core_run, 0);
		if (errors == e0)
			$display("PASS atg_cpu_fw.regs");

		/* load */
		e0 = errors;
		/* Not open, or core running: LOAD is ignored. */
		open = 1'b0;
		hw(GHCI_CPFW_CTRL, 32'h1, 32'hFFFF_FFFF);
		open = 1'b1;
		core_stopped = 1'b0;
		hw(GHCI_CPFW_CTRL, 32'h1, 32'hFFFF_FFFF);
		repeat (3) @(negedge clk);
		expect("ignored loads", starts, 0);
		core_stopped = 1'b1;
		hw(GHCI_CPFW_CTRL, 32'h1, 32'hFFFF_FFFF);
		hr(GHCI_CPFW_STATUS);
		expect("READY 0 while loading", r[0], 0);
		expect("LOADING", r[4], 1);
		expect("held in reset", core_rst_n, 0);
		wait_load;
		expect("two loads", starts, 2);
		expect("load 1 IMEM", li[0], 1);
		expect("load 1 addr", la[0], 32'h0040_0000);
		expect("load 1 words", lw[0], 1000);
		expect("load 2 DMEM", li[1], 0);
		expect("load 2 addr", la[1], 32'h0050_0000);
		expect("load 2 words", lw[1], 32'h1234);
		expect("READY", r[1:0], 2'b01);
		expect("released", core_rst_n, 1);
		expect("core in reset all along", reset_low_bad, 0);
		/* An error in the DMEM load: FAULT, READY 0, core held. */
		fail_next = 1'b1;
		hw(GHCI_CPFW_CTRL, 32'h1, 32'hFFFF_FFFF);
		wait_load;
		fail_next = 1'b0;
		expect("error loads", starts, 3);
		expect("error status", r[1:0], 2'b10);
		expect("error held", core_rst_n, 0);
		/* RESET keeps READY 0; a good LOAD fixes it. */
		do_reset;
		hr(GHCI_CPFW_STATUS);
		expect("READY kept 0", r[1:0], 2'b00);
		hw(GHCI_CPFW_CTRL, 32'h1, 32'hFFFF_FFFF);
		wait_load;
		expect("reload", r[1:0], 2'b01);
		expect("reload starts", starts, 5);
		if (errors == e0)
			$display("PASS atg_cpu_fw.load");

		/* fault */
		e0 = errors;
		hw(GHCI_CPFW_CTRL, 32'h2, 32'hFFFF_FFFF);
		@(negedge clk);
		core_fault = 1'b1;
		core_fault_pc = 32'h0000_1234;
		@(negedge clk);
		core_fault = 1'b0;
		repeat (2) @(negedge clk);
		expect("fault pulse", faults, 1);
		expect("fault_addr", fault_addr, 32'h0000_1234);
		hr(GHCI_CPFW_STATUS);
		expect("FAULT", r[1], 1);
		expect("fault held", core_rst_n, 0);
		repeat (5) @(negedge clk);
		expect("one pulse", faults, 1);
		do_reset;
		expect("RESET releases", core_rst_n, 1);
		hr(GHCI_CPFW_STATUS);
		expect("FAULT cleared", r[1], 0);
		/* HALT: the core runs until the firmware parks. */
		hw(GHCI_CPFW_CTRL, 32'h2, 32'hFFFF_FFFF);
		halt_req = 1'b1;
		repeat (3) @(negedge clk);
		expect("runs until parked", core_run, 1);
		sw(6'h20, 32'h0001_0100);
		expect("parked", core_run, 0);
		halt_req = 1'b0;
		@(negedge clk);
		@(negedge clk);
		expect("unparked", core_run, 1);
		hw(GHCI_CPFW_CTRL, 32'h6, 32'hFFFF_FFFF);	/* CPFW HALT */
		sw(6'h20, 32'h0001_0100);
		expect("CPFW HALT parks", core_run, 0);
		hw(GHCI_CPFW_CTRL, 32'h2, 32'hFFFF_FFFF);
		@(negedge clk);
		expect("CPFW HALT off", core_run, 1);
		if (errors == e0)
			$display("PASS atg_cpu_fw.fault");
		if (errors == 0)
			$display("PASS atg_cpu_fw");
		$finish;
	end
endmodule

`default_nettype wire
