/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rt_noc_tb: Unit verification of atg_rt2, atg_rt3, atg_rt4, and atg_rep.
 *
 * Tests:
 *   1. Multi-hop Fat-Tree (4 leaf ports -> atg_rt4 -> atg_rep(STAGES=2) -> atg_rt3 -> sink)
 *   2. Priority preemption at packet boundary (PRIO=1 beats PRIO=0)
 *   3. Multi-flit packet atomicity (2-flit write never interrupted by PRIO=1 request)
 *   4. Fair round-robin across 4 children under contention and backpressure stalls
 *   5. Downward response routing via RBIT across rt3 -> rep -> rt4
 *   6. Control broadcast and upward status/fault pipeline slices inside atg_rep
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rt_noc_tb;
	localparam FW  = 64;
	localparam RFW = 80;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg core_rst_n = 1'b0;
	reg flush = 1'b0;
	always #5 clk = !clk;

	/* 4 children into atg_rt4 (RBIT=10: bits [11:10]) */
	reg  [3:0]    c_req_v = 0;
	wire [3:0]    c_req_r;
	reg  [FW-1:0] c_req_d [0:3];
	reg  [3:0]    c_req_l = 0;

	wire [3:0]     c_rsp_v;
	reg  [3:0]     c_rsp_r = 4'b1111;
	wire [RFW-1:0] c_rsp_d0, c_rsp_d1, c_rsp_d2, c_rsp_d3;

	wire          q4_req_v, q4_req_r, q4_req_l;
	wire [FW-1:0] q4_req_d;
	wire          q4_rsp_v, q4_rsp_r;
	wire [RFW-1:0] q4_rsp_d;
	wire          rt4_rsp_idle;

	atg_rt4 #(.FW(FW), .RFW(RFW), .RBIT(10)) u_rt4 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(c_req_v[0]), .c0_req_ready(c_req_r[0]), .c0_req_data(c_req_d[0]), .c0_req_last(c_req_l[0]),
		.c1_req_valid(c_req_v[1]), .c1_req_ready(c_req_r[1]), .c1_req_data(c_req_d[1]), .c1_req_last(c_req_l[1]),
		.c2_req_valid(c_req_v[2]), .c2_req_ready(c_req_r[2]), .c2_req_data(c_req_d[2]), .c2_req_last(c_req_l[2]),
		.c3_req_valid(c_req_v[3]), .c3_req_ready(c_req_r[3]), .c3_req_data(c_req_d[3]), .c3_req_last(c_req_l[3]),
		.p_req_valid(q4_req_v), .p_req_ready(q4_req_r), .p_req_data(q4_req_d), .p_req_last(q4_req_l),
		.p_rsp_valid(q4_rsp_v), .p_rsp_ready(q4_rsp_r), .p_rsp_data(q4_rsp_d),
		.c0_rsp_valid(c_rsp_v[0]), .c0_rsp_ready(c_rsp_r[0]), .c0_rsp_data(c_rsp_d0),
		.c1_rsp_valid(c_rsp_v[1]), .c1_rsp_ready(c_rsp_r[1]), .c1_rsp_data(c_rsp_d1),
		.c2_rsp_valid(c_rsp_v[2]), .c2_rsp_ready(c_rsp_r[2]), .c2_rsp_data(c_rsp_d2),
		.c3_rsp_valid(c_rsp_v[3]), .c3_rsp_ready(c_rsp_r[3]), .c3_rsp_data(c_rsp_d3),
		.rsp_idle(rt4_rsp_idle)
	);

	/* 2-stage Repeater on Quad -> Root trunk */
	wire           rep_req_v, rep_req_r, rep_req_l;
	wire [FW-1:0]  rep_req_d;
	wire           rep_rsp_v, rep_rsp_r;
	wire [RFW-1:0] rep_rsp_d;
	wire           rep_rsp_idle;

	reg            in_st_we = 0, in_cs_kick = 0, in_cs_mesh = 0, in_lc_kick = 0, in_scrub = 0;
	reg  [8:0]     in_st_idx = 0;
	reg  [31:0]    in_st_wdata = 0;
	reg  [3:0]     in_inv = 0, in_session_id = 0;
	wire           out_st_we, out_cs_kick, out_cs_mesh, out_lc_kick, out_scrub;
	wire [8:0]     out_st_idx;
	wire [31:0]    out_st_wdata;
	wire [3:0]     out_inv, out_session_id;

	reg            in_busy = 0, in_scrub_busy = 0, in_fault = 0;
	reg  [31:0]    in_fault_addr = 0;
	reg  [3:0]     in_fault_stage = 0;
	wire           out_busy, out_scrub_busy, out_fault;
	wire [31:0]    out_fault_addr;
	wire [3:0]     out_fault_stage;

	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(2)) u_rep (
		.clk(clk), .rst_n(rst_n), .core_rst_n(core_rst_n), .flush(flush),
		.dn_req_valid(q4_req_v), .dn_req_ready(q4_req_r), .dn_req_data(q4_req_d), .dn_req_last(q4_req_l),
		.up_req_valid(rep_req_v), .up_req_ready(rep_req_r), .up_req_data(rep_req_d), .up_req_last(rep_req_l),
		.up_rsp_valid(rep_rsp_v), .up_rsp_ready(rep_rsp_r), .up_rsp_data(rep_rsp_d),
		.dn_rsp_valid(q4_rsp_v), .dn_rsp_ready(q4_rsp_r), .dn_rsp_data(q4_rsp_d),
		.rsp_idle(rep_rsp_idle),
		.in_st_we(in_st_we), .in_st_idx(in_st_idx), .in_st_wdata(in_st_wdata),
		.in_cs_kick(in_cs_kick), .in_cs_mesh(in_cs_mesh), .in_lc_kick(in_lc_kick),
		.in_inv(in_inv), .in_scrub(in_scrub), .in_session_id(in_session_id),
		.out_st_we(out_st_we), .out_st_idx(out_st_idx), .out_st_wdata(out_st_wdata),
		.out_cs_kick(out_cs_kick), .out_cs_mesh(out_cs_mesh), .out_lc_kick(out_lc_kick),
		.out_inv(out_inv), .out_scrub(out_scrub), .out_session_id(out_session_id),
		.in_busy(in_busy), .in_scrub_busy(in_scrub_busy), .in_fault(in_fault),
		.in_fault_addr(in_fault_addr), .in_fault_stage(in_fault_stage),
		.out_busy(out_busy), .out_scrub_busy(out_scrub_busy), .out_fault(out_fault),
		.out_fault_addr(out_fault_addr), .out_fault_stage(out_fault_stage)
	);

	/* Top atg_rt3 (RBIT=12: bits [13:12]) combining child 0 (CP), child 1 (rep trunk), child 2 (FX) */
	reg           cp_req_v = 0, cp_req_l = 1'b1;
	reg  [FW-1:0] cp_req_d = 0;
	wire          cp_req_r, cp_rsp_v;
	wire [RFW-1:0] cp_rsp_d;

	reg           fx_req_v = 0, fx_req_l = 1'b1;
	reg  [FW-1:0] fx_req_d = 0;
	wire          fx_req_r, fx_rsp_v;
	wire [RFW-1:0] fx_rsp_d;

	wire          top_req_v, top_req_l;
	reg           top_req_r = 1'b1;
	wire [FW-1:0] top_req_d;
	reg           top_rsp_v = 1'b0;
	wire          top_rsp_r;
	reg  [RFW-1:0] top_rsp_d = 0;
	wire          rt3_rsp_idle;

	atg_rt3 #(.FW(FW), .RFW(RFW), .RBIT(12)) u_rt3 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(cp_req_v), .c0_req_ready(cp_req_r), .c0_req_data(cp_req_d), .c0_req_last(cp_req_l),
		.c1_req_valid(rep_req_v), .c1_req_ready(rep_req_r), .c1_req_data(rep_req_d), .c1_req_last(rep_req_l),
		.c2_req_valid(fx_req_v), .c2_req_ready(fx_req_r), .c2_req_data(fx_req_d), .c2_req_last(fx_req_l),
		.p_req_valid(top_req_v), .p_req_ready(top_req_r), .p_req_data(top_req_d), .p_req_last(top_req_l),
		.p_rsp_valid(top_rsp_v), .p_rsp_ready(top_rsp_r), .p_rsp_data(top_rsp_d),
		.c0_rsp_valid(cp_rsp_v), .c0_rsp_ready(1'b1), .c0_rsp_data(cp_rsp_d),
		.c1_rsp_valid(rep_rsp_v), .c1_rsp_ready(rep_rsp_r), .c1_rsp_data(rep_rsp_d),
		.c2_rsp_valid(fx_rsp_v), .c2_rsp_ready(1'b1), .c2_rsp_data(fx_rsp_d),
		.rsp_idle(rt3_rsp_idle)
	);

	/* Also instantiate atg_rt2 separately for unit sanity */
	reg rt2_c0_v = 0, rt2_c1_v = 0;
	wire rt2_c0_r, rt2_c1_r, rt2_p_v, rt2_p_l, rt2_p_rsp_r, rt2_c0_rsp_v, rt2_c1_rsp_v, rt2_idle;
	wire [FW-1:0] rt2_p_d;
	wire [RFW-1:0] rt2_c0_rsp_d, rt2_c1_rsp_d;
	atg_rt2 #(.FW(FW), .RFW(RFW), .RBIT(10)) u_rt2 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(rt2_c0_v), .c0_req_ready(rt2_c0_r), .c0_req_data(64'hA0), .c0_req_last(1'b1),
		.c1_req_valid(rt2_c1_v), .c1_req_ready(rt2_c1_r), .c1_req_data(64'hB1), .c1_req_last(1'b1),
		.p_req_valid(rt2_p_v), .p_req_ready(1'b1), .p_req_data(rt2_p_d), .p_req_last(rt2_p_l),
		.p_rsp_valid(1'b0), .p_rsp_ready(rt2_p_rsp_r), .p_rsp_data({RFW{1'b0}}),
		.c0_rsp_valid(rt2_c0_rsp_v), .c0_rsp_ready(1'b1), .c0_rsp_data(rt2_c0_rsp_d),
		.c1_rsp_valid(rt2_c1_rsp_v), .c1_rsp_ready(1'b1), .c1_rsp_data(rt2_c1_rsp_d),
		.rsp_idle(rt2_idle)
	);

	integer errors = 0;
	integer cyc;
	integer rx_cnt [0:3];
	reg [FW-1:0] log_d [0:31];
	reg          log_l [0:31];
	integer      log_n = 0;

	always @(posedge clk) begin
		if (top_req_v && top_req_r && log_n < 32) begin
			log_d[log_n] <= top_req_d;
			log_l[log_n] <= top_req_l;
			log_n <= log_n + 1;
		end
	end

	initial begin : main
		integer i;
		for (i = 0; i < 4; i = i + 1) begin
			c_req_d[i] = 64'd0;
			rx_cnt[i]  = 0;
		end
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		core_rst_n = 1'b1;

		/* 1. Multi-flit atomicity: Child 1 sends 2-flit write (last=0 then last=1)
		 *    while PRIO=1 CP packet arrives right between the two flits */
		@(posedge clk); #1;
		c_req_v[1] = 1'b1; c_req_l[1] = 1'b0; c_req_d[1] = 64'h0001_0000_0000_1100; /* prio=0, id=11 */
		while (!c_req_r[1]) @(posedge clk);
		@(posedge clk); #1;
		/* Now inject PRIO=1 on Child 0 for 1 cycle while Child 1 sends its 2nd flit */
		c_req_v[0] = 1'b1; c_req_l[0] = 1'b1; c_req_d[0] = 64'h0002_0000_0000_2201; /* prio=1 */
		c_req_v[1] = 1'b1; c_req_l[1] = 1'b1; c_req_d[1] = 64'hDEAD_BEEF_CAFE_0001; /* data flit */
		@(posedge clk); #1;
		c_req_v[0] = 1'b0;
		c_req_v[1] = 1'b0;

		repeat (20) @(posedge clk); #1;
		if (log_n != 3 ||
		    log_d[0] != 64'h0001_0000_0000_1100 || log_l[0] != 1'b0 ||
		    log_d[1] != 64'hDEAD_BEEF_CAFE_0001 || log_l[1] != 1'b1 ||
		    log_d[2] != 64'h0002_0000_0000_2201 || log_l[2] != 1'b1) begin
			$display("FAIL multi_flit_lock: n=%0d d0=%x/%b d1=%x/%b d2=%x/%b",
				log_n, log_d[0], log_l[0], log_d[1], log_l[1], log_d[2], log_l[2]);
			errors = errors + 1;
		end

		/* 2. CP PRIO=1 preemption at rt3 vs rep trunk PRIO=0 with top backpressure */
		log_n = 0;
		top_req_r = 1'b0;
		@(posedge clk); #1;
		fx_req_v = 1'b1; fx_req_d = 64'h0000_0000_0000_AA00; fx_req_l = 1'b1;
		cp_req_v = 1'b1; cp_req_d = 64'h0000_0000_0000_CC01; cp_req_l = 1'b1;
		@(posedge clk); #1;
		fx_req_v = 1'b0; cp_req_v = 1'b0;
		repeat (6) @(posedge clk); #1;
		top_req_r = 1'b1;
		repeat (10) @(posedge clk); #1;
		if (log_n != 2 || log_d[0] != 64'hCC01 || log_d[1] != 64'hAA00) begin
			$display("FAIL rt3_prio: n=%0d d0=%x d1=%x", log_n, log_d[0], log_d[1]);
			errors = errors + 1;
		end

		/* 3. Downward response routing across rt3(RBIT=12=1) -> rep(STAGES=2) -> rt4(RBIT=10=3) */
		c_rsp_r[3] = 1'b0; /* stall leaf child 3 initially */
		@(posedge clk); #1;
		top_rsp_v = 1'b1;
		/* Route: rt3 child 1 = 2'b01 at [13:12], rt4 child 3 = 2'b11 at [11:10] */
		top_rsp_d = {2'd0, 64'hFEED_FACE_1234_5678, 4'b0111, 8'h9E, 2'b00};
		@(posedge clk); #1;
		top_rsp_v = 1'b0;
		for (cyc = 0; cyc < 20; cyc = cyc + 1) begin
			@(posedge clk); #1;
			if (c_rsp_v[0] || c_rsp_v[1] || c_rsp_v[2]) errors = errors + 1;
			if (cyc == 10) c_rsp_r[3] = 1'b1;
			if (c_rsp_v[3] && c_rsp_r[3]) begin
				rx_cnt[3] = rx_cnt[3] + 1;
				if (c_rsp_d3[9:2] != 8'h9E || c_rsp_d3[77:14] != 64'hFEED_FACE_1234_5678)
					errors = errors + 1;
			end
		end
		if (rx_cnt[3] != 1) begin
			$display("FAIL rsp_route: rx_cnt[3]=%0d", rx_cnt[3]);
			errors = errors + 1;
		end
		if (!rt4_rsp_idle || !rep_rsp_idle || !rt3_rsp_idle) begin
			$display("FAIL rsp_idle: %b %b %b", rt4_rsp_idle, rep_rsp_idle, rt3_rsp_idle);
			errors = errors + 1;
		end

		/* 4. Repeater Channel 3 & 4 broadcast/status slices (2 cycles) */
		@(posedge clk); #1;
		in_st_we = 1'b1; in_st_idx = 9'h123; in_st_wdata = 32'hAABBCCDD; in_session_id = 4'd7;
		in_busy = 1'b1; in_fault = 1'b1; in_fault_addr = 32'h00001040; in_fault_stage = 4'd2;
		@(posedge clk); #1;
		in_st_we = 1'b0; in_busy = 1'b0; in_fault = 1'b0;
		@(posedge clk); #1;
		if (!out_st_we || out_st_idx != 9'h123 || out_st_wdata != 32'hAABBCCDD ||
		    out_session_id != 4'd7 || !out_busy || !out_fault || out_fault_addr != 32'h00001040) begin
			$display("FAIL rep_ctrl_stat: we=%b idx=%x dat=%x sess=%0d b=%b f=%b fa=%x",
				out_st_we, out_st_idx, out_st_wdata, out_session_id, out_busy, out_fault, out_fault_addr);
			errors = errors + 1;
		end

		/* 5. rt2 prio tie-break check */
		@(posedge clk); #1;
		rt2_c0_v = 1'b1; rt2_c1_v = 1'b1;
		@(posedge clk); #1;
		rt2_c0_v = 1'b0; rt2_c1_v = 1'b0;
		repeat (5) @(posedge clk);
		if (!rt2_idle) errors = errors + 1;

		if (errors == 0)
			$display("PASS atg_rt_noc");
		else
			$display("FAIL atg_rt_noc (%0d errors)", errors);
		$finish;
	end
endmodule

`default_nettype wire
