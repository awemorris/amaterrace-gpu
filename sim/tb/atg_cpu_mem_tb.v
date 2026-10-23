/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_mem_tb: a small atg_cpu_mem (IMEM 64 words, DMEM 32 words) with
 * init files.  init: the files appear on the fetch, data and DMA ports.
 * ports: random traffic on the three ports at once (fetch, byte writes on
 * the data port, word writes and reads on the DMA port, IMEM writes by the
 * DMA) against a model; read latency 1, outputs held while disabled, the
 * address wraps, and x_rdata of an IMEM access is 0.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_mem_tb;
	localparam IWORDS = 64;
	localparam DWORDS = 32;

	reg clk = 1'b0;
	reg i_en = 1'b0, d_en = 1'b0, x_en = 1'b0, x_we = 1'b0, x_imem = 1'b0;
	reg [31:0] i_addr = 0, d_addr = 0, d_wdata = 0, x_addr = 0, x_wdata = 0;
	reg [3:0] d_we = 4'd0;
	wire [31:0] i_rdata, d_rdata, x_rdata;
	integer seed = 1;
	integer errors = 0;
	integer i, e0, k;
	reg [31:0] mi [0:IWORDS-1];
	reg [31:0] md [0:DWORDS-1];
	reg [31:0] want_i, want_d, want_x;

	always #5 clk = !clk;

	atg_cpu_mem #(
		.IMEM_WORDS(IWORDS), .DMEM_WORDS(DWORDS),
		.IMEM_INIT("sim/tb/cpu/mem_init_i.hex"), .DMEM_INIT("sim/tb/cpu/mem_init_d.hex")
	) dut (
		.clk(clk),
		.i_en(i_en), .i_addr(i_addr), .i_rdata(i_rdata),
		.d_en(d_en), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_rdata(d_rdata),
		.x_en(x_en), .x_we(x_we), .x_imem(x_imem), .x_addr(x_addr), .x_wdata(x_wdata),
		.x_rdata(x_rdata)
	);

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		for (i = 0; i < IWORDS; i = i + 1)
			mi[i] = 32'hA000_0000 + i * 32'h0101_0101;
		for (i = 0; i < DWORDS; i = i + 1)
			md[i] = 32'hD000_0000 + i * 32'h0003_0007;
		/* init: read every word through each port. */
		e0 = errors;
		for (i = 0; i < IWORDS; i = i + 1) begin
			@(negedge clk);
			i_en = 1'b1;
			i_addr = 4 * i;
			d_en = 1'b1;
			d_addr = 4 * (i % DWORDS);
			x_en = 1'b1;
			x_imem = 1'b0;
			x_addr = 4 * ((i + 5) % DWORDS);
			@(negedge clk);
			i_en = 1'b0;
			d_en = 1'b0;
			x_en = 1'b0;
			if (i_rdata !== mi[i] || d_rdata !== md[i % DWORDS] || x_rdata !== md[(i + 5) % DWORDS]) begin
				$display("FAIL init %0d: %h %h %h", i, i_rdata, d_rdata, x_rdata);
				errors = errors + 1;
			end
		end
		if (errors == e0)
			$display("PASS atg_cpu_mem.init");
		/* ports: random concurrent traffic. */
		e0 = errors;
		want_i = 32'hx;
		want_d = 32'hx;
		want_x = 32'hx;
		for (k = 0; k < 4000; k = k + 1) begin
			@(negedge clk);
			/* Outputs of the previous cycle's reads (held if no read). */
			if (want_i !== 32'hx && i_rdata !== want_i) begin
				$display("FAIL fetch %h want %h", i_rdata, want_i);
				errors = errors + 1;
			end
			if (want_d !== 32'hx && d_rdata !== want_d) begin
				$display("FAIL data %h want %h", d_rdata, want_d);
				errors = errors + 1;
			end
			if (want_x !== 32'hx && x_rdata !== want_x) begin
				$display("FAIL dma %h want %h", x_rdata, want_x);
				errors = errors + 1;
			end
			i_en = $random(seed);
			i_addr = {$random(seed)} & 32'hFFFF_FFFC;	/* wraps */
			d_en = $random(seed);
			d_we = $random(seed);
			d_addr = {$random(seed)} & 32'hFFFF_FFFC;
			d_wdata = $random(seed);
			x_en = $random(seed);
			x_we = $random(seed);
			x_imem = $random(seed);
			x_addr = {$random(seed)} & 32'hFFFF_FFFC;
			/* The DMA never writes the word the data port uses in the same cycle. */
			if (!x_imem && (x_addr[6:2] == d_addr[6:2]))
				x_addr = x_addr ^ 32'h4;
			/* Nor IMEM words being fetched in the same cycle. */
			if (x_imem && (x_addr[7:2] == i_addr[7:2]))
				x_addr = x_addr ^ 32'h4;
			x_wdata = $random(seed);
			/* Model: read-first, then write. */
			if (i_en)
				want_i = mi[i_addr[7:2]];
			if (d_en) begin
				want_d = md[d_addr[6:2]];
				if (d_we[0]) md[d_addr[6:2]][7:0] = d_wdata[7:0];
				if (d_we[1]) md[d_addr[6:2]][15:8] = d_wdata[15:8];
				if (d_we[2]) md[d_addr[6:2]][23:16] = d_wdata[23:16];
				if (d_we[3]) md[d_addr[6:2]][31:24] = d_wdata[31:24];
			end
			if (x_en) begin
				if (x_imem) begin
					want_x = 32'd0;
					if (x_we)
						mi[x_addr[7:2]] = x_wdata;
				end else begin
					want_x = md[x_addr[6:2]];
					if (x_we)
						md[x_addr[6:2]] = x_wdata;
				end
			end
		end
		if (errors == e0)
			$display("PASS atg_cpu_mem.ports");
		if (errors == 0)
			$display("PASS atg_cpu_mem");
		$finish;
	end
endmodule

`default_nettype wire
