/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_regs_tb: am_axi_regs on an AXI3-shaped port (12-bit IDs, 4-bit
 * lengths) in front of 16 test registers.  Checks single writes with byte
 * strobes and reads back, that a write's offset is the low 17 bits of the
 * address, a 4-beat burst read (every beat the burst's first register,
 * RLAST on the fourth), a 2-beat burst write (both beats to the first
 * register, one BRESP), and random host-side ready delays.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_regs_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	integer seed = 1;
	integer errors = 0;

	always #5 clk = !clk;

	reg [16:0] h_awaddr = 0;
	reg [11:0] h_awid = 0;
	reg h_awvalid = 1'b0;
	wire h_awready;
	reg [63:0] h_wdata = 0;
	reg [7:0] h_wstrb = 0;
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
	wire [63:0] h_rdata;
	wire [11:0] h_rid;
	wire [1:0] h_rresp;
	wire h_rlast;
	wire h_rvalid;
	reg h_rready = 1'b0;

	wire reg_wr;
	wire [16:0] reg_waddr;
	wire [31:0] reg_wdata;
	wire [3:0] reg_wstrb;
	wire reg_rd;
	wire [16:0] reg_raddr;
	reg [31:0] reg_rdata;

	am_axi_regs #(.ADDR_BITS(17), .ID_W(12), .LEN_W(4)) dut (
		.clk(clk), .rst_n(rst_n),
		.s_awaddr(h_awaddr), .s_awid(h_awid), .s_awvalid(h_awvalid), .s_awready(h_awready),
		.s_wdata(h_wdata), .s_wstrb(h_wstrb), .s_wlast(h_wlast), .s_wvalid(h_wvalid),
		.s_wready(h_wready), .s_bid(h_bid), .s_bresp(h_bresp), .s_bvalid(h_bvalid),
		.s_bready(h_bready), .s_araddr(h_araddr), .s_arid(h_arid), .s_arlen(h_arlen),
		.s_arvalid(h_arvalid), .s_arready(h_arready), .s_rdata(h_rdata), .s_rid(h_rid),
		.s_rresp(h_rresp), .s_rlast(h_rlast), .s_rvalid(h_rvalid), .s_rready(h_rready),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata)
	);

	/* The target: 16 registers at 0x10000 + 4 * n, 0 elsewhere; counts
	 * the reads and writes it sees. */
	reg [31:0] r [0:15];
	integer nwr = 0;
	integer nrd = 0;
	integer i;
	integer j;
	wire hit_w = reg_waddr[16:6] == 11'h400;
	wire hit_r = reg_raddr[16:6] == 11'h400;

	always @(posedge clk) begin
		if (reg_wr) begin
			nwr = nwr + 1;
			if (hit_w)
				for (j = 0; j < 4; j = j + 1)
					if (reg_wstrb[j])
						r[reg_waddr[5:2]][j*8 +: 8] <= reg_wdata[j*8 +: 8];
		end
		if (reg_rd) begin
			nrd = nrd + 1;
			reg_rdata <= hit_r ? r[reg_raddr[5:2]] : 32'd0;
		end else begin
			reg_rdata <= 32'hDEADBEEF;	/* only valid after reg_rd */
		end
	end

	`include "axi_host.vh"

	task expect;
		input [31:0] addr;
		input [31:0] want;
		reg [31:0] got;
		begin
			host_read(addr, got);
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL am_axi_regs: %h read %h, expected %h", addr, got, want);
			end
		end
	endtask

	task expect64;
		input [31:0] addr;
		input [63:0] want;
		reg [63:0] got;
		begin
			host_read64(addr, got);
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL am_axi_regs: 64-bit %h read %h, expected %h", addr, got, want);
			end
		end
	endtask

	integer beats;
	reg [31:0] v;

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		for (i = 0; i < 16; i = i + 1)
			r[i] = 0;
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		repeat (2) @(posedge clk);

		/* Singles, strobes, the 17-bit offset. */
		for (i = 0; i < 16; i = i + 1)
			host_write(32'h43C10000 + 4 * i, 32'h11110000 * i + i);
		for (i = 0; i < 16; i = i + 1)
			expect(32'h10000 + 4 * i, 32'h11110000 * i + i);
		host_write_strb(32'h10008, 32'hAABBCCDD, 4'b0101);
		expect(32'h10008, 32'h22BB00DD);
		expect(32'h00008, 32'd0);

		/* 64-bit access: writes r[0] and r[1] in 2 cycles, reads back 64 bits. */
		host_write64(32'h10000, 64'hFEDCBA98_76543210);
		expect64(32'h10000, 64'hFEDCBA98_76543210);
		expect(32'h10000, 32'h76543210);
		expect(32'h10004, 32'hFEDCBA98);

		/* A 4-beat burst read of register 3. */
		@(posedge clk);
		h_araddr <= 17'h1000C;
		h_arlen <= 4'd3;
		h_arid <= 12'h5A5;
		h_arvalid <= 1'b1;
		@(posedge clk);
		while (!h_arready)
			@(posedge clk);
		h_arvalid <= 1'b0;
		beats = 0;
		while (beats < 4) begin
			@(posedge clk);
			if (h_rvalid && h_rready) begin
				if (h_rdata[63:32] !== 32'h33330003 || h_rid !== 12'h5A5 ||
				    h_rlast !== (beats == 3)) begin
					errors = errors + 1;
					$display("FAIL am_axi_regs: burst beat %0d data %h last %b",
						beats, h_rdata, h_rlast);
				end
				beats = beats + 1;
			end
			h_rready <= ($unsigned($random(seed)) % 2) == 0;
		end
		h_rready <= 1'b0;
		repeat (3) @(posedge clk);
		if (h_rvalid) begin
			errors = errors + 1;
			$display("FAIL am_axi_regs: RVALID after the burst");
		end

		/* A 2-beat burst write to register 5: the second beat wins. */
		@(posedge clk);
		h_awaddr <= 17'h10014;
		h_awvalid <= 1'b1;
		@(posedge clk);
		while (!h_awready)
			@(posedge clk);
		h_awvalid <= 1'b0;
		h_wdata <= {32'h01010101, 32'd0};
		h_wstrb <= 8'hF0;
		h_wlast <= 1'b0;
		h_wvalid <= 1'b1;
		@(posedge clk);
		while (!h_wready)
			@(posedge clk);
		h_wdata <= {32'h02020202, 32'd0};
		h_wstrb <= 8'hF0;
		h_wlast <= 1'b1;
		@(posedge clk);
		while (!h_wready)
			@(posedge clk);
		h_wvalid <= 1'b0;
		h_bready <= 1'b1;
		@(posedge clk);
		while (!h_bvalid)
			@(posedge clk);
		h_bready <= 1'b0;
		@(posedge clk);
		if (h_bvalid) begin
			errors = errors + 1;
			$display("FAIL am_axi_regs: two BRESPs for one burst");
		end
		expect(32'h10014, 32'h02020202);

		/* Random traffic. */
		for (i = 0; i < 200; i = i + 1) begin
			v = $random(seed);
			host_write(32'h10000 + 4 * (i % 16), v);
			expect(32'h10000 + 4 * (i % 16), v);
		end

		if (errors == 0)
			$display("PASS am_axi_regs");
		$finish;
	end

	initial begin
		#1000000;
		$display("FAIL am_axi_regs: timeout");
		$finish;
	end
endmodule

`default_nettype wire
