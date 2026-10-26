/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_scrub_tb: the shader unit's scrub (session protection,
 * spec/gpu/su/atg_su_scrub.md): every memory that a warp can read without
 * having written it first (the RF's three copies, the LDS, the primitive
 * tables, the PT, the constant bank and its c-operand copy, the export
 * buffer) is filled with non-zero words (hierarchically), scrub pulses, and
 * after scrub_busy falls every word must be 0; scrub_busy must be 1 from
 * the cycle after scrub until the longest memory is done (its depth in
 * cycles).  NPHYS 8, the default sizes.  Prints PASS atg_su_scrub.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_scrub_tb;
	localparam NPHYS = 8;
	localparam GRP_W = 2;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg scrub = 1'b0;
	wire scrub_busy;
	always #5 clk = !clk;

	wire i_req_valid, i_req_ready, i_req_write, i_rsp_valid, i_rsp_write, i_rsp_error;
	wire [26:0] i_req_line;
	wire [31:0] i_req_be;
	wire [255:0] i_req_wdata, i_rsp_rdata;
	wire [7:0] i_req_tag, i_rsp_tag;
	wire busy, fault;
	wire [31:0] fault_addr;
	reg lc_kick = 1'b0;
	wire d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_write, d_rsp_error;
	wire [26:0] d_req_line;
	wire [31:0] d_req_be;
	wire [255:0] d_req_wdata, d_rsp_rdata;
	wire [7:0] d_req_tag, d_rsp_tag;
	wire at_valid, at_ready, at_rsp_valid, at_error;
	wire [3:0] at_op;
	wire [29:0] at_addr;
	wire [31:0] at_a, at_b, at_old;
	/* The D$ (requester 0) and the atomic unit (1) into dmem. */
	wire a_req_valid, a_req_ready, a_req_write, a_rsp_valid, m_rsp_write;
	wire [26:0] a_req_line;
	wire [31:0] a_req_be;
	wire [255:0] a_req_wdata, m_rsp_rdata;
	wire [7:0] a_req_tag, m_rsp_tag;
	wire [1:0] x_rsp_valid;
	wire m_req_valid, m_req_ready, m_req_write, m_rsp_valid, m_rsp_error;
	wire [26:0] m_req_line;
	wire [31:0] m_req_be;
	wire [255:0] m_req_wdata, x_rsp_rdata;
	wire [7:0] m_req_tag, x_rsp_tag;
	wire x_rsp_write, x_rsp_error;
	assign i_req_ready = 1'b1;
	assign i_rsp_valid = 1'b0;
	assign i_rsp_write = 1'b0;
	assign i_rsp_error = 1'b0;
	assign i_rsp_rdata = 256'd0;
	assign i_rsp_tag = 8'd0;
	assign d_req_ready = 1'b1;
	assign d_rsp_valid = 1'b0;
	assign d_rsp_write = 1'b0;
	assign d_rsp_error = 1'b0;
	assign d_rsp_rdata = 256'd0;
	assign d_rsp_tag = 8'd0;
	assign at_ready = 1'b1;
	assign at_rsp_valid = 1'b0;
	assign at_error = 1'b0;
	assign at_old = 32'd0;

	atg_su #(.NPHYS(NPHYS), .GRP_W(GRP_W)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(1'b0), .st_idx(9'd0), .st_wdata(32'd0),
		.scrub(scrub), .scrub_busy(scrub_busy),
		.cs_kick(1'b0), .lc_kick(1'b0), .inv(4'd0),
		.vl_req(1'b0), .vl_gnt(), .vl_slot(), .vl_ptbase(), .vl_we(1'b0), .vl_reg(6'd0),
		.vl_lane(5'd0), .vl_data(32'd0), .vl_go(1'b0), .vl_mask(32'd0),
		.fl_req(1'b0), .fl_gnt(), .fl_slot(), .fl_we(1'b0), .fl_reg(6'd0), .fl_lane(5'd0),
		.fl_data(32'd0), .fl_pw_we(1'b0), .fl_pw_addr(12'd0), .fl_pw_data(32'd0),
		.fl_go(1'b0), .fl_mask(32'd0), .fl_info(64'd0),
		.pt_rd(1'b0), .pt_idx(8'd0), .pt_word(7'd0), .pt_rdata(), .pt_free(1'b0),
		.pt_free_idx(8'd0), .pt_done(),
		.tx_valid(), .tx_ready(1'b1), .tx_op(), .tx_slot(), .tx_mask(), .tx_coord(), .tx_off(),
		.tx_tag(), .tx_last(), .tr_valid(1'b0), .tr_ready(), .tr_tag(16'd0),
		.tr_data(512'd0), .tr_last(1'b0),
		.ex_valid(), .ex_ready(1'b1), .ex_seq(), .ex_xy(), .ex_mask(), .ex_color(),
		.ex_depth(), .ex_last(), .ex_next(16'd0), .ex_aux(),
		.mesh_valid(), .mesh_ready(1'b1), .mesh_tri(), .mesh_last(), .mesh_id(),
		.d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_write(d_req_write),
		.d_req_line(d_req_line), .d_req_be(d_req_be), .d_req_wdata(d_req_wdata),
		.d_req_tag(d_req_tag), .d_rsp_valid(d_rsp_valid), .d_rsp_write(d_rsp_write),
		.d_rsp_tag(d_rsp_tag), .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
		.i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_write(i_req_write),
		.i_req_line(i_req_line), .i_req_be(i_req_be), .i_req_wdata(i_req_wdata),
		.i_req_tag(i_req_tag), .i_rsp_valid(i_rsp_valid), .i_rsp_write(i_rsp_write),
		.i_rsp_tag(i_rsp_tag), .i_rsp_rdata(i_rsp_rdata), .i_rsp_error(i_rsp_error),
		.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
		.at_a(at_a), .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
		.at_error(at_error),
		.sa_push_valid(), .sa_push_ready(1'b1), .sa_push_data(), .sa_pop_valid(1'b0),
		.sa_pop_ready(), .sa_pop_data({(NPHYS*32){1'b0}}), .sa_ctl_valid(), .sa_ctl_data(),
		.sa_qstat(32'd0), .sa_stat(32'd0), .sa_qtag(32'd0),
		.busy(busy), .fault(fault), .fault_addr(fault_addr)
	);

	integer errors = 0, nz = 0;
	integer k, w, cyc, longest;

	/* Fill and count the non-zero words, per generate instance. */
	event fill, count;
	genvar g;
	generate
		for (g = 0; g < NPHYS; g = g + 1) begin : g_rf
			always @(fill)
				for (k = 0; k < dut.rf.DEPTH; k = k + 1) begin
					dut.rf.lane[g].m1[k] = 32'hA5A50000 + k;
					dut.rf.lane[g].m2[k] = 32'h5A5A0000 + k;
					dut.rf.lane[g].m3[k] = 32'h3C3C0000 + k;
				end
			always @(count)
				for (k = 0; k < dut.rf.DEPTH; k = k + 1)
					nz = nz + (dut.rf.lane[g].m1[k] != 0) + (dut.rf.lane[g].m2[k] != 0) +
						(dut.rf.lane[g].m3[k] != 0);
		end
		for (g = 0; g < NPHYS; g = g + 1) begin : g_pt
			always @(fill)
				for (k = 0; k < dut.pt.DEPTH; k = k + 1)
					dut.pt.g_bank[g].m[k] = 32'h77000000 + k;
			always @(count)
				for (k = 0; k < dut.pt.DEPTH; k = k + 1)
					nz = nz + (dut.pt.g_bank[g].m[k] != 0);
		end
		for (g = 0; g < NPHYS; g = g + 1) begin : g_exp
			always @(fill) begin
				for (k = 0; k < dut.exp.ROWS * 4; k = k + 1) begin
					dut.exp.g_bank[g].m0[k] = 32'h1;
					dut.exp.g_bank[g].m1[k] = 32'h2;
					dut.exp.g_bank[g].m2[k] = 32'h3;
					dut.exp.g_bank[g].m3[k] = 32'h4;
				end
				for (k = 0; k < dut.exp.ROWS; k = k + 1) begin
					dut.exp.g_bank[g].m4[k] = 32'h5;
					dut.exp.g_bank[g].mz[k] = 32'h6;
					dut.exp.g_bank[g].m5[k] = 4'h7;
					dut.exp.g_bank[g].mr6[k] = 4'h8;
				end
			end
			always @(count) begin
				for (k = 0; k < dut.exp.ROWS * 4; k = k + 1)
					nz = nz + (dut.exp.g_bank[g].m0[k] != 0) + (dut.exp.g_bank[g].m1[k] != 0) +
						(dut.exp.g_bank[g].m2[k] != 0) + (dut.exp.g_bank[g].m3[k] != 0);
				for (k = 0; k < dut.exp.ROWS; k = k + 1)
					nz = nz + (dut.exp.g_bank[g].m4[k] != 0) + (dut.exp.g_bank[g].mz[k] != 0) +
						(dut.exp.g_bank[g].m5[k] != 0) + (dut.exp.g_bank[g].mr6[k] != 0);
			end
		end
		for (g = 0; g < 2; g = g + 1) begin : g_lda
			always @(fill)
				for (k = 0; k < dut.lda.DEPTH; k = k + 1)
					dut.lda.g_copy[g].m[k] = 32'h99000000 + k;
			always @(count)
				for (k = 0; k < dut.lda.DEPTH; k = k + 1)
					nz = nz + (dut.lda.g_copy[g].m[k] != 0);
		end
	endgenerate

	always @(fill) begin
		for (k = 0; k < dut.lds.NW; k = k + 1)
			dut.lds.ram[k] = 32'hDD000000 + k;
		for (k = 0; k < dut.cbank.CONST_WORDS; k = k + 1)
			dut.cbank.bank[k] = 32'hCC000000 + k;
		for (k = 0; k < 32; k = k + 1)
			dut.cbank.cw[k] = 32'hCB000000 + k;
	end
	always @(count) begin
		for (k = 0; k < dut.lds.NW; k = k + 1)
			nz = nz + (dut.lds.ram[k] != 0);
		for (k = 0; k < dut.cbank.CONST_WORDS; k = k + 1)
			nz = nz + (dut.cbank.bank[k] != 0);
		for (k = 0; k < 32; k = k + 1)
			nz = nz + (dut.cbank.cw[k] != 0);
	end

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1'b1;
		-> fill;
		#1;
		nz = 0;
		-> count;
		#1;
		if (nz == 0) begin
			errors = errors + 1;
			$display("FAIL atg_su_scrub: the fill wrote nothing");
		end
		@(negedge clk);
		scrub = 1'b1;
		@(negedge clk);
		scrub = 1'b0;
		cyc = 0;
		if (!scrub_busy) begin
			errors = errors + 1;
			$display("FAIL atg_su_scrub: not busy after scrub");
		end
		while (scrub_busy && cyc < 20000) begin
			@(negedge clk);
			cyc = cyc + 1;
		end
		longest = dut.lda.DEPTH;
		if (dut.lds.NW > longest)
			longest = dut.lds.NW;
		if (cyc != longest) begin
			errors = errors + 1;
			$display("FAIL atg_su_scrub: busy %0d cycles, the longest memory has %0d words",
				cyc, longest);
		end
		nz = 0;
		-> count;
		#1;
		if (nz != 0) begin
			errors = errors + 1;
			$display("FAIL atg_su_scrub: %0d words not 0 after the scrub", nz);
		end
		if (errors == 0)
			$display("PASS atg_su_scrub");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_su_scrub: timeout");
		$finish;
	end
endmodule

`default_nettype wire
