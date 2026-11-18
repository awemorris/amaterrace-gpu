/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_amb_mux_tb: three requesters behind am_amb_mux and amb_mem (random
 * ready, in-order responses).  Checks the fixed priority, that the
 * offered request does not change while it waits for ready, and that
 * every response reaches its requester, in order, with its own tag and
 * data (each requester writes and reads back its own lines).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_amb_mux_tb;
	localparam N = 3;
	localparam LA = 27;
	localparam LB = 256;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg [N-1:0] i_valid = 0;
	wire [N-1:0] i_ready;
	reg [N-1:0] i_write = 0;
	reg [N*LA-1:0] i_line = 0;
	reg [N*32-1:0] i_be = 0;
	reg [N*LB-1:0] i_wdata = 0;
	reg [N*8-1:0] i_tag = 0;
	wire [N-1:0] r_valid;
	wire r_write, r_error;
	wire [7:0] r_tag;
	wire [LB-1:0] r_rdata;

	wire o_valid, o_ready, o_write, o_rsp_valid, o_rsp_write, o_rsp_error;
	wire [LA-1:0] o_line;
	wire [31:0] o_be;
	wire [LB-1:0] o_wdata, o_rsp_rdata;
	wire [7:0] o_tag, o_rsp_tag;

	am_amb_mux #(.N(N), .ID_W(2)) dut (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid(i_valid), .i_req_ready(i_ready), .i_req_write(i_write),
		.i_req_line(i_line), .i_req_be(i_be), .i_req_wdata(i_wdata), .i_req_tag(i_tag),
		.i_rsp_valid(r_valid), .i_rsp_write(r_write), .i_rsp_tag(r_tag),
		.i_rsp_rdata(r_rdata), .i_rsp_error(r_error),
		.o_req_valid(o_valid), .o_req_ready(o_ready), .o_req_write(o_write),
		.o_req_line(o_line), .o_req_be(o_be), .o_req_wdata(o_wdata), .o_req_tag(o_tag),
		.o_rsp_valid(o_rsp_valid), .o_rsp_write(o_rsp_write), .o_rsp_tag(o_rsp_tag),
		.o_rsp_rdata(o_rsp_rdata), .o_rsp_error(o_rsp_error)
	);

	amb_mem #(.MEM_WORDS(8192), .SEED(3)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(o_valid), .req_ready(o_ready), .req_write(o_write), .req_line(o_line),
		.req_be(o_be), .req_wdata(o_wdata), .req_tag(o_tag),
		.rsp_valid(o_rsp_valid), .rsp_write(o_rsp_write), .rsp_tag(o_rsp_tag),
		.rsp_rdata(o_rsp_rdata), .rsp_error(o_rsp_error)
	);

	integer errors = 0;
	integer seed = 7;

	/* hold: the offered request does not change while it waits. */
	reg p_wait = 1'b0;
	reg [LA+8+1-1:0] p_req;
	always @(posedge clk) begin
		if (p_wait && {o_line, o_tag, o_write} !== p_req) begin
			errors = errors + 1;
			$display("FAIL am_amb_mux.hold: payload changed under the handshake");
		end
		p_wait <= o_valid && !o_ready;
		p_req <= {o_line, o_tag, o_write};
	end

	/* route: per requester, the tags come back in the order they went. */
	reg [5:0] sent [0:N-1];
	reg [5:0] got [0:N-1];
	reg [LB-1:0] expect_data [0:N-1][0:63];
	reg expect_read [0:N-1][0:63];
	integer k;

	always @(posedge clk) begin
		for (k = 0; k < N; k = k + 1)
			if (r_valid[k]) begin
				if (r_tag !== {2'b00, got[k]}) begin
					errors = errors + 1;
					$display("FAIL am_amb_mux.route: requester %0d tag %h, expected %h", k,
						r_tag, got[k]);
				end
				if (expect_read[k][got[k]] && r_rdata !== expect_data[k][got[k]]) begin
					errors = errors + 1;
					$display("FAIL am_amb_mux.route: requester %0d data", k);
				end
				got[k] = got[k] + 6'd1;
			end
		if ((r_valid & (r_valid - 1)) != 0) begin
			errors = errors + 1;
			$display("FAIL am_amb_mux.route: one response to two requesters");
		end
	end

	/* Requester k's lines: 64 * k + 0..63, a reference copy of each. */
	reg [LB-1:0] ref_line [0:N*64-1];
	integer first_k;

	task issue;
		input integer kk;
		input wr;
		input [5:0] ln;
		reg [LB-1:0] d;
		begin
			d = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed),
				$random(seed), $random(seed), $random(seed)};
			i_write[kk] = wr;
			i_line[kk * LA +: LA] = kk * 64 + ln;
			i_be[kk * 32 +: 32] = 32'hFFFFFFFF;
			i_wdata[kk * LB +: LB] = d;
			i_tag[kk * 8 +: 8] = {2'b00, sent[kk]};
			expect_read[kk][sent[kk]] = !wr;
			expect_data[kk][sent[kk]] = ref_line[kk * 64 + ln];
			if (wr)
				ref_line[kk * 64 + ln] = d;
			sent[kk] = sent[kk] + 6'd1;
			i_valid[kk] = 1'b1;
		end
	endtask

	integer n, t;
	reg [N-1:0] acc = 0;
	initial begin
		for (k = 0; k < N; k = k + 1) begin
			sent[k] = 0;
			got[k] = 0;
		end
		for (k = 0; k < N * 64; k = k + 1)
			ref_line[k] = 0;
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		@(posedge clk);

		/* priority: all three at once; the order of the handshakes. */
		@(negedge clk);
		issue(0, 1'b1, 6'd0);
		issue(1, 1'b1, 6'd0);
		issue(2, 1'b1, 6'd0);
		first_k = -1;
		t = 0;
		while (i_valid != 0 && t < 200) begin
			#1;
			acc = i_valid & i_ready;
			for (k = 0; k < N; k = k + 1)
				if (acc[k]) begin
					if (first_k + 1 != k) begin
						errors = errors + 1;
						$display("FAIL am_amb_mux.priority: requester %0d after %0d", k, first_k);
					end
					first_k = k;
				end
			@(negedge clk);
			i_valid = i_valid & ~acc;
			t = t + 1;
		end
		repeat (30) @(posedge clk);
		if (errors == 0 && first_k == 2)
			$display("PASS am_amb_mux.priority");
		else
			errors = errors + 1;

		/* route and hold: random traffic. */
		for (n = 0; n < 3000; n = n + 1) begin
			@(negedge clk);
			i_valid = i_valid & ~acc;
			for (k = 0; k < N; k = k + 1)
				if (!i_valid[k] && ($random(seed) & 1) && sent[k] - got[k] < 6'd8)
					issue(k, $random(seed) & 1, $unsigned($random(seed)) % 64);
			#1;
			acc = i_valid & i_ready;
		end
		@(negedge clk);
		i_valid = i_valid & ~acc;
		while (i_valid != 0) begin
			#1;
			acc = i_valid & i_ready;
			@(negedge clk);
			i_valid = i_valid & ~acc;
		end
		i_valid = 0;
		t = 0;
		while ((sent[0] != got[0] || sent[1] != got[1] || sent[2] != got[2]) && t < 1000) begin
			@(posedge clk);
			t = t + 1;
		end
		if (t >= 1000) begin
			errors = errors + 1;
			$display("FAIL am_amb_mux.route: responses missing");
		end
		$display("am_amb_mux: %0d writes reached memory", mem.writes);
		if (mem.writes < 100)
			errors = errors + 1;
		if (errors == 0) begin
			$display("PASS am_amb_mux.hold");
			$display("PASS am_amb_mux.route");
			$display("PASS am_amb_mux");
		end else begin
			$display("FAIL am_amb_mux: %0d errors", errors);
		end
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL am_amb_mux: timeout");
		$finish;
	end
endmodule

`default_nettype wire
