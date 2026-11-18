/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rt_tb: one atg_rt with random traffic.  Requests: each child sends
 * packets of 1 to 3 flits (every flit carries the child and a per-child
 * sequence number, the header the priority bit), with random gaps; the
 * parent takes flits with a random ready.  Checked: no packet is
 * interleaved with another, each child's packets arrive in order and
 * complete, a waiting header with the priority bit always beats one
 * without, and with equal priority the children take turns.  Responses:
 * random flits whose bit RBIT names the child; checked: each reaches that
 * child, in order, under random child readiness.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rt_tb;
	localparam FW = 16;	/* [0] prio (header), [1] child, [2] header, [15:3] sequence */
	localparam RFW = 16;	/* [3] child (RBIT), [15:4] sequence */
	localparam NPKT = 2000;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	integer errors = 0;
	integer seed = 11;

	always #5 clk = !clk;

	reg [1:0] c_valid;
	wire [1:0] c_ready;
	reg [FW-1:0] c_data [0:1];
	reg [1:0] c_last;
	wire p_valid, p_last;
	reg p_ready;
	wire [FW-1:0] p_data;
	reg pr_valid;
	wire pr_ready;
	reg [RFW-1:0] pr_data;
	wire [1:0] cr_valid;
	reg [1:0] cr_ready;
	wire [RFW-1:0] cr_data0, cr_data1;
	wire rsp_idle;

	atg_rt #(.FW(FW), .RFW(RFW), .RBIT(3)) dut (
		.clk(clk), .rst_n(rst_n), .flush(1'b0),
		.c0_req_valid(c_valid[0]), .c0_req_ready(c_ready[0]), .c0_req_data(c_data[0]),
		.c0_req_last(c_last[0]),
		.c1_req_valid(c_valid[1]), .c1_req_ready(c_ready[1]), .c1_req_data(c_data[1]),
		.c1_req_last(c_last[1]),
		.p_req_valid(p_valid), .p_req_ready(p_ready), .p_req_data(p_data), .p_req_last(p_last),
		.p_rsp_valid(pr_valid), .p_rsp_ready(pr_ready), .p_rsp_data(pr_data),
		.c0_rsp_valid(cr_valid[0]), .c0_rsp_ready(cr_ready[0]), .c0_rsp_data(cr_data0),
		.c1_rsp_valid(cr_valid[1]), .c1_rsp_ready(cr_ready[1]), .c1_rsp_data(cr_data1),
		.rsp_idle(rsp_idle)
	);

	/* Request sources: state per child. */
	integer seq [0:1];	/* next flit sequence number */
	integer left [0:1];	/* flits left in the current packet (0: a header is next) */
	integer sent [0:1];	/* packets started */
	reg phase_prio;	/* the priority phase: child 1 always prio, both always valid */
	integer c;

	task new_flit;
		input integer ch;
		reg hdr;
		begin
			hdr = left[ch] == 0;
			if (hdr) begin
				left[ch] = 1 + $unsigned($random(seed)) % 3;
				sent[ch] = sent[ch] + 1;
			end
			c_data[ch] <= {seq[ch][12:0], hdr, ch[0],
				hdr && (phase_prio ? ch == 1 : $random(seed) % 4 == 0)};
			c_last[ch] <= left[ch] == 1;
			seq[ch] = seq[ch] + 1;
		end
	endtask

	always @(posedge clk) begin
		if (rst_n) begin
			for (c = 0; c < 2; c = c + 1) begin
				if (c_valid[c] && c_ready[c]) begin
					left[c] = left[c] - 1;
					c_valid[c] <= 1'b0;
					if (sent[c] < NPKT || left[c] != 0) begin
						if (phase_prio || $unsigned($random(seed)) % 3 != 0) begin
							new_flit(c);
							c_valid[c] <= 1'b1;
						end
					end
				end else if (!c_valid[c] && (sent[c] < NPKT || left[c] != 0) &&
				    (phase_prio || $unsigned($random(seed)) % 3 != 0)) begin
					new_flit(c);
					c_valid[c] <= 1'b1;
				end
			end
			p_ready <= phase_prio || $unsigned($random(seed)) % 4 != 0;
		end
	end

	/* Arbitration checks at the router's packet starts (between the edges). */
	always @(negedge clk) begin
		if (rst_n && dut.take && !dut.lock && c_valid == 2'b11) begin
			if (c_data[0][0] != c_data[1][0]) begin
				if (c_data[dut.pick][0] != 1'b1) begin
					errors = errors + 1;
					$display("FAIL atg_rt: the header without priority won");
				end
			end else if (dut.pick == dut.last_won) begin
				errors = errors + 1;
				$display("FAIL atg_rt: the same child won twice at equal priority");
			end
		end
	end

	/* Parent side: no interleaving, order per child. */
	integer exp_seq [0:1];
	integer got [0:1];
	reg in_pkt;
	reg pkt_ch;
	always @(posedge clk) begin
		if (rst_n && p_valid && p_ready) begin
			if (in_pkt && (p_data[2] || p_data[1] != pkt_ch)) begin
				errors = errors + 1;
				$display("FAIL atg_rt: packets interleaved");
			end
			if (!in_pkt && !p_data[2]) begin
				errors = errors + 1;
				$display("FAIL atg_rt: a packet without a header");
			end
			if (p_data[15:3] != exp_seq[p_data[1]][12:0]) begin
				errors = errors + 1;
				$display("FAIL atg_rt: child %0d flit %0d, expected %0d", p_data[1],
					p_data[15:3], exp_seq[p_data[1]]);
			end
			exp_seq[p_data[1]] = exp_seq[p_data[1]] + 1;
			if (p_data[2])
				got[p_data[1]] = got[p_data[1]] + 1;
			pkt_ch = p_data[1];
			in_pkt = !p_last;
		end
	end

	/* Responses. */
	integer r_sent [0:1];
	integer r_got [0:1];
	reg rch;
	integer rc;
	always @(posedge clk) begin
		if (rst_n) begin
			cr_ready <= $random(seed);
			if (pr_valid && pr_ready)
				pr_valid <= 1'b0;
			if ((!pr_valid || pr_ready) && r_sent[0] + r_sent[1] < 2 * NPKT &&
			    $unsigned($random(seed)) % 2 == 0) begin
				rch = $random(seed);
				pr_data <= {r_sent[rch][11:0], rch, 3'd0};
				r_sent[rch] = r_sent[rch] + 1;
				pr_valid <= 1'b1;
			end
			for (rc = 0; rc < 2; rc = rc + 1) begin
				if (cr_valid[rc] && cr_ready[rc]) begin
					if ((rc == 0 ? cr_data0 : cr_data1) !== {r_got[rc][11:0], rc[0], 3'd0}) begin
						errors = errors + 1;
						$display("FAIL atg_rt: response to child %0d out of place", rc);
					end
					r_got[rc] = r_got[rc] + 1;
				end
			end
		end
	end

	integer n;
	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		for (c = 0; c < 2; c = c + 1) begin
			seq[c] = 0;
			left[c] = 0;
			sent[c] = 0;
			exp_seq[c] = 0;
			got[c] = 0;
			r_sent[c] = 0;
			r_got[c] = 0;
			c_data[c] = 0;
		end
		c_valid = 2'b00;
		c_last = 2'b00;
		p_ready = 1'b0;
		pr_valid = 1'b0;
		pr_data = 0;
		cr_ready = 2'b00;
		in_pkt = 1'b0;
		pkt_ch = 1'b0;
		phase_prio = 1'b0;
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		/* Random phase, then a phase where child 1 always has priority. */
		n = 0;
		while ((sent[0] < NPKT / 2 || sent[1] < NPKT / 2) && n < 200000) begin
			@(posedge clk);
			n = n + 1;
		end
		phase_prio = 1'b1;
		repeat (200) @(posedge clk);
		phase_prio = 1'b0;
		n = 0;
		while ((got[0] < sent[0] || got[1] < sent[1] || sent[0] < NPKT || sent[1] < NPKT ||
		    r_got[0] + r_got[1] < 2 * NPKT) && n < 200000) begin
			@(posedge clk);
			n = n + 1;
		end
		if (got[0] != NPKT || got[1] != NPKT || r_got[0] != r_sent[0] || r_got[1] != r_sent[1]) begin
			errors = errors + 1;
			$display("FAIL atg_rt: packets %0d/%0d, responses %0d/%0d of %0d/%0d", got[0], got[1],
				r_got[0], r_got[1], r_sent[0], r_sent[1]);
		end
		if (!rsp_idle) begin
			errors = errors + 1;
			$display("FAIL atg_rt: not idle at the end");
		end
		if (errors == 0)
			$display("PASS atg_rt");
		$finish;
	end

	initial begin
		#10000000;
		$display("FAIL atg_rt: timeout");
		$finish;
	end
endmodule

`default_nettype wire
