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
 * (MC client 0 ignored), the watchdog, locked writes and KICK.
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
	reg [7:0] busy_in = 0;
	reg mc_fault = 0, mc_fault_write = 0;
	reg [7:0] mc_fault_client = 0;
	reg [31:0] mc_fault_addr = 0;
	reg [7:0] src_fault = 0;
	reg [31:0] src_kind = 0;
	reg [255:0] src_addr = 0;
	reg [63:0] src_tag = 0;
	wire run, halt, quiesce, mc_flush, core_rst_n, open, step, ev_halted, ev_fault, ev_wdt;
	wire [3:0] cp_state;
	wire [2:0] host_kick;
	wire [31:0] ap_base, ap_limit;

	atg_cp_ctl #(.UNITS(8'h03)) dut (
		.clk(clk), .rst_n(rst_n),
		.mc_fault_prot(1'b0), .mc_fault_mem(1'b0), .mc_fault_tag(8'd0),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.mc_idle(mc_idle), .mem_ready(1'b1), .busy_in(busy_in), .ring_empty(1'b1),
		.ring_busy(ring_busy), .cmd_active(cmd_active), .wdt_hold(wdt_hold), .replay_busy(replay_busy),
		.mc_fault(mc_fault), .mc_fault_client(mc_fault_client), .mc_fault_addr(mc_fault_addr),
		.mc_fault_write(mc_fault_write),
		.src_fault(src_fault), .src_kind(src_kind), .src_addr(src_addr), .src_tag(src_tag),
		.run(run), .halt(halt), .quiesce(quiesce), .mc_flush(mc_flush),
		.core_rst_n(core_rst_n), .open(open), .cp_state(cp_state), .host_kick(host_kick),
		.step(step), .ev_halted(ev_halted), .ev_fault(ev_fault), .ev_wdt(ev_wdt),
		.aperture_base(ap_base), .aperture_limit(ap_limit)
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

	task expect_state;
		input [8*30-1:0] what;
		input [3:0] want;
		begin
			repeat (2) @(negedge clk);
			hcr_read(GHCI_STATUS[11:0], v);
			if (cp_state !== want || v[19:16] !== want ||
			    open !== (want == GHCI_ST_IDLE || want == GHCI_ST_HALTED) ||
			    halt !== (want >= GHCI_ST_HALTING) || (want != GHCI_ST_RUNNING && run) ||
			    v[10] !== (want == GHCI_ST_HALTED) || v[9] !== (want == GHCI_ST_FAULTED) ||
			    v[14] !== (want >= GHCI_ST_HALTING)) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ctl.%0s: state %0d STATUS %h, expected %0d", what,
					cp_state, v, want);
			end
		end
	endtask

	task ctrl;
		input [31:0] bits;
		hcr_write(GHCI_CTRL[11:0], bits);
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
			hcr_read(GHCI_FAULT_INFO[11:0], v);
			if (v !== info) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ctl.%0s: FAULT_INFO %h, expected %h", what, v, info);
			end
			hcr_read(GHCI_FAULT_ADDR[11:0], v);
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
		expect_state("states", GHCI_ST_IDLE);
		ctrl(32'd1);
		expect_state("states", GHCI_ST_RUNNING);
		/* RUN = 0 with the CP busy: RUNNING until it is idle. */
		busy_in[0] = 1;
		ctrl(32'd0);
		expect_state("states", GHCI_ST_RUNNING);
		busy_in[0] = 0;
		expect_state("states", GHCI_ST_IDLE);
		ctrl(32'd1);
		/* HALT: HALTING until mc_idle and the ring between packets. */
		mc_idle = 0;
		ring_busy = 1;
		ctrl(32'd5);
		expect_state("states", GHCI_ST_HALTING);
		mc_idle = 1;
		expect_state("states", GHCI_ST_HALTING);
		ring_busy = 0;
		expect_state("states", GHCI_ST_HALTED);
		/* HALTED stays HALTED when memory is busy again (the debug port). */
		mc_idle = 0;
		expect_state("states", GHCI_ST_HALTED);
		mc_idle = 1;
		ctrl(32'd5 | (32'd1 << GHCI_CTRL_STEP));
		ctrl(32'd1);
		expect_state("states", GHCI_ST_RUNNING);
		ctrl(32'd4);
		expect_state("states", GHCI_ST_HALTED);
		ctrl(32'd0);
		expect_state("states", GHCI_ST_IDLE);
		ctrl(32'd4);
		expect_state("states", GHCI_ST_HALTED);
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
		ctrl(32'd1);
		mc_idle = 0;
		pulses = 0;
		flushes = 0;
		ctrl(32'd1 << GHCI_CTRL_RESET);
		repeat (20) @(negedge clk);
		expect_state("reset", GHCI_ST_RESETTING);
		hcr_read(GHCI_CTRL[11:0], v);
		if (v[1] !== 1'b1 || pulses != 0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.reset: CTRL %h, %0d pulses before mc_idle", v, pulses);
		end
		/* A second RESET while resetting is ignored. */
		ctrl(32'd1 << GHCI_CTRL_RESET);
		@(negedge clk);
		replay_busy = 1;
		mc_idle = 1;
		repeat (10) @(negedge clk);
		expect_state("reset", GHCI_ST_RESETTING);
		replay_busy = 0;
		repeat (2) @(negedge clk);
		expect_state("reset", GHCI_ST_IDLE);
		hcr_read(GHCI_CTRL[11:0], v);
		if (v !== 32'd0 || pulses != 1 || flushes != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.reset: CTRL %h, %0d pulses, %0d flushes", v, pulses,
				flushes);
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.reset");
		e0 = errors;

		/* stuck: quiesced without mc_idle for 4 * WDT_CYCLES. */
		hcr_write(GHCI_WDT_CYCLES[11:0], 32'd10);
		mc_idle = 0;
		ctrl(32'd4);
		repeat (35) @(negedge clk);
		hcr_read(GHCI_STATUS[11:0], v);
		if (v[13]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.stuck: AXI_STUCK early");
		end
		repeat (10) @(negedge clk);
		hcr_read(GHCI_STATUS[11:0], v);
		if (!v[13]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.stuck: no AXI_STUCK");
		end
		mc_idle = 1;
		do_reset();
		hcr_read(GHCI_STATUS[11:0], v);
		if (v[13]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.stuck: AXI_STUCK after RESET");
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.stuck");
		e0 = errors;

		/* fault: an MC fault of client 0 is ignored; two sources at once:
		 * the MC's wins; later faults are not recorded; RESET clears. */
		ctrl(32'd1);
		@(negedge clk);
		mc_fault = 1;
		mc_fault_client = 0;
		@(negedge clk);
		mc_fault = 0;
		expect_state("fault", GHCI_ST_RUNNING);
		@(negedge clk);
		mc_fault = 1;
		mc_fault_client = 8'd3;
		mc_fault_addr = 32'h12345680;
		mc_fault_write = 1;
		src_fault[6] = 1;
		src_kind[27:24] = GHCI_FAULT_OPCODE;
		@(negedge clk);
		mc_fault = 0;
		src_fault = 0;
		expect_state("fault", GHCI_ST_FAULTED);
		expect_info("fault", {8'd0, 8'd3, GHCI_FAULT_APERTURE, 3'd0, 1'b1, 8'd3}, 32'h12345680);
		@(negedge clk);
		src_fault[1] = 1;
		@(negedge clk);
		src_fault = 0;
		expect_info("fault", {8'd0, 8'd3, GHCI_FAULT_APERTURE, 3'd0, 1'b1, 8'd3}, 32'h12345680);
		/* RESET is the only way out. */
		ctrl(32'd0);
		expect_state("fault", GHCI_ST_FAULTED);
		do_reset();
		expect_state("fault", GHCI_ST_IDLE);
		expect_info("fault", 32'd0, 32'd0);
		/* A source fault: tag, block, kind, client, address. */
		@(negedge clk);
		src_fault[6] = 1;
		src_kind[27:24] = GHCI_FAULT_AXI;
		src_addr[6 * 32 +: 32] = 32'hABCD0000;
		src_tag[6 * 8 +: 8] = 8'h5C;
		@(negedge clk);
		src_fault = 0;
		expect_info("fault", {8'h5C, 8'd1, GHCI_FAULT_AXI, 4'd0, 8'd1}, 32'hABCD0000);
		do_reset();
		@(negedge clk);
		src_fault[0] = 1;
		src_kind[3:0] = GHCI_FAULT_RING;
		src_addr[31:0] = 32'h400;
		src_tag[7:0] = 8'h77;
		@(negedge clk);
		src_fault = 0;
		expect_info("fault", {8'h77, 8'd0, GHCI_FAULT_RING, 4'd0, 8'd0}, 32'h400);
		/* A fault during RESETTING is ignored. */
		mc_idle = 0;
		ctrl(32'd1 << GHCI_CTRL_RESET);
		@(negedge clk);
		src_fault[1] = 1;
		@(negedge clk);
		src_fault = 0;
		mc_idle = 1;
		repeat (4) @(negedge clk);
		expect_state("fault", GHCI_ST_IDLE);
		expect_info("fault", 32'd0, 32'd0);
		if (faults != 3) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.fault: %0d fault events", faults);
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.fault");
		e0 = errors;

		/* wdt: counts only with WDT_EN and cmd_active. */
		hcr_write(GHCI_WDT_CYCLES[11:0], 32'd50);
		ctrl(32'd1);
		cmd_active = 1;
		repeat (100) @(negedge clk);
		expect_state("wdt", GHCI_ST_RUNNING);
		ctrl(32'd1 | (32'd1 << GHCI_CTRL_WDT_EN));
		repeat (30) @(negedge clk);
		cmd_active = 0;	/* restart the count */
		@(negedge clk);
		cmd_active = 1;
		repeat (30) @(negedge clk);
		expect_state("wdt", GHCI_ST_RUNNING);
		wdt_hold = 1;	/* the count pauses, it does not restart */
		repeat (100) @(negedge clk);
		expect_state("wdt", GHCI_ST_RUNNING);
		wdt_hold = 0;
		repeat (30) @(negedge clk);
		expect_state("wdt", GHCI_ST_FAULTED);
		expect_info("wdt", {16'd0, GHCI_FAULT_WATCHDOG, 12'd0}, 32'd0);
		cmd_active = 0;
		if (wdts != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.wdt: %0d watchdog events", wdts);
		end
		do_reset();
		ctrl(32'd0);
		hcr_write(GHCI_WDT_CYCLES[11:0], 32'h10000000);
		if (errors == e0)
			$display("PASS atg_cp_ctl.wdt");
		e0 = errors;

		/* locked: the aperture in IDLE; locked writes and KICK in RUNNING. */
		hcr_write(GHCI_APERTURE_BASE[11:0], 32'h0010003F);
		hcr_write(GHCI_APERTURE_LIMIT[11:0], 32'h00200000);
		if (ap_base !== 32'h00100020 || ap_limit !== 32'h00200000) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.locked: aperture %h %h", ap_base, ap_limit);
		end
		kicks = 0;
		hcr_write(GHCI_KICK[11:0], 32'd1);
		if (kicks != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.locked: no KICK in IDLE");
		end
		/* KICK.BLIT with the BLT busy: kind 6. */
		busy_in[1] = 1;
		hcr_write(GHCI_KICK[11:0], 32'd1);
		busy_in[1] = 0;
		expect_info("locked", {16'd0, GHCI_FAULT_KICK, 12'd0}, 32'd0);
		do_reset();
		/* KICK.DRAW without a VF: kind 2. */
		hcr_write(GHCI_KICK[11:0], 32'd2);
		expect_info("locked", {16'd0, GHCI_FAULT_OPCODE, 12'd0}, 32'd0);
		do_reset();
		ctrl(32'd1);
		hcr_write(GHCI_KICK[11:0], 32'd1);
		expect_info("locked", {16'd0, GHCI_FAULT_KICK, 12'd0}, 32'd0);
		if (kicks != 1) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.locked: KICK passed outside IDLE/HALTED");
		end
		do_reset();
		ctrl(32'd1);
		hcr_write(GHCI_APERTURE_BASE[11:0], 32'h0);
		expect_info("locked", {16'd0, GHCI_FAULT_LOCKED, 12'd0}, 32'd0);
		if (ap_base !== 32'h00100020) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.locked: aperture written in RUNNING");
		end
		do_reset();
		ctrl(32'd1);
		hcr_write(GHCI_RING_SIZE[11:0], 32'd12);
		expect_info("locked", {16'd0, GHCI_FAULT_LOCKED, 12'd0}, 32'd0);
		do_reset();
		if (ap_limit !== 32'h00200000) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ctl.locked: aperture lost in RESET");
		end
		if (errors == e0)
			$display("PASS atg_cp_ctl.locked");
		if (errors == 0)
			$display("PASS atg_cp_ctl");
		else
			$display("FAIL atg_cp_ctl: %0d errors", errors);
		$finish;
	end
endmodule

`default_nettype wire
