/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_core_tb: runs the RV32IM test programs of sim/tb/cpu/ (built by
 * tools/cpu-tests.sh; rv32i and rv32m are generated with their expected
 * values by gen.py) on atg_cpu_core with a behavioural IMEM (synchronous
 * read, held while i_en is 0) and a data memory at 0x0001_0000.  A
 * program reports through TOHOST (0xF000_0000: 1 pass, 2n+1 check n
 * failed); IRQ_REQ (0xF000_0004) raises irq after the stored number of
 * cycles and IRQ_ACK (0xF000_0008) drops it.  The data port may answer at
 * once or after random waits, and run may be dropped at random; the
 * testbench checks the valid/ready rule of the data port, that the core
 * stops when run is 0, the interrupt entry at 0x10 without nesting, and
 * the fault pulse with its PC, after which the core stays stopped.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_core_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg run = 1'b1;
	reg irq = 1'b0;
	wire stopped;
	wire i_en;
	wire [31:0] i_addr;
	reg [31:0] i_rdata = 32'd0;
	wire d_valid, d_write;
	wire [31:0] d_addr, d_wdata;
	wire [3:0] d_be;
	wire d_ready;
	wire [31:0] d_rdata;
	wire fault;
	wire [31:0] fault_pc;

	integer seed = 1;
	integer errors = 0;
	integer e0, i, n;

	always #5 clk = !clk;

	atg_cpu_core dut (
		.clk(clk), .rst_n(rst_n), .run(run), .stopped(stopped), .irq(irq),
		.i_en(i_en), .i_addr(i_addr), .i_rdata(i_rdata),
		.d_valid(d_valid), .d_write(d_write), .d_addr(d_addr), .d_wdata(d_wdata),
		.d_be(d_be), .d_ready(d_ready), .d_rdata(d_rdata),
		.fault(fault), .fault_pc(fault_pc)
	);

	/* IMEM: 64 KiB, the whole IMEM range of the core. */
	reg [31:0] imem [0:16383];

	always @(posedge clk) begin
		if (i_en)
			i_rdata <= imem[i_addr[15:2]];
	end

	/* Data memory at 0x0001_0000 and the testbench's I/O at 0xF000_0000. */
	reg [31:0] dmem [0:16383];
	wire in_dmem = d_addr[31:16] == 16'h0001;
	wire in_io = d_addr[31:16] == 16'hF000;
	integer lat_mode = 0;	/* 0: ready at once, 1: random waits */
	integer waited = 0;
	integer want_wait = 0;
	integer tohost = 0;
	integer irq_at = -1;
	integer irq_reqs = 0;
	integer irq_entries = 0;
	integer cycles = 0;
	integer retired = 0;
	integer faults = 0;
	reg [31:0] last_fault_pc;

	assign d_ready = d_valid && waited >= want_wait;
	assign d_rdata = in_dmem ? dmem[d_addr[15:2]] : 32'd0;

	/* Held payload of an access that waits. */
	reg hold;
	reg [31:0] h_addr, h_wdata;
	reg [3:0] h_be;
	reg h_write;

	always @(posedge clk) begin
		cycles = cycles + 1;
		if (rst_n && hold) begin
			if (!d_valid || d_addr != h_addr || d_write != h_write ||
				(h_write && (d_wdata != h_wdata || d_be != h_be))) begin
				$display("FAIL data port dropped or changed a waiting access at %h", h_addr);
				errors = errors + 1;
			end
		end
		hold = d_valid && !d_ready;
		h_addr = d_addr;
		h_write = d_write;
		h_wdata = d_wdata;
		h_be = d_be;
		if (d_valid && d_ready) begin
			waited = 0;
			want_wait = lat_mode ? (($random(seed) & 7) > 4 ? $random(seed) & 3 : 0) : 0;
			if (d_write && in_dmem) begin
				if (d_be[0]) dmem[d_addr[15:2]][7:0] <= d_wdata[7:0];
				if (d_be[1]) dmem[d_addr[15:2]][15:8] <= d_wdata[15:8];
				if (d_be[2]) dmem[d_addr[15:2]][23:16] <= d_wdata[23:16];
				if (d_be[3]) dmem[d_addr[15:2]][31:24] <= d_wdata[31:24];
			end
			if (d_write && in_io) begin
				case (d_addr[7:0])
				8'h00: tohost = d_wdata;
				8'h04: begin
					irq_at = cycles + d_wdata;
					irq_reqs = irq_reqs + 1;
				end
				8'h08: irq <= 1'b0;
				default: ;
				endcase
			end
		end else if (d_valid) begin
			waited = waited + 1;
		end
		if (cycles == irq_at) begin
			irq <= 1'b1;
			irq_at = -1;
		end
		if (rst_n && dut.e_done)
			retired = retired + 1;
		if (rst_n && dut.take_irq) begin
			irq_entries = irq_entries + 1;
			if (dut.in_irq) begin
				$display("FAIL nested interrupt");
				errors = errors + 1;
			end
		end
		if (fault) begin
			faults = faults + 1;
			last_fault_pc = fault_pc;
		end
		if (rst_n && stopped && d_valid && !dut.e_busy) begin
			$display("FAIL access issued while stopped");
			errors = errors + 1;
		end
	end

	/* After an interrupt is taken the next fetch is the vector. */
	always @(posedge clk) begin
		if (rst_n && dut.take_irq) begin
			@(negedge clk);
			if (dut.pc_f != 32'h10) begin
				$display("FAIL interrupt did not enter at 0x10 (pc %h)", dut.pc_f);
				errors = errors + 1;
			end
		end
	end

	/* run toggling: 0 off, else drop run for random spells. */
	integer run_mode = 0;
	integer run_low = 0;

	always @(negedge clk) begin
		if (run_mode && rst_n) begin
			if (run && ($random(seed) & 63) == 0)
				run = 1'b0;
			else if (!run && ($random(seed) & 15) == 0)
				run = 1'b1;
		end
		if (!run)
			run_low = run_low + 1;
		else
			run_low = 0;
		if (run_low == 40 && !stopped) begin
			$display("FAIL not stopped 40 cycles after run = 0");
			errors = errors + 1;
		end
	end

	task load;
		input [8*64-1:0] name;
		reg [8*96-1:0] f;
		reg [31:0] w;
		integer fd;
		begin
			for (i = 0; i < 16384; i = i + 1) begin
				imem[i] = 32'd0;
				dmem[i] = 32'd0;
			end
			$sformat(f, "sim/tb/cpu/%0s.imem.hex", name);
			fd = $fopen(f, "r");
			for (i = 0; i < 16384 && $fscanf(fd, "%h", w) == 1; i = i + 1)
				imem[i] = w;
			$fclose(fd);
			$sformat(f, "sim/tb/cpu/%0s.dmem.hex", name);
			fd = $fopen(f, "r");
			for (i = 0; i < 16384 && $fscanf(fd, "%h", w) == 1; i = i + 1)
				dmem[i] = w;
			$fclose(fd);
		end
	endtask

	task reset;
		begin
			@(negedge clk);
			rst_n = 1'b0;
			irq = 1'b0;
			irq_at = -1;
			tohost = 0;
			faults = 0;
			repeat (3) @(negedge clk);
			cycles = 0;
			retired = 0;
			irq_reqs = 0;
			irq_entries = 0;
			rst_n = 1'b1;
		end
	endtask

	/* Run a loaded program until TOHOST is written; expect 1. */
	task go;
		input [8*64-1:0] name;
		input integer limit;
		begin
			reset;
			n = 0;
			while (tohost == 0 && n < limit && faults == 0) begin
				@(negedge clk);
				n = n + 1;
			end
			if (tohost != 1) begin
				$display("FAIL %0s: tohost %0d (check %0d) faults %0d pc %h after %0d cycles",
					name, tohost, tohost >> 1, faults, dut.pc_e, n);
				errors = errors + 1;
			end
		end
	endtask

	reg [31:0] fpc [0:10];

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		/* rv32i and rv32m: data port answering at once, run held. */
		e0 = errors;
		load("rv32i");
		go("rv32i", 200000);
		$display("info: rv32i %0d instructions in %0d cycles", retired, cycles);
		if (errors == e0)
			$display("PASS atg_cpu_core.rv32i");
		e0 = errors;
		load("rv32m");
		go("rv32m", 400000);
		$display("info: rv32m %0d instructions in %0d cycles", retired, cycles);
		if (errors == e0)
			$display("PASS atg_cpu_core.rv32m");
		/* Interrupts, at once and with random waits. */
		e0 = errors;
		for (lat_mode = 0; lat_mode < 2; lat_mode = lat_mode + 1) begin
			load("irq");
			go("irq", 100000);
			if (irq_entries != irq_reqs || irq_reqs != 42) begin
				$display("FAIL irq: %0d requests, %0d entries", irq_reqs, irq_entries);
				errors = errors + 1;
			end
		end
		lat_mode = 0;
		if (errors == e0)
			$display("PASS atg_cpu_core.irq");
		/* Faults. */
		e0 = errors;
		for (i = 0; i < 11; i = i + 1)
			fpc[i] = 32'h100 + 16 * i;
		fpc[7] = 32'h0001_0000;
		fpc[10] = 32'h1A4;
		for (n = 0; n < 11; n = n + 1) begin
			load("fault");
			dmem[0] = n;
			reset;
			i = 0;
			while (faults == 0 && i < 1000) begin
				@(negedge clk);
				i = i + 1;
			end
			repeat (50) @(negedge clk);
			if (faults != 1 || last_fault_pc != fpc[n] || !stopped || i_en || d_valid ||
				tohost != 0) begin
				$display("FAIL fault case %0d: faults %0d pc %h want %h stopped %b tohost %0d",
					n, faults, last_fault_pc, fpc[n], stopped, tohost);
				errors = errors + 1;
			end
		end
		if (errors == e0)
			$display("PASS atg_cpu_core.fault");
		/* Stalls: random waits on the data port and run dropped at random. */
		e0 = errors;
		lat_mode = 1;
		run_mode = 1;
		load("rv32i");
		go("rv32i", 600000);
		load("rv32m");
		go("rv32m", 1200000);
		run_mode = 0;
		run = 1'b1;
		load("irq");
		go("irq", 200000);
		lat_mode = 0;
		if (errors == e0)
			$display("PASS atg_cpu_core.stall");
		if (errors == 0)
			$display("PASS atg_cpu_core");
		$finish;
	end
endmodule

`default_nettype wire
