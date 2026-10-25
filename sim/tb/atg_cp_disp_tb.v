/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_disp_tb: atg_cp_disp (KC705's shape: 64-byte lines, two planes,
 * local memory 0x80000000 + 1 GiB, aperture 0x80000000-0x90000000) with a
 * DC model (a word array behind d_*, pending flags, taken pulses driven by
 * the test, idle) and a memory model on the AMB port (random ready and
 * latency, an error on request).  Groups (spec/gpu/cp/atg_cp_disp.md §8):
 *   set     DISP_SET writes reach the DC in their cycle; kick_idle waits for
 *           the DC's idle
 *   flip    the checks (fault 3: plane, base outside the aperture, outside
 *           local memory, unaligned for plane 0 and 1, record unaligned or
 *           outside) in the kick's cycle; a good FLIP places base and holds
 *           disp_wait while the plane has a pending flip, slot or record
 *   take    the record {value, FRAME_COUNT} (value first, its byte enables)
 *           and ev_flip after its response, record 0: ev_flip at the take
 *   taken   TAKEN0/1 and STATUS[31] through the HCR read port; cancelled
 *           flips have bit 31
 *   excl    IDLE, HALTED, FAULTED: the sequencer's writes and kicks do
 *           nothing, disp_wait is 0
 *   gate    the host's writes by kind and state, BAD_WRITE, R dropped, the
 *           buffer when the sequencer writes in the same cycle
 *   reset   a record due in HALTED, FAULTED or RESETTING waits for IDLE
 *   err     a record write's error: dc_err[0], ev_flip, no retry
 * then PASS atg_cp_disp.  Mutations: MUT_DISP_NOEXCL, MUT_DISP_NOGATE,
 * MUT_DISP_EARLYIRQ, MUT_DISP_HALTSEND, MUT_DISP_NOTAKE fail.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_disp_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg hcr_we = 0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 0;
	wire [31:0] hcr_rdata;
	reg [3:0] cp_state = GHCI_ST_IDLE;
	reg uop_we = 0, kick_flip = 0, kick_idle = 0;
	reg [9:0] uop_idx = 0;
	reg [31:0] uop_wdata = 0;
	wire disp_wait, fault;
	wire [3:0] fault_kind;
	wire [31:0] fault_addr;
	wire [7:0] fault_tag;
	wire d_we, flip_valid, flip_plane, ev_flip;
	wire [5:0] d_idx, d_ridx;
	wire [31:0] d_wdata, d_wmask, flip_base;
	wire [31:0] d_rdata;
	reg [1:0] taken = 0, taken_cancel = 0, dc_pending = 0;
	reg dc_idle = 1;
	reg [31:0] frame_count = 32'h100;
	wire [1:0] dc_err;
	wire req_valid, req_write;
	reg req_ready = 0;
	wire [25:0] req_line;
	wire [63:0] req_be;
	wire [511:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 0, rsp_error = 0;

	atg_cp_disp #(
		.LINE_BYTES(64), .LINE_SHIFT(6), .NPLANES(2), .LOCAL_BASE(32'h80000000),
		.LOCAL_BYTES(32'h40000000), .BASE_IDX(10'h080)
	) dut (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata), .cp_state(cp_state),
		.uop_we(uop_we), .uop_idx(uop_idx), .uop_wdata(uop_wdata),
		.kick_flip(kick_flip), .kick_idle(kick_idle), .seq_tag(8'h5A),
		.disp_wait(disp_wait), .aperture_base(32'h80000000), .aperture_limit(32'h90000000),
		.fault(fault), .fault_kind(fault_kind), .fault_addr(fault_addr), .fault_tag(fault_tag),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(d_rdata), .flip_valid(flip_valid), .flip_plane(flip_plane),
		.flip_base(flip_base), .taken(taken), .taken_cancel(taken_cancel),
		.dc_pending(dc_pending), .dc_idle(dc_idle), .frame_count(frame_count), .dc_err(dc_err),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(1'b1), .rsp_tag(8'd0), .rsp_rdata(512'd0),
		.rsp_error(rsp_error), .ev_flip(ev_flip)
	);

	`include "hcr_snoop.vh"

	integer errors = 0;
	integer e0;
	integer seed = 5;

	task check;
		input [8*12-1:0] grp;
		input ok;
		input [8*60-1:0] what;
		begin
			if (!ok) begin
				errors = errors + 1;
				$display("FAIL atg_cp_disp.%0s: %0s", grp, what);
			end
		end
	endtask

	/* The DC model: its words, the bus writes logged, the flips placed. */
	reg [31:0] dcw [0:63];
	integer dw_n = 0, bad_n = 0, rec_err_n = 0, flips_n = 0, ev_n = 0;
	reg [5:0] dw_last_k;
	reg [31:0] dw_last;
	reg [31:0] last_base;
	reg last_plane;
	integer k;
	/* The words this module answers itself read 0 at the DC (STATUS[31], TAKEN0/1). */
	initial for (k = 0; k < 64; k = k + 1)
		dcw[k] = k == 44 || k == 45 ? 32'd0 : k == 5 ? 32'h00000004 : 32'h50000000 + k;
	assign d_rdata = dcw[d_ridx];
	always @(posedge clk) begin
		if (d_we) begin
			dcw[d_idx] <= (dcw[d_idx] & ~d_wmask) | (d_wdata & d_wmask);
			dw_n = dw_n + 1;
			dw_last_k = d_idx;
			dw_last = d_wdata;
		end
		if (dc_err[1])
			bad_n = bad_n + 1;
		if (dc_err[0])
			rec_err_n = rec_err_n + 1;
		if (flip_valid) begin
			flips_n = flips_n + 1;
			last_base = flip_base;
			last_plane = flip_plane;
			dc_pending[flip_plane] <= 1'b1;
		end
		if (ev_flip)
			ev_n = ev_n + 1;
	end

	/* The memory model: one write at a time, random ready and latency. */
	integer m_wait = 0, m_lat = 0, m_n = 0;
	reg m_err_next = 0;
	reg m_busy = 0;
	reg [25:0] m_line;
	reg [63:0] m_be;
	reg [511:0] m_data;
	always @(posedge clk) begin
		rsp_valid <= 1'b0;
		rsp_error <= 1'b0;
		if (req_valid && req_ready) begin
			m_busy = 1;
			m_lat = 2 + $unsigned($random(seed)) % 6;
			m_line = req_line;
			m_be = req_be;
			m_data = req_wdata;
			m_n = m_n + 1;
			if (!req_write)
				check("take", 1'b0, "a read request");
		end
		req_ready <= !m_busy && ($random(seed) & 1);
		if (m_busy) begin
			if (m_lat == 0) begin
				rsp_valid <= 1'b1;
				rsp_error <= m_err_next;
				m_err_next = 0;
				m_busy = 0;
			end else
				m_lat = m_lat - 1;
		end
	end

	/* The sequencer's side: a payload write, the FLIP staging, a kick. */
	task uop;
		input [9:0] idx;
		input [31:0] d;
		begin
			@(negedge clk);
			uop_we = 1;
			uop_idx = idx;
			uop_wdata = d;
			@(negedge clk);
			uop_we = 0;
		end
	endtask

	reg f_seen;
	reg [31:0] f_addr_seen;
	reg [3:0] f_kind_seen;
	reg [7:0] f_tag_seen;
	task flip;
		input [31:0] plane, base, record, value;
		begin
			uop(10'h3B8, plane);
			uop(10'h3B9, base);
			uop(10'h3BA, record);
			uop(10'h3BB, value);
			@(negedge clk);
			kick_flip = 1;
			#1;
			f_seen = fault;
			f_addr_seen = fault_addr;
			f_kind_seen = fault_kind;
			f_tag_seen = fault_tag;
			@(negedge clk);
			kick_flip = 0;
		end
	endtask

	task flip_bad;
		input [31:0] plane, base, record, want;
		integer n0;
		begin
			n0 = flips_n;
			flip(plane, base, record, 32'd1);
			check("flip", f_seen && f_kind_seen == GHCI_FAULT_RING && f_addr_seen == want &&
				f_tag_seen == 8'h5A, "a bad FLIP without its fault 3");
			@(negedge clk);
			check("flip", flips_n == n0, "a bad FLIP placed");
		end
	endtask

	/* The DC takes plane p's pending flip (a vsync or a cancel). */
	task take;
		input p;
		input cancel;
		begin
			@(negedge clk);
			taken[p] = 1;
			taken_cancel[p] = cancel;
			dc_pending[p] = 0;
			@(negedge clk);
			taken = 0;
			taken_cancel = 0;
			frame_count = frame_count + 1;
		end
	endtask

	task wait_ev;
		input integer n;
		integer t;
		begin
			t = 0;
			while (ev_n < n && t < 200) begin
				@(negedge clk);
				t = t + 1;
			end
			check("take", ev_n >= n, "no ev_flip");
		end
	endtask

	reg [31:0] v;
	integer n0, n1, t;
	reg [63:0] rec;
	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;
		cp_state = GHCI_ST_RUNNING;

		/* set */
		n0 = dw_n;
		@(negedge clk);
		uop_we = 1;
		uop_idx = 10'h3C4;
		uop_wdata = 32'h51;
		#1;
		check("set", d_we && d_idx == 6'd4 && d_wdata == 32'h51 && d_wmask == 32'hFFFFFFFF,
			"DISP_SET not on the DC bus in its cycle");
		@(negedge clk);
		uop_we = 0;
		uop(10'h3E9, 32'h00100020);
		check("set", dcw[41] == 32'h00100020 && dw_n == n0 + 2, "CURSOR_POS not written");
		dc_idle = 0;
		@(negedge clk);
		kick_idle = 1;
		@(negedge clk);
		kick_idle = 0;
		repeat (5) begin
			@(negedge clk);
			check("set", disp_wait, "idle wait ended without the DC's idle");
		end
		dc_idle = 1;
		@(negedge clk);
		@(negedge clk);
		check("set", !disp_wait, "idle wait does not end");
		if (errors == 0)
			$display("PASS atg_cp_disp.set");
		e0 = errors;

		/* flip: the checks, then a good one and disp_wait. */
		flip_bad(32'd2, 32'h80000000, 32'd0, 32'd2);
		flip_bad(32'd0, 32'h7FFFFFC0, 32'd0, 32'h7FFFFFC0);
		flip_bad(32'd0, 32'h90000000, 32'd0, 32'h90000000);
		flip_bad(32'd0, 32'h80000020, 32'd0, 32'h80000020);
		flip_bad(32'd1, 32'h80000020, 32'd0, 32'h80000020);
		flip_bad(32'd0, 32'h80000040, 32'h80001004, 32'h80001004);
		flip_bad(32'd0, 32'h80000040, 32'h00001000, 32'h00001000);
		n0 = flips_n;
		flip(32'd0, 32'h80010000, 32'h80002008, 32'h11);
		check("flip", !f_seen, "a good FLIP faulted");
		check("flip", flips_n == n0 + 1 && last_base == 32'h80010000 && !last_plane,
			"a good FLIP not placed");
		/* Stage another of plane 0: it must wait (pending and slot). */
		uop(10'h3B8, 32'd0);
		@(negedge clk);
		check("flip", disp_wait, "no wait for plane 0's pending flip");
		/* Plane 1 staged instead: free. */
		uop(10'h3B8, 32'd1);
		@(negedge clk);
		check("flip", !disp_wait, "plane 1 waits for plane 0");
		uop(10'h3B8, 32'd0);
		if (errors == e0)
			$display("PASS atg_cp_disp.flip");
		e0 = errors;

		/* take: the record after the take, ev_flip after its response. */
		n0 = ev_n;
		n1 = m_n;
		take(0, 0);
		@(negedge clk);
		hcr_read(12'h214, v);
		check("taken", v[31], "STATUS[31] not up with a record due");
		check("take", disp_wait, "plane 0 free with its record due");
		t = 0;
		while (m_n == n1 && t < 100) begin
			@(negedge clk);
			t = t + 1;
		end
		check("take", ev_n == n0, "ev_flip before the record's response");
		wait_ev(n0 + 1);
		check("take", m_line == (32'h80002008 >> 6), "record line");
		check("take", m_be == 64'h0000_0000_0000_FF00, "record byte enables");
		rec = m_data[64 +: 64];
		check("take", rec == {32'h100, 32'h11}, "record {value, FRAME_COUNT}");
		hcr_read(12'h2B0, v);
		check("taken", v == 32'h11, "TAKEN0");
		hcr_read(12'h214, v);
		check("taken", !v[31], "STATUS[31] still up");
		@(negedge clk);
		check("take", !disp_wait, "plane 0 not free after its record");
		/* record 0: ev_flip at the take; plane 1 cancelled: bit 31. */
		flip(32'd0, 32'h80020000, 32'd0, 32'h12);
		n0 = ev_n;
		n1 = m_n;
		take(0, 0);
		repeat (2) @(negedge clk);
		check("take", ev_n == n0 + 1 && m_n == n1, "record 0: not ev_flip alone");
		flip(32'd1, 32'h80030000, 32'h80002010, 32'h13);
		take(1, 1);
		wait_ev(n0 + 2);
		hcr_read(12'h2B4, v);
		check("taken", v == 32'h80000013, "TAKEN1 of a cancelled flip");
		check("take", m_data[128 +: 32] == 32'h80000013, "the cancelled record's value");
		/* A taken pulse without a slot is ignored. */
		n0 = ev_n;
		take(0, 0);
		repeat (3) @(negedge clk);
		check("take", ev_n == n0, "a take without a slot");
		hcr_read(12'h208, v);
		check("taken", v == 32'h50000002, "the DC's word through the window");
		hcr_read(12'h1FC, v);
		check("taken", v == 32'd0, "a read outside the window");
		if (errors == e0)
			$display("PASS atg_cp_disp.take");
		if (errors == e0)
			$display("PASS atg_cp_disp.taken");
		e0 = errors;

		/* excl: IDLE, HALTED, FAULTED. */
		for (k = 0; k < 3; k = k + 1) begin
			cp_state = k == 0 ? GHCI_ST_IDLE : k == 1 ? GHCI_ST_HALTED : GHCI_ST_FAULTED;
			n0 = dw_n;
			n1 = flips_n;
			uop(10'h3C4, 32'h77);
			flip(32'd0, 32'h80040000, 32'd0, 32'h14);
			dc_idle = 0;
			@(negedge clk);
			kick_idle = 1;
			@(negedge clk);
			kick_idle = 0;
			@(negedge clk);
			check("excl", dw_n == n0 && flips_n == n1 && !f_seen,
				"the sequencer's DISP µops act outside RUNNING and HALTING");
			check("excl", !disp_wait, "disp_wait outside RUNNING and HALTING");
			dc_idle = 1;
		end
		cp_state = GHCI_ST_HALTING;
		n1 = flips_n;
		flip(32'd0, 32'h80040000, 32'd0, 32'h15);
		check("excl", flips_n == n1 + 1, "no FLIP in HALTING");
		take(0, 0);
		if (errors == e0)
			$display("PASS atg_cp_disp.excl");
		e0 = errors;

		/* gate */
		cp_state = GHCI_ST_RUNNING;
		n0 = dw_n;
		n1 = bad_n;
		hcr_write(12'h210, 32'h1);	/* CTRL, S: dropped */
		hcr_write(12'h224, 32'h80000000);	/* FB_NEXT, S */
		hcr_write(12'h258, 32'h1);	/* PCLK_SEL, S */
		@(negedge clk);
		check("gate", dw_n == n0 && bad_n == n1 + 3, "S written in RUNNING");
		hcr_write(12'h2A4, 32'h00050006);	/* CURSOR_POS, C */
		hcr_write(12'h2A8, 32'h1);	/* CURSOR_CTRL, C */
		hcr_write(12'h260, 32'h3);	/* I2C_CTRL, L */
		hcr_write(12'h26C, 32'h0);	/* CONNECTED, L */
		hcr_write(12'h280, 32'h1);	/* MODE_INDEX, I */
		hcr_write(12'h214, 32'h38);	/* STATUS, W */
		@(negedge clk);
		check("gate", dw_n == n0 + 6 && bad_n == n1 + 3, "C, L, I or W dropped in RUNNING");
		hcr_write(12'h200, 32'h1);	/* DC_ID, R */
		hcr_write(12'h284, 32'h1);	/* MODE_H0, R */
		@(negedge clk);
		check("gate", dw_n == n0 + 6 && bad_n == n1 + 3, "R written");
		cp_state = GHCI_ST_IDLE;
		hcr_write(12'h210, 32'h51);
		@(negedge clk);
		check("gate", dw_n == n0 + 7 && dcw[4] == 32'h51, "S dropped in IDLE");
		cp_state = GHCI_ST_RESETTING;
		hcr_write(12'h210, 32'h52);
		@(negedge clk);
		check("gate", dw_n == n0 + 7 && bad_n == n1 + 4, "S written in RESETTING");
		/* A host write in the sequencer's cycle waits in the buffer. */
		cp_state = GHCI_ST_RUNNING;
		@(negedge clk);
		uop_we = 1;
		uop_idx = 10'h3EA;
		uop_wdata = 32'h0;
		hcr_we = 1;
		hcr_widx = 10'h0A9;
		hcr_wdata = 32'h00070008;
		hcr_wmask = 32'hFFFFFFFF;
		#1;
		check("gate", d_we && d_idx == 6'd42, "the sequencer's write not first");
		@(negedge clk);
		uop_we = 0;
		hcr_we = 0;
		#1;
		check("gate", disp_wait, "no wait while the buffer is full");
		check("gate", d_we && d_idx == 6'd41 && d_wdata == 32'h00070008,
			"the buffered host write not next");
		@(negedge clk);
		check("gate", dcw[41] == 32'h00070008 && dcw[42] == 32'h0 && !disp_wait,
			"the buffered write lost");
		if (errors == e0)
			$display("PASS atg_cp_disp.gate");
		e0 = errors;

		/* reset: a record due in HALTED, FAULTED or RESETTING waits. */
		for (k = 0; k < 3; k = k + 1) begin
			cp_state = GHCI_ST_RUNNING;
			flip(32'd0, 32'h80050000, 32'h80002000, 32'h20 + k);
			cp_state = k == 0 ? GHCI_ST_HALTED : k == 1 ? GHCI_ST_FAULTED : GHCI_ST_RESETTING;
			n0 = ev_n;
			n1 = m_n;
			take(0, 0);
			repeat (40) @(negedge clk);
			check("reset", m_n == n1 && ev_n == n0, "a record written outside IDLE/RUNNING/HALTING");
			hcr_read(12'h214, v);
			check("reset", v[31], "STATUS[31] down with a record due");
			cp_state = GHCI_ST_IDLE;
			wait_ev(n0 + 1);
			check("reset", m_data[0 +: 32] == 32'h20 + k, "the record after the reset");
		end
		if (errors == e0)
			$display("PASS atg_cp_disp.reset");
		e0 = errors;

		/* err: the record write's error. */
		cp_state = GHCI_ST_RUNNING;
		flip(32'd1, 32'h80060000, 32'h80002018, 32'h30);
		n0 = ev_n;
		n1 = rec_err_n;
		m_err_next = 1;
		take(1, 0);
		wait_ev(n0 + 1);
		repeat (2) @(negedge clk);
		check("err", rec_err_n == n1 + 1, "no record error");
		n1 = m_n;
		repeat (30) @(negedge clk);
		check("err", m_n == n1, "the record retried");
		@(negedge clk);
		check("err", !disp_wait, "plane 1 not free after a failed record");
		if (errors == e0)
			$display("PASS atg_cp_disp.err");

		if (errors == 0)
			$display("PASS atg_cp_disp");
		else
			$display("FAIL atg_cp_disp: %0d errors", errors);
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_cp_disp: timeout");
		$finish;
	end

	wire unused_ok = &{1'b0, req_tag};
endmodule

`default_nettype wire
