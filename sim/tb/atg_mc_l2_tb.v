/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_l2_tb;
	parameter ADDR_W = 32;
	parameter LINE_BYTES = 64;
	parameter LINE_SHIFT = 6;
	parameter UW = 21;
	parameter LA_W = ADDR_W - LINE_SHIFT;
	parameter LINE_BITS = LINE_BYTES * 8;
	parameter WAYS = 16;
	parameter SET_W = 8;
	parameter NSETS = 1 << SET_W;
	parameter TAG_W = LA_W - SET_W;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg flush = 1'b0;
	reg quiesce = 1'b0;

	always #5 clk = !clk;

	/* Upstream request */
	reg s_req_valid = 1'b0;
	wire s_req_ready;
	reg s_req_write = 1'b0;
	reg [LA_W-1:0] s_req_line = {LA_W{1'b0}};
	reg [LINE_BYTES-1:0] s_req_be = {LINE_BYTES{1'b0}};
	reg [LINE_BITS-1:0] s_req_wdata = {LINE_BITS{1'b0}};
	reg [UW-1:0] s_req_user = {UW{1'b0}};
	reg s_req_id = 1'b0;
	reg s_req_nc = 1'b0;
	reg s_req_high = 1'b0;

	/* Upstream response */
	wire s_rsp_valid;
	wire s_rsp_write;
	wire [UW-1:0] s_rsp_user;
	wire [LINE_BITS-1:0] s_rsp_rdata;
	wire s_rsp_error;

	/* Downstream AXI request */
	wire m_req_valid;
	reg m_req_ready = 1'b1;
	wire m_req_write;
	wire [LA_W-1:0] m_req_line;
	wire [LINE_BYTES-1:0] m_req_be;
	wire [LINE_BITS-1:0] m_req_wdata;
	wire [UW-1:0] m_req_user;
	wire m_req_id;
	wire [7:0] m_req_key;

	/* Downstream AXI response */
	reg m_rsp_valid = 1'b0;
	reg m_rsp_write = 1'b0;
	reg [UW-1:0] m_rsp_user = {UW{1'b0}};
	reg [LINE_BITS-1:0] m_rsp_rdata = {LINE_BITS{1'b0}};
	reg m_rsp_error = 1'b0;

	/* Control invalidate */
	reg ctrl_inv_valid = 1'b0;
	reg ctrl_inv_clean = 1'b0;
	reg ctrl_inv_range = 1'b0;
	reg [LA_W-1:0] ctrl_inv_base = {LA_W{1'b0}};
	reg [LA_W-1:0] ctrl_inv_limit = {LA_W{1'b0}};
	wire ctrl_inv_done;

	wire idle;
	wire [3:0] fsm;

	atg_mc_l2 #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
		.UW(UW), .WAYS(WAYS), .SET_W(SET_W)
	) dut (
		.clk(clk), .rst_n(rst_n), .flush(flush), .quiesce(quiesce),
		.s_req_valid(s_req_valid), .s_req_ready(s_req_ready), .s_req_write(s_req_write),
		.s_req_line(s_req_line), .s_req_be(s_req_be), .s_req_wdata(s_req_wdata),
		.s_req_user(s_req_user), .s_req_id(s_req_id), .s_req_nc(s_req_nc),
		.s_req_high(s_req_high),
		.s_rsp_valid(s_rsp_valid), .s_rsp_write(s_rsp_write), .s_rsp_user(s_rsp_user),
		.s_rsp_rdata(s_rsp_rdata), .s_rsp_error(s_rsp_error),
		.m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_write(m_req_write),
		.m_req_line(m_req_line), .m_req_be(m_req_be), .m_req_wdata(m_req_wdata),
		.m_req_user(m_req_user), .m_req_id(m_req_id), .m_req_key(m_req_key),
		.m_rsp_valid(m_rsp_valid), .m_rsp_write(m_rsp_write), .m_rsp_user(m_rsp_user),
		.m_rsp_rdata(m_rsp_rdata), .m_rsp_error(m_rsp_error),
		.ctrl_inv_valid(ctrl_inv_valid), .ctrl_inv_clean(ctrl_inv_clean),
		.ctrl_inv_range(ctrl_inv_range), .ctrl_inv_base(ctrl_inv_base),
		.ctrl_inv_limit(ctrl_inv_limit), .ctrl_inv_done(ctrl_inv_done),
		.idle(idle), .fsm(fsm)
	);

	integer errors = 0;
	integer axi_req_count = 0;
	reg [LINE_BITS-1:0] simulated_mem [0:4095];

	/* Synchronous AXI memory slave emulation */
	reg axi_pending = 1'b0;
	reg axi_pending_write = 1'b0;
	reg [UW-1:0] axi_pending_user = {UW{1'b0}};
	reg [11:0] axi_pending_line = 12'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			axi_pending <= 1'b0;
			m_rsp_valid <= 1'b0;
			m_rsp_write <= 1'b0;
			m_rsp_user <= {UW{1'b0}};
			m_rsp_rdata <= {LINE_BITS{1'b0}};
			m_rsp_error <= 1'b0;
		end else begin
			m_rsp_valid <= 1'b0;
			if (axi_pending) begin
				m_rsp_valid <= 1'b1;
				m_rsp_write <= axi_pending_write;
				m_rsp_user  <= axi_pending_user;
				m_rsp_rdata <= simulated_mem[axi_pending_line];
				m_rsp_error <= 1'b0;
				axi_pending <= 1'b0;
			end else if (m_req_valid && m_req_ready) begin
				axi_req_count = axi_req_count + 1;
				if (m_req_write) begin
					simulated_mem[m_req_line[11:0]] <= m_req_wdata;
				end
				axi_pending <= 1'b1;
				axi_pending_write <= m_req_write;
				axi_pending_user <= m_req_user;
				axi_pending_line <= m_req_line[11:0];
			end
		end
	end

	integer i;
	initial begin
		for (i = 0; i < 4096; i = i + 1) begin
			simulated_mem[i] = {16{i[31:0]}};
		end

		/* Reset sequence */
		@(negedge clk);
		rst_n = 1'b0;
		repeat (5) @(negedge clk);
		rst_n = 1'b1;
		repeat (5) @(negedge clk);

		$display("--- Test 1: Read Miss (Cold) ---");
		axi_req_count = 0;
		s_req_valid = 1'b1;
		s_req_write = 1'b0;
		s_req_line  = 26'h123405; /* Set index 0x05, tag 0x1234 */
		s_req_user  = 21'h10001;
		s_req_nc    = 1'b0;
		@(negedge clk);
		s_req_valid = 1'b0;

		/* Wait for response */
		while (!s_rsp_valid) @(negedge clk);
		if (axi_req_count !== 1) begin
			$display("FAIL: Expected 1 AXI request on cold miss, got %0d", axi_req_count);
			errors = errors + 1;
		end
		if (s_rsp_rdata !== simulated_mem[s_req_line[11:0]]) begin
			$display("FAIL: Data mismatch on read miss. Got %h, expected %h", s_rsp_rdata, simulated_mem[s_req_line[11:0]]);
			errors = errors + 1;
		end
		$display("PASS: Cold read miss completed correctly.");

		repeat (5) @(negedge clk);

		$display("--- Test 2: Read Hit ---");
		axi_req_count = 0;
		s_req_valid = 1'b1;
		s_req_write = 1'b0;
		s_req_line  = 26'h123405; /* Same line */
		s_req_user  = 21'h10002;
		s_req_nc    = 1'b0;
		@(negedge clk);
		s_req_valid = 1'b0;

		/* Should hit in 1-2 cycles */
		while (!s_rsp_valid) @(negedge clk);
		if (axi_req_count !== 0) begin
			$display("FAIL: Expected 0 AXI requests on read hit, got %0d", axi_req_count);
			errors = errors + 1;
		end
		if (s_rsp_rdata !== simulated_mem[s_req_line[11:0]]) begin
			$display("FAIL: Data mismatch on read hit.");
			errors = errors + 1;
		end
		$display("PASS: Read hit served from L2 without AXI request.");

		repeat (5) @(negedge clk);

		$display("--- Test 3: Write Hit (Write-back) ---");
		axi_req_count = 0;
		s_req_valid = 1'b1;
		s_req_write = 1'b1;
		s_req_line  = 26'h123405;
		s_req_be    = {LINE_BYTES{1'b1}};
		s_req_wdata = {16{32'hDEADBEEF}};
		s_req_user  = 21'h10003;
		@(negedge clk);
		s_req_valid = 1'b0;

		while (!s_rsp_valid) @(negedge clk);
		if (axi_req_count !== 0) begin
			$display("FAIL: Write hit should not issue AXI request in write-back cache!");
			errors = errors + 1;
		end
		$display("PASS: Write hit completed and marked dirty in L2.");

		repeat (5) @(negedge clk);

		$display("--- Test 4: Read Hit after Write ---");
		s_req_valid = 1'b1;
		s_req_write = 1'b0;
		s_req_line  = 26'h123405;
		s_req_user  = 21'h10004;
		@(negedge clk);
		s_req_valid = 1'b0;

		while (!s_rsp_valid) @(negedge clk);
		if (s_rsp_rdata !== {16{32'hDEADBEEF}}) begin
			$display("FAIL: Read after write did not return new data.");
			errors = errors + 1;
		end
		$display("PASS: Read after write returned updated cache data.");

		repeat (5) @(negedge clk);

		$display("--- Test 5: Cache Flush / Clean ---");
		axi_req_count = 0;
		ctrl_inv_valid = 1'b1;
		ctrl_inv_clean = 1'b1;
		ctrl_inv_range = 1'b0;
		@(negedge clk);
		ctrl_inv_valid = 1'b0;

		while (!ctrl_inv_done) @(negedge clk);
		if (axi_req_count !== 1) begin
			$display("FAIL: Flush should have written back 1 dirty line, got %0d", axi_req_count);
			errors = errors + 1;
		end
		if (simulated_mem[s_req_line[11:0]] !== {16{32'hDEADBEEF}}) begin
			$display("FAIL: Memory does not contain flushed data.");
			errors = errors + 1;
		end
		$display("PASS: Flush wrote back dirty line to memory.");

		repeat (5) @(negedge clk);

		$display("--- Test 6: Read after Flush (Should Miss) ---");
		axi_req_count = 0;
		s_req_valid = 1'b1;
		s_req_write = 1'b0;
		s_req_line  = 26'h123405;
		s_req_user  = 21'h10005;
		@(negedge clk);
		s_req_valid = 1'b0;

		while (!s_rsp_valid) @(negedge clk);
		if (axi_req_count !== 1) begin
			$display("FAIL: Expected miss and AXI request after flush, got %0d", axi_req_count);
			errors = errors + 1;
		end
		$display("PASS: Cache line was invalidated by flush.");

		repeat (5) @(negedge clk);

		$display("--- Test 7: Bypass / Non-Cacheable ---");
		axi_req_count = 0;
		s_req_valid = 1'b1;
		s_req_write = 1'b0;
		s_req_line  = 26'h000005;
		s_req_nc    = 1'b1;
		s_req_user  = 21'h10006;
		@(negedge clk);
		s_req_valid = 1'b0;

		while (!s_rsp_valid) @(negedge clk);
		if (axi_req_count !== 1) begin
			$display("FAIL: Expected 1 AXI request for bypass, got %0d", axi_req_count);
			errors = errors + 1;
		end
		$display("PASS: Bypass request passed directly to AXI.");

		repeat (5) @(negedge clk);

		$display("--- Test 8: 16-Way Eviction with Dirty Writeback ---");
		/* Fill 16 ways of set 0x07 with dirty writes */
		for (i = 1; i <= 16; i = i + 1) begin
			s_req_valid = 1'b1;
			s_req_write = 1'b1;
			s_req_line  = {i[17:0], 8'h07};
			s_req_be    = {LINE_BYTES{1'b1}};
			s_req_wdata = {16{i[31:0]}};
			s_req_user  = {13'd0, i[7:0]};
			s_req_nc    = 1'b0;
			@(negedge clk);
			s_req_valid = 1'b0;
			while (!s_rsp_valid) @(negedge clk);
		end

		/* Access 17th line on set 0x07: must evict one dirty way */
		axi_req_count = 0;
		s_req_valid = 1'b1;
		s_req_write = 1'b0;
		s_req_line  = {18'd17, 8'h07};
		s_req_user  = 21'h10017;
		s_req_nc    = 1'b0;
		@(negedge clk);
		s_req_valid = 1'b0;

		while (!s_rsp_valid) @(negedge clk);
		/* Expected 2 AXI requests: 1 evict write + 1 refill read */
		if (axi_req_count !== 2) begin
			$display("FAIL: Expected 2 AXI requests on dirty eviction (writeback + refill), got %0d", axi_req_count);
			errors = errors + 1;
		end else begin
			$display("PASS: 16-way conflict eviction successfully wrote back dirty victim and refilled.");
		end

		repeat (10) @(negedge clk);

		if (errors == 0)
			$display("PASS atg_mc_l2");
		else
			$display("FAIL atg_mc_l2: %0d errors", errors);

		$finish;
	end

endmodule

`default_nettype wire
