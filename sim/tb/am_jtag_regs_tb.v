/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_jtag_regs_tb: am_jtag_regs behind the BSCANE2 model (sim/models/xilinx),
 * which walks the TAP as the cable would (TCK 25 MHz, clk 100 MHz), and a
 * register file of 16 words on the bus side that answers a read the next
 * cycle.  Checks, in order:
 *
 *   - write: a write scan gives reg_wr exactly once with the address and
 *     data, strobes F; a status scan then reports done;
 *   - read: a read scan, status scans until done, the data field is the
 *     register's value and the address field the scanned address; a scan
 *     during a pending access is dropped (status [1]) and does nothing;
 *   - busy: with bus_busy held the access waits (no strobe), and happens
 *     once after bus_busy falls.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_jtag_regs_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg bus_busy = 1'b0;
	reg [31:0] reg_rdata = 32'd0;
	wire tck, tdi, tdo, sel, capture, shift, update;
	wire reg_wr, reg_rd;
	wire [16:0] reg_waddr, reg_raddr;
	wire [31:0] reg_wdata;
	wire [3:0] reg_wstrb;

	integer errors = 0;
	integer wr_count = 0;
	integer rd_count = 0;
	reg [31:0] regfile [0:15];
	reg [16:0] last_waddr;
	reg [31:0] last_wdata;
	integer k;

	always #5 clk = !clk;

	BSCANE2 #(.JTAG_CHAIN(2), .TCK_HALF(20)) bscan (
		.CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift),
		.TCK(tck), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo)
	);

	am_jtag_regs dut (
		.clk(clk), .rst_n(rst_n),
		.tck(tck), .tdi(tdi), .tdo(tdo), .sel(sel), .capture(capture), .shift(shift),
		.update(update),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata), .bus_busy(bus_busy)
	);

	/* The bus side: a register file, read data the next cycle. */
	always @(posedge clk) begin
		if (reg_wr) begin
			wr_count = wr_count + 1;
			last_waddr = reg_waddr;
			last_wdata = reg_wdata;
			if (reg_wstrb !== 4'hF)
				fail("wstrb not F");
			if (bus_busy)
				fail("write while bus_busy");
			regfile[reg_waddr[5:2]] = reg_wdata;
		end
		if (reg_rd) begin
			rd_count = rd_count + 1;
			if (bus_busy)
				fail("read while bus_busy");
			reg_rdata <= regfile[reg_raddr[5:2]];
		end else begin
			reg_rdata <= 32'hDEADBEEF;	/* only the cycle after reg_rd counts */
		end
	end

	task fail;
		input [8*48-1:0] what;
		begin
			errors = errors + 1;
			$display("FAIL am_jtag_regs: %0s at %0t", what, $time);
		end
	endtask

	task scan72;
		input [7:0] cmd;
		input [31:0] addr;
		input [31:0] data;
		output [71:0] got;
		reg [127:0] o;
		begin
			bscan.scan(72, {56'd0, data, addr, cmd}, o);
			got = o[71:0];
		end
	endtask

	/* Status scans until done; the last captured word. */
	task wait_done;
		output [71:0] got;
		integer n;
		begin
			n = 0;
			scan72(8'd3, 32'd0, 32'd0, got);
			while (!got[0] && n < 50) begin
				scan72(8'd3, 32'd0, 32'd0, got);
				n = n + 1;
			end
			if (!got[0])
				fail("status never done");
		end
	endtask

	reg [71:0] got;
	integer w0, r0;

	initial begin
		for (k = 0; k < 16; k = k + 1)
			regfile[k] = 32'h1000 + k;
		bscan.idle(4);
		repeat (5) @(posedge clk);
		rst_n = 1'b1;

		/* write */
		scan72(8'd1, 32'h0001_0024, 32'hA5A5_1234, got);
		if (got[0] !== 1'b1)
			fail("not done before the first command");
		wait_done(got);
		if (wr_count != 1 || last_waddr !== 17'h10024 || last_wdata !== 32'hA5A51234)
			fail("write not seen once with its address and data");
		if (rd_count != 0)
			fail("write gave a read");
		if (got[39:8] !== 32'h0001_0024)
			fail("captured address");
		if (errors == 0)
			$display("PASS am_jtag_regs.write");

		/* read */
		w0 = wr_count;
		scan72(8'd2, 32'h0000_0024, 32'd0, got);
		wait_done(got);
		if (got[71:40] !== 32'hA5A51234 || got[39:8] !== 32'h24)
			fail("read data or address");
		if (rd_count != 1 || wr_count != w0)
			fail("read not seen once");
		if (errors == 0)
			$display("PASS am_jtag_regs.read");

		/* busy: the access waits; a scan meanwhile is dropped. */
		@(posedge clk);
		bus_busy = 1'b1;
		r0 = rd_count;
		w0 = wr_count;
		scan72(8'd1, 32'h0000_0008, 32'h0BAD_F00D, got);
		bscan.idle(20);
		scan72(8'd2, 32'h0000_0030, 32'd0, got);	/* dropped */
		if (got[0] !== 1'b0)
			fail("done while the bus is busy");
		scan72(8'd3, 32'd0, 32'd0, got);
		if (got[1] !== 1'b1 || got[0] !== 1'b0)
			fail("dropped not reported");
		if (wr_count != w0 || rd_count != r0)
			fail("access while bus_busy");
		@(posedge clk);
		bus_busy = 1'b0;
		wait_done(got);
		if (wr_count != w0 + 1 || rd_count != r0)
			fail("the waiting write did not happen once (or the dropped read ran)");
		if (regfile[2] !== 32'h0BADF00D)
			fail("waiting write data");
		if (got[39:8] !== 32'h8)
			fail("dropped command changed the address");
		/* The next accepted command clears dropped. */
		scan72(8'd2, 32'h0000_0008, 32'd0, got);
		wait_done(got);
		if (got[1] !== 1'b0 || got[71:40] !== 32'h0BADF00D)
			fail("dropped not cleared or read after busy");
		if (errors == 0)
			$display("PASS am_jtag_regs.busy");

		if (errors == 0)
			$display("PASS am_jtag_regs");
		else
			$display("FAIL am_jtag_regs: %0d errors", errors);
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL am_jtag_regs: timeout");
		$finish;
	end
endmodule

`default_nettype wire
