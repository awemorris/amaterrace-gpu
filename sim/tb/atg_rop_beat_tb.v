/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_beat_tb: the beats of the SU's quads (CAPS[30], one per colour
 * attachment) through atg_rop as a whole, one sample, a D32_SFLOAT depth
 * test (LESS, written) and the occlusion counter:
 *   quad A (sequence 0): four beats (attachments 0-3; attachment 2 has no
 *     format), its depths pass in lanes 0 and 2 only;
 *   quad B (sequence 1): one beat without colour, every lane passes;
 *   quad C (sequence 1, the warp's second quad): attachments 1 and 3.
 *   PASS atg_rop_beat.colour  attachment 0 (R8G8B8A8_UNORM), 1 (R32_UINT)
 *                             and 3 (R32G32B32A32_UINT) take the passing
 *                             lanes of the quad's first beat; nothing else
 *                             changes (attachment 2, the nocol beat)
 *   PASS atg_rop_beat.depth   the depths written once per quad
 *   PASS atg_rop_beat.occ     the counter: each quad's passing samples once
 *                             (2 + 4 + 4)
 *   PASS atg_rop_beat
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_beat_tb;
	`include "ghci_regs.vh"
	localparam [31:0] RT0 = 32'h1000, RT1 = 32'h1400, RT3 = 32'h1800, DS = 32'h3000;
	localparam [31:0] HALF = 32'h3F000000, QUART = 32'h3E800000, TQ = 32'h3F400000,
		TENTH = 32'h3DCCCCCD, ONE = 32'h3F800000;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg ex_valid = 1'b0, ex_last = 1'b0, ord_valid = 1'b0;
	reg [15:0] ex_seq = 0, ord_seq = 0;
	reg [31:0] ex_xy = 0;
	reg [3:0] ex_mask = 0;
	reg [511:0] ex_color = 0;
	reg [127:0] ex_depth = 0;
	reg [153:0] ex_aux = 0;
	wire busy, ex_ready, dx_ready;
	wire [15:0] ex_next;
	wire [39:0] occ;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_rop dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.busy(busy), .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next), .ex_aux(ex_aux),
		.dx_valid(1'b0), .dx_ready(dx_ready), .dx_seq(16'd0), .dx_xy(32'd0),
		.dx_mask(4'd0), .dx_depth(128'd0), .dx_last(1'b0),
		.ord_valid(ord_valid), .ord_seq(ord_seq), .occ_count(occ), .occ_clear(1'b0),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
	amb_mem #(.MEM_WORDS(4096), .SEED(7)) mem (.clk(clk), .rst_n(rst_n),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

	integer i, k, e_col = 0, e_dep = 0, e_occ = 0;

	task st;
		input [8:0] idx;
		input [31:0] val;
		begin
			@(posedge clk);
			st_we <= 1'b1;
			st_idx <= idx;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	/* one beat: {x, y}, lanes' depths, attachment, its place, colours */
	task beat;
		input [15:0] sq;
		input [31:0] xy;
		input [127:0] z;
		input [1:0] rt;
		input first, lastb, nocol, last;
		input [511:0] c;
		begin
			@(posedge clk);
			ex_valid <= 1'b1;
			ex_seq <= sq;
			ex_xy <= xy;
			ex_mask <= 4'hF;
			ex_depth <= z;
			ex_color <= c;
			ex_last <= last;
			ex_aux <= {rt, lastb, first, nocol, 1'b1, 128'd0, 4'd0, 16'h1111};
			@(posedge clk);
			while (!ex_ready)
				@(posedge clk);
			ex_valid <= 1'b0;
		end
	endtask

	/* colours: lane l component c = 0x100 l + c + 16 rt (integers), or 0 / 1.0 */
	function [511:0] cols;
		input [1:0] rt;
		integer l, c;
		begin
			for (l = 0; l < 4; l = l + 1)
				for (c = 0; c < 4; c = c + 1)
					cols[128 * l + 32 * c +: 32] = rt == 2'd0 ? (((l + c) & 1) ? ONE : 32'd0) :
						32'h100 * l + c + 16 * rt;
		end
	endfunction

	task chk;
		input [31:0] a, want;
		input integer kind;
		begin
			if (mem.peek(a) !== want) begin
				$display("FAIL atg_rop_beat: word %h = %h, want %h", a, mem.peek(a), want);
				if (kind == 0)
					e_col = e_col + 1;
				else
					e_dep = e_dep + 1;
			end
		end
	endtask

	reg [31:0] old [0:1023];	/* the colour region 0x1000-0x1FFF before */
	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		for (i = 0; i < 64; i = i + 1)
			mem.poke(DS + 4 * i, HALF);
		for (i = 0; i < 1024; i = i + 1)
			old[i] = mem.peek(32'h1000 + 4 * i);
		st(GHCI_S_RT_FORMATS, {8'd107, 8'd0, 8'd98, 8'd37});
		st(GHCI_S_RT_BASE, RT0);
		st(GHCI_S_RT_STRIDE, 32'd64);
		st(GHCI_S_RT1_BASE, RT1);
		st(GHCI_S_RT1_BASE + 9'd1, 32'd64);
		st(GHCI_S_RT1_BASE + 9'd2, 32'h1C00);	/* attachment 2: no format, not written */
		st(GHCI_S_RT1_BASE + 9'd3, 32'd64);
		st(GHCI_S_RT1_BASE + 9'd4, RT3);
		st(GHCI_S_RT1_BASE + 9'd5, 32'd256);
		st(GHCI_S_WRITE_MASK, 32'hFFFF);
		st(GHCI_S_DS_BASE, DS);
		st(GHCI_S_DS_STRIDE, 32'd32);
		st(GHCI_S_DEPTH, 32'h47);	/* test, write, LESS, D32_SFLOAT */
		st(GHCI_S_ROP_CTRL, 32'd1);
		@(posedge clk);
		ord_valid <= 1'b1;
		ord_seq <= 16'd1;
		@(posedge clk);
		ord_valid <= 1'b0;
		/* quad A at (0, 0): lanes 0 and 2 pass */
		for (k = 0; k < 4; k = k + 1)
			beat(16'd0, 32'd0, {TQ, QUART, TQ, QUART}, k, k == 0, k == 3, 1'b0, k == 3, cols(k));
		/* quad B at (2, 0) without colour; quad C at (4, 0): attachments 1, 3 */
		beat(16'd1, 32'd2, {TENTH, TENTH, TENTH, TENTH}, 2'd0, 1'b1, 1'b1, 1'b1, 1'b0, cols(0));
		beat(16'd1, 32'd4, {TENTH, TENTH, TENTH, TENTH}, 2'd1, 1'b1, 1'b0, 1'b0, 1'b0, cols(1));
		beat(16'd1, 32'd4, {TENTH, TENTH, TENTH, TENTH}, 2'd3, 1'b0, 1'b1, 1'b0, 1'b1, cols(3));
		i = 0;
		@(posedge clk);
		while ((busy || ex_next != 16'd2) && i < 20000) begin
			@(posedge clk);
			i = i + 1;
		end
		/* attachment 0: pixels (0, 0) and (0, 1) of quad A only */
		chk(RT0, 32'hFF00FF00, 0);
		chk(RT0 + 64, 32'hFF00FF00, 0);
		chk(RT0 + 4, old[1], 0);
		chk(RT0 + 68, old[17], 0);
		for (i = 2; i < 8; i = i + 1) begin
			chk(RT0 + 4 * i, old[i], 0);
			chk(RT0 + 64 + 4 * i, old[16 + i], 0);
		end
		/* attachment 1: quad A lanes 0, 2; quad C every lane */
		chk(RT1, 32'h10, 0);
		chk(RT1 + 64, 32'h210, 0);
		chk(RT1 + 4, old[257], 0);
		chk(RT1 + 68, old[273], 0);
		chk(RT1 + 8, old[258], 0);
		chk(RT1 + 16, 32'h10, 0);
		chk(RT1 + 20, 32'h110, 0);
		chk(RT1 + 80, 32'h210, 0);
		chk(RT1 + 84, 32'h310, 0);
		/* attachment 2's region unchanged */
		for (i = 0; i < 4; i = i + 1)
			chk(32'h1C00 + 4 * i, old[768 + i], 0);
		/* attachment 3: 16-byte pixels */
		for (i = 0; i < 4; i = i + 1) begin
			chk(RT3 + 4 * i, 32'h30 + i, 0);
			chk(RT3 + 256 + 4 * i, 32'h230 + i, 0);
			chk(RT3 + 16 + 4 * i, old[516 + i], 0);
			chk(RT3 + 64 + 4 * i, 32'h30 + i, 0);
			chk(RT3 + 80 + 4 * i, 32'h130 + i, 0);
			chk(RT3 + 256 + 64 + 4 * i, 32'h230 + i, 0);
			chk(RT3 + 256 + 80 + 4 * i, 32'h330 + i, 0);
		end
		/* depths: quad A lanes 0, 2; quads B and C every lane */
		chk(DS, QUART, 1);
		chk(DS + 4, HALF, 1);
		chk(DS + 32, QUART, 1);
		chk(DS + 36, HALF, 1);
		for (i = 2; i < 6; i = i + 1) begin
			chk(DS + 4 * i, TENTH, 1);
			chk(DS + 32 + 4 * i, TENTH, 1);
		end
		if (occ !== 40'd10) begin
			$display("FAIL atg_rop_beat.occ: %0d samples, want 10", occ);
			e_occ = 1;
		end
		if (i >= 20000 || busy) begin
			$display("FAIL atg_rop_beat: still busy");
			e_col = e_col + 1;
		end
		if (e_col == 0)
			$display("PASS atg_rop_beat.colour");
		if (e_dep == 0)
			$display("PASS atg_rop_beat.depth");
		if (e_occ == 0)
			$display("PASS atg_rop_beat.occ");
		if (e_col + e_dep + e_occ == 0)
			$display("PASS atg_rop_beat");
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_rop_beat: timeout");
		$finish;
	end
endmodule

`default_nettype wire
