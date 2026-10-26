/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * A host test of platform/fpga/kc705/bringup (Icarus Verilog): IBUFDS, BUFG
 * and BSCANE2 are replaced by the models below, and the test drives the
 * BSCANE2's side the way the TAP does in Capture-DR, Shift-DR and Update-DR.
 * The walking one (2^26 cycles a step) is not simulated.
 */

`timescale 1ns / 1ps
`default_nettype none

module IBUFDS (input wire I, input wire IB, output wire O);
	assign O = I;
endmodule

module BUFG (input wire I, output wire O);
	assign O = I;
endmodule

module BSCANE2 #(parameter integer JTAG_CHAIN = 1) (
	output wire CAPTURE, output wire DRCK, output wire RESET,
	output wire RUNTEST, output wire SEL, output wire SHIFT,
	output wire TCK, output wire TDI, output wire TMS, output wire UPDATE,
	input wire TDO
);
	reg capture = 0, sel = 0, shift = 0, tck = 0, tdi = 0, update = 0;
	assign CAPTURE = capture;
	assign SEL = sel;
	assign SHIFT = shift;
	assign TCK = tck;
	assign TDI = tdi;
	assign UPDATE = update;
	assign DRCK = 1'b0;
	assign RESET = 1'b0;
	assign RUNTEST = 1'b0;
	assign TMS = 1'b0;
endmodule

module bringup_tb;
	reg clk = 0;
	reg cpu_reset = 1;
	reg [3:0] dip = 4'b0000;
	reg btn_n = 0, btn_e = 0, btn_s = 0, btn_w = 0, btn_c = 0;
	wire [7:0] led;
	integer failed = 0;
	integer i;
	reg [127:0] q;
	reg [31:0] c0, c1;

	always #2.5 clk = ~clk;

	bringup dut (
		.sysclk_p(clk), .sysclk_n(~clk), .cpu_reset(cpu_reset),
		.dip(dip), .btn_n(btn_n), .btn_e(btn_e), .btn_s(btn_s),
		.btn_w(btn_w), .btn_c(btn_c), .led(led)
	);

	task tck_pulse;
		begin
			#20 dut.bscan.tck = 1;
			#20 dut.bscan.tck = 0;
		end
	endtask

	/* One DR scan of 128 bits: din in, the captured value out. */
	task scan(input [127:0] din, output [127:0] dout);
		begin
			dut.bscan.sel = 1;
			dut.bscan.capture = 1;
			tck_pulse;
			dut.bscan.capture = 0;
			dut.bscan.shift = 1;
			for (i = 0; i < 128; i = i + 1) begin
				dout[i] = dut.bscan.TDO;
				dut.bscan.tdi = din[i];
				tck_pulse;
			end
			dut.bscan.shift = 0;
			dut.bscan.update = 1;
			tck_pulse;
			dut.bscan.update = 0;
			dut.bscan.sel = 0;
		end
	endtask

	function [31:0] gray2bin(input [31:0] g);
		integer k;
		begin
			gray2bin[31] = g[31];
			for (k = 30; k >= 0; k = k - 1)
				gray2bin[k] = gray2bin[k + 1] ^ g[k];
		end
	endfunction

	task check(input ok, input [8*40-1:0] what);
		begin
			if (ok)
				$display("ok   %0s", what);
			else begin
				$display("FAIL %0s", what);
				failed = failed + 1;
			end
		end
	endtask

	initial begin
		#100 cpu_reset = 0;
		dip = 4'b1010;
		#200;
		scan(128'd0, q);
		check(q[31:0] == 32'h4B373035, "ID");
		check(q[63:56] == 8'd1, "VERSION");
		check(q[35:32] == 4'b1010, "STATUS dip");
		check(q[40:36] == 5'd0, "STATUS buttons idle");
		check(q[51:48] == 4'b1010 && q[55:52] == 4'b0001,
		    "STATUS leds (dip, walk)");
		check(led == 8'b0001_1010, "led pins");
		check(q[127:96] == 32'd0, "SCRATCH 0");
		c0 = gray2bin(q[95:64]);
		#1000;	/* plus one scan of 130 TCK cycles, 5.2 us: about 1240 clocks */
		scan(128'd0, q);
		c1 = gray2bin(q[95:64]);
		$display("     counter %0d -> %0d", c0, c1);
		check(c1 > c0 && c1 - c0 > 1200 && c1 - c0 < 1300,
		    "COUNTER advances at clk");

		btn_n = 1;
		btn_c = 1;
		#100;
		scan(128'd0, q);
		check(q[40:36] == 5'b10001, "STATUS buttons N C");
		check(led[7:4] == 4'b1000, "led N");
		btn_n = 0;
		btn_c = 0;

		/* A write: bits [63:32] in are the key. */
		scan({64'd0, 32'h57524954, 32'h8000_00A5}, q);
		scan(128'd0, q);
		check(q[127:96] == 32'h8000_00A5, "SCRATCH written");
		#100;
		check(led == 8'hA5, "led from SCRATCH");
		scan(128'd0, q);
		check(q[127:96] == 32'h8000_00A5, "read-only scan keeps SCRATCH");
		scan({64'd0, 32'h57524955, 32'h0}, q);
		scan(128'd0, q);
		check(q[127:96] == 32'h8000_00A5, "wrong key ignored");
		scan({64'd0, 32'h57524954, 32'h0}, q);
		#100;
		check(led == 8'b0001_1010, "SCRATCH[31] 0 gives the pattern");

		cpu_reset = 1;
		#100;
		scan(128'd0, q);
		check(gray2bin(q[95:64]) < 10, "CPU_RESET clears COUNTER");

		if (failed == 0)
			$display("PASS bringup-tb");
		else
			$display("FAIL bringup-tb (%0d)", failed);
		$finish;
	end
endmodule

`default_nettype wire
