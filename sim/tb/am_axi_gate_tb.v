/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_gate_tb: am_axi_gate in front of an axi_id_slave model, with a
 * random master (NTX writes and NTX reads, 4 IDs, 1-4 beats, W sometimes
 * before its AW, random B/R ready) while en goes up and down at random.
 * Checked: a burst taken while the direction is open reaches the slave
 * with its data (the slave checks the data and WLAST), one taken while it
 * is closed does not (the slave's AWs, ARs and W beats are counted against
 * the open ones), every response comes back in request order with the
 * request's ID and OKAY, a read taken closed answers AxLEN + 1 beats of
 * zeros with RLAST on the last, an open one the slave's data, B/R stable
 * while not ready, a direction's mode changes only with nothing in flight,
 * and both modes are used in both directions.  Two shapes: (a) a slow
 * slave, (b) a fast slave that waits for WVALID before AWREADY.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_gate_harness #(
	parameter PCT = 50,
	parameter WAIT_W = 0,
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

	reg en = 1'b1;
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

	wire [ID_W-1:0] m_awid, m_bid, m_arid, m_rid;
	wire [31:0] m_awaddr, m_araddr;
	wire [7:0] m_awlen, m_arlen;
	wire [2:0] m_awsize, m_arsize;
	wire [1:0] m_awburst, m_arburst, m_bresp, m_rresp;
	wire m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
	wire m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
	wire [D_W-1:0] m_wdata, m_rdata;
	wire [D_W/8-1:0] m_wstrb;

	am_axi_gate #(.A_W(32), .D_W(D_W), .ID_W(ID_W), .CNT_W(3)) dut (
		.clk(clk), .rst_n(rst_n), .en(en),
		.s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(3'd3), .s_awburst(2'b01),
		.s_awvalid(awvalid), .s_awready(awready), .s_wdata(wdata), .s_wstrb({(D_W/8){1'b1}}),
		.s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready), .s_bid(bid), .s_bresp(bresp),
		.s_bvalid(bvalid), .s_bready(bready),
		.s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(3'd3), .s_arburst(2'b01),
		.s_arvalid(arvalid), .s_arready(arready), .s_rid(rid), .s_rdata(rdata),
		.s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
		.m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
		.m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
		.m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
		.m_wready(m_wready), .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
		.m_bready(m_bready),
		.m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
		.m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
		.m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
		.m_rvalid(m_rvalid), .m_rready(m_rready)
	);

	axi_id_slave #(.ID_W(ID_W), .D_W(D_W), .K(1), .PCT(PCT), .WAIT_W(WAIT_W), .SEED(SEED + 10)) s (
		.clk(clk), .rst_n(rst_n), .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen),
		.awvalid(m_awvalid), .awready(m_awready), .wdata(m_wdata), .wstrb(m_wstrb),
		.wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready), .bid(m_bid),
		.bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready), .arid(m_arid),
		.araddr(m_araddr), .arlen(m_arlen), .arvalid(m_arvalid), .arready(m_arready),
		.rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
		.rvalid(m_rvalid), .rready(m_rready)
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
			$display("FAIL am_axi_gate: %0s at %0t", what, $time);
		end
	endtask

	/* Writes generated, in order: AW and W walk them separately. */
	reg [ID_W-1:0] g_id [0:QN-1];
	reg [31:0] g_addr [0:QN-1];
	reg [7:0] g_len [0:QN-1];
	integer nw = 0, nr = 0, aw_i = 0, w_i = 0, w_b = 0;

	/* Expected responses, in request order (the gate and the slave keep it). */
	reg [ID_W-1:0] ew_id [0:QN-1];
	reg ew_open [0:QN-1];
	reg [ID_W-1:0] er_id [0:QN-1];
	reg er_open [0:QN-1];
	reg [31:0] er_addr [0:QN-1];
	reg [7:0] er_len [0:QN-1];
	integer ew_h = 0, ew_t = 0, er_h = 0, er_t = 0;
	integer done_w = 0, done_r = 0, r_beat = 0, cyc = 0, k;
	integer open_w = 0, open_r = 0, open_beats = 0, m_aw = 0, m_ar = 0, m_beats = 0;
	integer en_left = 100, aw_before = 0;
	reg p_wopen = 1'b1, p_ropen = 1'b1;
	reg p_bv = 1'b0, p_br = 1'b0, p_rv = 1'b0, p_rr = 1'b0;
	reg [ID_W+1:0] p_b = 0;
	reg [D_W+ID_W+2:0] p_r = 0;

	initial begin
		finished = 1'b0;
		errors = 0;
	end

	always @(posedge clk) begin
		if (rst_n) begin
			cyc = cyc + 1;
			aw_before = aw_i;	/* the AWs taken before this cycle */
			/* ---- a mode changes only with nothing in flight ---- */
			if (dut.w_open != p_wopen && ew_t != ew_h)
				fail("write mode changed with writes in flight");
			if (dut.r_open != p_ropen && er_t != er_h)
				fail("read mode changed with reads in flight");
			/* ---- what reached the slave ---- */
			if (m_awvalid && m_awready)
				m_aw = m_aw + 1;
			if (m_arvalid && m_arready)
				m_ar = m_ar + 1;
			if (m_wvalid && m_wready)
				m_beats = m_beats + 1;
			/* ---- the response checks ---- */
			if (p_bv && !p_br && (!bvalid || {bid, bresp} != p_b))
				fail("B changed before ready");
			if (p_rv && !p_rr && (!rvalid || {rid, rdata, rresp, rlast} != p_r))
				fail("R changed before ready");
			if (bvalid && bready) begin
				if (ew_h == ew_t) begin
					fail("B without a write");
				end else begin
					if (bid != ew_id[ew_h % QN] || bresp != 2'b00)
						fail("B ID or BRESP (order)");
					ew_h = ew_h + 1;
					done_w = done_w + 1;
				end
			end
			if (rvalid && rready) begin
				if (er_h == er_t) begin
					fail("R without a read");
				end else begin
					k = er_h % QN;
					if (rid != er_id[k] || rresp != 2'b00 ||
					    rdata != (er_open[k] ? axi_id_data(1, er_addr[k], r_beat) : {D_W{1'b0}}))
						fail("R ID, data or RRESP (order)");
					if (rlast != (r_beat == er_len[k]))
						fail("RLAST");
					if (rlast) begin
						er_h = er_h + 1;
						done_r = done_r + 1;
						r_beat = 0;
					end else begin
						r_beat = r_beat + 1;
					end
				end
			end
			/* ---- the requests taken, with the mode they were taken in ---- */
			if (awvalid && awready) begin
				ew_id[ew_t % QN] = awid;
				ew_open[ew_t % QN] = dut.w_open;
				if (dut.w_open) begin
					open_w = open_w + 1;
					open_beats = open_beats + awlen + 1;
				end
				ew_t = ew_t + 1;
				awvalid <= 1'b0;
				aw_i = aw_i + 1;
			end
			if (arvalid && arready) begin
				k = er_t % QN;
				er_id[k] = arid;
				er_open[k] = dut.r_open;
				er_addr[k] = araddr;
				er_len[k] = arlen;
				if (dut.r_open)
					open_r = open_r + 1;
				er_t = er_t + 1;
				arvalid <= 1'b0;
			end
			if (wvalid && wready) begin
				if (!dut.w_open && w_i >= aw_before)
					fail("W taken before its AW (closed)");
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
				g_addr[nw % QN] = {$random(seed)} % 32'h00100000 & 32'hFFFFFFE0;
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
				araddr <= {$random(seed)} % 32'h00100000 & 32'hFFFFFFE0;
				arlen <= {$random(seed)} % 4;
				nr = nr + 1;
			end
			bready <= rnd(70);
			rready <= rnd(70);
			/* en: up or down for 20-400 cycles at a time. */
			en_left = en_left - 1;
			if (en_left == 0) begin
				en <= !en;
				en_left = 20 + {$random(seed)} % 380;
			end
			if (done_w == NTX && done_r == NTX && !finished) begin
				finished <= 1'b1;
				errors = errors + s.errors;
				if (m_aw != open_w || m_ar != open_r || m_beats != open_beats)
					fail("a closed burst reached the slave, or an open one did not");
				if (open_w == 0 || open_w == NTX || open_r == 0 || open_r == NTX)
					fail("a mode was not used");
				$display("am_axi_gate: %0d writes (%0d open), %0d reads (%0d open), %0d cycles",
					done_w, open_w, done_r, open_r, cyc);
			end
		end
		p_wopen <= dut.w_open;
		p_ropen <= dut.r_open;
		p_bv <= bvalid;
		p_br <= bready;
		p_b <= {bid, bresp};
		p_rv <= rvalid;
		p_rr <= rready;
		p_r <= {rid, rdata, rresp, rlast};
	end
endmodule

module am_axi_gate_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	integer seed = 1;
	wire fa, fb;
	wire [31:0] ea, eb;

	always #5 clk = !clk;

	am_axi_gate_harness #(.PCT(20), .WAIT_W(0), .SEED(3)) a (
		.clk(clk), .rst_n(rst_n), .finished(fa), .errors(ea)
	);
	am_axi_gate_harness #(.PCT(80), .WAIT_W(1), .SEED(9)) b (
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
				$display("FAIL am_axi_gate: timeout (a %0d/%0d, b %0d/%0d)",
					a.done_w, a.done_r, b.done_w, b.done_r);
				disable wait_done;
			end
		join
		@(posedge clk);
		if (fa && fb && ea == 0 && eb == 0)
			$display("PASS am_axi_gate");
		else
			$display("FAIL am_axi_gate: %0d + %0d errors", ea, eb);
		$finish;
	end
endmodule

`default_nettype wire
