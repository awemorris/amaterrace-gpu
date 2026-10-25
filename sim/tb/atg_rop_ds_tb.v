/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_ds_tb: atg_rop_ds against amb_mem and the reference model
 * (sim/vec/rop_ds.txt from tools/rx-vectors.py): each of the 8 depth
 * functions with D32F and D24S8, with and without the write, on a 16x16
 * buffer of random depths (NaN, 0, 1 among them), 60 overlapping quads per
 * run in order (later quads read what earlier ones wrote), and a run with
 * the test off.  Checks the passing lanes on d_*, the colour (DEBUG_COLOR
 * or the SU's), and the buffer at the end (the stencil byte of D24S8
 * kept).  Then sim/vec/rop_ds2.txt (tools/rop-vectors.py, CAPS[30]): runs
 * of D24S8 with the stencil test and ops (random faces per quad), of D16
 * (2-byte pixels) and of the depth bounds of the three formats, with the
 * same checks.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_ds_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg q_valid = 1'b0, q_dbg = 1'b0, d_ready = 1'b0, q_front = 1'b0;
	reg [31:0] q_xy = 0;
	reg [3:0] q_mask = 0;	/* one sample: lane l is q_smask bit 4 l */
	reg [511:0] q_color = 0;
	reg [127:0] q_depth = 0;
	wire q_ready, d_valid, busy;
	wire [31:0] d_xy;
	wire [15:0] d_smask;
	wire [3:0] d_mask = {d_smask[12], d_smask[8], d_smask[4], d_smask[0]};
	wire [511:0] d_color;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;
	integer seed;

	atg_rop_ds dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .q_valid(q_valid), .q_ready(q_ready), .q_xy(q_xy),
		.q_smask({3'd0, q_mask[3], 3'd0, q_mask[2], 3'd0, q_mask[1], 3'd0, q_mask[0]}),
		.q_color(q_color),
		.q_sdepth({96'd0, q_depth[127:96], 96'd0, q_depth[95:64], 96'd0, q_depth[63:32], 96'd0,
			q_depth[31:0]}), .q_dbg(q_dbg), .q_front(q_front), .q_beat(4'b0001),
		.d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_smask(d_smask),
		.d_color(d_color), .d_beat(), .busy(busy),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	amb_mem #(.MEM_WORDS(4096), .SEED(5)) mem (.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	`include "atg_rop_unorm8.vh"

	localparam [31:0] DS_BASE = 32'h1000;
	integer fd, code, i, j, nrun, nq, e_funcs = 0, e_raw = 0, e_out = 0, sect, nrun2, fr;
	integer e_s [0:2];
	reg [31:0] v_dep, v_sf, v_sb, v_sops, v_bmin, v_bmax, v_str;
	reg [7:0] tag, dep;
	reg [31:0] dbgc, v, x, y, z0, z1, z2, z3, wt;
	reg [3:0] m, pass;
	/* expected d_* outputs of the run */
	reg [31:0] o_xy [0:63];
	reg [3:0] o_m [0:63];
	reg [511:0] o_c [0:63];
	integer o_n, o_got;

	always @(posedge clk) begin
		d_ready <= ($random(seed) & 3) != 0;
		if (d_valid && d_ready) begin
			if (o_got >= o_n || d_xy !== o_xy[o_got] || d_mask !== o_m[o_got] ||
			    (d_smask & 16'hEEEE) !== 16'd0 ||
			    d_color !== o_c[o_got]) begin
				e_out = e_out + 1;
				if (e_out < 8)
					$display("FAIL atg_rop_ds: run %0d output %0d: %h mask %h, expected %h %h",
						nrun, o_got, d_xy, d_mask, o_xy[o_got], o_m[o_got]);
			end
			o_got = o_got + 1;
		end
	end

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

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		fd = $fopen("sim/vec/rop_ds.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_ds: no sim/vec/rop_ds.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		st_put(9'h074, DS_BASE);
		st_put(9'h075, 32'd64);
		nrun = 0;
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "R") begin
				code = $fscanf(fd, " %h %h", dep, dbgc);
				for (i = 0; i < 256; i = i + 1) begin
					code = $fscanf(fd, " %h", wt);
					mem.poke(DS_BASE + 4 * i, wt);
				end
				code = $fscanf(fd, "%c", tag);
				st_put(9'h076, {24'd0, dep});
				st_put(9'h05C, dbgc);
				o_n = 0;
				o_got = 0;
				nq = 0;
			end else if (tag == "Q") begin
				code = $fscanf(fd, " %h %h %h %h %h %h %h %h\n", x, y, m, z0, z1, z2, z3, pass);
				q_valid <= 1'b1;
				q_xy <= {y[15:0], x[15:0]};
				q_mask <= m;
				q_depth <= {z3, z2, z1, z0};
				q_dbg <= nq[0];
				q_color <= {16{$random(seed)}};
				@(posedge clk);
				while (!q_ready)
					@(posedge clk);
				if (pass != 4'd0) begin
					o_xy[o_n] = {y[15:0], x[15:0]};
					o_m[o_n] = pass;
					o_c[o_n] = nq[0] ? {4{atg_rop_unorm8(dbgc[31:24]), atg_rop_unorm8(dbgc[23:16]),
						atg_rop_unorm8(dbgc[15:8]), atg_rop_unorm8(dbgc[7:0])}} : q_color;
					o_n = o_n + 1;
				end
				q_valid <= 1'b0;
				@(posedge clk);
				nq = nq + 1;
			end else if (tag == "F") begin
				j = 0;
				while ((busy || o_got < o_n) && j < 20000) begin
					@(posedge clk);
					j = j + 1;
				end
				if (o_got != o_n) begin
					e_out = e_out + 1;
					$display("FAIL atg_rop_ds: run %0d: %0d of %0d outputs", nrun, o_got, o_n);
				end
				for (i = 0; i < 256; i = i + 1) begin
					code = $fscanf(fd, " %h", wt);
					v = mem.peek(DS_BASE + 4 * i);
					if (v !== wt) begin
						if (nrun < 32)
							e_funcs = e_funcs + 1;
						else
							e_raw = e_raw + 1;
						if (e_funcs + e_raw < 8)
							$display("FAIL atg_rop_ds: run %0d (DEPTH %h) pixel %0d = %h, expected %h",
								nrun, dep, i, v, wt);
					end
				end
				code = $fscanf(fd, "%c", tag);
				nrun = nrun + 1;
			end else
				code = 0;
		end
		$fclose(fd);

		/* CAPS[30] (the earlier output errors kept in e_funcs) */
		e_funcs = e_funcs + e_out;
		for (i = 0; i < 3; i = i + 1)
			e_s[i] = 0;
		nrun2 = 0;
		fd = $fopen("sim/vec/rop_ds2.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_ds: no sim/vec/rop_ds2.txt");
			$finish;
		end
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "R") begin
				code = $fscanf(fd, " %d %h %h %h %h %h %h %h %h", sect, v_dep, v_sf, v_sb, v_sops,
					v_bmin, v_bmax, dbgc, v_str);
				for (i = 0; i < 256; i = i + 1) begin
					code = $fscanf(fd, " %h", wt);
					mem.poke(DS_BASE + 4 * i, wt);
				end
				code = $fscanf(fd, "%c", tag);
				st_put(9'h076, v_dep);
				st_put(9'h077, v_sf);
				st_put(9'h079, v_sb);
				st_put(9'h078, v_sops);
				st_put(9'h08B, v_bmin);
				st_put(9'h08C, v_bmax);
				st_put(9'h075, v_str);
				st_put(9'h05C, dbgc);
				o_n = 0;
				o_got = 0;
				nq = 0;
				e_out = 0;
			end else if (tag == "Q") begin
				code = $fscanf(fd, " %h %h %h %d %h %h %h %h %h\n", x, y, m, fr, z0, z1, z2, z3,
					pass);
				q_valid <= 1'b1;
				q_xy <= {y[15:0], x[15:0]};
				q_mask <= m;
				q_depth <= {z3, z2, z1, z0};
				q_dbg <= 1'b0;
				q_front <= fr != 0;
				q_color <= {16{$random(seed)}};
				@(posedge clk);
				while (!q_ready)
					@(posedge clk);
				if (pass != 4'd0) begin
					o_xy[o_n] = {y[15:0], x[15:0]};
					o_m[o_n] = pass;
					o_c[o_n] = q_color;
					o_n = o_n + 1;
				end
				q_valid <= 1'b0;
				@(posedge clk);
				nq = nq + 1;
			end else if (tag == "F") begin
				j = 0;
				while ((busy || o_got < o_n) && j < 20000) begin
					@(posedge clk);
					j = j + 1;
				end
				if (o_got != o_n || e_out != 0) begin
					e_s[sect] = e_s[sect] + 1;
					$display("FAIL atg_rop_ds: CAPS[30] run %0d: %0d of %0d outputs, %0d wrong",
						nrun2, o_got, o_n, e_out);
				end
				for (i = 0; i < 256; i = i + 1) begin
					code = $fscanf(fd, " %h", wt);
					v = mem.peek(DS_BASE + 4 * i);
					if (v !== wt) begin
						e_s[sect] = e_s[sect] + 1;
						if (e_s[0] + e_s[1] + e_s[2] < 8)
							$display("FAIL atg_rop_ds: CAPS[30] run %0d (section %0d DEPTH %h) word %0d = %h, expected %h",
								nrun2, sect, v_dep, i, v, wt);
					end
				end
				code = $fscanf(fd, "%c", tag);
				nrun2 = nrun2 + 1;
			end else
				code = 0;
		end
		$fclose(fd);
		e_out = 0;
		$display("atg_rop_ds: %0d runs, %0d CAPS[30] runs", nrun, nrun2);
		if (e_funcs == 0 && e_out == 0)
			$display("PASS atg_rop_ds.funcs");
		if (e_s[0] == 0 && nrun2 > 0)
			$display("PASS atg_rop_ds.stencil");
		if (e_raw == 0 && e_out == 0)
			$display("PASS atg_rop_ds.raw");
		if (e_s[1] == 0 && nrun2 > 0)
			$display("PASS atg_rop_ds.d16");
		if (e_s[2] == 0 && nrun2 > 0)
			$display("PASS atg_rop_ds.bounds");
		if (e_funcs + e_raw + e_out + e_s[0] + e_s[1] + e_s[2] == 0 && nrun2 > 0)
			$display("PASS atg_rop_ds");
		$finish;
	end
endmodule

`default_nettype wire
