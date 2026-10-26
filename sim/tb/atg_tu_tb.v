/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_tb: the whole TU (atg_tu: addressing, the cache on a memory
 * model, the 8-bit and the fp32 filter paths) against tools/tumodel.py
 * (sample; sim/vec/tu_quad.txt, tools/tu-vectors.py), with 32-byte and
 * 64-byte (KC705) lines.  Memory word a is (a >> 2) x 0x9E3779B1; requests
 * are taken and answered after random delays.  The STATE writes go in
 * between quads (after the TU is idle); the quads go in back to back with
 * random gaps, tr_ready is random, and the 16 words, the tag and last of
 * every returned quad are checked in order (quads of the two paths
 * follow each other, so their order is checked too).  Group "quads":
 * random descriptors of the earlier codes and of TEX_FORMAT's formats,
 * every op.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifndef CFG_ENABLE_BC
`define CFG_ENABLE_BC 1
`endif
`ifndef CFG_ENABLE_3D_CUBE
`define CFG_ENABLE_3D_CUBE 1
`endif
`ifndef CFG_ENABLE_TRILINEAR
`define CFG_ENABLE_TRILINEAR 1
`endif

module atg_tu_tb_run #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done,
	output reg [31:0] errs,
	output reg [31:0] nq
);
	localparam LB = LINE_BYTES * 8;

	reg st_we = 1'b0;
	reg [9:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg tx_valid = 1'b0;
	reg [7:0] tx_op = 0;
	reg [3:0] tx_slot = 0, tx_mask = 0;
	reg tx_vs = 1'b0;
	reg [639:0] tx_coord = 0;
	reg [11:0] tx_off = 0;
	reg [15:0] tx_tag = 0;
	reg tx_last = 1'b0;
	reg tr_ready = 1'b0;
	wire tx_ready, tr_valid, tr_last, busy;
	wire [15:0] tr_tag;
	wire [511:0] tr_data;
	wire req_valid, req_write;
	reg req_ready = 1'b0;
	wire [31-LINE_SHIFT:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LB-1:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 1'b0;
	reg [7:0] rsp_tag = 0;
	reg [LB-1:0] rsp_rdata = 0;

	atg_tu #(.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.inv(1'b0), .busy(busy),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot), .tx_vs(tx_vs),
		.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
		.tx_last(tx_last),
		.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
		.tr_last(tr_last),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(1'b0), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(1'b0)
	);

	integer seed = SEED;

	/* The memory: pipelined response queue (supports multiple outstanding requests). */
	localparam MQ_DEPTH = 16;
	reg [LB-1:0] mq_data [0:MQ_DEPTH-1];
	reg [7:0]    mq_tag  [0:MQ_DEPTH-1];
	integer      mq_due  [0:MQ_DEPTH-1];
	integer      mq_head = 0, mq_tail = 0, mq_cnt = 0, now = 0;
	reg [31:0] la;
	reg [LB-1:0] line;
	integer w;

	always @(posedge clk) begin
		now = now + 1;
		rsp_valid <= 1'b0;

		/* Service due response from queue */
		if (mq_cnt > 0 && mq_due[mq_head] <= now) begin
			rsp_valid <= 1'b1;
			rsp_rdata <= mq_data[mq_head];
			rsp_tag   <= mq_tag[mq_head];
			mq_head = (mq_head + 1) % MQ_DEPTH;
			mq_cnt = mq_cnt - 1;
		end

		/* Accept new request when queue has space */
		req_ready <= (mq_cnt < MQ_DEPTH) && (($random(seed) & 1) == 0);
		if (req_valid && req_ready) begin
			la = {req_line, {LINE_SHIFT{1'b0}}};
			if (req_write)
				$display("FAIL atg_tu(%0d): a write request", LINE_BYTES);
			for (w = 0; w < LINE_BYTES / 4; w = w + 1)
				line[w*32 +: 32] = ((la >> 2) + w) * 32'h9E3779B1;
			mq_data[mq_tail] = line;
			mq_tag[mq_tail]  = req_tag;
			mq_due[mq_tail]  = now + ($random(seed) & 7) + 1;
			mq_tail = (mq_tail + 1) % MQ_DEPTH;
			mq_cnt = mq_cnt + 1;
		end
	end

	/* The expected returns, in order. */
	reg [511:0] x_data [0:2047];
	reg x_last [0:2047];
	integer nx, nr;
	integer fd, code, k;
	reg [8*12-1:0] kind, gname;
	reg [9:0] sidx;
	reg [31:0] sval;
	reg [7:0] op;
	reg [4:0] slot;
	reg [3:0] mask;
	reg [11:0] off;
	reg [639:0] crd;
	reg [511:0] data;
	reg [31:0] gerrs;

	/* The checker. */
	always @(posedge clk)
		if (rst_n) begin
			tr_ready <= ($random(seed) & 3) != 0;
			if (tr_valid && tr_ready) begin
				if (nr >= nx) begin
					$display("FAIL atg_tu(%0d): an unexpected return", LINE_BYTES);
					gerrs = gerrs + 1;
				end else begin
					for (k = 0; k < 16; k = k + 1)
						if (tr_data[k*32 +: 32] !== x_data[nr % 2048][k*32 +: 32]) begin
							if (gerrs < 10)
								$display("FAIL atg_tu(%0d): quad %0d word %0d: %h, model %h",
									LINE_BYTES, nr, k, tr_data[k*32 +: 32],
									x_data[nr % 2048][k*32 +: 32]);
							gerrs = gerrs + 1;
						end
					if (tr_tag !== nr[15:0] || tr_last !== x_last[nr % 2048]) begin
						$display("FAIL atg_tu(%0d): quad %0d: tag %h last %b", LINE_BYTES, nr,
							tr_tag, tr_last);
						gerrs = gerrs + 1;
					end
				end
				nr = nr + 1;
			end
		end

	initial begin
		done = 1'b0;
		errs = 0;
		gerrs = 0;
		nq = 0;
		nx = 0;
		nr = 0;
		fd = $fopen("sim/vec/tu_quad.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_tu: no sim/vec/tu_quad.txt");
			$finish;
		end
		@(posedge rst_n);
		@(posedge clk);
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%s", kind);
			if (code != 1) begin
				/* end of file */
			end else if (kind == "S") begin
				code = $fscanf(fd, "%h %h\n", sidx, sval);
				/* STATE changes only between quads (the CP waits for the TU). */
				while (nr < nx || busy)
					@(posedge clk);
				st_we <= 1'b1;
				st_idx <= sidx;
				st_wdata <= sval;
				@(posedge clk);
				st_we <= 1'b0;
			end else if (kind == "Q") begin
				code = $fscanf(fd, "%h %h %h %h %h %h\n", op, slot, mask, off, crd, data);
				while (nx - nr >= 2000)
					@(posedge clk);
				x_data[nx % 2048] = data;
				x_last[nx % 2048] = $random(seed);
				while (($random(seed) & 3) == 0)
					@(posedge clk);
				tx_valid <= 1'b1;
				tx_op <= op;
				tx_slot <= slot[3:0];
				tx_vs <= slot[4];
				tx_mask <= mask;
				tx_coord <= crd;
				tx_off <= off;
				tx_tag <= nx[15:0];
				tx_last <= x_last[nx % 2048];
				nx = nx + 1;
				@(posedge clk);
				while (!tx_ready)
					@(posedge clk);
				tx_valid <= 1'b0;
				nq = nq + 1;
			end else if (kind == "P") begin
				code = $fscanf(fd, "%s\n", gname);
				while (nr < nx)
					@(posedge clk);
				if (gerrs == 0)
					$display("PASS atg_tu.%0s (%0d)", gname, LINE_BYTES);
				errs = errs + gerrs;
				gerrs = 0;
			end
		end
		$fclose(fd);
		done = 1'b1;
	end
endmodule

module atg_tu_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	wire d32, d64;
	wire [31:0] e32, e64, n32, n64;
	atg_tu_tb_run #(.LINE_BYTES(32), .LINE_SHIFT(5), .SEED(21)) r32 (
		.clk(clk), .rst_n(rst_n), .done(d32), .errs(e32), .nq(n32));
	atg_tu_tb_run #(.LINE_BYTES(64), .LINE_SHIFT(6), .SEED(22)) r64 (
		.clk(clk), .rst_n(rst_n), .done(d64), .errs(e64), .nq(n64));

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		wait (d32 && d64);
		if (e32 == 0 && e64 == 0 && n32 > 1000 && n64 > 1000)
			$display("PASS atg_tu");
		else
			$display("FAIL atg_tu: %0d / %0d errors, %0d / %0d quads", e32, e64, n32, n64);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_tu: timeout");
		$finish;
	end
endmodule

`default_nettype wire
