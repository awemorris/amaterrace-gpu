/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_master_tb: am_axi_master against axi_mem (random ready and
 * latency, protocol checks) in two shapes, 32-byte lines on
 * 64-bit AXI (4 beats) and the KC705's (64-byte lines, 512-bit AXI,
 * 1 beat).  Random line reads and byte-masked writes are compared with a
 * reference copy of memory; reads and writes must each come back in order
 * with their user bits; addresses in the error region answer error.
 * Quiesce: with halt raised at random moments req_ready stays 0, idle
 * comes within a bound, and the traffic resumes after halt falls.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_master_harness #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter DATA_W = 64,
	parameter NREQ = 2000,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	localparam LB = LINE_BYTES * 8;
	localparam NLINES = 64;		/* lines under test, from 0 */
	localparam [31:0] ERR_BASE = 32'h00100000;

	reg halt = 1'b0;
	wire idle;
	reg req_valid = 1'b0;
	wire req_ready;
	reg req_write = 1'b0;
	reg [31-LINE_SHIFT:0] req_line = 0;
	reg [LINE_BYTES-1:0] req_be = 0;
	reg [LB-1:0] req_wdata = 0;
	reg [15:0] req_user = 0;
	wire rsp_valid;
	wire rsp_write;
	wire [15:0] rsp_user;
	wire [LB-1:0] rsp_rdata;
	wire rsp_error;

	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] wdata, rdata;
	wire [DATA_W/8-1:0] wstrb;

	am_axi_master #(
		.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W), .UW(16)
	) dut (
		.clk(clk), .rst_n(rst_n), .halt(halt), .idle(idle),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_user(req_user),
		.req_id(1'b0), .req_key(8'd0), .m_awid(), .m_bid(1'b0), .m_arid(), .m_rid(1'b0),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_user(rsp_user),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready)
	);

	axi_mem #(.DATA_W(DATA_W), .MEM_BYTES(1 << 16), .ERR_BASE(ERR_BASE), .SEED(SEED)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	/* The reference, per line; the expected data of each outstanding read
	 * by its user number. */
	reg [LB-1:0] ref [0:NLINES-1];
	integer rd_pend [0:NLINES-1];
	integer wr_pend [0:NLINES-1];
	reg [LB-1:0] rd_expect [0:255];
	reg rd_experr [0:255];
	reg [7:0] rd_line [0:255];
	reg wr_experr [0:255];
	reg [7:0] wr_line [0:255];
	integer seed;
	integer issued, answered;
	integer rd_seq, wr_seq;		/* user numbers given */
	integer rd_next, wr_next;	/* user numbers expected back */
	integer n, b, line, halt_wait;
	reg is_err;
	reg wr;
	reg [LB-1:0] mask;

	function [LB-1:0] be_mask;
		input [LINE_BYTES-1:0] be;
		integer k;
		begin
			for (k = 0; k < LINE_BYTES; k = k + 1)
				be_mask[k*8 +: 8] = {8{be[k]}};
		end
	endfunction

	/* Responses. */
	always @(posedge clk) begin
		if (rst_n && rsp_valid) begin
			answered = answered + 1;
			if (rsp_write) begin
				if (rsp_user[15] !== 1'b1 || rsp_user[7:0] !== wr_next[7:0]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: write response %h, expected %h", rsp_user, wr_next);
				end
				if (rsp_error !== wr_experr[wr_next % 256]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: write error %b", rsp_error);
				end
				if (!wr_experr[wr_next % 256])
					wr_pend[wr_line[wr_next % 256]] = wr_pend[wr_line[wr_next % 256]] - 1;
				wr_next = wr_next + 1;
			end else begin
				if (rsp_user[15] !== 1'b0 || rsp_user[7:0] !== rd_next[7:0]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: read response %h, expected %h", rsp_user, rd_next);
				end
				if (rsp_error !== rd_experr[rd_next % 256]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: read error %b", rsp_error);
				end else if (!rsp_error && rsp_rdata !== rd_expect[rd_next % 256]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: read data %h, expected %h", rsp_rdata,
						rd_expect[rd_next % 256]);
				end
				if (!rd_experr[rd_next % 256])
					rd_pend[rd_line[rd_next % 256]] = rd_pend[rd_line[rd_next % 256]] - 1;
				rd_next = rd_next + 1;
			end
		end
	end

	initial begin
		finished = 1'b0;
		errors = 0;
		seed = SEED;
		issued = 0;
		answered = 0;
		rd_seq = 0;
		wr_seq = 0;
		rd_next = 0;
		wr_next = 0;
		for (n = 0; n < NLINES; n = n + 1) begin
			ref[n] = {LB{1'b0}};
			rd_pend[n] = 0;
			wr_pend[n] = 0;
		end
		wait (rst_n);
		@(posedge clk);
		while (issued < NREQ) begin
			/* Sometimes: quiesce. */
			if ($unsigned($random(seed)) % 200 == 0) begin
				halt <= 1'b1;
				req_valid <= 1'b0;
				halt_wait = 0;
				@(posedge clk);
				while (!idle) begin
					if (req_ready) begin
						errors = errors + 1;
						$display("FAIL am_axi_master: req_ready under halt");
					end
					halt_wait = halt_wait + 1;
					if (halt_wait > 400) begin
						errors = errors + 1;
						$display("FAIL am_axi_master: no idle after halt");
						halt_wait = -100000;
					end
					@(posedge clk);
				end
				if (rd_seq != rd_next || wr_seq != wr_next) begin
					errors = errors + 1;
					$display("FAIL am_axi_master: idle with responses owed");
				end
				halt <= 1'b0;
				@(posedge clk);
			end
			/* A request on a line with nothing outstanding against it. */
			line = $unsigned($random(seed)) % NLINES;
			is_err = ($unsigned($random(seed)) % 50) == 0;
			wr = $random(seed);
			if (wr ? (rd_pend[line] != 0 || wr_pend[line] > 2) : (wr_pend[line] != 0)) begin
				@(posedge clk);
			end else begin
				req_write <= wr;
				req_line <= is_err ? (ERR_BASE >> LINE_SHIFT) + line : line;
				for (b = 0; b < LINE_BYTES; b = b + 1)
					req_be[b] <= $random(seed);
				for (b = 0; b < LB / 32; b = b + 1)
					req_wdata[b*32 +: 32] <= $random(seed);
				req_user <= wr ? {8'h80, wr_seq[7:0]} : {8'h00, rd_seq[7:0]};
				req_valid <= 1'b1;
				@(posedge clk);
				while (!req_ready)
					@(posedge clk);
				/* Taken at this edge. */
				if (wr) begin
					wr_experr[wr_seq % 256] = is_err;
					wr_line[wr_seq % 256] = line;
					if (!is_err) begin
						mask = be_mask(req_be);
						ref[line] = (ref[line] & ~mask) | (req_wdata & mask);
						wr_pend[line] = wr_pend[line] + 1;
					end
					wr_seq = wr_seq + 1;
				end else begin
					rd_experr[rd_seq % 256] = is_err;
					rd_line[rd_seq % 256] = line;
					rd_expect[rd_seq % 256] = ref[line];
					if (!is_err)
						rd_pend[line] = rd_pend[line] + 1;
					rd_seq = rd_seq + 1;
				end
				issued = issued + 1;
				req_valid <= 1'b0;
				if ($unsigned($random(seed)) % 2)
					@(posedge clk);
			end
		end
		req_valid <= 1'b0;
		n = 0;
		while (answered < issued && n < 1000) begin
			@(posedge clk);
			n = n + 1;
		end
		if (answered != issued) begin
			errors = errors + 1;
			$display("FAIL am_axi_master: %0d requests, %0d responses", issued, answered);
		end
		@(posedge clk);
		if (!idle) begin
			errors = errors + 1;
			$display("FAIL am_axi_master: not idle at the end");
		end
		errors = errors + mem.errors;
		finished = 1'b1;
	end
endmodule

module am_axi_master_deep_harness (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	localparam LINE_BYTES = 64;
	localparam LINE_SHIFT = 6;
	localparam DATA_W = 512;
	localparam LB = LINE_BYTES * 8;
	localparam NREQ = 32;
	localparam LATENCY = 60;

	reg req_valid;
	wire req_ready;
	reg [31-LINE_SHIFT:0] req_line;
	reg [15:0] req_user;
	wire rsp_valid;
	wire rsp_write;
	wire [15:0] rsp_user;
	wire [LB-1:0] rsp_rdata;
	wire rsp_error;

	wire [31:0] araddr;
	wire [7:0] arlen;
	wire [2:0] arsize, arprot;
	wire [1:0] arburst, rresp;
	wire [3:0] arcache;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [DATA_W-1:0] rdata;

	am_axi_master #(
		.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W),
		.UW(16), .OUTSTANDING_LOG2(5), .NID(1), .ID_W(1), .KEY_W(8)
	) dut (
		.clk(clk), .rst_n(rst_n), .halt(1'b0), .idle(),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(1'b0),
		.req_line(req_line), .req_be({LINE_BYTES{1'b0}}), .req_wdata({LB{1'b0}}),
		.req_user(req_user), .req_id(1'b0), .req_key(8'd0),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_user(rsp_user),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.m_awid(), .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(),
		.m_awcache(), .m_awprot(), .m_awvalid(), .m_awready(1'b1),
		.m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(), .m_wready(1'b1),
		.m_bid(1'b0), .m_bresp(2'b00), .m_bvalid(1'b0), .m_bready(),
		.m_arid(), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize),
		.m_arburst(arburst), .m_arcache(arcache), .m_arprot(arprot),
		.m_arvalid(arvalid), .m_arready(arready),
		.m_rid(1'b0), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast),
		.m_rvalid(rvalid), .m_rready(rready)
	);

	/* 60-cycle latency AXI responder */
	assign arready = 1'b1;
	reg [31:0] ar_fifo_addr [0:63];
	integer ar_wp, ar_rp;
	integer timer [0:63];
	integer count;

	reg r_v;
	reg [DATA_W-1:0] r_d;
	assign rvalid = r_v;
	assign rlast = 1'b1;
	assign rresp = 2'b00;
	assign rdata = r_d;

	always @(posedge clk) begin
		if (!rst_n) begin
			ar_wp <= 0;
			ar_rp <= 0;
			r_v <= 1'b0;
			r_d <= {DATA_W{1'b0}};
		end else begin
			if (arvalid && arready) begin
				ar_fifo_addr[ar_wp] <= araddr;
				timer[ar_wp] <= LATENCY;
				ar_wp <= ar_wp + 1;
			end

			for (count = 0; count < 64; count = count + 1) begin
				if (count >= ar_rp && count < ar_wp) begin
					if (timer[count] > 0)
						timer[count] <= timer[count] - 1;
				end
			end

			if (r_v && rready)
				r_v <= 1'b0;

			if ((!r_v || rready) && ar_rp < ar_wp) begin
				if (timer[ar_rp] == 0) begin
					r_v <= 1'b1;
					r_d <= {16{ar_fifo_addr[ar_rp]}};
					ar_rp <= ar_rp + 1;
				end
			end
		end
	end

	integer i;
	integer issue_cycles, total_cycles;
	integer rsp_count;
	reg [LB-1:0] exp_data;

	initial begin
		finished = 1'b0;
		errors = 0;
		req_valid = 1'b0;
		req_line = 0;
		req_user = 0;
		issue_cycles = 0;
		total_cycles = 0;
		rsp_count = 0;

		wait (rst_n);
		@(posedge clk);

		// Issue 32 requests back-to-back
		for (i = 0; i < NREQ; i = i + 1) begin
			req_valid <= 1'b1;
			req_line <= i + 10;
			req_user <= 16'hA000 | i;
			@(posedge clk);
			issue_cycles = issue_cycles + 1;
			while (!req_ready) begin
				@(posedge clk);
				issue_cycles = issue_cycles + 1;
			end
		end
		req_valid <= 1'b0;

		if (issue_cycles != NREQ) begin
			errors = errors + 1;
			$display("FAIL am_axi_master.deep_32: expected 32 issue cycles, took %0d", issue_cycles);
		end

		while (rsp_count < NREQ) begin
			@(posedge clk);
			total_cycles = total_cycles + 1;
		end

		@(posedge clk);
		if (errors == 0) begin
			$display("PASS am_axi_master.deep_32 (issued 32 reads in %0d cycles, 32 responses in %0d cycles)",
				issue_cycles, total_cycles);
		end
		finished = 1'b1;
	end

	reg [31:0] exp_word;
	always @(posedge clk) begin
		if (rst_n && rsp_valid) begin
			if (rsp_user !== (16'hA000 | rsp_count)) begin
				errors = errors + 1;
				$display("FAIL am_axi_master.deep_32: rsp_user mismatch %h vs %h",
					rsp_user, (16'hA000 | rsp_count));
			end
			exp_word = (rsp_count + 10) << LINE_SHIFT;
			exp_data = {16{exp_word}};
			if (rsp_rdata !== exp_data) begin
				errors = errors + 1;
				$display("FAIL am_axi_master.deep_32: rsp_rdata mismatch %h vs %h",
					rsp_rdata, exp_data);
			end
			if (rsp_error) begin
				errors = errors + 1;
				$display("FAIL am_axi_master.deep_32: unexpected rsp_error");
			end
			rsp_count = rsp_count + 1;
		end
	end
endmodule

module am_axi_master_reorder_harness (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	localparam LINE_BYTES = 32;
	localparam LINE_SHIFT = 5;
	localparam DATA_W = 64;
	localparam LB = LINE_BYTES * 8;
	localparam NREQ = 16;

	reg req_valid;
	wire req_ready;
	reg req_write;
	reg [31-LINE_SHIFT:0] req_line;
	reg [LINE_BYTES-1:0] req_be;
	reg [LB-1:0] req_wdata;
	reg [15:0] req_user;
	reg req_id;
	reg [7:0] req_key;

	wire rsp_valid;
	wire rsp_write;
	wire [15:0] rsp_user;
	wire [LB-1:0] rsp_rdata;
	wire rsp_error;

	wire m_awid, m_bid, m_arid, m_rid;
	wire [31:0] m_awaddr, m_araddr;
	wire [7:0] m_awlen, m_arlen;
	wire [2:0] m_awsize, m_arsize, m_awprot, m_arprot;
	wire [1:0] m_awburst, m_arburst;
	wire [3:0] m_awcache, m_arcache;
	wire m_awvalid, m_awready, m_wlast, m_wvalid, m_wready;
	wire [DATA_W-1:0] m_wdata, m_rdata;
	wire [DATA_W/8-1:0] m_wstrb;
	wire [1:0] m_bresp, m_rresp;
	wire m_bvalid, m_bready;
	wire m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;

	am_axi_master #(
		.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .DATA_W(DATA_W),
		.UW(16), .OUTSTANDING_LOG2(5), .NID(2), .ID_W(1), .KEY_W(8)
	) dut (
		.clk(clk), .rst_n(rst_n), .halt(1'b0), .idle(),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata),
		.req_user(req_user), .req_id(req_id), .req_key(req_key),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_user(rsp_user),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
		.m_awburst(m_awburst), .m_awcache(m_awcache), .m_awprot(m_awprot),
		.m_awvalid(m_awvalid), .m_awready(m_awready),
		.m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
		.m_wvalid(m_wvalid), .m_wready(m_wready),
		.m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
		.m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
		.m_arburst(m_arburst), .m_arcache(m_arcache), .m_arprot(m_arprot),
		.m_arvalid(m_arvalid), .m_arready(m_arready),
		.m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
		.m_rvalid(m_rvalid), .m_rready(m_rready)
	);

	assign m_awready = 1'b1;
	assign m_wready = 1'b1;
	assign m_bresp = 2'b00;
	assign m_bvalid = 1'b0;
	assign m_arready = 1'b1;

	reg [31:0] q0_addr [0:31];
	reg [31:0] q1_addr [0:31];
	integer q0_wp, q0_rp, q1_wp, q1_rp;

	always @(posedge clk) begin
		if (!rst_n) begin
			q0_wp <= 0; q0_rp <= 0;
			q1_wp <= 0; q1_rp <= 0;
		end else if (m_arvalid && m_arready) begin
			if (m_arid == 1'b0) begin
				q0_addr[q0_wp] <= m_araddr;
				q0_wp <= q0_wp + 1;
			end else begin
				q1_addr[q1_wp] <= m_araddr;
				q1_wp <= q1_wp + 1;
			end
		end
	end

	reg r_v;
	reg r_id_reg;
	reg [63:0] r_data_reg;
	reg [1:0] beat;
	reg r_last_reg;

	assign m_rvalid = r_v;
	assign m_rid = r_id_reg;
	assign m_rdata = r_data_reg;
	assign m_rresp = 2'b00;
	assign m_rlast = r_last_reg;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_v <= 1'b0;
			r_id_reg <= 1'b0;
			r_data_reg <= 64'd0;
			beat <= 2'd0;
			r_last_reg <= 1'b0;
		end else begin
			if (r_v && m_rready) begin
				if (r_last_reg) begin
					r_v <= 1'b0;
					beat <= 2'd0;
				end else begin
					beat <= beat + 1;
					r_last_reg <= (beat == 2'd2);
					r_data_reg <= {32'hBEEF0000 | {14'd0, beat + 2'd1}, (r_id_reg ? q1_addr[q1_rp] : q0_addr[q0_rp])};
				end
			end

			if (!r_v || (r_v && m_rready && r_last_reg)) begin
				if (q1_rp < q1_wp) begin
					r_v <= 1'b1;
					r_id_reg <= 1'b1;
					beat <= 2'd0;
					r_last_reg <= 1'b0;
					r_data_reg <= {32'hBEEF0000, q1_addr[q1_rp]};
					q1_rp <= q1_rp + 1;
				end else if (q0_rp < q0_wp) begin
					r_v <= 1'b1;
					r_id_reg <= 1'b0;
					beat <= 2'd0;
					r_last_reg <= 1'b0;
					r_data_reg <= {32'hBEEF0000, q0_addr[q0_rp]};
					q0_rp <= q0_rp + 1;
				end else begin
					r_v <= 1'b0;
				end
			end
		end
	end

	integer k;
	integer rsp0_cnt, rsp1_cnt;

	initial begin
		finished = 1'b0;
		errors = 0;
		req_valid = 1'b0;
		req_write = 1'b0;
		req_line = 0;
		req_be = {LINE_BYTES{1'b1}};
		req_wdata = 0;
		req_user = 0;
		req_id = 0;
		req_key = 0;
		rsp0_cnt = 0;
		rsp1_cnt = 0;

		wait (rst_n);
		@(posedge clk);

		for (k = 0; k < NREQ; k = k + 1) begin
			req_valid <= 1'b1;
			req_id <= 1'b0;
			req_key <= 8'd1;
			req_line <= 32'h100 + k;
			req_user <= 16'h0000 | k;
			@(posedge clk);
			while (!req_ready) @(posedge clk);

			req_valid <= 1'b1;
			req_id <= 1'b1;
			req_key <= 8'd2;
			req_line <= 32'h200 + k;
			req_user <= 16'h1000 | k;
			@(posedge clk);
			while (!req_ready) @(posedge clk);
		end
		req_valid <= 1'b0;

		while (rsp0_cnt < NREQ || rsp1_cnt < NREQ) begin
			@(posedge clk);
		end

		@(posedge clk);
		if (errors == 0) begin
			$display("PASS am_axi_master.reorder (NID=2 reordered response verified: 16 on ID0, 16 on ID1)");
		end
		finished = 1'b1;
	end

	always @(posedge clk) begin
		if (rst_n && rsp_valid) begin
			if (rsp_user[15:12] == 4'h0) begin
				if (rsp_user[7:0] !== rsp0_cnt[7:0]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master.reorder: ID 0 user mismatch got %h want %h",
						rsp_user, rsp0_cnt);
				end
				rsp0_cnt = rsp0_cnt + 1;
			end else if (rsp_user[15:12] == 4'h1) begin
				if (rsp_user[7:0] !== rsp1_cnt[7:0]) begin
					errors = errors + 1;
					$display("FAIL am_axi_master.reorder: ID 1 user mismatch got %h want %h",
						rsp_user, rsp1_cnt);
				end
				rsp1_cnt = rsp1_cnt + 1;
			end else begin
				errors = errors + 1;
				$display("FAIL am_axi_master.reorder: unknown response tag %h", rsp_user);
			end
		end
	end
endmodule

module am_axi_master_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	wire done_l32, done_kc705, done_deep, done_reorder;
	wire [31:0] err_l32, err_kc705, err_deep, err_reorder;

	always #5 clk = !clk;

	am_axi_master_harness #(.LINE_BYTES(32), .LINE_SHIFT(5), .DATA_W(64), .SEED(11)) l32 (
		.clk(clk), .rst_n(rst_n), .finished(done_l32), .errors(err_l32)
	);
	am_axi_master_harness #(.LINE_BYTES(64), .LINE_SHIFT(6), .DATA_W(512), .SEED(23)) kc705 (
		.clk(clk), .rst_n(rst_n), .finished(done_kc705), .errors(err_kc705)
	);
	am_axi_master_deep_harness deep (
		.clk(clk), .rst_n(rst_n), .finished(done_deep), .errors(err_deep)
	);
	am_axi_master_reorder_harness reorder (
		.clk(clk), .rst_n(rst_n), .finished(done_reorder), .errors(err_reorder)
	);

	initial begin
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		wait (done_l32 && done_kc705 && done_deep && done_reorder);
		if (err_l32 == 0 && err_kc705 == 0 && err_deep == 0 && err_reorder == 0)
			$display("PASS am_axi_master");
		else
			$display("FAIL am_axi_master: %0d + %0d + %0d + %0d errors",
				err_l32, err_kc705, err_deep, err_reorder);
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL am_axi_master: timeout");
		$finish;
	end
endmodule

`default_nettype wire
