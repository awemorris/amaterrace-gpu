/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_cbank_tb: atg_su_cbank (NPHYS 8, 256 words) with amb_mem on its
 * AMB port.
 *   load: LOAD_CONST through the STATE words 0x1EC-0x1EE and lc_kick, from
 *         unaligned addresses and word counts (1..256, also more than 256),
 *         busy until done; region 1 loads nothing;
 *   read: c operands (cr_en registers three words, the output holds while
 *         cr_en is 0) and lwc (rs1 + imm per lane, EXEC lanes, beat
 *         fields); after inv both read 0.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_cbank_tb;
`include "atg_su_uop.vh"

	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0, x_last = 1'b0;
	reg [1:0] x_warp = 0, x_grp = 0;
	reg [2:0] x_sbe = 0;
	reg [103:0] x_uop = 0;
	reg [DW-1:0] x_a = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg l_ready = 1'b0;
	wire x_ready, l_valid, l_wr, l_last;
	wire [1:0] l_warp, l_grp;
	wire [6:0] l_rd;
	wire [DW-1:0] l_data;
	wire [NPHYS-1:0] l_lanes;
	wire [2:0] l_sbe, l_cls;
	reg cr_en = 1'b0;
	reg [14:0] cr_idx = 0;
	wire [95:0] cr_data;
	reg st_we = 1'b0, lc_kick = 1'b0, inv = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	wire busy;
	wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata, rsp_rdata;
	wire [7:0] req_tag, rsp_tag;

	atg_su_cbank #(.NPHYS(NPHYS)) dut (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a),
		.x_b({DW{1'b0}}), .x_c({DW{1'b0}}), .x_mask(x_mask), .x_info(32'd0),
		.x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp),
		.l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr),
		.l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls),
		.cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .lc_kick(lc_kick), .inv(inv),
		.busy(busy),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);
	amb_mem #(.MEM_WORDS(2048)) mem (
		.clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
		.req_write(req_write), .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata),
		.req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	reg [31:0] cref [0:255];
	integer seed, i, j, l, n, err_l, err_r, words, base;

	task state;
		input [8:0] idx;
		input [31:0] v;
		begin
			@(negedge clk);
			st_we = 1'b1;
			st_idx = idx;
			st_wdata = v;
			@(negedge clk);
			st_we = 1'b0;
		end
	endtask

	task load;
		input [31:0] region;
		input [31:0] addr;
		input [31:0] w;
		begin
			state(9'h1EC, region);
			state(9'h1ED, addr);
			state(9'h1EE, w);
			@(negedge clk);
			lc_kick = 1'b1;
			@(negedge clk);
			lc_kick = 1'b0;
			n = 0;
			while (busy) begin
				@(negedge clk);
				n = n + 1;
				if (n > 20000) begin
					$display("FAIL atg_su_cbank: load does not end");
					$finish;
				end
			end
			if (region == 0)
				for (j = 0; j < 256; j = j + 1)
					if (j < w)
						cref[j] = mem.peek(addr + 4 * j);
		end
	endtask

	task check;
		input zero;
		reg [4:0] a, b, c;
		reg [95:0] held;
		begin
			for (j = 0; j < 40; j = j + 1) begin
				a = $random(seed);
				b = $random(seed);
				c = $random(seed);
				@(negedge clk);
				cr_en = 1'b1;
				cr_idx = {c, b, a};
				@(negedge clk);
				cr_en = 1'b0;
				cr_idx = $random(seed);
				held = cr_data;
				@(negedge clk);
				if (held !== (zero ? 96'd0 : {cref[c], cref[b], cref[a]}) || cr_data !== held) begin
					$display("FAIL atg_su_cbank: c operands %0d %0d %0d", a, b, c);
					err_r = err_r + 1;
				end
			end
			for (j = 0; j < 40; j = j + 1) begin
				@(negedge clk);
				x_uop = 0;
				x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_CBANK;
				x_uop[ATG_UOP_IMM +: 32] = $random(seed) % 8;
				x_uop[ATG_UOP_RD +: 7] = j;
				x_uop[ATG_UOP_WRD] = 1'b1;
				x_mask = $random(seed);
				x_last = $random(seed);
				x_sbe = $random(seed);
				x_warp = $random(seed);
				x_grp = $random(seed);
				for (l = 0; l < NPHYS; l = l + 1)
					x_a[l*32 +: 32] = j % 4 == 0 ? 32'd5 : $random(seed);
				x_valid = 1'b1;
				@(posedge clk);
				while (!x_ready)
					@(posedge clk);
				@(negedge clk);
				x_valid = 1'b0;
				n = 0;
				l_ready = $random(seed);
				#1;
				while (!(l_valid && l_ready)) begin
					@(negedge clk);
					l_ready = $random(seed);
					#1;
					n = n + 1;
					if (n > 1000) begin
						$display("FAIL atg_su_cbank: no lwc beat");
						$finish;
					end
				end
				if (l_rd !== j || l_lanes !== x_mask[NPHYS-1:0] || !l_wr || l_last !== x_last ||
				    l_sbe !== x_sbe || l_cls !== ATG_CLS_M || l_warp !== x_warp ||
				    l_grp !== x_grp) begin
					$display("FAIL atg_su_cbank: lwc beat fields");
					err_r = err_r + 1;
				end
				for (l = 0; l < NPHYS; l = l + 1)
					if (x_mask[l] && l_data[l*32 +: 32] !== (zero ? 32'd0 :
					    cref[(x_a[l*32 +: 32] + x_uop[ATG_UOP_IMM +: 32]) % 256])) begin
						$display("FAIL atg_su_cbank: lwc lane %0d %h", l, l_data[l*32 +: 32]);
						err_r = err_r + 1;
					end
				@(negedge clk);
				l_ready = 1'b0;
			end
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		err_l = 0;
		err_r = 0;
		for (i = 0; i < 2048; i = i + 1)
			mem.poke(4 * i, $random(seed));
		for (i = 0; i < 256; i = i + 1)
			cref[i] = 32'd0;
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		for (i = 0; i < 12; i = i + 1) begin
			base = ($unsigned($random(seed)) % 512) * 4;
			words = i == 0 ? 256 : i == 1 ? 300 : i == 2 ? 1 : 1 + $unsigned($random(seed)) % 256;
			load(0, base, words);
			for (j = 0; j < 256; j = j + 1)
				if (dut.bank[j] !== cref[j] && j < (words > 256 ? 256 : words)) begin
					if (err_l < 10)
						$display("FAIL atg_su_cbank: load %0d word %0d %h want %h", i, j,
							dut.bank[j], cref[j]);
					err_l = err_l + 1;
				end
			check(1'b0);
		end
		/* Region 1: nothing changes. */
		load(1, 0, 16);
		check(1'b0);
		@(negedge clk);
		inv = 1'b1;
		@(negedge clk);
		inv = 1'b0;
		check(1'b1);
		if (err_l == 0) $display("PASS atg_su_cbank.load");
		if (err_r == 0) $display("PASS atg_su_cbank.read");
		if (err_l + err_r == 0) $display("PASS atg_su_cbank");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_su_cbank timeout");
		$finish;
	end
endmodule

`default_nettype wire
