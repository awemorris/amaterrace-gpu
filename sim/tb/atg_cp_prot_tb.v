/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_prot_tb: the CP's side of session protection
 * (spec/gpu/cp/atg_cp_prot.md), the module alone, driven as the
 * sequencer, the CPU's window and the host would.  Groups (each prints
 * PASS atg_cp_prot.GROUP):
 *   regs    PROT_CAPS, PROT_TABLE (aligned, kept while a slot is mapped,
 *           0 after an aperture write), PROT_TABLE_BYTES, PROT_INFO
 *   slots   PROT_SLOT: SLOT_MAP (tag 0 stays 0), v_slot, SLOT_TAG (fault_tag)
 *   uslot   the µop's slot: a ring µop's from SLOT_MAP, a firmware µop's from
 *           its side; f_chk only for a firmware µop that is not SELF
 *   switch  a unit µop of another slot waits for drain_ok, then sw_inv once,
 *           the scrub only when the shader units hold another owner's data
 *           (after reset: always), then prot_unit; the same slot again: at
 *           once; A, then unchecked work without the shader units, then A:
 *           no second scrub
 *   close   clearing a slot drops prot_unit and makes its data foreign: the
 *           next session in that slot gets a scrub
 *   mc      PROT_INV_G/N and the CAM's registers make one pulse each with
 *           the values for the MC
 * Mutations (each must FAIL): MUT_CPPROT_CLOSEKEEP, MUT_CPPROT_NODRAIN,
 * MUT_CPPROT_NOSCRUB, MUT_CPPROT_NOINV, MUT_CPPROT_RESID0, MUT_CPPROT_FCHK.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_prot_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg hcr_we = 1'b0;
	reg [9:0] hcr_widx = 10'd0;
	reg [31:0] hcr_wdata = 32'd0;
	reg [9:0] hcr_ridx = 10'd0;
	wire [31:0] hcr_rdata;
	reg [31:0] ap_base = 32'h00000800, ap_limit = 32'h40000000;
	reg sb_we = 1'b0;
	reg [5:0] sb_idx = 6'd0;
	reg [31:0] sb_wdata = 32'd0;
	wire [31:0] sb_rdata;
	reg [7:0] v_tag = 8'd0;
	wire [5:0] v_slot;
	reg [7:0] u_tag = 8'd0;
	reg u_fw = 1'b0;
	reg [6:0] u_side = 7'd0;
	reg [1:0] u_req = 2'd0;
	wire u_ok, f_chk;
	wire [5:0] f_slot;
	reg drain_ok = 1'b1;
	wire sw_inv, scrub;
	reg scrub_busy = 1'b0;
	wire [5:0] prot_unit;
	wire [31:0] tbase;
	wire inv_valid, gw_valid;
	wire [19:0] inv_g;
	wire [31:0] inv_n;
	wire [5:0] gw_idx;
	wire [49:0] gw_data;
	reg [5:0] fault_slot = 6'd0;
	wire [7:0] fault_tag, unit_tag;

	atg_cp_prot #(.SLOTS(8'd31), .GRANTS(16'd64), .GIDX_W(6)) dut (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata),
		.hcr_wmask(32'hFFFFFFFF), .hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.aperture_base(ap_base), .aperture_limit(ap_limit),
		.sb_we(sb_we), .sb_idx(sb_idx), .sb_wdata(sb_wdata), .sb_rdata(sb_rdata),
		.v_tag(v_tag), .v_slot(v_slot),
		.u_tag(u_tag), .u_fw(u_fw), .u_side(u_side), .u_req(u_req), .u_ok(u_ok),
		.f_chk(f_chk), .f_slot(f_slot),
		.drain_ok(drain_ok), .sw_inv(sw_inv), .scrub(scrub), .scrub_busy(scrub_busy),
		.prot_unit(prot_unit),
		.tbase(tbase), .inv_valid(inv_valid), .inv_g(inv_g), .inv_n(inv_n),
		.inv_pending(1'b0), .gw_valid(gw_valid), .gw_idx(gw_idx), .gw_data(gw_data),
		.fault_slot(fault_slot), .fault_tag(fault_tag), .unit_tag(unit_tag)
	);

	integer errors = 0, before;
	integer n_inv = 0, n_scrub = 0, n_inv_mc = 0, n_gw = 0;
	reg [19:0] last_inv_g;
	reg [31:0] last_inv_n;
	reg [49:0] last_gw;
	reg [5:0] last_gw_idx;

	/* The scrub: the SUs are busy for a while after it. */
	integer sc = 0;
	reg [5:0] pu_q = 6'd0;
	reg dr_seen = 1'b0;
	always @(posedge clk) begin
		if (sw_inv)
			n_inv = n_inv + 1;
		if (scrub) begin
			n_scrub = n_scrub + 1;
			sc = 6;
		end else if (sc > 0) begin
			sc = sc - 1;
		end
		scrub_busy <= sc > 0;
		if (inv_valid) begin
			n_inv_mc = n_inv_mc + 1;
			last_inv_g = inv_g;
			last_inv_n = inv_n;
		end
		if (gw_valid) begin
			n_gw = n_gw + 1;
			last_gw = gw_data;
			last_gw_idx = gw_idx;
		end
		/* prot_unit takes a new slot only after a drained cycle. */
		if (prot_unit != pu_q && prot_unit != 6'd0 && !dr_seen) begin
			errors = errors + 1;
			$display("FAIL atg_cp_prot.switch: prot_unit changed without drain");
		end
		if (prot_unit != pu_q)
			dr_seen = 1'b0;
		else if (drain_ok && dut.st == 3'd1)
			dr_seen = 1'b1;
		pu_q <= prot_unit;
	end

	task check;
		input ok;
		input [8*24-1:0] what;
		begin
			if (!ok) begin
				errors = errors + 1;
				$display("FAIL atg_cp_prot: %0s", what);
			end
		end
	endtask

	task group;
		input [8*8-1:0] name;
		begin
			if (errors == before)
				$display("PASS atg_cp_prot.%0s", name);
			else
				$display("FAIL atg_cp_prot.%0s: %0d errors", name, errors - before);
			before = errors;
		end
	endtask

	task hw;
		input [11:0] off;
		input [31:0] v;
		begin
			@(negedge clk);
			hcr_we = 1'b1;
			hcr_widx = off[11:2];
			hcr_wdata = v;
			@(negedge clk);
			hcr_we = 1'b0;
		end
	endtask

	task hr;
		input [11:0] off;
		output [31:0] v;
		begin
			@(negedge clk);
			hcr_ridx = off[11:2];
			#1;
			v = hcr_rdata;
		end
	endtask

	task sw;
		input [5:0] idx;
		input [31:0] v;
		begin
			@(negedge clk);
			sb_we = 1'b1;
			sb_idx = idx;
			sb_wdata = v;
			@(negedge clk);
			sb_we = 1'b0;
			sb_idx = 6'd0;
		end
	endtask

	task sr;
		input [5:0] idx;
		output [31:0] v;
		begin
			@(negedge clk);
			sb_idx = idx;
			#1;
			v = sb_rdata;
			sb_idx = 6'd0;
		end
	endtask

	/* A unit µop: waits for u_ok (at most `lim` cycles), then one cycle more. */
	integer waited;
	task uop;
		input fw;
		input [7:0] tag;
		input [6:0] side;
		input su;
		input integer lim;
		begin
			@(negedge clk);
			u_fw = fw;
			u_tag = tag;
			u_side = side;
			u_req = {su, 1'b1};
			waited = 0;
			#1;
			while (!u_ok && waited < lim) begin
				@(negedge clk);
				#1;
				waited = waited + 1;
			end
			@(negedge clk);
			u_req = 2'd0;
		end
	endtask

	reg [31:0] v;
	integer i0, s0;

	initial begin
		before = 0;
		repeat (3) @(posedge clk);
		rst_n = 1'b1;

		/* regs */
		hr(12'h1D0, v);
		check(v == {16'd64, 8'd12, 8'd31}, "PROT_CAPS");
		hr(12'h1D8, v);
		/* [0x800, 0x40000000): G0 0, G1 0x40000: 0x40000 bytes. */
		check(v == 32'h00040000, "PROT_TABLE_BYTES");
		hw(12'h1D4, 32'h00123456);
		hr(12'h1D4, v);
		check(v == 32'h00123000, "PROT_TABLE aligned");
		sr(6'h2E, v);
		check(v[1:0] == 2'b11 && v[13:8] == 6'd31 && v[31:16] == 16'd64, "PROT_INFO");
		hw(12'h060, 32'h00000800);
		hr(12'h1D4, v);
		check(v == 32'd0, "aperture clears PROT_TABLE");
		hw(12'h1D4, 32'h00200000);
		sw(6'h28, {18'd0, 6'd3, 8'd5});	/* tag 5 -> slot 3 */
		hw(12'h1D4, 32'h00300000);
		hr(12'h1D4, v);
		check(v == 32'h00200000, "PROT_TABLE locked");
		sr(6'h30, v);
		check(v == 32'd0, "PROT_G0");
		sr(6'h31, v);
		check(v == 32'h40000, "PROT_G1");
		group("regs");

		/* slots */
		v_tag = 8'd5;
		#1;
		check(v_slot == 6'd3, "v_slot");
		sw(6'h28, {18'd0, 6'd4, 8'd0});	/* tag 0: ignored */
		v_tag = 8'd0;
		#1;
		check(v_slot == 6'd0, "tag 0");
		fault_slot = 6'd3;
		#1;
		check(fault_tag == 8'd5, "SLOT_TAG");
		sw(6'h28, {18'd0, 6'd2, 8'd9});	/* tag 9 -> slot 2 */
		group("slots");

		/* uslot */
		@(negedge clk);
		u_fw = 1'b0;
		u_tag = 8'd5;
		#1;
		check(f_slot == 6'd3 && !f_chk, "ring µop");
		u_fw = 1'b1;
		u_side = {1'b0, 6'd2};
		#1;
		check(f_slot == 6'd2 && f_chk, "firmware µop");
		u_side = {1'b1, 6'd2};
		#1;
		check(!f_chk, "SELF");
		u_side = {1'b0, 6'd0};
		#1;
		check(!f_chk, "slot 0");
		u_fw = 1'b0;
		group("uslot");

		/* switch: after reset the data is mixed, so the first switch to 3 scrubs. */
		drain_ok = 1'b0;
		i0 = n_inv;
		s0 = n_scrub;
		uop(1'b0, 8'd5, 7'd0, 1'b1, 30);
		check(waited >= 30 && prot_unit != 6'd3, "waits for drain");
		check(n_inv == i0, "no inv before drain");
		drain_ok = 1'b1;
		uop(1'b0, 8'd5, 7'd0, 1'b1, 50);
		check(prot_unit == 6'd3 && waited < 50, "switched to 3");
		check(n_inv == i0 + 1 && n_scrub == s0 + 1, "inv and scrub once");
		uop(1'b1, 8'd0, {1'b0, 6'd3}, 1'b1, 5);
		check(waited == 0 && n_inv == i0 + 1, "same slot at once");
		/* Unchecked work without the shader units (a blit, tag 77 unmapped), then 3. */
		uop(1'b0, 8'd77, 7'd0, 1'b0, 50);
		check(prot_unit == 6'd0, "switched to 0");
		check(n_scrub == s0 + 1, "no scrub for slot 0");
		uop(1'b0, 8'd5, 7'd0, 1'b1, 50);
		check(prot_unit == 6'd3 && n_scrub == s0 + 1, "A again: no scrub");
		/* Slot 2's work after 3's data: scrub. */
		uop(1'b1, 8'd0, {1'b0, 6'd2}, 1'b1, 50);
		check(prot_unit == 6'd2 && n_scrub == s0 + 2, "B after A: scrub");
		check(unit_tag == 8'd9, "unit_tag");
		group("switch");

		/* close: slot 2 (tag 9) ends while it holds the units and their data. */
		sw(6'h28, {18'd0, 6'd0, 8'd9});
		@(negedge clk);
		check(prot_unit == 6'd0, "prot_unit dropped");
		sw(6'h28, {18'd0, 6'd2, 8'd11});	/* a new session in slot 2 */
		s0 = n_scrub;
		uop(1'b0, 8'd11, 7'd0, 1'b1, 50);
		check(prot_unit == 6'd2 && n_scrub == s0 + 1, "new session: scrub");
		group("close");

		/* mc */
		sw(6'h29, 32'h00012345);
		check(n_inv_mc == 0, "INV_G alone");
		sw(6'h33, 32'd7);
		repeat (2) @(posedge clk);
		#1;
		check(n_inv_mc == 1 && last_inv_g == 20'h12345 && last_inv_n == 32'd7, "PROT_INV");
		sw(6'h2A, 32'd17);
		sw(6'h2B, 32'h00000100);
		sw(6'h2C, 32'h00000140);
		sw(6'h2D, {18'd0, 6'd3, 5'd0, 3'b011});	/* valid, read */
		repeat (2) @(posedge clk);
		#1;
		check(n_gw == 1 && last_gw_idx == 6'd17 &&
			last_gw == {21'h140, 20'h100, 1'b0, 1'b1, 6'd3, 1'b1}, "CAM write");
		group("mc");

		if (errors == 0)
			$display("PASS atg_cp_prot");
		else
			$display("FAIL atg_cp_prot: %0d errors", errors);
		$finish;
	end

	initial begin
		#200000;
		$display("FAIL atg_cp_prot: timeout");
		$finish;
	end
endmodule

`default_nettype wire
