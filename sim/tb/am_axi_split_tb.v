/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_split_tb: am_axi_split with two axi_id_slave models (range 0 =
 * [0x8000_0000, +1 GiB), range 1 = [0, 2 GiB), DECERR above 0xC000_0000)
 * and a random master: NTX bursts of random direction, ID (4 IDs),
 * destination and length (1-4 beats), W sometimes before its AW, random
 * B/R ready.  Checked: every burst reaches the right slave with its data
 * (the slaves check the write data), the responses of each ID come back
 * in order with the right RESP (DECERR outside the ranges) and read data
 * (the slave's pattern, zeros for DECERR), R bursts never interleave,
 * RLAST on the last beat, B/R stable while not ready, every burst
 * answered.  Two shapes: (a) slave 0 slow, slave 1 fast; (b) slave 1
 * waits for WVALID before AWREADY, both fast.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_split_harness #(
	parameter PCT0 = 20,
	parameter PCT1 = 80,
	parameter WAIT1 = 0,
	parameter NTX = 1500,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg finished,
	output integer errors
);
	localparam D_W = 64;
	localparam ID_W = 2;
	localparam QN = 256;

	`include "axi_id_data.vh"

	reg [ID_W-1:0] awid = 0, arid = 0;
	reg [31:0] awaddr = 0, araddr = 0;
	reg [7:0] awlen = 0, arlen = 0;
	reg awvalid = 1'b0, arvalid = 1'b0, wvalid = 1'b0, wlast = 1'b0;
	reg [D_W-1:0] wdata = 0;
	reg bready = 1'b0, rready = 1'b0;
	wire awready, wready, bvalid, arready, rvalid, rlast;
	wire [ID_W-1:0] bid, rid;
	wire [1:0] bresp, rresp;
	wire [D_W-1:0] rdata;

	wire [ID_W-1:0] a0_awid, a0_bid, a0_arid, a0_rid, a1_awid, a1_bid, a1_arid, a1_rid;
	wire [31:0] a0_awaddr, a0_araddr, a1_awaddr, a1_araddr;
	wire [7:0] a0_awlen, a0_arlen, a1_awlen, a1_arlen;
	wire [2:0] a0_awsize, a0_arsize, a0_awprot, a0_arprot, a1_awsize, a1_arsize, a1_awprot, a1_arprot;
	wire [1:0] a0_awburst, a0_arburst, a0_bresp, a0_rresp, a1_awburst, a1_arburst, a1_bresp, a1_rresp;
	wire [3:0] a0_awcache, a0_arcache, a1_awcache, a1_arcache;
	wire a0_awvalid, a0_awready, a0_wlast, a0_wvalid, a0_wready, a0_bvalid, a0_bready;
	wire a0_arvalid, a0_arready, a0_rlast, a0_rvalid, a0_rready;
	wire a1_awvalid, a1_awready, a1_wlast, a1_wvalid, a1_wready, a1_bvalid, a1_bready;
	wire a1_arvalid, a1_arready, a1_rlast, a1_rvalid, a1_rready;
	wire [D_W-1:0] a0_wdata, a0_rdata, a1_wdata, a1_rdata;
	wire [D_W/8-1:0] a0_wstrb, a1_wstrb;

	am_axi_split #(
		.A_W(32), .D_W(D_W), .ID_W(ID_W), .BASE0(32'h80000000), .SIZE0(32'h40000000),
		.BASE1(32'h00000000), .SIZE1(32'h80000000), .CNT_W(3), .WQ_LOG2(2)
	) dut (
		.clk(clk), .rst_n(rst_n),
		.s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(3'd3), .s_awburst(2'b01),
		.s_awcache(4'd3), .s_awprot(3'd0), .s_awvalid(awvalid), .s_awready(awready),
		.s_wdata(wdata), .s_wstrb({(D_W/8){1'b1}}), .s_wlast(wlast), .s_wvalid(wvalid),
		.s_wready(wready), .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
		.s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(3'd3), .s_arburst(2'b01),
		.s_arcache(4'd3), .s_arprot(3'd0), .s_arvalid(arvalid), .s_arready(arready),
		.s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid),
		.s_rready(rready),
		.m0_awid(a0_awid), .m0_awaddr(a0_awaddr), .m0_awlen(a0_awlen), .m0_awsize(a0_awsize),
		.m0_awburst(a0_awburst), .m0_awcache(a0_awcache), .m0_awprot(a0_awprot),
		.m0_awvalid(a0_awvalid), .m0_awready(a0_awready), .m0_wdata(a0_wdata),
		.m0_wstrb(a0_wstrb), .m0_wlast(a0_wlast), .m0_wvalid(a0_wvalid), .m0_wready(a0_wready),
		.m0_bid(a0_bid), .m0_bresp(a0_bresp), .m0_bvalid(a0_bvalid), .m0_bready(a0_bready),
		.m0_arid(a0_arid), .m0_araddr(a0_araddr), .m0_arlen(a0_arlen), .m0_arsize(a0_arsize),
		.m0_arburst(a0_arburst), .m0_arcache(a0_arcache), .m0_arprot(a0_arprot),
		.m0_arvalid(a0_arvalid), .m0_arready(a0_arready), .m0_rid(a0_rid),
		.m0_rdata(a0_rdata), .m0_rresp(a0_rresp), .m0_rlast(a0_rlast), .m0_rvalid(a0_rvalid),
		.m0_rready(a0_rready),
		.m1_awid(a1_awid), .m1_awaddr(a1_awaddr), .m1_awlen(a1_awlen), .m1_awsize(a1_awsize),
		.m1_awburst(a1_awburst), .m1_awcache(a1_awcache), .m1_awprot(a1_awprot),
		.m1_awvalid(a1_awvalid), .m1_awready(a1_awready), .m1_wdata(a1_wdata),
		.m1_wstrb(a1_wstrb), .m1_wlast(a1_wlast), .m1_wvalid(a1_wvalid), .m1_wready(a1_wready),
		.m1_bid(a1_bid), .m1_bresp(a1_bresp), .m1_bvalid(a1_bvalid), .m1_bready(a1_bready),
		.m1_arid(a1_arid), .m1_araddr(a1_araddr), .m1_arlen(a1_arlen), .m1_arsize(a1_arsize),
		.m1_arburst(a1_arburst), .m1_arcache(a1_arcache), .m1_arprot(a1_arprot),
		.m1_arvalid(a1_arvalid), .m1_arready(a1_arready), .m1_rid(a1_rid),
		.m1_rdata(a1_rdata), .m1_rresp(a1_rresp), .m1_rlast(a1_rlast), .m1_rvalid(a1_rvalid),
		.m1_rready(a1_rready)
	);

	axi_id_slave #(.ID_W(ID_W), .D_W(D_W), .K(1), .PCT(PCT0), .WAIT_W(0), .SEED(SEED + 10)) s0 (
		.clk(clk), .rst_n(rst_n), .awid(a0_awid), .awaddr(a0_awaddr), .awlen(a0_awlen),
		.awvalid(a0_awvalid), .awready(a0_awready), .wdata(a0_wdata), .wstrb(a0_wstrb),
		.wlast(a0_wlast), .wvalid(a0_wvalid), .wready(a0_wready), .bid(a0_bid),
		.bresp(a0_bresp), .bvalid(a0_bvalid), .bready(a0_bready), .arid(a0_arid),
		.araddr(a0_araddr), .arlen(a0_arlen), .arvalid(a0_arvalid), .arready(a0_arready),
		.rid(a0_rid), .rdata(a0_rdata), .rresp(a0_rresp), .rlast(a0_rlast),
		.rvalid(a0_rvalid), .rready(a0_rready)
	);
	axi_id_slave #(.ID_W(ID_W), .D_W(D_W), .K(2), .PCT(PCT1), .WAIT_W(WAIT1), .SEED(SEED + 20)) s1 (
		.clk(clk), .rst_n(rst_n), .awid(a1_awid), .awaddr(a1_awaddr), .awlen(a1_awlen),
		.awvalid(a1_awvalid), .awready(a1_awready), .wdata(a1_wdata), .wstrb(a1_wstrb),
		.wlast(a1_wlast), .wvalid(a1_wvalid), .wready(a1_wready), .bid(a1_bid),
		.bresp(a1_bresp), .bvalid(a1_bvalid), .bready(a1_bready), .arid(a1_arid),
		.araddr(a1_araddr), .arlen(a1_arlen), .arvalid(a1_arvalid), .arready(a1_arready),
		.rid(a1_rid), .rdata(a1_rdata), .rresp(a1_rresp), .rlast(a1_rlast),
		.rvalid(a1_rvalid), .rready(a1_rready)
	);

	integer seed = SEED;

	function rnd;
		input integer pct;
		rnd = ($unsigned($random(seed)) % 100) < pct;
	endfunction

	task fail;
		input [8*48-1:0] what;
		begin
			errors = errors + 1;
			$display("FAIL am_axi_split: %0s at %0t", what, $time);
		end
	endtask

	/* A random burst: destination 0 (slave 0), 1 (slave 1) or 2 (DECERR). */
	function [31:0] pick_addr;
		input integer d;
		reg [31:0] off;
		begin
			off = {$random(seed)} % 32'h00100000;
			off = {off[31:5], 5'd0};	/* 4 beats of 8 bytes stay inside 4 KiB */
			pick_addr = d == 0 ? 32'h80000000 + off : d == 1 ? off : 32'hC0000000 + off;
		end
	endfunction

	function integer dest_of;
		input [31:0] a;
		dest_of = a >= 32'hC0000000 ? 2 : a >= 32'h80000000 ? 0 : 1;
	endfunction

	/* Writes generated, in order: AW and W walk them separately. */
	reg [ID_W-1:0] g_id [0:QN-1];
	reg [31:0] g_addr [0:QN-1];
	reg [7:0] g_len [0:QN-1];
	integer nw = 0, nr = 0, aw_i = 0, w_i = 0, w_b = 0;

	/* Expected responses per ID: 64 entries each. */
	integer ew_dst [0:4*64-1];
	integer er_dst [0:4*64-1];
	reg [31:0] er_addr [0:4*64-1];
	reg [7:0] er_len [0:4*64-1];
	integer ew_h [0:3], ew_t [0:3], er_h [0:3], er_t [0:3];
	integer done_w = 0, done_r = 0, r_beat = 0, k, cyc = 0;
	reg in_burst = 1'b0;
	reg [ID_W-1:0] cur_id = 0;
	reg p_bv = 1'b0, p_br = 1'b0, p_rv = 1'b0, p_rr = 1'b0;
	reg [ID_W+1:0] p_b = 0;
	reg [D_W+ID_W+2:0] p_r = 0;

	initial begin
		finished = 1'b0;
		errors = 0;
		for (k = 0; k < 4; k = k + 1) begin
			ew_h[k] = 0;
			ew_t[k] = 0;
			er_h[k] = 0;
			er_t[k] = 0;
		end
	end

	always @(posedge clk) begin
		if (rst_n) begin
			cyc = cyc + 1;
			/* ---- the response checks ---- */
			if (p_bv && !p_br && (!bvalid || {bid, bresp} != p_b))
				fail("B changed before ready");
			if (p_rv && !p_rr && (!rvalid || {rid, rdata, rresp, rlast} != p_r))
				fail("R changed before ready");
			if (bvalid && bready) begin
				if (ew_h[bid] == ew_t[bid]) begin
					fail("B without a write");
				end else begin
					if (bresp != (ew_dst[bid*64 + ew_h[bid] % 64] == 2 ? 2'b11 : 2'b00))
						fail("BRESP");
					ew_h[bid] = ew_h[bid] + 1;
					done_w = done_w + 1;
				end
			end
			if (rvalid && rready) begin
				if (in_burst && rid != cur_id)
					fail("R bursts interleaved");
				if (er_h[rid] == er_t[rid]) begin
					fail("R without a read");
				end else begin
					k = rid * 64 + er_h[rid] % 64;
					if (er_dst[k] == 2 ? (rresp != 2'b11 || rdata != 0) :
						(rresp != 2'b00 || rdata != axi_id_data(er_dst[k] + 1, er_addr[k], r_beat)))
						fail("R data or RRESP (order per ID)");
					if (rlast != (r_beat == er_len[k]))
						fail("RLAST");
					if (rlast) begin
						er_h[rid] = er_h[rid] + 1;
						done_r = done_r + 1;
						r_beat = 0;
						in_burst = 1'b0;
					end else begin
						r_beat = r_beat + 1;
						in_burst = 1'b1;
						cur_id = rid;
					end
				end
			end
			/* ---- the requests taken ---- */
			if (awvalid && awready) begin
				ew_dst[awid*64 + ew_t[awid] % 64] = dest_of(awaddr);
				ew_t[awid] = ew_t[awid] + 1;
				awvalid <= 1'b0;
				aw_i = aw_i + 1;
			end
			if (arvalid && arready) begin
				k = arid * 64 + er_t[arid] % 64;
				er_dst[k] = dest_of(araddr);
				er_addr[k] = araddr;
				er_len[k] = arlen;
				er_t[arid] = er_t[arid] + 1;
				arvalid <= 1'b0;
			end
			if (wvalid && wready) begin
				wvalid <= 1'b0;
				if (wlast) begin
					w_i = w_i + 1;
					w_b = 0;
				end else begin
					w_b = w_b + 1;
				end
			end
			/* ---- new requests ---- */
			if (nw < NTX && nw - aw_i < 8 && rnd(30)) begin
				g_id[nw % QN] = $random(seed);
				g_addr[nw % QN] = pick_addr({$random(seed)} % 3);
				g_len[nw % QN] = {$random(seed)} % 4;
				nw = nw + 1;
			end
			if ((!awvalid || awready) && aw_i < nw && rnd(60)) begin
				awvalid <= 1'b1;
				awid <= g_id[aw_i % QN];
				awaddr <= g_addr[aw_i % QN];
				awlen <= g_len[aw_i % QN];
			end
			/* W may come before its AW is taken (after it is generated). */
			if ((!wvalid || wready) && w_i < nw && rnd(60)) begin
				wvalid <= 1'b1;
				wdata <= axi_id_data(0, g_addr[w_i % QN], w_b);
				wlast <= w_b == g_len[w_i % QN];
			end
			if ((!arvalid || arready) && nr < NTX && rnd(30)) begin
				arvalid <= 1'b1;
				arid <= $random(seed);
				araddr <= pick_addr({$random(seed)} % 3);
				arlen <= {$random(seed)} % 4;
				nr = nr + 1;
			end
			bready <= rnd(70);
			rready <= rnd(70);
			if (done_w == NTX && done_r == NTX && !finished) begin
				finished <= 1'b1;
				errors = errors + s0.errors + s1.errors;
				if (s0.bursts + s1.bursts == 0)
					fail("no burst reached a slave");
				$display("am_axi_split: %0d writes, %0d reads, slaves %0d + %0d bursts, %0d cycles",
					done_w, done_r, s0.bursts, s1.bursts, cyc);
			end
		end
		p_bv <= bvalid;
		p_br <= bready;
		p_b <= {bid, bresp};
		p_rv <= rvalid;
		p_rr <= rready;
		p_r <= {rid, rdata, rresp, rlast};
	end
endmodule

module am_axi_split_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	integer seed = 1;
	wire fa, fb;
	wire [31:0] ea, eb;

	always #5 clk = !clk;

	am_axi_split_harness #(.PCT0(15), .PCT1(85), .WAIT1(0), .SEED(1)) a (
		.clk(clk), .rst_n(rst_n), .finished(fa), .errors(ea)
	);
	am_axi_split_harness #(.PCT0(70), .PCT1(70), .WAIT1(1), .SEED(7)) b (
		.clk(clk), .rst_n(rst_n), .finished(fb), .errors(eb)
	);

	initial begin
		if ($value$plusargs("seed=%d", seed)) begin
			a.seed = seed;
			b.seed = seed + 1000;
		end
		repeat (5) @(posedge clk);
		rst_n <= 1'b1;
		fork : wait_done
			begin
				wait (fa && fb);
				disable wait_done;
			end
			begin
				repeat (400000) @(posedge clk);
				$display("FAIL am_axi_split: timeout (a %0d/%0d, b %0d/%0d)",
					a.done_w, a.done_r, b.done_w, b.done_r);
				disable wait_done;
			end
		join
		@(posedge clk);
		if (fa && fb && ea == 0 && eb == 0)
			$display("PASS am_axi_split");
		else
			$display("FAIL am_axi_split: %0d + %0d errors", ea, eb);
		$finish;
	end
endmodule

`default_nettype wire
