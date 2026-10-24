/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_tb: the blitter (atg_blt with MS4: the 2D engine and RESOLVE)
 * against tools/blt-vectors.py (sim/vec/blt.txt), with 32-byte and
 * 64-byte (KC705) lines.  Each case starts from memory byte a of
 * 0x0000-0x7FFF = ((a >> 2) x 0x9E3779B1) >> 8 (a mod 4), writes the BLT
 * state, kicks and waits for done or error (its kind is checked); then
 * every byte the model lists must hold its value and every other byte the
 * blitter wrote must have kept its own.  The AMB port takes requests at
 * random, answers in order after random delays (up to 8 outstanding),
 * applies a write when it takes it.  Groups: "ps" (FILL and COPY of 8- to
 * 128-bit pixels, offsets, strides, the clip, the reverse direction, the
 * wide FILL's colour words), "keep" (KEEP of 32-bit FILL and COPY),
 * "tile" (TILE, UNTILE, blend-over as before), "refuse" (refused
 * combinations: kind 2, nothing written), "resolve" (every average with
 * every pixel size it takes, tiled destinations, the clip).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_tb_run #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	output reg done_all,
	output reg [31:0] errs,
	output reg [31:0] ncase
);
	localparam LB = LINE_BYTES * 8;
	localparam MEMB = 32768;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg kick = 1'b0;
	wire busy, done, error;
	wire [3:0] error_kind;
	wire req_valid, req_write;
	reg req_ready = 1'b0;
	wire [31-LINE_SHIFT:0] req_line;
	wire [LINE_BYTES-1:0] req_be;
	wire [LB-1:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 1'b0;
	reg rsp_write = 1'b0;
	reg [7:0] rsp_tag = 0;
	reg [LB-1:0] rsp_rdata = 0;

	atg_blt #(.ADDR_W(32), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .MS4(1)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.kick(kick), .busy(busy), .done(done), .error(error), .error_kind(error_kind),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(1'b0)
	);

	integer seed = SEED;

	function [7:0] hbyte;
		input [31:0] a;
		reg [31:0] w;
		begin
			w = a[31:2] * 32'h9E3779B1;
			hbyte = w[a[1:0]*8 +: 8];
		end
	endfunction

	/* The memory and the bytes written. */
	reg [7:0] mem [0:MEMB-1];
	reg dirty [0:MEMB-1];
	integer dlist [0:MEMB-1];
	integer nd;
	reg [7:0] expv [0:MEMB-1];
	reg expf [0:MEMB-1];
	integer elist [0:MEMB-1];
	integer ne;

	/* The port: up to 8 requests answered in order. */
	reg [LB-1:0] q_data [0:7];
	reg q_wr [0:7];
	reg [7:0] q_tag [0:7];
	integer q_due [0:7];
	integer qh, qt, qn, now;
	integer i, a;
	reg [31:0] la;
	always @(posedge clk) begin
		now = now + 1;
		rsp_valid <= 1'b0;
		if (qn > 0 && now >= q_due[qh]) begin
			rsp_valid <= 1'b1;
			rsp_write <= q_wr[qh];
			rsp_tag <= q_tag[qh];
			rsp_rdata <= q_data[qh];
			qh = (qh + 1) % 8;
			qn = qn - 1;
		end
		if (req_valid && req_ready) begin
			la = {req_line, {LINE_SHIFT{1'b0}}};
			for (i = 0; i < LINE_BYTES; i = i + 1) begin
				a = la + i;
				if (a >= MEMB) begin
					$display("FAIL atg_blt(%0d): an access at %h", LINE_BYTES, a);
					errs = errs + 1;
				end else if (req_write && req_be[i]) begin
					mem[a] = req_wdata[i*8 +: 8];
					if (!dirty[a]) begin
						dirty[a] = 1'b1;
						dlist[nd] = a;
						nd = nd + 1;
					end
				end else
					q_data[qt][i*8 +: 8] = mem[a];
			end
			q_wr[qt] = req_write;
			q_tag[qt] = req_tag;
			q_due[qt] = now + 1 + ($random(seed) & 7);
			if (qn > 0 && q_due[qt] < q_due[(qt + 7) % 8])
				q_due[qt] = q_due[(qt + 7) % 8];
			qt = (qt + 1) % 8;
			qn = qn + 1;
		end
		req_ready <= qn < 7 && ($random(seed) & 3) != 0;
	end

	integer fd, code, k, gerrs, tmo;
	reg [8*12-1:0] kind, gname;
	reg [8:0] sidx;
	reg [31:0] sval;
	reg x_ok;
	reg [3:0] x_kind;
	reg [15:0] eaddr;
	reg [7:0] ebyte;
	reg got_done, got_err;
	reg [3:0] got_kind;

	always @(posedge clk) begin
		if (done)
			got_done <= 1'b1;
		if (error) begin
			got_err <= 1'b1;
			got_kind <= error_kind;
		end
	end

	/* The end of a case: check, then put the memory back. */
	task finish_case;
		integer j;
		begin
			for (j = 0; j < ne; j = j + 1)
				if (mem[elist[j]] !== expv[elist[j]]) begin
					if (gerrs < 10)
						$display("FAIL atg_blt(%0d): case %0d byte %h: %h, model %h", LINE_BYTES,
							ncase, elist[j], mem[elist[j]], expv[elist[j]]);
					gerrs = gerrs + 1;
				end
			for (j = 0; j < nd; j = j + 1)
				if (!expf[dlist[j]] && mem[dlist[j]] !== hbyte(dlist[j])) begin
					if (gerrs < 10)
						$display("FAIL atg_blt(%0d): case %0d byte %h written: %h", LINE_BYTES,
							ncase, dlist[j], mem[dlist[j]]);
					gerrs = gerrs + 1;
				end
			for (j = 0; j < nd; j = j + 1) begin
				mem[dlist[j]] = hbyte(dlist[j]);
				dirty[dlist[j]] = 1'b0;
			end
			for (j = 0; j < ne; j = j + 1)
				expf[elist[j]] = 1'b0;
			nd = 0;
			ne = 0;
		end
	endtask

	initial begin
		done_all = 1'b0;
		errs = 0;
		gerrs = 0;
		ncase = 0;
		nd = 0;
		ne = 0;
		qh = 0;
		qt = 0;
		qn = 0;
		now = 0;
		for (k = 0; k < MEMB; k = k + 1) begin
			mem[k] = hbyte(k);
			dirty[k] = 1'b0;
			expf[k] = 1'b0;
		end
		fd = $fopen("sim/vec/blt.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_blt: no sim/vec/blt.txt");
			$finish;
		end
		@(posedge rst_n);
		@(posedge clk);
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%s", kind);
			if (code != 1) begin
				/* end of file */
			end else if (kind == "C") begin
				if (ncase > 0)
					finish_case;
				ncase = ncase + 1;
			end else if (kind == "S") begin
				code = $fscanf(fd, "%h %h\n", sidx, sval);
				st_we <= 1'b1;
				st_idx <= sidx;
				st_wdata <= sval;
				@(posedge clk);
				st_we <= 1'b0;
			end else if (kind == "K") begin
				code = $fscanf(fd, "%h %h\n", x_ok, x_kind);
				got_done <= 1'b0;
				got_err <= 1'b0;
				@(posedge clk);
				kick <= 1'b1;
				@(posedge clk);
				kick <= 1'b0;
				tmo = 0;
				while (!got_done && !got_err && tmo < 200000) begin
					@(posedge clk);
					tmo = tmo + 1;
				end
				@(posedge clk);
				if (got_done !== x_ok || (!x_ok && (!got_err || got_kind !== x_kind)) || busy) begin
					$display("FAIL atg_blt(%0d): case %0d: done %b error %b kind %0d busy %b", LINE_BYTES,
						ncase, got_done, got_err, got_kind, busy);
					gerrs = gerrs + 1;
				end
			end else if (kind == "E") begin
				code = $fscanf(fd, "%h %h\n", eaddr, ebyte);
				expv[eaddr] = ebyte;
				if (!expf[eaddr]) begin
					expf[eaddr] = 1'b1;
					elist[ne] = eaddr;
					ne = ne + 1;
				end
			end else if (kind == "P") begin
				code = $fscanf(fd, "%s\n", gname);
				finish_case;
				if (gerrs == 0)
					$display("PASS atg_blt.%0s (%0d)", gname, LINE_BYTES);
				errs = errs + gerrs;
				gerrs = 0;
			end
		end
		$fclose(fd);
		done_all = 1'b1;
	end
endmodule

module atg_blt_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	wire d32, d64;
	wire [31:0] e32, e64, n32, n64;
	atg_blt_tb_run #(.LINE_BYTES(32), .LINE_SHIFT(5), .SEED(31)) r32 (
		.clk(clk), .rst_n(rst_n), .done_all(d32), .errs(e32), .ncase(n32));
	atg_blt_tb_run #(.LINE_BYTES(64), .LINE_SHIFT(6), .SEED(32)) r64 (
		.clk(clk), .rst_n(rst_n), .done_all(d64), .errs(e64), .ncase(n64));

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		wait (d32 && d64);
		if (e32 == 0 && e64 == 0 && n32 > 300 && n64 > 300)
			$display("PASS atg_blt");
		else
			$display("FAIL atg_blt: %0d / %0d errors, %0d / %0d cases", e32, e64, n32, n64);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL atg_blt: timeout");
		$finish;
	end
endmodule

`default_nettype wire
