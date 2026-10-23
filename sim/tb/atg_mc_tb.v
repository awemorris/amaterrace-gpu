/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_tb: atg_mc in two shapes, each on its own axi_mem: (A) three
 * clients (client 0 with the priority bit, 1 and 2 taking turns) in a
 * two-level router tree; (B) five clients with client 4 one hop from the
 * root (ROOT_CLIENT, the DC's place) and clients 0 and 4 with the priority
 * bit, and a 1 MiB VRAM window (VRAM_AW 20), where some refused requests
 * are outside the window as well.  Each client runs random reads and
 * byte-masked writes on its own lines and checks its responses (data
 * against a reference, tags in order per direction).  Some requests fall
 * outside the aperture: they must get an error response without reaching
 * memory, and the MC's fault pulse must name the client, the line and the
 * direction.  Quiesce is raised at random: no new packet may start under it
 * and axi_idle must come within a bound.  At the end every client must
 * have been granted.  Responses are routed per client through the tree: a
 * response that reached the wrong client fails the data or the order
 * check of the receiver.  The router's priority and turn-taking are
 * checked in detail by atg_rt_tb.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_client #(
	parameter ID = 0,
	parameter NREQ = 600,
	parameter SEED = 1,
	parameter FAR = 0	/* some refused requests also outside a 1 MiB VRAM window */
) (
	input wire clk,
	input wire rst_n,
	input wire stop,		/* quiesce in the TB: do not count stalls */
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [26:0] req_line,
	output reg [31:0] req_be,
	output reg [255:0] req_wdata,
	output reg [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [255:0] rsp_rdata,
	input wire rsp_error,
	output reg finished,
	output integer errors,
	output integer bad_issued
);
	localparam NLINES = 32;
	localparam [26:0] BASE = 27'h100 + ID * NLINES;	/* inside the aperture */
	localparam [26:0] OUTSIDE = 27'h7000 + ID * NLINES;

	reg [255:0] ref [0:NLINES-1];
	integer rd_pend [0:NLINES-1];
	integer wr_pend [0:NLINES-1];
	reg [255:0] rd_expect [0:127];
	reg rd_bad [0:127];
	reg [4:0] rd_ln [0:127];
	reg wr_bad [0:127];
	reg [4:0] wr_ln [0:127];
	integer rd_seq, wr_seq, rd_next, wr_next, issued, answered;
	integer seed, n, b, line;
	reg wr, bad;
	reg [255:0] mask;

	/* Responses: the good ones in order per direction; a refused
	 * request's error may overtake (atg_mc: it is a device fault). */
	reg rd_done [0:127];
	reg wr_done [0:127];
	integer s0, found;

	always @(posedge clk) begin
		if (rst_n && rsp_valid) begin
			answered = answered + 1;
			found = -1;
			if (rsp_write) begin
				for (s0 = wr_next; s0 < wr_seq; s0 = s0 + 1)
					if (found < 0 && !wr_done[s0 % 128] && wr_bad[s0 % 128] == rsp_error &&
					    (rsp_error ? rsp_tag[6:0] == s0[6:0] : 1'b1))
						found = s0;
				if (found < 0 || rsp_tag !== {1'b1, found[6:0]}) begin
					errors = errors + 1;
					$display("FAIL atg_mc: client %0d write tag %h error %b, expected %h", ID,
						rsp_tag, rsp_error, found);
				end else begin
					wr_done[found % 128] = 1'b1;
					if (!rsp_error)
						wr_pend[wr_ln[found % 128]] = wr_pend[wr_ln[found % 128]] - 1;
				end
				while (wr_next < wr_seq && wr_done[wr_next % 128])
					wr_next = wr_next + 1;
			end else begin
				for (s0 = rd_next; s0 < rd_seq; s0 = s0 + 1)
					if (found < 0 && !rd_done[s0 % 128] && rd_bad[s0 % 128] == rsp_error &&
					    (rsp_error ? rsp_tag[6:0] == s0[6:0] : 1'b1))
						found = s0;
				if (found < 0 || rsp_tag !== {1'b0, found[6:0]}) begin
					errors = errors + 1;
					$display("FAIL atg_mc: client %0d read tag %h error %b, expected %h", ID,
						rsp_tag, rsp_error, found);
				end else begin
					if (!rsp_error && rsp_rdata !== rd_expect[found % 128]) begin
						errors = errors + 1;
						$display("FAIL atg_mc: client %0d read data", ID);
					end
					rd_done[found % 128] = 1'b1;
					if (!rsp_error)
						rd_pend[rd_ln[found % 128]] = rd_pend[rd_ln[found % 128]] - 1;
				end
				while (rd_next < rd_seq && rd_done[rd_next % 128])
					rd_next = rd_next + 1;
			end
		end
	end

	initial begin
		req_valid = 1'b0;
		req_write = 1'b0;
		req_line = 0;
		req_be = 0;
		req_wdata = 0;
		req_tag = 0;
		finished = 1'b0;
		errors = 0;
		bad_issued = 0;
		seed = SEED;
		rd_seq = 0;
		wr_seq = 0;
		rd_next = 0;
		wr_next = 0;
		issued = 0;
		answered = 0;
		for (n = 0; n < NLINES; n = n + 1) begin
			ref[n] = 0;
			rd_pend[n] = 0;
			wr_pend[n] = 0;
		end
		wait (rst_n);
		@(posedge clk);
		while (issued < NREQ) begin
			line = $unsigned($random(seed)) % NLINES;
			bad = ($unsigned($random(seed)) % 40) == 0;
			wr = $random(seed);
			if (rd_seq - rd_next > 100 || wr_seq - wr_next > 100 ||
			    (wr ? (rd_pend[line] != 0) : (wr_pend[line] != 0))) begin
				@(posedge clk);
			end else begin
				req_write <= wr;
				/* With FAR, half of the refused requests alias a good line of
				 * the 1 MiB window: only the window check refuses them. */
				req_line <= (bad ? ((FAR != 0 && line[0]) ? BASE + 27'h8000 : OUTSIDE) : BASE) +
					line;
				for (b = 0; b < 32; b = b + 1)
					req_be[b] <= $random(seed);
				for (b = 0; b < 8; b = b + 1)
					req_wdata[b*32 +: 32] <= $random(seed);
				req_tag <= wr ? {1'b1, wr_seq[6:0]} : {1'b0, rd_seq[6:0]};
				req_valid <= 1'b1;
				@(posedge clk);
				while (!req_ready)
					@(posedge clk);
				if (wr) begin
					wr_bad[wr_seq % 128] = bad;
					wr_done[wr_seq % 128] = 1'b0;
					wr_ln[wr_seq % 128] = line;
					if (!bad) begin
						for (b = 0; b < 32; b = b + 1)
							mask[b*8 +: 8] = {8{req_be[b]}};
						ref[line] = (ref[line] & ~mask) | (req_wdata & mask);
						wr_pend[line] = wr_pend[line] + 1;
					end
					wr_seq = wr_seq + 1;
				end else begin
					rd_bad[rd_seq % 128] = bad;
					rd_done[rd_seq % 128] = 1'b0;
					rd_ln[rd_seq % 128] = line;
					rd_expect[rd_seq % 128] = ref[line];
					if (!bad)
						rd_pend[line] = rd_pend[line] + 1;
					rd_seq = rd_seq + 1;
				end
				if (bad)
					bad_issued = bad_issued + 1;
				issued = issued + 1;
				req_valid <= 1'b0;
			end
		end
		n = 0;
		while (answered < issued && n < 2000) begin
			@(posedge clk);
			n = n + 1;
		end
		if (answered != issued) begin
			errors = errors + 1;
			$display("FAIL atg_mc: client %0d: %0d requests, %0d responses", ID, issued, answered);
		end
		finished = 1'b1;
	end

	wire unused_ok = &{1'b0, stop};
endmodule

module atg_mc_case #(
	parameter N = 3,
	parameter [N-1:0] HIGH = 1,
	parameter ROOT = -1,
	parameter VRAM_AW = 32,
	parameter FAR = 0,
	parameter SEED0 = 3
) (
	input wire clk,
	output reg done,
	output integer errors
);
	reg rst_n = 1'b0;
	reg quiesce = 1'b0;
	integer seed;

	wire [N-1:0] c_req_valid, c_req_ready, c_req_write;
	wire [N*27-1:0] c_req_line;
	wire [N*32-1:0] c_req_be;
	wire [N*256-1:0] c_req_wdata;
	wire [N*8-1:0] c_req_tag;
	wire [N-1:0] rsp_valid, rsp_write, rsp_error;
	wire [N*8-1:0] rsp_tag;
	wire [N*256-1:0] rsp_rdata;
	wire axi_idle, fault, fault_write;
	wire [7:0] fault_client;
	wire [31:0] fault_addr;
	wire [N-1:0] fin;
	wire [31:0] cerr [0:N-1];
	wire [31:0] cbad [0:N-1];

	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [63:0] wdata, rdata;
	wire [7:0] wstrb;

	atg_mc #(.NCLIENT(N), .HIGH_MASK(HIGH), .ROOT_CLIENT(ROOT), .VRAM_AW(VRAM_AW)) dut (
		.clk(clk), .rst_n(rst_n),
		.c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write),
		.c_req_line(c_req_line), .c_req_be(c_req_be), .c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write),
		.rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.quiesce(quiesce), .flush(1'b0),
		.aperture_base(32'h00002000), .aperture_limit(32'h00080000),
		.axi_idle(axi_idle), .fault(fault), .fault_client(fault_client),
		.fault_addr(fault_addr), .fault_write(fault_write),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready)
	);

	axi_mem #(.DATA_W(64), .MEM_BYTES(1 << 20), .SEED(9)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	genvar g;
	generate
		for (g = 0; g < N; g = g + 1) begin : cl
			atg_mc_client #(.ID(g), .SEED(SEED0 * 100 + g), .FAR(FAR)) c (
				.clk(clk), .rst_n(rst_n), .stop(quiesce),
				.req_valid(c_req_valid[g]), .req_ready(c_req_ready[g]),
				.req_write(c_req_write[g]), .req_line(c_req_line[g*27 +: 27]),
				.req_be(c_req_be[g*32 +: 32]), .req_wdata(c_req_wdata[g*256 +: 256]),
				.req_tag(c_req_tag[g*8 +: 8]), .rsp_valid(rsp_valid[g]),
				.rsp_write(rsp_write[g]), .rsp_tag(rsp_tag[g*8 +: 8]),
				.rsp_rdata(rsp_rdata[g*256 +: 256]),
				.rsp_error(rsp_error[g]), .finished(fin[g]), .errors(cerr[g]),
				.bad_issued(cbad[g])
			);
		end
	endgenerate

	/* Grants, faults, quiesce. */
	integer grants [0:N-1];
	integer faults [0:N-1];
	integer wait_idle;
	integer q_taken [0:N-1];
	integer k;
	reg [26:0] line_k;
	initial for (k = 0; k < N; k = k + 1) q_taken[k] = 0;

	always @(posedge clk) begin
		if (rst_n) begin
			/* Under quiesce no new packet starts at a leaf: a client has at
			 * most one request taken (a write whose header was already in
			 * the tree); the tree drains. */
			for (k = 0; k < N; k = k + 1) begin
				if (c_req_ready[k] && c_req_valid[k]) begin
					grants[k] = grants[k] + 1;
					if (quiesce)
						q_taken[k] = q_taken[k] + 1;
				end
				if (!quiesce)
					q_taken[k] = 0;
				if (q_taken[k] > 1) begin
					errors = errors + 1;
					$display("FAIL atg_mc: client %0d taken twice under quiesce", k);
					q_taken[k] = 0;
				end
			end
			/* A refused request: the fault comes one cycle after its
			 * grant and names it. */
			if (fault) begin
				if (fault_client >= N) begin
					errors = errors + 1;
					$display("FAIL atg_mc: fault client %0d", fault_client);
				end else begin
					faults[fault_client] = faults[fault_client] + 1;
					line_k = fault_addr[31:5];
					/* The root reports the window offset over VRAM_BASE (0). */
					if ((line_k < 27'h7000 + fault_client * 32 ||
					    line_k >= 27'h7000 + fault_client * 32 + 32) &&
					    !(FAR != 0 && line_k >= 27'h100 + fault_client * 32 &&
					    line_k < 27'h100 + fault_client * 32 + 32)) begin
						errors = errors + 1;
						$display("FAIL atg_mc: fault address %h for client %0d",
							fault_addr, fault_client);
					end
				end
			end
			if ((awvalid && awaddr >= 32'h00080000) || (arvalid && araddr >= 32'h00080000)) begin
				errors = errors + 1;
				$display("FAIL atg_mc: a refused request reached AXI");
			end
		end
	end

	initial begin
		done = 1'b0;
		errors = 0;
		seed = SEED0;
		if ($value$plusargs("seed=%d", seed))
			seed = seed + SEED0;
		for (k = 0; k < N; k = k + 1) begin
			grants[k] = 0;
			faults[k] = 0;
		end
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		while (fin != {N{1'b1}}) begin
			@(posedge clk);
			if ($unsigned($random(seed)) % 300 == 0) begin
				quiesce <= 1'b1;
				wait_idle = 0;
				@(posedge clk);
				while (!axi_idle && wait_idle < 500) begin
					@(posedge clk);
					wait_idle = wait_idle + 1;
				end
				if (!axi_idle) begin
					errors = errors + 1;
					$display("FAIL atg_mc: no AXI_IDLE under quiesce");
				end
				repeat ($unsigned($random(seed)) % 20)
					@(posedge clk);
				quiesce <= 1'b0;
			end
		end
		repeat (10) @(posedge clk);
		for (k = 0; k < N; k = k + 1) begin
			errors = errors + cerr[k];
			if (grants[k] == 0) begin
				errors = errors + 1;
				$display("FAIL atg_mc: client %0d never granted", k);
			end
			if (faults[k] != cbad[k]) begin
				errors = errors + 1;
				$display("FAIL atg_mc: client %0d %0d faults for %0d refused", k,
					faults[k], cbad[k]);
			end
		end
		errors = errors + mem.errors;
		done = 1'b1;
	end
endmodule

module atg_mc_tb;
	reg clk = 1'b0;
	wire done_a, done_b;
	wire [31:0] err_a, err_b;

	always #5 clk = !clk;

	atg_mc_case #(.N(3), .HIGH(3'b001), .ROOT(-1), .VRAM_AW(32), .FAR(0), .SEED0(3)) a (
		.clk(clk), .done(done_a), .errors(err_a)
	);
	atg_mc_case #(.N(5), .HIGH(5'b10001), .ROOT(4), .VRAM_AW(20), .FAR(1), .SEED0(7)) b (
		.clk(clk), .done(done_b), .errors(err_b)
	);

	initial begin
		wait (done_a && done_b);
		if (err_a == 0 && err_b == 0)
			$display("PASS atg_mc");
		else
			$display("FAIL atg_mc: %0d + %0d errors", err_a, err_b);
		$finish;
	end

	initial begin
		#40000000;
		$display("FAIL atg_mc: timeout");
		$finish;
	end
endmodule

`default_nettype wire
