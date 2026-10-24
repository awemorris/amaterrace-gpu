/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_i2c_tb: atg_dc_i2c (CLK_DIV 4) on an open-drain bus with pull-ups
 * and two slave models (sim/models/i2c_slave.v): the ADV7511's address
 * 0x39 with clock stretching, and 0x74 (the KC705's I2C mux) without.
 * Checks, in order:
 *
 *   - write: START + address, the register pointer, two data bytes + STOP
 *     reach the slave's registers, no NACK, one START and one STOP; the
 *     stretched transfer takes longer than the stretching; the mux takes
 *     its one byte; the lines rest released;
 *   - read: pointer write, repeated START + read address, a byte with
 *     ACK and a byte with NACK + STOP give the registers back in DATA; the
 *     slave saw the master's NACK; a wrong address gives STATUS.NACK, and
 *     a following transfer works; CTRL and DATA writes while busy are
 *     ignored.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_i2c_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg i_we = 1'b0;
	reg [1:0] i_idx = 2'd0;
	reg [31:0] i_wdata = 32'd0;
	wire [31:0] i_rdata;
	wire scl_t, sda_t;
	wire scl, sda;
	integer errors = 0;

	always #5 clk = !clk;

	pullup (scl);
	pullup (sda);
	assign scl = scl_t ? 1'bz : 1'b0;
	assign sda = sda_t ? 1'bz : 1'b0;

	atg_dc_i2c #(.CLK_DIV(4)) dut (
		.clk(clk), .rst_n(rst_n), .i_we(i_we), .i_idx(i_idx), .i_wdata(i_wdata),
		.i_rdata(i_rdata), .scl_t(scl_t), .scl_i(scl), .sda_t(sda_t), .sda_i(sda)
	);

	i2c_slave #(.ADDR(7'h39), .STRETCH_NS(700)) adv (.scl(scl), .sda(sda));
	i2c_slave #(.ADDR(7'h74)) mux (.scl(scl), .sda(sda));

	localparam [4:0] START = 5'd1;
	localparam [4:0] STOP = 5'd2;
	localparam [4:0] WRITE = 5'd4;
	localparam [4:0] READ = 5'd8;
	localparam [4:0] ACK = 5'd16;

	task fail;
		input [8*56-1:0] what;
		begin
			errors = errors + 1;
			$display("FAIL atg_dc_i2c: %0s at %0t", what, $time);
		end
	endtask

	task wr;
		input [1:0] idx;
		input [31:0] v;
		begin
			@(posedge clk);
			i_we <= 1'b1;
			i_idx <= idx;
			i_wdata <= v;
			@(posedge clk);
			i_we <= 1'b0;
			i_idx <= 2'd2;
		end
	endtask

	task rd;
		input [1:0] idx;
		output [31:0] v;
		begin
			@(posedge clk);
			i_idx <= idx;
			@(posedge clk);
			#1 v = i_rdata;
			i_idx <= 2'd2;
		end
	endtask

	task wait_idle;
		reg [31:0] st;
		integer n;
		begin
			n = 0;
			rd(2'd2, st);
			while (st[0] && n < 20000) begin
				rd(2'd2, st);
				n = n + 1;
			end
			if (st[0])
				fail("stays busy");
		end
	endtask

	/* One command: DATA, then CTRL, then wait. */
	task op;
		input [4:0] ctrl;
		input [7:0] byte;
		begin
			wr(2'd1, {24'd0, byte});
			wr(2'd0, {27'd0, ctrl});
			wait_idle;
		end
	endtask

	task expect_nack;
		input want;
		reg [31:0] st;
		begin
			rd(2'd2, st);
			if (st[1] !== want)
				fail(want ? "no NACK where expected" : "unexpected NACK");
		end
	endtask

	reg [31:0] v;
	time t0;

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1'b1;
		repeat (4) @(posedge clk);
		if (scl !== 1'b1 || sda !== 1'b1)
			fail("lines not released after reset");

		/* write: 0x72 (0x39 W), pointer 0x41, data 0x10, 0x20. */
		t0 = $time;
		op(START | WRITE, 8'h72);
		expect_nack(1'b0);
		op(WRITE, 8'h41);
		op(WRITE, 8'h10);
		op(WRITE | STOP, 8'h20);
		expect_nack(1'b0);
		if (adv.regs[8'h41] !== 8'h10 || adv.regs[8'h42] !== 8'h20)
			fail("written registers");
		if (adv.starts != 1 || adv.stops != 1 || adv.wbytes != 3)
			fail("START/STOP/byte count");
		if ($time - t0 < 4 * 700)
			fail("the stretching was not waited for");
		/* The mux: one control byte. */
		op(START | WRITE, 8'hE8);
		op(WRITE | STOP, 8'h20);
		expect_nack(1'b0);
		if (mux.last !== 8'h20 || mux.wbytes != 1)
			fail("mux control byte");
		if (adv.starts != 2 || adv.naddr != 1)
			fail("0x39 should ignore the mux's address");
		repeat (10) @(posedge clk);
		if (scl !== 1'b1 || sda !== 1'b1)
			fail("lines not released after STOP");
		if (errors == 0)
			$display("PASS atg_dc_i2c.write");

		/* read: pointer 0x41, repeated START, 0x73, ACK, NACK + STOP. */
		op(START | WRITE, 8'h72);
		op(WRITE, 8'h41);
		op(START | WRITE, 8'h73);
		expect_nack(1'b0);
		op(READ | ACK, 8'h00);
		rd(2'd1, v);
		if (v[7:0] !== 8'h10)
			fail("first byte read");
		op(READ | STOP, 8'h00);
		rd(2'd1, v);
		if (v[7:0] !== 8'h20)
			fail("second byte read");
		if (!adv.master_nacked)
			fail("slave did not see the master's NACK");
		rd(2'd0, v);
		if (v[4:0] !== (READ | STOP))
			fail("CTRL read back");
		/* A wrong address: NACK. */
		op(START | WRITE | STOP, 8'hA0);
		expect_nack(1'b1);
		/* Writes while busy are ignored. */
		wr(2'd1, 32'h72);
		wr(2'd0, {27'd0, START | WRITE});
		wr(2'd1, 32'h55);
		wr(2'd0, {27'd0, STOP});
		wait_idle;
		expect_nack(1'b0);
		op(WRITE, 8'h43);
		op(WRITE | STOP, 8'h99);
		if (adv.regs[8'h43] !== 8'h99 || adv.regs[8'h55] !== 8'h00)
			fail("transfer after NACK, or a busy write took effect");
		if (errors == 0)
			$display("PASS atg_dc_i2c.read");

		if (errors == 0)
			$display("PASS atg_dc_i2c");
		else
			$display("FAIL atg_dc_i2c: %0d errors", errors);
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_dc_i2c: timeout");
		$finish;
	end
endmodule

`default_nettype wire
