/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_fetch_tb: atg_vf_fetch against amb_mem and a reference computed
 * here from the memory.  Random attribute sets (some disabled, every
 * format, strides 0..64, per-instance with divisors 0, 1, 2, 3, 7 and 255
 * and a FIRST_INSTANCE above 0) and random warps of 1..32 vertices; af_ready
 * is random (seeded).  Each af is checked in order (lane-major, attributes
 * ascending): attribute, lane, the format's bytes, af_last on the last
 * attribute of the warp's last vertex; a warp without enabled attributes
 * gives one af with af_last.  "addr" keeps attributes inside a line
 * (aligned bases, strides of 16 and formats of at most 16 bytes on 16-byte
 * boundaries); "cross" uses any byte alignment, so attributes cross lines.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_fetch_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg vb_valid = 1'b0;
	reg [31:0] vb_index = 0, vb_inst = 0;
	reg [4:0] vb_lane = 0;
	reg vb_last = 1'b0;
	reg af_ready = 1'b0;
	wire vb_ready, af_valid, af_last, busy;
	wire [3:0] af_attr;
	wire [4:0] af_lane;
	wire [127:0] af_raw;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_vf_fetch dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index),
		.vb_inst(vb_inst), .vb_lane(vb_lane), .vb_last(vb_last), .af_valid(af_valid),
		.af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane), .af_raw(af_raw),
		.af_last(af_last), .busy(busy),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
	amb_mem #(.MEM_WORDS(8192), .SEED(7)) mem (.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	integer seed, i, errs, sect_errs, xn, xg, tmo, w;
	reg [31:0] finst;
	reg [31:0] a_base [0:15];
	reg [15:0] a_stride [0:15];
	reg [3:0] a_fmt [0:15];
	reg a_inst [0:15];
	reg [7:0] a_div [0:15];
	reg [7:0] a_dst [0:15];
	/* expected af */
	reg [3:0] x_attr [0:4095];
	reg [4:0] x_lane [0:4095];
	reg [127:0] x_raw [0:4095];
	reg [4:0] x_size [0:4095];
	reg x_last [0:4095];

	task st_put;
		input [8:0] i_;
		input [31:0] val;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	function [7:0] mbyte;
		input [31:0] a;
		reg [31:0] wd;
		begin
			wd = mem.peek(a & ~32'd3);
			mbyte = wd >> (8 * (a & 3));
		end
	endfunction

	function [4:0] fsize;
		input [3:0] f;
		case (f)
		4'd1, 4'd7, 4'd9: fsize = 5'd8;
		4'd2: fsize = 5'd12;
		4'd3: fsize = 5'd16;
		default: fsize = 5'd4;
		endcase
	endfunction

	/* Push the expected af of one accepted vertex. */
	task expect_vertex;
		input [31:0] idx, inst;
		input [4:0] lane;
		input last;
		integer k, b, nk;
		reg [31:0] e, a;
		reg [127:0] r;
		begin
			nk = 0;
			for (k = 0; k < 16; k = k + 1)
				if (a_dst[k] != 8'd0)
					nk = nk + 1;
			for (k = 0; k < 16; k = k + 1)
				if (a_dst[k] != 8'd0) begin
					if (!a_inst[k])
						e = idx;
					else if (a_div[k] == 8'd0)
						e = finst;
					else
						e = finst + (inst - finst) / a_div[k];
					a = a_base[k] + e * a_stride[k];
					r = 128'd0;
					for (b = 0; b < 16; b = b + 1)
						r[8 * b +: 8] = mbyte(a + b);
					x_attr[xn] = k;
					x_lane[xn] = lane;
					x_raw[xn] = r;
					x_size[xn] = fsize(a_fmt[k]);
					nk = nk - 1;
					x_last[xn] = last && nk == 0;
					xn = xn + 1;
				end
			if (last && a_dst[0] == 8'd0 && a_dst[1] == 8'd0 && a_dst[2] == 8'd0 &&
				a_dst[3] == 8'd0 && a_dst[4] == 8'd0 && a_dst[5] == 8'd0 &&
				a_dst[6] == 8'd0 && a_dst[7] == 8'd0 && a_dst[8] == 8'd0 &&
				a_dst[9] == 8'd0 && a_dst[10] == 8'd0 && a_dst[11] == 8'd0 &&
				a_dst[12] == 8'd0 && a_dst[13] == 8'd0 && a_dst[14] == 8'd0 &&
				a_dst[15] == 8'd0) begin
				x_attr[xn] = 4'd0;
				x_lane[xn] = lane;
				x_raw[xn] = 128'd0;
				x_size[xn] = 5'd0;
				x_last[xn] = 1'b1;
				xn = xn + 1;
			end
		end
	endtask

	reg [127:0] m;
	always @(posedge clk) begin
		if (vb_valid && vb_ready)
			expect_vertex(vb_index, vb_inst, vb_lane, vb_last);
		if (af_valid && af_ready) begin
			m = x_size[xg] == 5'd16 ? {128{1'b1}} : ({128{1'b1}} >> (128 - 8 * x_size[xg]));
			if (xg >= xn) begin
				$display("FAIL atg_vf_fetch: af %0d beyond %0d", xg, xn);
				errs = errs + 1;
			end else if (af_attr !== x_attr[xg] || af_lane !== x_lane[xg] ||
				af_last !== x_last[xg] || (af_raw & m) !== (x_raw[xg] & m)) begin
				$display("FAIL atg_vf_fetch: af %0d attr %0d lane %0d last %b raw %h, want %0d %0d %b %h",
					xg, af_attr, af_lane, af_last, af_raw & m, x_attr[xg], x_lane[xg],
					x_last[xg], x_raw[xg] & m);
				errs = errs + 1;
			end
			xg = xg + 1;
		end
		af_ready <= ($random(seed) & 3) != 0;
	end

	/* A random attribute set; crossing: any byte alignment. */
	task setup;
		input crossing;
		input integer nen;
		integer k;
		reg [31:0] r;
		begin
			finst = $unsigned($random(seed)) % 20;
			st_put(9'h027, finst);
			for (k = 0; k < 16; k = k + 1) begin
				r = $random(seed);
				a_fmt[k] = $unsigned($random(seed)) % 10;
				if (crossing) begin
					a_base[k] = $unsigned($random(seed)) % 16384;
					a_stride[k] = $unsigned($random(seed)) % 65;
				end else begin
					a_base[k] = ($unsigned($random(seed)) % 1024) * 16;
					a_stride[k] = 16 * ($unsigned($random(seed)) % 5);
				end
				a_inst[k] = r[0] && r[1];
				case (r[4:2])
				3'd0: a_div[k] = 8'd0;
				3'd1, 3'd2: a_div[k] = 8'd1;
				3'd3: a_div[k] = 8'd2;
				3'd4: a_div[k] = 8'd3;
				3'd5: a_div[k] = 8'd7;
				default: a_div[k] = 8'd255;
				endcase
				a_dst[k] = ($unsigned($random(seed)) % 16) < nen ?
					{r[9:8], r[15:10] | 6'd1} : 8'd0;
				st_put(9'h030 + 2 * k, a_base[k]);
				st_put(9'h031 + 2 * k, {a_div[k], 3'd0, a_inst[k], a_fmt[k], a_stride[k]});
				st_put(9'h1C0 + k, {24'd0, a_dst[k]});
			end
		end
	endtask

	task warp;
		input integer nv;
		integer v;
		begin
			for (v = 0; v < nv; v = v + 1) begin
				vb_valid <= 1'b1;
				vb_index <= $unsigned($random(seed)) % 100;
				vb_inst <= finst + $unsigned($random(seed)) % 40;
				vb_lane <= v;
				vb_last <= v == nv - 1;
				@(negedge clk);
				while (!vb_ready)
					@(negedge clk);
				@(posedge clk);
				vb_valid <= 1'b0;
				if ($random(seed) & 1)
					@(posedge clk);
			end
			@(negedge clk);
			tmo = 0;
			while ((busy || xg < xn) && tmo < 200000) begin
				@(negedge clk);
				tmo = tmo + 1;
			end
			if (tmo >= 200000 || xg != xn) begin
				$display("FAIL atg_vf_fetch: warp of %0d: %0d of %0d af", nv, xg, xn);
				errs = errs + 1;
			end
			xn = 0;
			xg = 0;
		end
	endtask

	task section;
		input [8*8-1:0] name;
		begin
			if (errs == sect_errs)
				$display("PASS atg_vf_fetch.%0s", name);
			sect_errs = errs;
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		errs = 0;
		sect_errs = 0;
		xn = 0;
		xg = 0;
		for (i = 0; i < 8192; i = i + 1)
			mem.poke(4 * i, $random(seed));
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		for (w = 0; w < 12; w = w + 1) begin
			setup(1'b0, w == 0 ? 0 : 1 + w);
			warp(w == 1 ? 32 : 1 + ($unsigned($random(seed)) % 32));
			warp(1 + ($unsigned($random(seed)) % 32));
		end
		section("addr");

		for (w = 0; w < 12; w = w + 1) begin
			setup(1'b1, 1 + w);
			warp(1 + ($unsigned($random(seed)) % 32));
			warp(32);
		end
		section("cross");

		if (errs == 0)
			$display("PASS atg_vf_fetch");
		$finish;
	end

	initial begin
		#50000000;
		$display("FAIL atg_vf_fetch: timeout");
		$finish;
	end
endmodule

`default_nettype wire
