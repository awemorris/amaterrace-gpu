/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ctl_tb: the CP state machine with its inputs driven by the
 * testbench: every transition of design §2.6, the RESET order (waits for
 * mc_idle, one core reset pulse with mc_flush, the replay, the bit
 * falls), AXI_STUCK, the first fault wins with its FAULT_INFO fields
 * (MC client 0 ignored), the watchdog (its job tag from wdt_tag), locked
 * writes and KICK (refused while kick_prot_ok is 0: the units are a
 * protected session's).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_ctl_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg hcr_we = 0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 0;
	wire [31:0] hcr_rdata;
	reg mc_idle = 1, ring_busy = 0, cmd_active = 0, wdt_hold = 0, replay_busy = 0;
	reg [3:0] seq_st = 0;
	reg f_busy = 0;
	reg [7:0] busy_in = 0;
	reg mc_fault = 0, mc_fault_write = 0;
	reg [7:0] mc_fault_client = 0;
	reg [7:0] mc_fault_req_tag = 0;
	reg [31:0] mc_fault_addr = 0;
	reg [7:0] src_fault = 0;
	reg [31:0] src_kind = 0;
	reg [255:0] src_addr = 0;
	reg [63:0] src_tag = 0;
	reg [31:0] src_stage = 0;
	reg [7:0] wdt_tag = 0;
	wire run, halt, quiesce, mc_flush, core_rst_n, open, step, ev_halted, ev_fault, ev_wdt;
	wire ctrl_irq_global;
	wire [3:0] cp_state;
	wire [2:0] lc_state;
	wire [2:0] host_kick;
	wire [31:0] ap_base, ap_limit;

	atg_cp_ctl #(.UNITS(8'h03), .DC_CLIENT(8'd5)) dut (
		.clk(clk), .rst_n(rst_n),
		.mc_fault_prot(1'b0), .mc_fault_mem(1'b0), .mc_fault_tag(8'd0),
		.mc_fault_req_tag(mc_fault_req_tag),
		.wdt_tag(wdt_tag),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.mc_idle(mc_idle), .mem_ready(1'b1), .busy_in(busy_in), .ring_empty(1'b1),
		.ring_busy(ring_busy), .cmd_active(cmd_active), .wdt_hold(wdt_hold), .replay_busy(replay_busy),
		.seq_st(seq_st), .f_busy(f_busy),
		.mc_fault(mc_fault), .mc_fault_client(mc_fault_client), .mc_fault_addr(mc_fault_addr),
		.mc_fault_write(mc_fault_write),
		.src_fault(src_fault), .src_kind(src_kind), .src_addr(src_addr), .src_tag(src_tag),
		.src_stage(src_stage),
		.run(run), .halt(halt), .ctrl_irq_global(ctrl_irq_global), .quiesce(quiesce), .mc_flush(mc_flush),
		.core_rst_n(core_rst_n), .open(open), .cp_state(cp_state), .lc_state(lc_state), .host_kick(host_kick),
		.step(step), .ev_halted(ev_halted), .ev_fault(ev_fault), .ev_wdt(ev_wdt),
		.aperture_base(ap_base), .aperture_limit(ap_limit)
	);

	/* Verification of HAS_CPU=0 configuration where C_CPU == C_VF == 2 */
	wire [31:0] nocpu_rdata;
	reg nocpu_mc_fault = 0;
	atg_cp_ctl #(
		.C_CPU(2),
		.C_VF(2),
		.C_TU(3),
		.C_ROP(4),
		.C_ATOM(5),
		.C_SA(6),
		.C_SU(7),
		.DC_CLIENT(8'hFF)
	) dut_nocpu (
		.clk(clk), .rst_n(rst_n),
		.mc_fault_prot(1'b0), .mc_fault_mem(1'b0), .mc_fault_tag(8'd0),
		.mc_fault_req_tag(8'd0),
		.wdt_tag(8'd0),
		.hcr_we(1'b0), .hcr_widx(10'd0), .hcr_wdata(32'd0), .hcr_wmask(32'd0),
		.hcr_ridx(GHCI_REG_FAULT_INFO[11:2]), .hcr_rdata(nocpu_rdata),
		.mc_idle(1'b1), .mem_ready(1'b1), .busy_in(8'd0), .ring_empty(1'b1),
		.ring_busy(1'b0), .cmd_active(1'b0), .wdt_hold(1'b0), .replay_busy(1'b0),
		.seq_st(4'd0), .f_busy(1'b0),
		.mc_fault(nocpu_mc_fault), .mc_fault_client(8'd2), .mc_fault_addr(32'h30005000),
		.mc_fault_write(1'b0),
		.src_fault(8'd0), .src_kind(32'd0), .src_addr(256'd0), .src_tag(64'd0),
		.src_stage(32'd0),
		.run(), .halt(), .ctrl_irq_global(), .quiesce(), .mc_flush(),
		.core_rst_n(), .open(), .cp_state(), .lc_state(), .host_kick(),
		.step(), .ev_halted(), .ev_fault(), .ev_wdt(),
		.aperture_base(), .aperture_limit()
	);

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer pulses = 0, flushes = 0, halteds = 0, faults = 0, wdts = 0, steps = 0, kicks = 0;
	integer e0;
	reg [31:0] v;

	always @(posedge clk) begin
		if (!core_rst_n && rst_n)
			pulses = pulses + 1;
		if (mc_flush)
			flushes = flushes + 1;
		if (rst_n && mc_flush !== !core_rst_n) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.reset: mc_flush and core_rst_n apart at %0t: %b %b", $time, mc_flush, core_rst_n);
		end
		if (ev_halted)
			halteds = halteds + 1;
		if (ev_fault)
			faults = faults + 1;
		if (ev_wdt)
			wdts = wdts + 1;
		if (step)
			steps = steps + 1;
		if (host_kick != 0)
			kicks = kicks + 1;
	end

	localparam [2:0] LC_IDLE      = 3'd0;
	localparam [2:0] LC_RUNNING   = 3'd1;
	localparam [2:0] LC_HALTING   = 3'd2;
	localparam [2:0] LC_HALTED    = 3'd3;
	localparam [2:0] LC_FAULTED   = 3'd4;
	localparam [2:0] LC_RESETTING = 3'd5;

	reg ctrl_run_val = 0;

	task expect_state;
		input [8*30-1:0] what;
		input [2:0] want;
		reg want_run, want_halt, want_fault, want_quiesce, want_open;
		reg [3:0] want_cp_state;
		begin
			repeat (2) @(negedge clk);
			hcr_read(GHCI_REG_STATUS[11:0], v);
			want_run = (want == LC_RUNNING) && ctrl_run_val;
			want_halt = (want == LC_HALTED);
			want_fault = (want == LC_FAULTED);
			want_quiesce = (want == LC_HALTING || want == LC_HALTED || want == LC_FAULTED || want == LC_RESETTING);
			want_open = (want == LC_IDLE || want == LC_HALTED);
			want_cp_state = (want == LC_FAULTED) ? GHCI_ST_FAULT :
			                (want == LC_RESETTING) ? GHCI_ST_WAIT_MEM :
			                (want == LC_HALTING && !mc_idle) ? GHCI_ST_WAIT_MEM :
			                (want == LC_HALTING && ring_busy) ? GHCI_ST_FETCH :
			                GHCI_ST_IDLE;
			if (v[0] !== want_run ||
			    v[1] !== want_halt ||
			    v[2] !== want_fault ||
			    v[14] !== want_quiesce ||
			    v[19:16] !== want_cp_state ||
			    run !== want_run ||
			    halt !== want_quiesce ||
			    open !== want_open ||
			    lc_state !== want) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ctl.%0s: want %0d STATUS %h (run=%b halt=%b fault=%b q=%b cp_st=%0d open=%b lc=%0d)",
					what, want, v, v[0], v[1], v[2], v[14], v[19:16], open, lc_state);
			end
		end
	endtask

	task ctrl;
		input [31:0] bits;
		begin
			ctrl_run_val = bits[GHCI_CTRL_RUN];
			hcr_write(GHCI_REG_CTRL[11:0], bits);
		end
	endtask

	task do_reset;
		begin
			ctrl(32'd1 << GHCI_CTRL_RESET);
			repeat (5) @(negedge clk);
		end
	endtask

	task expect_info;
		input [8*30-1:0] what;
		input [31:0] info;
		input [31:0] addr;
		begin
			hcr_read(GHCI_REG_FAULT_INFO[11:0], v);
			if (v !== info) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ctl.%0s: FAULT_INFO %h, expected %h", what, v, info);
			end
			hcr_read(GHCI_REG_FAULT_ADDR_LO[11:0], v);
			if (v !== addr) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ctl.%0s: FAULT_ADDR %h, expected %h", what, v, addr);
			end
		end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		@(negedge clk);
		rst_n = 1;
		/* states */
		expect_state("states", LC_IDLE);
		ctrl(32'd1 << GHCI_CTRL_RUN);
		expect_state("states", LC_RUNNING);
		/* RUN = 0 with the CP busy: RUNNING until it is idle. */
		busy_in[0] = 1;
		ctrl(32'd0);
		expect_state("states", LC_RUNNING);
		busy_in[0] = 0;
		expect_state("states", LC_IDLE);
		ctrl(32'd1 << GHCI_CTRL_RUN);
		/* HALT: HALTING until mc_idle and the ring between packets. */
		mc_idle = 0;
		ring_busy = 1;
		ctrl((32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_HALT));
		expect_state("states", LC_HALTING);
		mc_idle = 1;
		expect_state("states", LC_HALTING);
		ring_busy = 0;
		expect_state("states", LC_HALTED);
		/* HALTED stays HALTED when memory is busy again (the debug port). */
		mc_idle = 0;
		expect_state("states", LC_HALTED);
		mc_idle = 1;
		ctrl((32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_HALT) | (32'd1 << GHCI_CTRL_STEP));
		ctrl(32'd1 << GHCI_CTRL_RUN);
		expect_state("states", LC_RUNNING);
		ctrl(32'd1 << GHCI_CTRL_HALT);
		expect_state("states", LC_HALTED);
		ctrl(32'd0);
		expect_state("states", LC_IDLE);
		ctrl(32'd1 << GHCI_CTRL_HALT);
		expect_state("states", LC_HALTED);
		ctrl(32'd0);
		if (halteds != 3 || steps != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.states: %0d HALTED events, %0d steps", halteds, steps);
		end
		/* A STEP outside HALTED does nothing. */
		ctrl(32'd1 << GHCI_CTRL_STEP);
		if (steps != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.states: step outside HALTED");
		end
		if (errors == 0)
			$display("PASS atg_cp_ctl.states");
		e0 = errors;

		/* reset: from RUNNING with memory busy; the replay holds RESETTING. */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		mc_idle = 0;
		pulses = 0;
		flushes = 0;
		ctrl(32'd1 << GHCI_CTRL_RESET);
		repeat (20) @(negedge clk);
		expect_state("reset", LC_RESETTING);
		hcr_read(GHCI_REG_CTRL[11:0], v);
		if (v[GHCI_CTRL_RESET] !== 1'b1 || pulses != 0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.reset: CTRL %h, %0d pulses before mc_idle", v, pulses);
		end
		/* A second RESET while resetting is ignored. */
		ctrl(32'd1 << GHCI_CTRL_RESET);
		@(negedge clk);
		replay_busy = 1;
		mc_idle = 1;
		repeat (10) @(negedge clk);
		expect_state("reset", LC_RESETTING);
		replay_busy = 0;
		repeat (2) @(negedge clk);
		expect_state("reset", LC_IDLE);
		hcr_read(GHCI_REG_CTRL[11:0], v);
		if (v !== 32'd0 || pulses != 1 || flushes != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.reset: CTRL %h, %0d pulses, %0d flushes", v, pulses,
				flushes);
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.reset");
		e0 = errors;

		/* CTRL bits 6:5: IRQ_GLOBAL and WDT_EN */
		ctrl(32'h00000060);
		hcr_read(GHCI_REG_CTRL[11:0], v);
		if (v !== 32'h00000060 || ctrl_irq_global !== 1'b1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.ctrl_bits: CTRL %h (irq_global=%b), expected 00000060", v, ctrl_irq_global);
		end
		/* Writing CTRL.RESET clears CTRL to 0 (including WDT_EN and IRQ_GLOBAL) */
		do_reset();
		hcr_read(GHCI_REG_CTRL[11:0], v);
		if (v !== 32'd0 || ctrl_irq_global !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.ctrl_bits: CTRL %h (irq_global=%b) after RESET, expected 0", v, ctrl_irq_global);
		end
		/* Also test writing CTRL.RESET with 0x60 in same write */
		ctrl(32'h00000060);
		hcr_read(GHCI_REG_CTRL[11:0], v);
		if (v !== 32'h00000060) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.ctrl_bits: CTRL %h, expected 00000060", v);
		end
		ctrl((32'd1 << GHCI_CTRL_RESET) | 32'h60);
		@(negedge clk);
		if (ctrl_irq_global !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.ctrl_bits: irq_global not cleared immediately on RESET write");
		end
		repeat (5) @(negedge clk);
		hcr_read(GHCI_REG_CTRL[11:0], v);
		if (v !== 32'd0 || ctrl_irq_global !== 1'b0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.ctrl_bits: CTRL %h after RESET, expected 0", v);
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.ctrl_bits");
		e0 = errors;

		/* stuck: quiesced without mc_idle for 4 * WDT_CYCLES. */
		hcr_write(GHCI_REG_WDT_CYCLES[11:0], 32'd10);
		mc_idle = 0;
		ctrl(32'd1 << GHCI_CTRL_HALT);
		repeat (35) @(negedge clk);
		hcr_read(GHCI_REG_STATUS[11:0], v);
		if (v[13]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.stuck: AXI_STUCK early");
		end
		repeat (10) @(negedge clk);
		hcr_read(GHCI_REG_STATUS[11:0], v);
		if (!v[13]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.stuck: no AXI_STUCK");
		end
		mc_idle = 1;
		do_reset();
		hcr_read(GHCI_REG_STATUS[11:0], v);
		if (v[13]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.stuck: AXI_STUCK after RESET");
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.stuck");
		e0 = errors;

		/* fault: an MC fault of client 0 or of the DC is ignored; two sources at once:
		 * the MC's wins; later faults are not recorded; RESET clears. */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		@(negedge clk);
		mc_fault = 1;
		mc_fault_client = 0;
		@(negedge clk);
		mc_fault = 0;
		expect_state("fault", LC_RUNNING);
		/* The DC's (DC_CLIENT 5) refusal is not a device fault either. */
		@(negedge clk);
		mc_fault = 1;
		mc_fault_client = 8'd5;
		@(negedge clk);
		mc_fault = 0;
		expect_state("fault", LC_RUNNING);
		@(negedge clk);
		mc_fault = 1;
		mc_fault_client = 8'd3;
		mc_fault_addr = 32'h12345680;
		mc_fault_write = 1;
		src_fault[6] = 1;
		src_kind[27:24] = GHCI_FAULT_KIND_INVALID_OP;
		@(negedge clk);
		mc_fault = 0;
		src_fault = 0;
		expect_state("fault", LC_FAULTED);
		expect_info("fault", {11'd0, 1'b1, 4'd0, 8'd0, GHCI_FAULT_UNIT_VF, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h12345680);
		@(negedge clk);
		src_fault[1] = 1;
		@(negedge clk);
		src_fault = 0;
		expect_info("fault", {11'd0, 1'b1, 4'd0, 8'd0, GHCI_FAULT_UNIT_VF, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h12345680);
		/* RESET is the only way out. */
		ctrl(32'd0);
		expect_state("fault", LC_FAULTED);
		do_reset();
		expect_state("fault", LC_IDLE);
		expect_info("fault", 32'd0, 32'd0);
		/* A source fault: tag, block, kind, client, address. */
		@(negedge clk);
		src_fault[6] = 1;
		src_kind[27:24] = GHCI_FAULT_KIND_AXI_ERROR;
		src_addr[6 * 32 +: 32] = 32'hABCD0000;
		src_tag[6 * 8 +: 8] = 8'h5C;
		@(negedge clk);
		src_fault = 0;
		expect_info("fault", {12'd0, 4'd0, 8'h5C, GHCI_FAULT_UNIT_BLT, GHCI_FAULT_KIND_AXI_ERROR}, 32'hABCD0000);
		do_reset();
		@(negedge clk);
		src_fault[0] = 1;
		src_kind[3:0] = GHCI_FAULT_KIND_BAD_REG;
		src_addr[31:0] = 32'h400;
		src_tag[7:0] = 8'h77;
		@(negedge clk);
		src_fault = 0;
		expect_info("fault", {12'd0, 4'd0, 8'h77, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_BAD_REG}, 32'h400);
		/* A fault during RESETTING is ignored. */
		mc_idle = 0;
		ctrl(32'd1 << GHCI_CTRL_RESET);
		@(negedge clk);
		src_fault[1] = 1;
		@(negedge clk);
		src_fault = 0;
		mc_idle = 1;
		repeat (4) @(negedge clk);
		expect_state("fault", LC_IDLE);
		expect_info("fault", 32'd0, 32'd0);
		if (faults != 3) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.fault: %0d fault events", faults);
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.fault");
		e0 = errors;

		/* wdt: counts only with WDT_EN and cmd_active. */
		hcr_write(GHCI_REG_WDT_CYCLES[11:0], 32'd50);
		ctrl(32'd1 << GHCI_CTRL_RUN);
		cmd_active = 1;
		repeat (100) @(negedge clk);
		expect_state("wdt", LC_RUNNING);
		ctrl((32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_WDT_EN));
		repeat (30) @(negedge clk);
		cmd_active = 0;	/* restart the count */
		@(negedge clk);
		cmd_active = 1;
		repeat (30) @(negedge clk);
		expect_state("wdt", LC_RUNNING);
		wdt_hold = 1;	/* the count pauses, it does not restart */
		repeat (100) @(negedge clk);
		expect_state("wdt", LC_RUNNING);
		wdt_hold = 0;
		wdt_tag = 8'h5C;	/* the session the units were draining */
		repeat (30) @(negedge clk);
		expect_state("wdt", LC_FAULTED);
		expect_info("wdt", {12'd0, 4'd0, 8'h5C, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_WATCHDOG}, 32'd0);
		wdt_tag = 8'd0;
		cmd_active = 0;
		if (wdts != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.wdt: %0d watchdog events", wdts);
		end
		do_reset();
		ctrl(32'd0);
		hcr_write(GHCI_REG_WDT_CYCLES[11:0], 32'h10000000);
		if (errors == e0)
			$display("PASS atg_cp_ctl.wdt");
		e0 = errors;

		/* locked: writes in IDLE are fine; writes in RUNNING trigger LOCKED fault. */
		hcr_write(GHCI_REG_CP_HEAP_BASE[11:0], 32'h00100000);
		hcr_write(GHCI_REG_CP_HEAP_LIMIT[11:0], 32'h00200000);
		expect_info("locked_idle", 32'd0, 32'd0);

		ctrl(32'd1 << GHCI_CTRL_RUN);
		expect_state("locked_run", LC_RUNNING);

		/* HEAP_BASE in RUNNING -> LOCKED fault */
		hcr_write(GHCI_REG_CP_HEAP_BASE[11:0], 32'h0);
		expect_info("locked_heap_base", {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_LOCKED_REG}, 32'd0);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		hcr_write(GHCI_REG_CP_HEAP_LIMIT[11:0], 32'h0);
		expect_info("locked_heap_limit", {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_LOCKED_REG}, 32'd0);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		hcr_write(GHCI_REG_RING_BASE_LO[11:0], 32'h1000);
		expect_info("locked_ring_base_lo", {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_LOCKED_REG}, 32'd0);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		hcr_write(GHCI_REG_RING_BASE_HI[11:0], 32'h0);
		expect_info("locked_ring_base_hi", {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_LOCKED_REG}, 32'd0);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		hcr_write(GHCI_REG_RING_SIZE[11:0], 32'd12);
		expect_info("locked_ring_size", {12'd0, 4'd0, 8'd0, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_LOCKED_REG}, 32'd0);
		do_reset();

		if (errors == e0)
			$display("PASS atg_cp_ctl.locked");
		e0 = errors;

		/* U4 normalization checks (docs/ghci.md §3.5) */
		/* 1. BLT MC error reports UNIT 6 */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		mc_fault = 1;
		mc_fault_client = 8'd1;
		mc_fault_addr = 32'h20004000;
		mc_fault_write = 0;
		@(negedge clk);
		mc_fault = 0;
		expect_info("u4_blt_mc", {11'd0, 1'b0, 4'd0, 8'd0, GHCI_FAULT_UNIT_BLT, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h20004000);
		do_reset();

		/* 2. VF MC error reports UNIT 1 */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		mc_fault = 1;
		mc_fault_client = 8'd3;
		mc_fault_addr = 32'h30008000;
		mc_fault_write = 0;
		@(negedge clk);
		mc_fault = 0;
		expect_info("u4_vf_mc", {11'd0, 1'b0, 4'd0, 8'd0, GHCI_FAULT_UNIT_VF, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h30008000);
		do_reset();

		/* 3. Fence write error reports KIND 5, UNIT 0 */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		src_fault[3] = 1;
		src_kind[3 * 4 +: 4] = GHCI_FAULT_KIND_FENCE_ERROR;
		src_addr[3 * 32 +: 32] = 32'h00001000;
		src_tag[3 * 8 +: 8] = 8'h81;
		@(negedge clk);
		src_fault = 0;
		expect_info("u4_fence_fault", {12'd0, 4'd0, 8'h81, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_FENCE_ERROR}, 32'h00001000);
		do_reset();

		/* 4. Ring header error reports KIND 3, UNIT 0 */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		src_fault[0] = 1;
		src_kind[0 * 4 +: 4] = GHCI_FAULT_KIND_BAD_REG;
		src_addr[31:0] = 32'h00000400;
		src_tag[7:0] = 8'h77;
		@(negedge clk);
		src_fault = 0;
		expect_info("u4_ring_header", {12'd0, 4'd0, 8'h77, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_BAD_REG}, 32'h00000400);
		do_reset();

		/* 5. Watchdog reports KIND 4, UNIT 0 */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		hcr_write(GHCI_REG_WDT_CYCLES[11:0], 32'd10);
		ctrl((32'd1 << GHCI_CTRL_RUN) | (32'd1 << GHCI_CTRL_WDT_EN));
		cmd_active = 1;
		wdt_tag = 8'h44;
		repeat (15) @(negedge clk);
		expect_info("u4_wdt", {12'd0, 4'd0, 8'h44, GHCI_FAULT_UNIT_CP, GHCI_FAULT_KIND_WATCHDOG}, 32'd0);
		cmd_active = 0;
		wdt_tag = 8'd0;
		do_reset();
		ctrl(32'd0);
		hcr_write(GHCI_REG_WDT_CYCLES[11:0], 32'h10000000);

		/* 6. SU illegal instruction reports KIND 1, UNIT 2, and stage (FS=1, CS=2) */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		src_fault[4] = 1;
		src_kind[4 * 4 +: 4] = GHCI_FAULT_KIND_INVALID_OP;
		src_stage[4 * 4 +: 4] = GHCI_STAGE_FS;
		src_addr[4 * 32 +: 32] = 32'h000000A0;
		src_tag[4 * 8 +: 8] = 8'h2A;
		@(negedge clk);
		src_fault = 0;
		expect_info("u4_su_isa_fs", {12'd0, GHCI_STAGE_FS, 8'h2A, GHCI_FAULT_UNIT_SU, GHCI_FAULT_KIND_INVALID_OP}, 32'h000000A0);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		src_fault[4] = 1;
		src_kind[4 * 4 +: 4] = GHCI_FAULT_KIND_INVALID_OP;
		src_stage[4 * 4 +: 4] = GHCI_STAGE_CS;
		src_addr[4 * 32 +: 32] = 32'h000001B4;
		src_tag[4 * 8 +: 8] = 8'h5B;
		@(negedge clk);
		src_fault = 0;
		expect_info("u4_su_isa_cs", {12'd0, GHCI_STAGE_CS, 8'h5B, GHCI_FAULT_UNIT_SU, GHCI_FAULT_KIND_INVALID_OP}, 32'h000001B4);
		do_reset();

		/* 7. SU MC fault reports KIND 3, UNIT 2, and STAGE from mc_fault_req_tag[1:0] */
		ctrl(32'd1 << GHCI_CTRL_RUN);
		mc_fault = 1;
		mc_fault_client = 8'd8; /* SU D$ */
		mc_fault_addr = 32'h20001000;
		mc_fault_write = 0;
		mc_fault_req_tag = {6'd0, GHCI_STAGE_FS};
		@(negedge clk);
		mc_fault = 0;
		expect_info("u4_su_mc_fs", {11'd0, 1'b0, GHCI_STAGE_FS, 8'd0, GHCI_FAULT_UNIT_SU, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h20001000);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		mc_fault = 1;
		mc_fault_client = 8'd8; /* SU D$ */
		mc_fault_addr = 32'h20002000;
		mc_fault_write = 1;
		mc_fault_req_tag = {6'd0, GHCI_STAGE_CS};
		@(negedge clk);
		mc_fault = 0;
		expect_info("u4_su_mc_cs", {11'd0, 1'b1, GHCI_STAGE_CS, 8'd0, GHCI_FAULT_UNIT_SU, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h20002000);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		mc_fault = 1;
		mc_fault_client = 8'd6; /* ATOM (C_ATOM) */
		mc_fault_addr = 32'h20003000;
		mc_fault_write = 1;
		mc_fault_req_tag = {6'd0, GHCI_STAGE_MS};
		@(negedge clk);
		mc_fault = 0;
		expect_info("u4_su_mc_ms", {11'd0, 1'b1, GHCI_STAGE_MS, 8'd0, GHCI_FAULT_UNIT_SU, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h20003000);
		do_reset();

		ctrl(32'd1 << GHCI_CTRL_RUN);
		mc_fault = 1;
		mc_fault_client = 8'd9; /* SU I$ */
		mc_fault_addr = 32'h20004000;
		mc_fault_write = 0;
		mc_fault_req_tag = {6'd0, GHCI_STAGE_VS};
		@(negedge clk);
		mc_fault = 0;
		expect_info("u4_su_mc_vs", {11'd0, 1'b0, GHCI_STAGE_VS, 8'd0, GHCI_FAULT_UNIT_SU, GHCI_FAULT_KIND_PAGE_FAULT}, 32'h20004000);
		do_reset();

		/* 8. HAS_CPU=0 configuration: client 2 (VF) maps to UNIT 1 (GHCI_FAULT_UNIT_VF) */
		@(negedge clk);
		nocpu_mc_fault = 1;
		@(negedge clk);
		nocpu_mc_fault = 0;
		#1;
		if (nocpu_rdata[7:4] !== GHCI_FAULT_UNIT_VF) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl: HAS_CPU=0 VF fault unit %0d, expected %0d (GHCI_FAULT_UNIT_VF)",
				nocpu_rdata[7:4], GHCI_FAULT_UNIT_VF);
		end

		if (errors == e0)
			$display("PASS atg_cp_ctl.u4_normalization");
		e0 = errors;

		/* U6: CP_STATE micro-state normalization (§5.1) */
		ctrl(32'd1 << GHCI_CTRL_RUN);

		/* 1. CMD_WAIT_FENCE wait state (Q_FWAIT = 5) strictly maps to WAIT_FENCE (4) */
		seq_st = 4'd5;
		f_busy = 1;
		@(negedge clk);
		hcr_read(GHCI_REG_STATUS[11:0], v);
		if (v[19:16] !== GHCI_ST_WAIT_FENCE) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.u6: WAIT_FENCE cp_state %0d, expected %0d", v[19:16], GHCI_ST_WAIT_FENCE);
		end

		/* 2. CMD_FENCE dispatch (Q_FREQ = 4) maps to EXEC (3) */
		seq_st = 4'd4;
		f_busy = 0;
		@(negedge clk);
		hcr_read(GHCI_REG_STATUS[11:0], v);
		if (v[19:16] !== GHCI_ST_EXEC) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.u6: FENCE dispatch (Q_FREQ) cp_state %0d, expected %0d", v[19:16], GHCI_ST_EXEC);
		end

		/* 3. CMD_FENCE memory write in flight (f_busy = 1, seq_st != 5) maps to EXEC (3) */
		seq_st = 4'd0;
		f_busy = 1;
		@(negedge clk);
		hcr_read(GHCI_REG_STATUS[11:0], v);
		if (v[19:16] !== GHCI_ST_EXEC) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.u6: FENCE mem write (f_busy) cp_state %0d, expected %0d", v[19:16], GHCI_ST_EXEC);
		end

		/* 4. CMD_BARRIER pipeline drain (Q_BARRIER = 10) maps to WAIT_MEM (5) */
		f_busy = 0;
		seq_st = 4'd10;
		@(negedge clk);
		hcr_read(GHCI_REG_STATUS[11:0], v);
		if (v[19:16] !== GHCI_ST_WAIT_MEM) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.u6: BARRIER drain (Q_BARRIER) cp_state %0d, expected %0d", v[19:16], GHCI_ST_WAIT_MEM);
		end

		seq_st = 4'd0;
		do_reset();

		if (errors == e0)
			$display("PASS atg_cp_ctl.u6_normalization");
		if (errors == 0)
			$display("PASS atg_cp_ctl");
		else
			$display("FAIL atg_cp_ctl: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
