/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_seq_tb: the sequencer fed from a ring model and a firmware model
 * (both with random gaps), with block models (busy for some cycles after
 * their kick) and a fence-unit model.  Every output event is logged and
 * compared with the expected list; monitors check the wait rules at the
 * moment of each event (a kick only when its block is idle, a FENCE only
 * when every block is idle, RESULT only when the fence unit is idle, no
 * write to the BLT range while the BLT is busy, none to the RX and ROP
 * ranges while the VF, the SUs, the RX or the ROP are busy).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_seq_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* The ring and firmware sources. */
	reg [32:0] rq [0:1023];
	integer rq_head = 0, rq_tail = 0;
	reg [32:0] fq [0:1023];
	integer fq_head = 0, fq_tail = 0;
	reg r_gap = 0, f_gap = 0;
	reg fw_active = 0, halt = 0;
	wire n_valid = rq_head != rq_tail && !r_gap;
	wire [31:0] n_data = rq[rq_head % 1024][31:0];
	wire n_last = rq[rq_head % 1024][32];
	wire fw_valid = fq_head != fq_tail && !f_gap;
	wire [31:0] fw_data = fq[fq_head % 1024][31:0];
	wire fw_last = fq[fq_head % 1024][32];
	wire n_ready, fw_ready;

	wire uop_we, blt_kick, draw_kick, cs_kick, lc_kick, raw_kick, perf_reset;
	wire [8:0] uop_idx;
	wire [31:0] uop_wdata;
	wire [3:0] inv;
	reg [7:0] busy_in = 0;
	reg vsync = 0;
	wire f_valid, f_irq, busy, cmd_active, fault;
	reg f_ready = 0, f_busy = 0;
	wire [1:0] f_op;
	wire [31:0] f_addr, f_value, f_aux, fault_addr;
	wire [3:0] fault_kind;
	wire [7:0] fault_tag;
	reg [39:0] occ_count = 40'h0;
	wire occ_clear;

	atg_cp_seq #(.UNITS(8'hFF), .HAS_VSYNC(1)) dut (
		.clk(clk), .rst_n(rst_n),
		.n_valid(n_valid), .n_ready(n_ready), .n_data(n_data), .n_last(n_last),
		.fw_valid(fw_valid), .fw_ready(fw_ready), .fw_data(fw_data), .fw_last(fw_last),
		.fw_active(fw_active), .halt(halt),
		.uop_we(uop_we), .uop_idx(uop_idx), .uop_wdata(uop_wdata),
		.blt_kick(blt_kick), .draw_kick(draw_kick), .cs_kick(cs_kick), .lc_kick(lc_kick),
		.raw_kick(raw_kick), .inv(inv), .perf_reset(perf_reset), .busy_in(busy_in),
		.vsync(vsync),
		.f_valid(f_valid), .f_ready(f_ready), .f_op(f_op), .f_addr(f_addr), .f_value(f_value),
		.f_aux(f_aux), .f_irq(f_irq), .f_busy(f_busy),
		.occ_count(occ_count), .occ_clear(occ_clear),
		.busy(busy), .cmd_active(cmd_active),
		.fault(fault), .fault_kind(fault_kind), .fault_addr(fault_addr), .fault_tag(fault_tag)
	);

	/* A second instance with only the CP and the BLT: absent units. */
	wire s_n_ready, s_fault;
	wire [3:0] s_fault_kind;
	reg [31:0] s_data = 0;
	reg s_valid = 0;
	atg_cp_seq #(.UNITS(8'h03)) u_small (
		.clk(clk), .rst_n(rst_n),
		.n_valid(s_valid), .n_ready(s_n_ready), .n_data(s_data), .n_last(1'b1),
		.fw_valid(1'b0), .fw_ready(), .fw_data(32'd0), .fw_last(1'b0), .fw_active(1'b0),
		.halt(1'b0), .uop_we(), .uop_idx(), .uop_wdata(),
		.blt_kick(), .draw_kick(), .cs_kick(), .lc_kick(), .raw_kick(), .inv(),
		.perf_reset(), .busy_in(8'd0), .vsync(1'b0),
		.f_valid(), .f_ready(1'b0), .f_op(), .f_addr(), .f_value(), .f_aux(), .f_irq(),
		.f_busy(1'b0), .occ_count(40'd0), .occ_clear(), .busy(), .cmd_active(),
		.fault(s_fault), .fault_kind(s_fault_kind), .fault_addr(), .fault_tag()
	);

	integer errors = 0;
	integer seed = 21;

	/* Sources: pop on the handshake, random gaps. */
	always @(posedge clk) begin
		if (n_valid && n_ready)
			rq_head = rq_head + 1;
		if (fw_valid && fw_ready)
			fq_head = fq_head + 1;
		if (n_valid && n_ready && fw_valid && fw_ready) begin
			errors = errors + 1;
			$display("FAIL atg_cp_seq.source: both sources taken in one cycle");
		end
		r_gap <= ($random(seed) & 3) == 0;
		f_gap <= ($random(seed) & 3) == 0;
	end

	/* Blocks: busy for a while after the kick; SU long (for the mask test). */
	integer c_blt = 0, c_vf = 0, c_su = 0, c_rx = 0, c_f = 0;
	integer su_len = 15;
	always @(posedge clk) begin
		if (c_blt > 0) c_blt = c_blt - 1;
		if (c_vf > 0) c_vf = c_vf - 1;
		if (c_su > 0) c_su = c_su - 1;
		if (c_rx > 0) c_rx = c_rx - 1;
		if (blt_kick) c_blt = 20;
		if (draw_kick) c_vf = 12;
		if (cs_kick || lc_kick) c_su = su_len;
		if (raw_kick) c_rx = 9;
		busy_in <= {1'b0, c_su != 0, 2'b00, c_rx != 0, c_vf != 0, c_blt != 0, 1'b0};
		/* The fence unit: takes a request when ready, then busy. */
		if (c_f > 0) c_f = c_f - 1;
		if (f_valid && f_ready)
			c_f = 10 + $unsigned($random(seed)) % 10;
		f_busy <= c_f != 0;
		f_ready <= c_f == 0 && ($random(seed) & 1);
	end

	/* The event log and the monitors. */
	reg [63:0] ev [0:1023];
	integer ev_n = 0;
	task log;
		input [63:0] e;
		begin
			ev[ev_n % 1024] = e;
			ev_n = ev_n + 1;
		end
	endtask

	always @(posedge clk) begin
		if (uop_we) begin
			log({8'h01, 15'd0, uop_idx, uop_wdata});
			if (uop_idx < 9'h020 && busy_in[1]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq: BLT state written while the BLT is busy");
			end
			if (((uop_idx >= 9'h020 && uop_idx < 9'h050) || uop_idx[8:5] == 4'hE) && busy_in[2]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq: VF state %h written while the VF is busy", uop_idx);
			end
			if (uop_idx >= 9'h050 && uop_idx < 9'h090 &&
			    (busy_in[2] || busy_in[3] || busy_in[4] || busy_in[6])) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.drawstate: RX/ROP state %h written with busy %b",
					uop_idx, busy_in);
			end
			if (uop_idx >= 9'h190 && uop_idx < 9'h1B0 && (busy_in[2] || busy_in[3] || busy_in[6])) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.progwait: program state %h written with busy %b",
					uop_idx, busy_in);
			end
			if (uop_idx >= 9'h090 && uop_idx < 9'h190 && busy_in[2]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.tuwait: TU state %h written while the VF is busy", uop_idx);
			end
			if (uop_idx >= 9'h090 && uop_idx < 9'h190 && (busy_in[6] || busy_in[5] || busy_in[3])) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.kicks: TU state %h written while the SU, TU or RX is busy",
					uop_idx);
			end
		end
		if (blt_kick) begin
			log({8'h02, 56'd0});
			if (busy_in[1]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.kicks: BLIT while the BLT is busy");
			end
		end
		if (draw_kick) begin
			log({8'h03, 56'd0});
			if (busy_in[2]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.kicks: DRAW while the VF is busy");
			end
		end
		if (cs_kick)
			log({8'h04, 56'd0});
		if (lc_kick) begin
			log({8'h05, 56'd0});
			if (busy_in[2] || busy_in[3]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.ldconst: LOAD_CONST while the VF or the RX is busy (%b)",
					busy_in);
			end
			if (busy_in[6]) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.kicks: LOAD_CONST while the SUs are busy");
			end
		end
		if (raw_kick)
			log({8'h06, 56'd0});
		if (inv != 4'd0)
			log({8'h07, 52'd0, inv});
		if (perf_reset)
			log({8'h08, 56'd0});
		if (f_valid && f_ready) begin
			log({8'h09, 6'd0, f_op, f_irq, 15'd0, f_addr ^ f_value ^ (f_op == 2'd1 ? f_aux : 32'd0)});
			if (f_op != 2'd2 && busy_in[7:1] != 7'd0) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.fence: request while a block is busy (%b)", busy_in);
			end
			if (f_op == 2'd1 && f_busy) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.fence: RESULT before the earlier writes");
			end
		end
		if (occ_clear)
			log({8'h0A, 24'd0, occ_count[31:0]});
	end

	/* Expected events. */
	reg [63:0] want [0:1023];
	integer want_n = 0;
	task expect_ev;
		input [63:0] e;
		begin
			want[want_n % 1024] = e;
			want_n = want_n + 1;
		end
	endtask

	task push;
		input fw;
		input [31:0] d;
		input last;
		begin
			if (fw) begin
				fq[fq_tail % 1024] = {last, d};
				fq_tail = fq_tail + 1;
			end else begin
				rq[rq_tail % 1024] = {last, d};
				rq_tail = rq_tail + 1;
			end
		end
	endtask

	function [31:0] hdr;
		input vendor;
		input [5:0] op;
		input [7:0] flags;
		input [7:0] n;
		hdr = {1'b0, vendor, op, 8'hA5, flags, n};
	endfunction

	/* A packet: the header, then n payload dwords from pl[]. */
	reg [31:0] pl [0:15];
	task packet;
		input fw;
		input vendor;
		input [5:0] op;
		input [7:0] flags;
		input [7:0] n;
		integer i;
		begin
			push(fw, hdr(vendor, op, flags, n), n == 0);
			for (i = 0; i < n; i = i + 1)
				push(fw, pl[i], i == n - 1);
		end
	endtask

	task settle;
		input [8*30-1:0] what;
		integer t;
		begin
			t = 0;
			while ((rq_head != rq_tail || fq_head != fq_tail || busy) && t < 5000) begin
				@(negedge clk);
				t = t + 1;
			end
			repeat (3) @(negedge clk);
			if (t >= 5000) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.%0s: does not finish", what);
			end
		end
	endtask

	task compare;
		input [8*30-1:0] what;
		integer i;
		begin
			if (ev_n != want_n) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.%0s: %0d events, expected %0d", what, ev_n, want_n);
			end
			for (i = 0; i < ev_n && i < want_n; i = i + 1)
				if (ev[i % 1024] !== want[i % 1024]) begin
					errors = errors + 1;
					$display("FAIL atg_cp_seq.%0s: event %0d %h, expected %h", what, i,
						ev[i % 1024], want[i % 1024]);
				end
			ev_n = 0;
			want_n = 0;
		end
	endtask

	task reset;
		begin
			@(negedge clk);
			rst_n = 0;
			rq_head = rq_tail;
			fq_head = fq_tail;
			@(negedge clk);
			rst_n = 1;
			ev_n = 0;
			want_n = 0;
		end
	endtask

	task expect_fault;
		input [8*30-1:0] what;
		input [3:0] kind;
		input [31:0] addr;
		integer t;
		begin
			t = 0;
			while (!fault && t < 200) begin
				@(posedge clk);
				#1;
				t = t + 1;
			end
			if (!fault || fault_kind !== kind || fault_addr !== addr || fault_tag !== 8'hA5) begin
				errors = errors + 1;
				$display("FAIL atg_cp_seq.%0s: fault %b kind %h addr %h", what, fault, fault_kind,
					fault_addr);
			end
			reset();
		end
	endtask

	integer e0, i, mark_t;
	reg [8:0] sidx;
	reg s_seen = 0;
	always @(posedge clk)
		if (s_fault && s_fault_kind == GHCI_FAULT_OPCODE)
			s_seen = 1;
	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;

		/* setreg: three pairs in order, then index 512. */
		pl[0] = 32'h010; pl[1] = 32'h11111111;
		pl[2] = 32'h1FE; pl[3] = 32'h22222222;
		pl[4] = 32'h000; pl[5] = 32'h33333333;
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd6);
		expect_ev({8'h01, 15'd0, 9'h010, 32'h11111111});
		expect_ev({8'h01, 15'd0, 9'h1FE, 32'h22222222});
		expect_ev({8'h01, 15'd0, 9'h000, 32'h33333333});
		settle("setreg");
		compare("setreg");
		pl[0] = 32'h200; pl[1] = 32'h0;
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd2);
		expect_fault("setreg", GHCI_FAULT_RING, 32'h200);
		if (errors == 0)
			$display("PASS atg_cp_seq.setreg");
		e0 = errors;

		/* kicks: BLIT twice (the second waits), DRAW, DISPATCH, DRAW_RAW,
		 * LOAD_CONST, LOAD_PROGRAM, INVALIDATE, PERF_RESET, DBG_MARK. */
		packet(1'b0, 1'b0, 6'd2, 8'd0, 8'd0);
		pl[0] = 32'h005; pl[1] = 32'h55;	/* BLT state while the first blit runs */
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd2);
		packet(1'b0, 1'b0, 6'd2, 8'd1, 8'd0);
		packet(1'b0, 1'b0, 6'd3, 8'd0, 8'd0);
		pl[0] = 32'h021; pl[1] = 32'h77;	/* VF state while the draw runs */
		pl[2] = 32'h1C2; pl[3] = 32'h88;
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd4);
		pl[0] = 32'd4; pl[1] = 32'd5; pl[2] = 32'd6;
		packet(1'b0, 1'b0, 6'd4, 8'd0, 8'd3);
		pl[0] = 32'h095; pl[1] = 32'h99;	/* TU state while the SUs run */
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd2);
		for (i = 0; i < 9; i = i + 1)
			pl[i] = 32'h900 + i;
		packet(1'b0, 1'b1, 6'd0, 8'd0, 8'd9);
		pl[0] = 32'd1; pl[1] = 32'h4000; pl[2] = 32'd16;
		packet(1'b0, 1'b0, 6'd7, 8'd0, 8'd3);
		pl[0] = 32'd0;
		packet(1'b0, 1'b0, 6'd8, 8'd0, 8'd1);
		packet(1'b0, 1'b0, 6'd12, 8'h05, 8'd0);
		packet(1'b0, 1'b0, 6'd10, 8'd0, 8'd0);
		pl[0] = 32'hD00D; pl[1] = 32'hEEEE;	/* a longer payload is skipped */
		packet(1'b0, 1'b1, 6'd1, 8'd0, 8'd2);
		expect_ev({8'h02, 56'd0});
		expect_ev({8'h01, 15'd0, 9'h005, 32'h55});
		expect_ev({8'h02, 56'd0});
		expect_ev({8'h03, 56'd0});	/* the same cycle as inv */
		expect_ev({8'h07, 52'd0, 4'b0011});
		expect_ev({8'h01, 15'd0, 9'h021, 32'h77});
		expect_ev({8'h01, 15'd0, 9'h1C2, 32'h88});
		expect_ev({8'h01, 15'd0, 9'h1E9, 32'd4});
		expect_ev({8'h01, 15'd0, 9'h1EA, 32'd5});
		expect_ev({8'h01, 15'd0, 9'h1EB, 32'd6});
		expect_ev({8'h04, 56'd0});
		expect_ev({8'h01, 15'd0, 9'h095, 32'h99});
		for (i = 0; i < 9; i = i + 1) begin
			sidx = 9'h1E0 + i;
			expect_ev({8'h01, 15'd0, sidx, 32'h900 + i});
		end
		expect_ev({8'h06, 56'd0});
		expect_ev({8'h01, 15'd0, 9'h1EC, 32'd1});
		expect_ev({8'h01, 15'd0, 9'h1ED, 32'h4000});
		expect_ev({8'h01, 15'd0, 9'h1EE, 32'd16});
		expect_ev({8'h05, 56'd0});
		expect_ev({8'h07, 52'd0, 4'b1000});
		expect_ev({8'h07, 52'd0, 4'b0101});
		expect_ev({8'h08, 56'd0});
		expect_ev({8'h01, 15'd0, 9'h1FF, 32'hD00D});
		settle("kicks");
		compare("kicks");
		if (errors == e0)
			$display("PASS atg_cp_seq.kicks");
		e0 = errors;

		/* drawstate: the next draw's RX and ROP state (MS_CTRL, BLEND)
		 * right after a DRAW, while the draw is still in the VF, and ROP
		 * state (RT_FORMAT) during a DISPATCH (the SUs busy): the writes
		 * wait (the monitor above checks the busy bits at each write). */
		packet(1'b0, 1'b0, 6'd3, 8'd0, 8'd0);
		pl[0] = 32'h05E; pl[1] = 32'h2;
		pl[2] = 32'h07A; pl[3] = 32'h1234;
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd4);
		pl[0] = 32'd1; pl[1] = 32'd1; pl[2] = 32'd1;
		packet(1'b0, 1'b0, 6'd4, 8'd0, 8'd3);
		pl[0] = 32'h072; pl[1] = 32'h1;
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd2);
		expect_ev({8'h03, 56'd0});
		expect_ev({8'h07, 52'd0, 4'b0011});
		expect_ev({8'h01, 15'd0, 9'h05E, 32'h2});
		expect_ev({8'h01, 15'd0, 9'h07A, 32'h1234});
		expect_ev({8'h01, 15'd0, 9'h1E9, 32'd1});
		expect_ev({8'h01, 15'd0, 9'h1EA, 32'd1});
		expect_ev({8'h01, 15'd0, 9'h1EB, 32'd1});
		expect_ev({8'h04, 56'd0});
		expect_ev({8'h01, 15'd0, 9'h072, 32'h1});
		settle("drawstate");
		compare("drawstate");
		if (errors == e0)
			$display("PASS atg_cp_seq.drawstate");
		e0 = errors;

		/* tuwait, progwait, ldconst, attrlimit_wait: right after a DRAW
		 * (the VF busy), TU state (0x095), program state (FS_BASE 0x192),
		 * a LOAD_CONST and ATTR_LIMIT (0x1D2) wait until the VF is idle
		 * (the monitor checks each write and kick). */
		begin : more
			reg [8:0] wi [0:3];
			wi[0] = 9'h095; wi[1] = 9'h192; wi[2] = 9'h000; wi[3] = 9'h1D2;
			for (i = 0; i < 4; i = i + 1) begin
				packet(1'b0, 1'b0, 6'd3, 8'd0, 8'd0);
				expect_ev({8'h03, 56'd0});
				expect_ev({8'h07, 52'd0, 4'b0011});
				if (i == 2) begin
					pl[0] = 32'd1; pl[1] = 32'h4000; pl[2] = 32'd16;
					packet(1'b0, 1'b0, 6'd7, 8'd0, 8'd3);
					expect_ev({8'h01, 15'd0, 9'h1EC, 32'd1});
					expect_ev({8'h01, 15'd0, 9'h1ED, 32'h4000});
					expect_ev({8'h01, 15'd0, 9'h1EE, 32'd16});
					expect_ev({8'h05, 56'd0});
				end else begin
					pl[0] = {23'd0, wi[i]}; pl[1] = 32'h600D + i;
					packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd2);
					expect_ev({8'h01, 15'd0, wi[i], 32'h600D + i});
				end
				settle("more");
				compare("more");
				if (errors == e0)
					$display("PASS atg_cp_seq.%0s", i == 0 ? "tuwait" : i == 1 ? "progwait" :
						i == 2 ? "ldconst" : "attrlimit_wait");
				e0 = errors;
			end
		end

		/* wait: WAIT_IDLE(BLT) with a long SU job: DBG_MARK comes after the
		 * BLT is idle but while the SUs still run. */
		su_len = 300;
		pl[0] = 32'd1; pl[1] = 32'd1; pl[2] = 32'd1;
		packet(1'b0, 1'b0, 6'd4, 8'd0, 8'd3);
		packet(1'b0, 1'b0, 6'd2, 8'd0, 8'd0);
		packet(1'b0, 1'b0, 6'd6, 8'h02, 8'd0);
		pl[0] = 32'hBEEF;
		packet(1'b0, 1'b1, 6'd1, 8'd0, 8'd1);
		mark_t = 0;
		while (!(uop_we && uop_idx == 9'h1FF) && mark_t < 2000) begin
			@(posedge clk);
			#1;
			mark_t = mark_t + 1;
		end
		if (busy_in[1] || !busy_in[6]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_seq.wait: DBG_MARK with busy %b", busy_in);
		end
		/* WAIT_IDLE(0) waits for all. */
		packet(1'b0, 1'b0, 6'd6, 8'h00, 8'd0);
		pl[0] = 32'hCAFE;
		packet(1'b0, 1'b1, 6'd1, 8'd0, 8'd1);
		mark_t = 0;
		while (!(uop_we && uop_wdata == 32'hCAFE) && mark_t < 2000) begin
			@(posedge clk);
			#1;
			mark_t = mark_t + 1;
		end
		if (busy_in != 8'd0) begin
			errors = errors + 1;
			$display("FAIL atg_cp_seq.wait: WAIT_IDLE(all) with busy %b", busy_in);
		end
		su_len = 15;
		settle("wait");
		ev_n = 0;
		if (errors == e0)
			$display("PASS atg_cp_seq.wait");
		e0 = errors;

		/* fence: after a BLIT, FENCE waits for the BLT; RESULT for the fence
		 * unit; WAIT_FENCE holds the next µop until !f_busy. */
		packet(1'b0, 1'b0, 6'd2, 8'd0, 8'd0);
		pl[0] = 32'h100; pl[1] = 32'd7;
		packet(1'b0, 1'b0, 6'd5, 8'd1, 8'd2);
		pl[0] = 32'h108; pl[1] = 32'h11; pl[2] = 32'h22;
		packet(1'b0, 1'b0, 6'd13, 8'd0, 8'd3);
		pl[0] = 32'h104; pl[1] = 32'd9;
		packet(1'b0, 1'b0, 6'd9, 8'd0, 8'd2);
		packet(1'b0, 1'b0, 6'd10, 8'd0, 8'd0);
		expect_ev({8'h02, 56'd0});
		expect_ev({8'h09, 6'd0, 2'd0, 1'b1, 15'd0, 32'h100 ^ 32'd7});
		expect_ev({8'h09, 6'd0, 2'd1, 1'b0, 15'd0, 32'h108 ^ 32'h11 ^ 32'h22});
		expect_ev({8'h09, 6'd0, 2'd2, 1'b0, 15'd0, 32'h104 ^ 32'd9});
		expect_ev({8'h08, 56'd0});
		/* PERF_RESET only after the WAIT_FENCE's f_busy fell. */
		while (!perf_reset) begin
			@(posedge clk);
			#1;
		end
		if (f_busy) begin
			errors = errors + 1;
			$display("FAIL atg_cp_seq.fence: WAIT_FENCE did not wait");
		end
		settle("fence");
		compare("fence");
		if (errors == e0)
			$display("PASS atg_cp_seq.fence");
		e0 = errors;

		/* source: a firmware stream while fw_active, the ring's waits. */
		pl[0] = 32'h040; pl[1] = 32'hF1;
		packet(1'b1, 1'b0, 6'd1, 8'd0, 8'd2);
		pl[0] = 32'h041; pl[1] = 32'hF2;
		packet(1'b1, 1'b0, 6'd1, 8'd0, 8'd2);
		@(negedge clk);
		fw_active = 1;
		pl[0] = 32'h042; pl[1] = 32'hA1;
		packet(1'b0, 1'b0, 6'd1, 8'd0, 8'd2);
		while (fq_head != fq_tail || busy) @(negedge clk);
		@(negedge clk);
		fw_active = 0;
		expect_ev({8'h01, 15'd0, 9'h040, 32'hF1});
		expect_ev({8'h01, 15'd0, 9'h041, 32'hF2});
		expect_ev({8'h01, 15'd0, 9'h042, 32'hA1});
		settle("source");
		compare("source");
		/* halt: no header is taken. */
		halt = 1;
		packet(1'b0, 1'b0, 6'd10, 8'd0, 8'd0);
		repeat (50) @(negedge clk);
		if (rq_head == rq_tail) begin
			errors = errors + 1;
			$display("FAIL atg_cp_seq.source: header taken while halted");
		end
		halt = 0;
		expect_ev({8'h08, 56'd0});
		settle("source");
		compare("source");
		if (errors == e0)
			$display("PASS atg_cp_seq.source");
		e0 = errors;

		/* query: QUERY flags[0] clears without waiting (while the BLT is
		 * busy); flags 0 waits for every block and the fence unit and writes
		 * {lo, hi} by the RESULT request; flags[1] clears after taking it. */
		occ_count = 40'hA5_1234_5678;
		packet(1'b0, 1'b0, 6'd2, 8'd0, 8'd0);
		pl[0] = 32'h200;
		packet(1'b0, 1'b0, 6'd14, 8'd1, 8'd1);
		pl[0] = 32'h208;
		packet(1'b0, 1'b0, 6'd14, 8'd0, 8'd1);
		pl[0] = 32'h210;
		packet(1'b0, 1'b0, 6'd14, 8'd2, 8'd1);
		expect_ev({8'h02, 56'd0});
		expect_ev({8'h0A, 24'd0, 32'h12345678});
		expect_ev({8'h09, 6'd0, 2'd1, 1'b0, 15'd0, 32'h208 ^ 32'h12345678 ^ 32'h000000A5});
		expect_ev({8'h09, 6'd0, 2'd1, 1'b0, 15'd0, 32'h210 ^ 32'h12345678 ^ 32'h000000A5});
		expect_ev({8'h0A, 24'd0, 32'h12345678});
		/* the clear-only QUERY must not wait for the BLT */
		while (!occ_clear) begin
			@(posedge clk);
			#1;
		end
		if (!busy_in[1]) begin
			errors = errors + 1;
			$display("FAIL atg_cp_seq.query: the clear waited for the BLT");
		end
		settle("query");
		compare("query");
		if (errors == e0)
			$display("PASS atg_cp_seq.query");
		e0 = errors;

		/* badop: op 15, vendor op 5, class 2; a short payload (kind 3);
		 * DRAW without a VF (kind 2). */
		packet(1'b0, 1'b0, 6'd15, 8'd0, 8'd0);
		expect_fault("badop", GHCI_FAULT_OPCODE, 32'd0);
		packet(1'b0, 1'b1, 6'd5, 8'd0, 8'd0);
		expect_fault("badop", GHCI_FAULT_OPCODE, 32'd0);
		push(1'b0, {2'b10, 6'd0, 8'hA5, 16'd0}, 1'b1);
		expect_fault("badop", GHCI_FAULT_OPCODE, 32'd0);
		pl[0] = 32'h100;
		packet(1'b0, 1'b0, 6'd5, 8'd0, 8'd1);
		expect_fault("badop", GHCI_FAULT_RING, 32'd0);
		@(negedge clk);
		s_data = hdr(1'b0, 6'd3, 8'd0, 8'd0);
		s_valid = 1;
		@(negedge clk);
		s_valid = 0;
		repeat (3) @(negedge clk);
		if (!s_seen) begin
			errors = errors + 1;
			$display("FAIL atg_cp_seq.badop: DRAW without a VF");
		end
		if (errors == e0)
			$display("PASS atg_cp_seq.badop");
		if (errors == 0)
			$display("PASS atg_cp_seq");
		else
			$display("FAIL atg_cp_seq: %0d errors", errors);
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_cp_seq: timeout");
		$finish;
	end
endmodule

`default_nettype wire
