/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_sched_tb: the warp scheduler (NPHYS 8, NWARPS 4).  Instance a
 * (NSU 1) runs one 96-lane workgroup: rr (round-robin over the three
 * warps, never the same warp twice within 32/NPHYS cycles, f_addr =
 * CS_BASE + 8 pc), feedback (replay waits for wake, kind 1 waits for
 * wc_*), barrier, end (slots free only after xr_valid), then alloc
 * (vertex grants keep FRAG_RESERVE and need pt_ok, fragment grants take
 * any slot).  Instance b (NSU 2, SU_INDEX 1) launches a 2x2 grid of 64-lane
 * workgroups and must take ids 1 and 3 with their LIDs and q_info.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sched_tb;
`include "atg_su_uop.vh"
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg cs_kick = 1'b0;
	reg vl_req = 0, vl_go = 0, fl_req = 0, fl_go = 0;
	reg [31:0] vl_mask = 0, fl_mask = 0;
	reg [63:0] fl_info = 0;
	wire vl_gnt, fl_gnt;
	wire [1:0] vl_slot, fl_slot;
	wire f_valid;
	reg f_ready = 1'b1;
	wire [1:0] f_warp;
	wire [15:0] f_pc;
	wire [31:0] f_addr;
	reg fb_valid = 0;
	reg [1:0] fb_warp = 0, fb_kind = 0;
	reg [3:0] wake = 0;
	reg wc_valid = 0;
	reg [1:0] wc_warp = 0, wc_op = 0;
	reg [15:0] wc_pc = 0;
	reg [1:0] q_warp = 0;
	wire [159:0] q_info, q_info_b;
	wire init_valid, init_valid_b;
	wire [1:0] init_warp, init_warp_b;
	wire [31:0] init_mask, init_mask_b;
	reg pt_ok = 1'b1;
	reg xr_valid = 0;
	reg [1:0] xr_warp = 0;
	wire busy, busy_b;
	wire f_valid_b;
	wire [1:0] f_warp_b;
	wire [15:0] f_pc_b;
	wire [31:0] f_addr_b;
	integer errors = 0, ec;
	integer cyc = 0;

	always #5 clk = !clk;
	always @(posedge clk)
		cyc <= cyc + 1;

	atg_su_sched #(.NPHYS(8), .NWARPS(4), .NSU(1), .SU_INDEX(0), .FRAG_RESERVE(1), .GTO(0)) a (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .vl_req(vl_req), .vl_gnt(vl_gnt), .vl_slot(vl_slot),
		.vl_go(vl_go), .vl_mask(vl_mask), .fl_req(fl_req), .fl_gnt(fl_gnt),
		.fl_slot(fl_slot), .fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
		.f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp), .f_pc(f_pc), .f_addr(f_addr),
		.fb_valid(fb_valid), .fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake),
		.warp_ready(4'b1111),
		.wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
		.q_warp(q_warp), .q_info(q_info), .init_valid(init_valid), .init_warp(init_warp),
		.init_mask(init_mask), .pt_ok(pt_ok), .xr_valid(xr_valid), .xr_warp(xr_warp),
		.busy(busy)
	);
	atg_su_sched #(.NPHYS(8), .NWARPS(4), .NSU(2), .SU_INDEX(1), .FRAG_RESERVE(1), .GTO(0)) b (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .vl_req(1'b0), .vl_gnt(), .vl_slot(), .vl_go(1'b0),
		.vl_mask(32'd0), .fl_req(1'b0), .fl_gnt(), .fl_slot(), .fl_go(1'b0),
		.fl_mask(32'd0), .fl_info(64'd0),
		.f_valid(f_valid_b), .f_ready(1'b0), .f_warp(f_warp_b), .f_pc(f_pc_b),
		.f_addr(f_addr_b), .fb_valid(1'b0), .fb_warp(2'd0), .fb_kind(2'd0), .wake(4'd0),
		.warp_ready(4'b1111),
		.wc_valid(1'b0), .wc_warp(2'd0), .wc_op(2'd0), .wc_pc(16'd0),
		.q_warp(q_warp), .q_info(q_info_b), .init_valid(init_valid_b),
		.init_warp(init_warp_b), .init_mask(init_mask_b), .pt_ok(1'b1), .xr_valid(1'b0),
		.xr_warp(2'd0), .busy(busy_b)
	);

	task fail;
		input [8*48-1:0] what;
		begin
			$display("FAIL atg_su_sched.%0s", what);
			errors = errors + 1;
		end
	endtask

	task state;
		input [8:0] idx;
		input [31:0] v;
		begin
			@(negedge clk);
			st_we = 1'b1;
			st_idx = idx;
			st_wdata = v;
			@(negedge clk);
			st_we = 1'b0;
		end
	endtask

	/* The front-end model: every fetch gets feedback fb_delay cycles later
	 * with the kind given per warp in fb_mode (0 issued; 3 = hold, no feedback). */
	reg [1:0] fb_mode [0:3];
	reg [31:0] due [0:3];
	reg pend [0:3];
	integer last_fetch [0:3];
	reg [15:0] last_pc [0:3];
	integer n_fetch [0:3];
	integer seq_n;
	reg [1:0] seq [0:63];
	integer w;
	always @(negedge clk) begin
		fb_valid = 1'b0;
		for (w = 0; w < 4; w = w + 1)
			if (pend[w] && due[w] <= cyc && !fb_valid) begin
				pend[w] = 1'b0;
				if (fb_mode[w] != 2'd3) begin
					fb_valid = 1'b1;
					fb_warp = w;
					fb_kind = fb_mode[w];
				end
			end
	end
	always @(posedge clk) begin
		if (rst_n && f_valid && f_ready) begin
			if (cyc - last_fetch[f_warp] < 4)
				fail("rr spacing");
			if (f_addr !== 32'h1000 + 8 * f_pc)
				fail("rr f_addr");
			last_fetch[f_warp] = cyc;
			last_pc[f_warp] = f_pc;
			n_fetch[f_warp] = n_fetch[f_warp] + 1;
			if (seq_n < 64)
				seq[seq_n] = f_warp;
			seq_n = seq_n + 1;
			pend[f_warp] = 1'b1;
			due[f_warp] = cyc + 3;
		end
	end

	integer k, n0, n1, n2;
	initial begin
		for (k = 0; k < 4; k = k + 1) begin
			fb_mode[k] = 0;
			pend[k] = 0;
			last_fetch[k] = -100;
			n_fetch[k] = 0;
		end
		seq_n = 0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		state(9'h194, 32'h1000);
		state(9'h199, 32'h010140);	/* 64 lanes for b first */
		state(9'h1E9, 2);
		state(9'h1EA, 2);
		state(9'h1EB, 1);
		/* compute (instance b; a's launch of 64-lane groups is discarded below) */
		ec = errors;
		@(negedge clk);
		cs_kick = 1'b1;
		@(negedge clk);
		cs_kick = 1'b0;
		repeat (30) @(negedge clk);
		/* b: workgroups 1 = (1,0) and 3 = (1,1), two warps each, LID 0/32. */
		n0 = 0;
		for (k = 0; k < 4; k = k + 1) begin
			q_warp = k;
			#1;
			if (q_info_b[ATG_WI_KIND +: 2] !== 2'd2 || q_info_b[ATG_WI_WGX +: 16] !== 16'd1 ||
			    q_info_b[ATG_WI_WGX + 16 +: 16] !== (k >= 2) ||
			    q_info_b[ATG_WI_LID +: 8] !== (k % 2) * 32 ||
			    q_info_b[ATG_WI_NWGX +: 48] !== {16'd1, 16'd2, 16'd2} ||
			    q_info_b[ATG_WI_MASK +: 32] !== 32'hFFFFFFFF)
				begin fail("compute q_info"); $display("  k%0d kind %0d wg %0d,%0d lid %0d nwg %h mask %h", k, q_info_b[105:104], q_info_b[15:0], q_info_b[31:16], q_info_b[103:96], q_info_b[95:48], q_info_b[159:128]); end
		end
		if (!busy_b)
			fail("compute busy");
		if (errors == ec)
			$display("PASS atg_su_sched.compute");
		/* Reset a (it launched all of its 4 workgroups... start over). */
		rst_n = 1'b0;
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		for (k = 0; k < 4; k = k + 1) begin
			n_fetch[k] = 0;
			last_fetch[k] = -100;
			pend[k] = 0;
		end
		seq_n = 0;
		state(9'h194, 32'h1000);
		state(9'h199, 32'h010160);	/* 96 lanes */
		state(9'h1E9, 1);
		state(9'h1EA, 1);
		state(9'h1EB, 1);
		/* rr */
		ec = errors;
		@(negedge clk);
		cs_kick = 1'b1;
		@(negedge clk);
		cs_kick = 1'b0;
		repeat (60) @(negedge clk);
		if (n_fetch[0] < 5 || n_fetch[1] < 5 || n_fetch[2] < 5 || n_fetch[3] != 0)
			fail("rr counts");
		for (k = 3; k < 30; k = k + 1)
			if (seq[k] == seq[k-1] || seq[k] == seq[k-2])
				fail("rr order");
		if (errors == ec)
			$display("PASS atg_su_sched.rr");
		/* feedback: warp 1 replays until wake; warp 2 waits for wc. */
		ec = errors;
		fb_mode[1] = 2;
		fb_mode[2] = 1;
		repeat (20) @(negedge clk);
		n1 = n_fetch[1];
		n2 = n_fetch[2];
		k = last_pc[1];
		repeat (20) @(negedge clk);
		if (n_fetch[1] != n1 || n_fetch[2] != n2)
			fail("feedback fetched while waiting");
		fb_mode[1] = 0;
		wake = 4'b0010;
		@(negedge clk);
		wake = 0;
		repeat (4) @(negedge clk);
		if (n_fetch[1] != n1 + 1 || last_pc[1] != k)
			fail("feedback replay pc");
		fb_mode[2] = 0;
		wc_valid = 1'b1;
		wc_warp = 2;
		wc_op = 0;
		wc_pc = 16'h40;
		@(negedge clk);
		wc_valid = 1'b0;
		repeat (3) @(negedge clk);
		if (last_pc[2] != 16'h40)
			fail("feedback wc_pc");
		if (errors == ec)
			$display("PASS atg_su_sched.feedback");
		/* barrier: all three wait for wc; 0 and 1 arrive, then 2. */
		ec = errors;
		for (k = 0; k < 3; k = k + 1)
			fb_mode[k] = 1;
		repeat (20) @(negedge clk);
		for (k = 0; k < 2; k = k + 1) begin
			wc_valid = 1'b1;
			wc_warp = k;
			wc_op = 2;
			wc_pc = 16'h80 + k;
			fb_mode[k] = 0;
			@(negedge clk);
			wc_valid = 1'b0;
		end
		n0 = n_fetch[0];
		repeat (10) @(negedge clk);
		if (n_fetch[0] != n0)
			fail("barrier released early");
		wc_valid = 1'b1;
		wc_warp = 2;
		wc_op = 2;
		wc_pc = 16'h82;
		@(negedge clk);
		wc_valid = 1'b0;
		repeat (8) @(negedge clk);
		if (n_fetch[0] == n0 || last_pc[2] != 16'h82)
			fail("barrier release");
		/* Park everything for the end test: kind 1 on the next fetch. */
		for (k = 0; k < 3; k = k + 1)
			fb_mode[k] = 1;
		repeat (12) @(negedge clk);
		if (errors == ec)
			$display("PASS atg_su_sched.barrier");
		/* end */
		ec = errors;
		for (k = 0; k < 3; k = k + 1) begin
			wc_valid = 1'b1;
			wc_warp = k;
			wc_op = 1;
			@(negedge clk);
		end
		wc_valid = 1'b0;
		repeat (4) @(negedge clk);
		if (!busy)
			fail("end busy before xr");
		/* Ended slots stay taken: three vertex requests cannot get a slot
		 * beyond FRAG_RESERVE (only slot 3 is free). */
		vl_req = 1'b1;
		#1;
		if (vl_gnt)
			fail("end slot freed early");
		vl_req = 1'b0;
		for (k = 0; k < 3; k = k + 1) begin
			@(negedge clk);
			xr_valid = 1'b1;
			xr_warp = k;
		end
		@(negedge clk);
		xr_valid = 1'b0;
		@(negedge clk);
		if (busy)
			fail("end busy after xr");
		if (errors == ec)
			$display("PASS atg_su_sched.end");
		/* alloc */
		ec = errors;
		f_ready = 1'b0;
		pt_ok = 1'b0;
		vl_req = 1'b1;
		#1;
		if (vl_gnt)
			fail("alloc vertex without pt_ok");
		pt_ok = 1'b1;
		for (k = 0; k < 3; k = k + 1) begin
			#1;
			if (!vl_gnt)
				fail("alloc vertex grant");
			@(negedge clk);
			vl_req = 1'b0;
			vl_go = 1'b1;
			vl_mask = 32'h0000FFFF;
			#1;
			if (!init_valid || init_mask !== 32'h0000FFFF)
				fail("alloc init");
			@(negedge clk);
			vl_go = 1'b0;
			vl_req = 1'b1;
		end
		#1;
		if (vl_gnt)
			fail("alloc FRAG_RESERVE");
		vl_req = 1'b0;
		fl_req = 1'b1;
		#1;
		if (!fl_gnt)
			fail("alloc fragment");
		@(negedge clk);
		fl_req = 1'b0;
		fl_go = 1'b1;
		fl_mask = 32'hF0F0F0F0;
		fl_info = {16'd0, 1'b1, 16'h1234, 32'hFFFF0000};
		q_warp = fl_slot;
		#1;
		if (!init_valid || init_mask !== 32'hF0F0F0F0)
			fail("alloc fragment init");
		@(negedge clk);
		fl_go = 1'b0;
		#1;
		if (q_info[ATG_WI_KIND +: 2] !== 2'd1 || q_info[ATG_WI_SEQ +: 16] !== 16'h1234 ||
		    !q_info[ATG_WI_FRONT] || q_info[ATG_WI_MASK +: 32] !== 32'hFFFF0000)
			fail("alloc fragment info");
		if (errors == ec)
			$display("PASS atg_su_sched.alloc");
		if (errors == 0)
			$display("PASS atg_su_sched");
		$finish;
	end

	initial begin
		#1000000;
		$display("FAIL atg_su_sched timeout");
		$finish;
	end
endmodule

`default_nettype wire
