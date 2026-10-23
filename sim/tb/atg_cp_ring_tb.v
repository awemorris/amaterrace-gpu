/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ring_tb: the ring against amb_mem (random ready and latency) and
 * a sequencer model with random n_ready.  The testbench writes packets
 * into the ring as a driver would (whole packet, then the doorbell) and
 * keeps the dwords it expects on n_* and the class V packets it expects
 * on v_*.  Checks the class N stream and n_last, class V hand-over and
 * v_done, class 3 padding at the end, many wraps with a doorbell per
 * packet (the line at RPTR is read again: a stale line from the previous
 * lap would give wrong dwords), RPTR/empty/retire, a header that runs
 * past WPTR (fault kind 3, nothing handed over), halt and step, and a
 * class V packet without firmware (CLASS_V = 0: fault kind 2).
 */

`timescale 1ns / 1ps
`default_nettype none

module ring_bench #(
	parameter CLASS_V = 1,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n
);
	`include "ghci_regs.vh"

	localparam LA = 32 - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam [31:0] BASE = 32'h00000400;
	localparam NW = 256;	/* RING_SIZE 10 */

	reg hcr_we = 0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 0;
	wire [31:0] hcr_rdata;
	reg run = 0, halt = 0, step = 0, open = 1;
	wire n_valid, n_last, v_valid, empty, retire, busy, fault;
	reg n_ready = 0;
	wire [31:0] n_data, v_addr, fault_addr;
	wire [15:0] v_dwords;
	wire [7:0] v_tag, fault_tag;
	wire [3:0] fault_kind;
	reg v_done = 0;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [LA-1:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LB-1:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;
	reg core_rst_n = 1;

	atg_cp_ring #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .CLASS_V(CLASS_V)) dut (
		.clk(clk), .rst_n(rst_n), .core_rst_n(core_rst_n && rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.run(run), .halt(halt), .step(step), .open(open),
		.n_valid(n_valid), .n_ready(n_ready), .n_data(n_data), .n_last(n_last),
		.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag), .v_done(v_done),
		.empty(empty), .retire(retire), .busy(busy),
		.fault(fault), .fault_kind(fault_kind), .fault_addr(fault_addr), .fault_tag(fault_tag),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	amb_mem #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .MEM_WORDS(4096),
		.SEED(SEED)) mem (
		.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer seed = SEED;
	integer wp = 0;	/* the driver's WPTR */

	/* Expected class N dwords (with their last flag) and V packets. */
	reg [32:0] nq [0:16383];
	integer nq_head = 0, nq_tail = 0;
	reg [55:0] vq [0:255];	/* {tag, dwords, addr} */
	integer vq_head = 0, vq_tail = 0;
	integer retires = 0, faults = 0, packets = 0;

	task put;
		input [31:0] v;
		begin
			mem.poke(BASE + wp * 4, v);
			wp = (wp + 1) % NW;
		end
	endtask

	/* A class N packet of n payload dwords. */
	task pkt_n;
		input vendor;
		input [5:0] op;
		input [7:0] n;
		reg [31:0] d;
		integer i;
		begin
			d = {1'b0, vendor, op, 8'h5A ^ wp[7:0], 8'h00, n};
			put(d);
			nq[nq_tail % 16384] = {n == 0, d};
			nq_tail = nq_tail + 1;
			for (i = 0; i < n; i = i + 1) begin
				d = $random(seed);
				put(d);
				nq[nq_tail % 16384] = {i == n - 1, d};
				nq_tail = nq_tail + 1;
			end
			packets = packets + 1;
		end
	endtask

	task pkt_v;
		input [15:0] n;
		integer i;
		reg [31:0] a;
		begin
			a = BASE + ((wp + 1) % NW) * 4;
			vq[vq_tail % 256] = {wp[7:0] ^ 8'hC3, n, a};
			vq_tail = vq_tail + 1;
			put({2'b10, 6'd0, wp[7:0] ^ 8'hC3, n});
			for (i = 0; i < n; i = i + 1)
				put($random(seed));
			packets = packets + 1;
		end
	endtask

	/* Padding when fewer than room dwords are left before the end. */
	task pad_if;
		input integer room;
		reg [31:0] r;
		begin
			if (NW - wp < room) begin
				r = NW - wp - 1;
				put({2'b11, 14'd0, r[15:0]});
				wp = 0;
				packets = packets + 1;
			end
		end
	endtask

	task doorbell;
		hcr_write(GHCI_RING_WPTR[11:0], wp);
	endtask

	/* The sequencer and the firmware models. */
	reg v_wait = 0;
	integer v_delay = 0;
	always @(posedge clk) begin
		if (n_valid && n_ready) begin
			if (nq_head == nq_tail) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ring: unexpected dword %h", n_data);
			end else if ({n_last, n_data} !== nq[nq_head % 16384]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ring: dword %h last %b, expected %h", n_data, n_last,
					nq[nq_head % 16384]);
			end
			nq_head = nq_head + 1;
		end
		n_ready <= ($random(seed) & 3) != 0;
		v_done <= 1'b0;
		if (v_valid && !v_wait && !v_done) begin
			if (vq_head == vq_tail || {v_tag, v_dwords, v_addr} !== vq[vq_head % 256]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ring: class V %h %h %h", v_tag, v_dwords, v_addr);
			end
			vq_head = vq_head + 1;
			v_wait <= 1'b1;
			v_delay = 3 + $unsigned($random(seed)) % 20;
		end
		if (v_wait) begin
			v_delay = v_delay - 1;
			if (v_delay == 0) begin
				v_done <= 1'b1;
				v_wait <= 1'b0;
			end
		end
		if (retire)
			retires = retires + 1;
		if (fault)
			faults = faults + 1;
	end

	task drain;
		input [8*30-1:0] what;
		integer t;
		reg [31:0] rp;
		begin
			t = 0;
			hcr_read(GHCI_RING_RPTR[11:0], rp);
			while ((rp != wp || busy) && t < 20000) begin
				@(negedge clk);
				hcr_read(GHCI_RING_RPTR[11:0], rp);
				t = t + 1;
			end
			repeat (2) @(negedge clk);
			if (rp != wp || nq_head != nq_tail || vq_head != vq_tail || !empty) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ring.%0s: RPTR %0d WPTR %0d, %0d/%0d dwords, %0d/%0d V",
					what, rp, wp, nq_head, nq_tail, vq_head, vq_tail);
			end
		end
	endtask

	integer e0, i, k, r0, p0;
	reg [31:0] v;
	reg done = 0;

	initial begin
		@(posedge rst_n);
		repeat (2) @(negedge clk);
		hcr_write(GHCI_RING_BASE[11:0], BASE | 32'h1F);
		hcr_write(GHCI_RING_SIZE[11:0], 32'd3);	/* clamped to 10 */
		hcr_read(GHCI_RING_BASE[11:0], v);
		if (v !== BASE) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring: RING_BASE %h", v);
		end
		hcr_read(GHCI_RING_SIZE[11:0], v);
		if (v !== 32'd10) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring: RING_SIZE %h", v);
		end
		run = 1;

		/* classn: SET_REG with 4 dwords, BLIT, a vendor DBG_MARK. */
		pkt_n(1'b0, 6'd1, 8'd4);
		pkt_n(1'b0, 6'd2, 8'd0);
		pkt_n(1'b1, 6'd1, 8'd1);
		doorbell();
		drain("classn");
		if (retires != 3) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring.classn: %0d retires", retires);
		end
		if (errors == 0)
			$display("PASS atg_cp_ring.classn");
		e0 = errors;

		if (CLASS_V != 0) begin
			/* classv: RPTR waits for v_done. */
			pkt_v(16'd5);
			pkt_n(1'b0, 6'd0, 8'd2);
			doorbell();
			drain("classv");
			if (errors == e0)
				$display("PASS atg_cp_ring.classv");
			e0 = errors;
		end

		/* pad: up to the end, then at index 0. */
		while (wp < NW - 6)
			pkt_n(1'b0, 6'd1, 8'd2);
		doorbell();
		drain("pad");
		pad_if(10);
		pkt_n(1'b0, 6'd1, 8'd8);
		doorbell();
		drain("pad");
		if (wp != 9) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring.pad: WPTR %0d", wp);
		end
		if (errors == e0)
			$display("PASS atg_cp_ring.pad");
		e0 = errors;

		/* wrap: random packets, a doorbell after each, the ring never full. */
		r0 = retires;
		p0 = packets;
		for (i = 0; i < 400; i = i + 1) begin
			k = $unsigned($random(seed)) % 24;
			pad_if(k + 1 + 1);
			if (CLASS_V != 0 && ($random(seed) % 8) == 0)
				pkt_v(k);
			else
				pkt_n($random(seed) & 1, 6'd1, k);
			doorbell();
			if (($random(seed) % 4) == 0)
				drain("wrap");
			/* Keep space: wait while more than half is pending. */
			hcr_read(GHCI_RING_RPTR[11:0], v);
			while (((wp - v + NW) % NW) > NW / 2) begin
				@(negedge clk);
				hcr_read(GHCI_RING_RPTR[11:0], v);
			end
		end
		drain("wrap");
		if (retires - r0 != packets - p0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring.wrap: %0d retires for %0d packets", retires - r0,
				packets - p0);
		end
		if (errors == e0)
			$display("PASS atg_cp_ring.wrap");
		e0 = errors;

		/* halt: nothing is fetched; step takes one packet. */
		halt = 1;
		pkt_n(1'b0, 6'd0, 8'd1);
		pkt_n(1'b0, 6'd0, 8'd1);
		doorbell();
		repeat (100) @(negedge clk);
		if (nq_head != nq_tail - 4 || busy) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring.halt: fetched while halted");
		end
		@(negedge clk);
		step = 1;
		@(negedge clk);
		step = 0;
		repeat (100) @(negedge clk);
		if (nq_head != nq_tail - 2) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring.halt: step took %0d dwords", nq_head - (nq_tail - 4));
		end
		halt = 0;
		drain("halt");
		if (errors == e0)
			$display("PASS atg_cp_ring.halt");
		e0 = errors;

		/* fault: a header whose n passes WPTR; or class V without a CPU. */
		hcr_read(GHCI_RING_RPTR[11:0], v);
		if (CLASS_V == 0) begin
			put({2'b10, 6'd0, 8'h99, 16'd1});
			put(32'd0);
			doorbell();
			repeat (100) @(negedge clk);
			if (faults != 1 || fault_kind !== GHCI_FAULT_OPCODE || fault_tag !== 8'h99 ||
			    fault_addr !== BASE + v * 4) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ring.fault: class V: %0d faults kind %h tag %h addr %h",
					faults, fault_kind, fault_tag, fault_addr);
			end
			/* The core reset clears the pointers and starts over. */
			@(negedge clk);
			core_rst_n = 0;
			@(negedge clk);
			core_rst_n = 1;
			wp = 0;
			faults = 0;
			hcr_read(GHCI_RING_BASE[11:0], v);
			if (v !== BASE) begin
				errors = errors + 1;
				$display("FAIL atg_cp_ring.fault: RING_BASE lost in the core reset");
			end
			pkt_n(1'b0, 6'd1, 8'd2);
			doorbell();
			drain("fault");
			hcr_read(GHCI_RING_RPTR[11:0], v);
		end
		put({2'b00, 6'd1, 8'h77, 8'd0, 8'd6});
		put(32'd1);
		doorbell();
		repeat (100) @(negedge clk);
		if (faults != 1 || fault_kind !== GHCI_FAULT_RING || fault_tag !== 8'h77 ||
		    fault_addr !== BASE + v * 4 || nq_head != nq_tail || busy) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring.fault: %0d faults kind %h tag %h addr %h", faults,
				fault_kind, fault_tag, fault_addr);
		end
		hcr_read(GHCI_RING_RPTR[11:0], k);
		if (k != v) begin
			errors = errors + 1;
			$display("FAIL atg_cp_ring.fault: RPTR moved");
		end
		if (errors == e0)
			$display("PASS atg_cp_ring.fault");
		done = 1;
	end
endmodule

module atg_cp_ring_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	ring_bench #(.CLASS_V(1), .SEED(11)) b1 (.clk(clk), .rst_n(rst_n));
	ring_bench #(.CLASS_V(0), .LINE_BYTES(64), .LINE_SHIFT(6), .SEED(12)) b0 (
		.clk(clk), .rst_n(rst_n));

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;
		wait (b1.done && b0.done);
		if (b1.errors == 0 && b0.errors == 0)
			$display("PASS atg_cp_ring");
		else
			$display("FAIL atg_cp_ring: %0d + %0d errors", b1.errors, b0.errors);
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_cp_ring: timeout");
		$finish;
	end
endmodule

`default_nettype wire
