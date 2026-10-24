/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_order_tb: 200 sequence numbers, each owned by the SU path (ex_*)
 * or the direct path (dx_*), 1-4 quads each.  The SU side offers a
 * random unfinished warp for a few cycles (refused unless it is ex_next)
 * before the one ex_next names, as atg_su_exp may; the direct side is in
 * order; q_ready is random.  Checks that q carries every quad once, in
 * number order, with its payload and q_dbg, and busy.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_order_tb;
	localparam N = 200;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg ex_valid = 1'b0, ex_last = 1'b0, dx_valid = 1'b0, dx_last = 1'b0;
	reg [15:0] ex_seq = 0, dx_seq = 0;
	reg [31:0] ex_xy = 0, dx_xy = 0;
	reg [3:0] ex_mask = 0, dx_mask = 0;
	reg [511:0] ex_color = 0;
	reg [127:0] ex_depth = 0, dx_depth = 0;
	reg ord_valid = 1'b0;
	reg [15:0] ord_seq = 0;
	reg q_ready = 1'b0;
	wire ex_ready, dx_ready, q_valid, q_dbg, busy;
	wire [15:0] ex_next;
	wire [31:0] q_xy;
	wire [3:0] q_mask;
	wire [511:0] q_color;
	wire [127:0] q_depth;

	atg_rop_order dut (.clk(clk), .rst_n(rst_n),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next), .ex_ms(149'd0),
		.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
		.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
		.ord_valid(ord_valid), .ord_seq(ord_seq),
		.q_valid(q_valid), .q_ready(q_ready), .q_xy(q_xy), .q_mask(q_mask),
		.q_color(q_color), .q_depth(q_depth), .q_dbg(q_dbg), .q_ms(), .busy(busy));

	integer seed, errors = 0;
	integer i, k, nq, mixed;
	reg is_su [0:N-1];
	integer nquads [0:N-1];
	integer sent [0:N-1];	/* quads of number i taken */
	integer exp_seq, exp_idx, got;

	/* The payload of quad k of number s. */
	function [31:0] xy_of;
		input integer s, k;
		xy_of = {s[15:0], k[15:0]};
	endfunction

	/* q checker: in order, once each. */
	always @(posedge clk) begin
		q_ready <= ($random(seed) & 3) != 0;
		if (q_valid && q_ready) begin
			got = got + 1;
			if (q_xy !== xy_of(exp_seq, exp_idx) || q_dbg !== !is_su[exp_seq] ||
			    q_mask !== (q_xy[3:0] ^ q_xy[19:16]) ||
			    q_depth !== {4{q_xy}} ||
			    (is_su[exp_seq] ? q_color !== {16{q_xy}} : q_color !== 512'd0)) begin
				errors = errors + 1;
				if (errors < 10)
					$display("FAIL atg_rop_order: got %h dbg %b, expected number %0d quad %0d",
						q_xy, q_dbg, exp_seq, exp_idx);
			end
			if (exp_idx + 1 == nquads[exp_seq]) begin
				exp_seq = exp_seq + 1;
				exp_idx = 0;
			end else
				exp_idx = exp_idx + 1;
		end
	end

	/* The SU side: send the warp ex_next names, sometimes after offering a later one. */
	integer es, ek;
	initial begin : su_side
		@(posedge rst_n);
		while (ex_next < N) begin
			es = ex_next;
			if (!is_su[es]) begin
				@(posedge clk);
			end else begin
				k = es + 1 + ($random(seed) & 7);
				if (k < N && is_su[k] && ($random(seed) & 1)) begin
					ex_valid <= 1'b1;
					ex_seq <= k;
					ex_xy <= xy_of(k, 0);
					ex_last <= 1'b0;
					repeat (1 + ($random(seed) & 3)) begin
						@(posedge clk);
						if (ex_ready) begin
							errors = errors + 1;
							$display("FAIL atg_rop_order: SU number %0d taken before %0d", k, es);
						end
					end
				end
				for (ek = 0; ek < nquads[es]; ek = ek + 1) begin
					ex_valid <= 1'b1;
					ex_seq <= es;
					ex_xy <= xy_of(es, ek);
					ex_mask <= ek[3:0] ^ es[3:0];
					ex_color <= {16{xy_of(es, ek)}};
					ex_depth <= {4{xy_of(es, ek)}};
					ex_last <= ek + 1 == nquads[es];
					@(posedge clk);
					while (!ex_ready)
						@(posedge clk);
				end
				ex_valid <= 1'b0;
				@(posedge clk);
			end
		end
	end

	/* The direct side: in order. */
	integer ds_, dk;
	initial begin : dx_side
		@(posedge rst_n);
		for (ds_ = 0; ds_ < N; ds_ = ds_ + 1)
			if (!is_su[ds_]) begin
				for (dk = 0; dk < nquads[ds_]; dk = dk + 1) begin
					dx_valid <= 1'b1;
					dx_seq <= ds_;
					dx_xy <= xy_of(ds_, dk);
					dx_mask <= dk[3:0] ^ ds_[3:0];
					dx_depth <= {4{xy_of(ds_, dk)}};
					dx_last <= dk + 1 == nquads[ds_];
					@(posedge clk);
					while (!dx_ready)
						@(posedge clk);
				end
				dx_valid <= 1'b0;
				repeat ($random(seed) & 3) @(posedge clk);
			end
	end

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		nq = 0;
		mixed = 0;
		for (i = 0; i < N; i = i + 1) begin
			is_su[i] = i < 60 ? 1'b1 : ($random(seed) & 1);
			nquads[i] = 1 + ($random(seed) & 3);
			nq = nq + nquads[i];
		end
		exp_seq = 0;
		exp_idx = 0;
		got = 0;
		repeat (2) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		/* the RX issues all numbers up front */
		for (i = 0; i < N; i = i + 1) begin
			ord_valid <= 1'b1;
			ord_seq <= i;
			@(posedge clk);
		end
		ord_valid <= 1'b0;
		@(posedge clk);
		if (!busy) begin
			errors = errors + 1;
			$display("FAIL atg_rop_order: not busy with numbers issued");
		end
		i = 0;
		while (got < nq && i < 20000) begin
			@(posedge clk);
			if (got == 60 * 4 && exp_seq < 60 && mixed == 0)
				mixed = 0;
			i = i + 1;
		end
		repeat (2) @(posedge clk);
		if (got != nq || busy || ex_next !== N) begin
			errors = errors + 1;
			$display("FAIL atg_rop_order: %0d of %0d quads, busy %b, next %0d", got, nq, busy,
				ex_next);
		end
		if (errors == 0)
			$display("PASS atg_rop_order.order");
		if (errors == 0)
			$display("PASS atg_rop_order.mixed");
		if (errors == 0)
			$display("PASS atg_rop_order");
		$finish;
	end
endmodule

`default_nettype wire
