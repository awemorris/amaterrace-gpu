/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_gfx_dist_tb: Unit verification of Option-I Spine distribution/aggregation
 * modules: atg_warp_dist, atg_tx_rt, atg_ex_rt, atg_pt_exp_rt, and atg_atom_rt.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_gfx_dist_tb;
	localparam K = 4;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* ---- 1. atg_warp_dist ---- */
	reg         p_vl_req = 0, p_vl_we = 0, p_vl_go = 0;
	wire        p_vl_gnt, p_vl_avail;
	wire [7:0]  p_vl_ptbase;
	reg  [5:0]  p_vl_reg = 0;
	reg  [4:0]  p_vl_lane = 0;
	reg  [31:0] p_vl_data = 0, p_vl_mask = 0;
	reg  [7:0]  p_vl_go_ptbase = 0;

	wire [K-1:0]    c_vl_req, c_vl_we, c_vl_go;
	reg  [K-1:0]    c_vl_gnt = 0, c_vl_avail = 4'b0110; /* SUs 1 & 2 available */
	reg  [K*8-1:0]  c_vl_ptbase = {8'h60, 8'h40, 8'h20, 8'h00};
	wire [5:0]      c_vl_reg;
	wire [4:0]      c_vl_lane;
	wire [31:0]     c_vl_data, c_vl_mask;
	wire [7:0]      c_vl_go_ptbase;

	reg         p_fl_req = 0, p_fl_we = 0, p_fl_pw_we = 0, p_fl_go = 0;
	wire        p_fl_gnt, p_fl_avail;
	wire [K-1:0] c_fl_req, c_fl_we, c_fl_pw_we, c_fl_go;
	reg  [K-1:0] c_fl_gnt = 0, c_fl_avail = 4'b1000;
	wire [5:0]  c_fl_reg;
	wire [4:0]  c_fl_lane;
	wire [11:0] c_fl_pw_addr;
	wire [31:0] c_fl_data, c_fl_pw_data, c_fl_mask;
	wire [63:0] c_fl_info;

	atg_warp_dist #(.K(K)) u_dist (
		.clk(clk), .rst_n(rst_n),
		.p_vl_req(p_vl_req), .p_vl_gnt(p_vl_gnt), .p_vl_ptbase(p_vl_ptbase), .p_vl_avail(p_vl_avail),
		.p_vl_we(p_vl_we), .p_vl_reg(p_vl_reg), .p_vl_lane(p_vl_lane), .p_vl_data(p_vl_data),
		.p_vl_go(p_vl_go), .p_vl_mask(p_vl_mask), .p_vl_go_ptbase(p_vl_go_ptbase),
		.c_vl_req(c_vl_req), .c_vl_gnt(c_vl_gnt), .c_vl_ptbase(c_vl_ptbase), .c_vl_avail(c_vl_avail),
		.c_vl_we(c_vl_we), .c_vl_reg(c_vl_reg), .c_vl_lane(c_vl_lane), .c_vl_data(c_vl_data),
		.c_vl_go(c_vl_go), .c_vl_mask(c_vl_mask), .c_vl_go_ptbase(c_vl_go_ptbase),
		.p_fl_req(p_fl_req), .p_fl_gnt(p_fl_gnt), .p_fl_avail(p_fl_avail),
		.p_fl_we(p_fl_we), .p_fl_reg(6'd1), .p_fl_lane(5'd2), .p_fl_data(32'h55),
		.p_fl_pw_we(p_fl_pw_we), .p_fl_pw_addr(12'h12), .p_fl_pw_data(32'h66),
		.p_fl_go(p_fl_go), .p_fl_mask(32'hFFFF0000), .p_fl_info(64'hABCD),
		.c_fl_req(c_fl_req), .c_fl_gnt(c_fl_gnt), .c_fl_avail(c_fl_avail),
		.c_fl_we(c_fl_we), .c_fl_reg(c_fl_reg), .c_fl_lane(c_fl_lane), .c_fl_data(c_fl_data),
		.c_fl_pw_we(c_fl_pw_we), .c_fl_pw_addr(c_fl_pw_addr), .c_fl_pw_data(c_fl_pw_data),
		.c_fl_go(c_fl_go), .c_fl_mask(c_fl_mask), .c_fl_info(c_fl_info)
	);

	/* ---- 2. atg_tx_rt (4 SUs -> TU, TBIT=14) ---- */
	reg  [K-1:0]     c_tx_v = 0, c_tx_vs = 0, c_tx_last = 0, c_tr_r = 4'b1111;
	wire [K-1:0]     c_tx_r, c_tr_v, c_tr_last;
	reg  [K*16-1:0]  c_tx_tag = 0;
	wire [K*16-1:0]  c_tr_tag;
	wire [K*512-1:0] c_tr_data;
	wire             p_tx_v, p_tx_vs, p_tx_last, p_tr_r;
	wire [7:0]       p_tx_op;
	wire [3:0]       p_tx_slot, p_tx_samp, p_tx_mask;
	wire [639:0]     p_tx_coord;
	wire [11:0]      p_tx_off;
	wire [15:0]      p_tx_tag;
	reg              p_tr_v = 0, p_tr_last = 0;
	reg  [15:0]      p_tr_tag = 0;
	reg  [511:0]     p_tr_data = 0;

	atg_tx_rt #(.K(K), .TBIT(14)) u_tx (
		.clk(clk), .rst_n(rst_n),
		.c_tx_valid(c_tx_v), .c_tx_ready(c_tx_r), .c_tx_op({K{8'h01}}),
		.c_tx_slot({K{4'd0}}), .c_tx_samp_slot({K{4'd0}}), .c_tx_vs(c_tx_vs),
		.c_tx_mask({K{4'hF}}), .c_tx_coord({(K*640){1'b0}}), .c_tx_off({K{12'd0}}),
		.c_tx_tag(c_tx_tag), .c_tx_last(c_tx_last),
		.c_tr_valid(c_tr_v), .c_tr_ready(c_tr_r), .c_tr_tag(c_tr_tag), .c_tr_data(c_tr_data), .c_tr_last(c_tr_last),
		.p_tx_valid(p_tx_v), .p_tx_ready(1'b1), .p_tx_op(p_tx_op), .p_tx_slot(p_tx_slot),
		.p_tx_samp_slot(p_tx_samp), .p_tx_vs(p_tx_vs), .p_tx_mask(p_tx_mask),
		.p_tx_coord(p_tx_coord), .p_tx_off(p_tx_off), .p_tx_tag(p_tx_tag), .p_tx_last(p_tx_last),
		.p_tr_valid(p_tr_v), .p_tr_ready(p_tr_r), .p_tr_tag(p_tr_tag), .p_tr_data(p_tr_data), .p_tr_last(p_tr_last)
	);

	/* ---- 3. atg_ex_rt (4 SUs -> ROP with ex_next priority) ---- */
	reg  [K-1:0]     c_ex_v = 0, c_ex_last = 0, c_ex_src1 = 0;
	wire [K-1:0]     c_ex_r;
	reg  [K*16-1:0]  c_ex_seq = 0;
	wire [15:0]      c_ex_next, p_ex_seq;
	wire             p_ex_v, p_ex_last, p_ex_src1;
	wire [31:0]      p_ex_xy;
	wire [3:0]       p_ex_mask;
	wire [511:0]     p_ex_c0, p_ex_c1;
	wire [127:0]     p_ex_depth;
	wire [154:0]     p_ex_aux;
	reg  [15:0]      p_ex_next = 16'd7;

	atg_ex_rt #(.K(K)) u_ex (
		.clk(clk), .rst_n(rst_n),
		.c_ex_valid(c_ex_v), .c_ex_ready(c_ex_r), .c_ex_seq(c_ex_seq),
		.c_ex_xy({K{32'd0}}), .c_ex_mask({K{4'hF}}), .c_ex_color({(K*512){1'b0}}),
		.c_ex_color1({(K*512){1'b0}}), .c_ex_has_src1(c_ex_src1), .c_ex_depth({(K*128){1'b0}}),
		.c_ex_last(c_ex_last), .c_ex_aux({(K*155){1'b0}}), .c_ex_next(c_ex_next),
		.p_ex_valid(p_ex_v), .p_ex_ready(1'b1), .p_ex_seq(p_ex_seq),
		.p_ex_xy(p_ex_xy), .p_ex_mask(p_ex_mask), .p_ex_color(p_ex_c0), .p_ex_color1(p_ex_c1),
		.p_ex_has_src1(p_ex_src1), .p_ex_depth(p_ex_depth), .p_ex_last(p_ex_last),
		.p_ex_aux(p_ex_aux), .p_ex_next(p_ex_next)
	);

	/* ---- 4. atg_pt_exp_rt & 5. atg_atom_rt ---- */
	reg  [K-1:0]    c_pt_v = 0;
	wire [K-1:0]    c_pt_r;
	reg  [K*64-1:0] c_pt_d = 0;
	wire            p_pt_v;
	wire [63:0]     p_pt_d;
	atg_pt_exp_rt #(.K(K), .W(64)) u_pt (
		.clk(clk), .rst_n(rst_n),
		.c_valid(c_pt_v), .c_ready(c_pt_r), .c_data(c_pt_d),
		.p_valid(p_pt_v), .p_ready(1'b1), .p_data(p_pt_d)
	);

	reg  [K-1:0]    c_at_v = 0;
	wire [K-1:0]    c_at_r, c_at_rsp_v;
	wire [31:0]     c_at_old;
	wire            c_at_err;
	wire            p_at_v, p_at_stage_0;
	wire [3:0]      p_at_op;
	wire [29:0]     p_at_addr;
	wire [31:0]     p_at_a, p_at_b;
	wire [1:0]      p_at_stage;
	reg             p_at_rsp_v = 0, p_at_err = 0;
	reg  [31:0]     p_at_old = 0;

	atg_atom_rt #(.K(K), .ATOM_AW(30)) u_atom (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(c_at_v), .c_at_ready(c_at_r), .c_at_op({K{4'd4}}),
		.c_at_addr({K{30'h0000100}}), .c_at_a({32'd40, 32'd30, 32'd20, 32'd10}),
		.c_at_b({K{32'd0}}), .c_at_stage({K{2'd0}}),
		.c_at_rsp_valid(c_at_rsp_v), .c_at_old(c_at_old), .c_at_error(c_at_err),
		.p_at_valid(p_at_v), .p_at_ready(1'b1), .p_at_op(p_at_op), .p_at_addr(p_at_addr),
		.p_at_a(p_at_a), .p_at_b(p_at_b), .p_at_stage(p_at_stage),
		.p_at_rsp_valid(p_at_rsp_v), .p_at_old(p_at_old), .p_at_error(p_at_err)
	);

	integer errors = 0;
	integer cyc;
	reg [1:0] granted_vl = 0;
	integer ex_cnt = 0;
	reg [15:0] ex_seq0 = 0, ex_seq1 = 0;

	always @(posedge clk) begin
		if (p_ex_v) begin
			if (ex_cnt == 0) ex_seq0 <= p_ex_seq;
			if (ex_cnt == 1) ex_seq1 <= p_ex_seq;
			ex_cnt <= ex_cnt + 1;
		end
	end

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1'b1;

		/* 1. Warp dist VL: SU 1 & 2 avail -> pick 1, then route vl_we & vl_go strictly to SU 1 */
		@(posedge clk); #1;
		if (!p_vl_avail || !p_vl_fl_dummy) ;
		p_vl_req = 1'b1;
		cyc = 0;
		while (!(|c_vl_req) && cyc < 10) begin @(posedge clk); #1; cyc = cyc + 1; end
		if (c_vl_req != 4'b0010) begin $display("FAIL vl_pick: %b", c_vl_req); errors = errors + 1; end
		c_vl_gnt = 4'b0010;
		@(posedge clk); #1;
		c_vl_gnt = 4'b0000;
		while (!p_vl_gnt) @(posedge clk);
		#1;
		p_vl_req = 1'b0;
		p_vl_we = 1'b1; p_vl_reg = 6'd5; p_vl_data = 32'hCAFE0001;
		@(posedge clk); #1;
		if (c_vl_we != 4'b0010 || c_vl_data != 32'hCAFE0001) begin $display("FAIL vl_we: %b", c_vl_we); errors = errors + 1; end
		p_vl_we = 1'b0; p_vl_go = 1'b1; p_vl_mask = 32'hFFFFFFFF; p_vl_go_ptbase = 8'h60;
		@(posedge clk); #1;
		p_vl_go = 1'b0;
		if (c_vl_go != 4'b0010 || c_vl_go_ptbase != 8'h60) begin $display("FAIL vl_go: %b %x", c_vl_go, c_vl_go_ptbase); errors = errors + 1; end

		/* 2. EX priority match: SU 0 has seq=9, SU 2 has seq=7 (== ex_next=7) -> SU 2 must win first! */
		@(posedge clk); #1;
		c_ex_seq[0*16 +: 16] = 16'd9;
		c_ex_seq[2*16 +: 16] = 16'd7;
		c_ex_v = 4'b0101; c_ex_last = 4'b0101;
		@(posedge clk); #1;
		c_ex_v = 4'b0000;
		repeat (6) @(posedge clk);
		if (ex_cnt != 2 || ex_seq0 != 16'd7 || ex_seq1 != 16'd9) begin
			$display("FAIL ex_prio: cnt=%0d s0=%0d s1=%0d", ex_cnt, ex_seq0, ex_seq1);
			errors = errors + 1;
		end

		/* 3. TX tag stamp & return route: SU 3 sends tag=0x0015 -> p_tx_tag[15:14]=2'd3 */
		@(posedge clk); #1;
		c_tx_v[3] = 1'b1; c_tx_last[3] = 1'b1; c_tx_tag[3*16 +: 16] = 16'h0015;
		@(posedge clk); #1;
		c_tx_v[3] = 1'b0;
		cyc = 0;
		while (!p_tx_v && cyc < 10) begin @(posedge clk); #1; cyc = cyc + 1; end
		if (!p_tx_v || p_tx_tag[15:14] != 2'd3 || p_tx_tag[13:0] != 14'h0015) begin
			$display("FAIL tx_tag: v=%b tag=%x", p_tx_v, p_tx_tag);
			errors = errors + 1;
		end
		p_tr_v = 1'b1; p_tr_tag = p_tx_tag; p_tr_data = 512'h12345678; p_tr_last = 1'b1;
		@(posedge clk); #1;
		p_tr_v = 1'b0;
		cyc = 0;
		while (!c_tr_v[3] && cyc < 10) begin @(posedge clk); #1; cyc = cyc + 1; end
		if (!c_tr_v[3] || c_tr_v[2:0] != 3'b000 || c_tr_data[3*512 +: 32] != 32'h12345678) begin
			$display("FAIL tr_route: v=%b", c_tr_v);
			errors = errors + 1;
		end

		/* 4. Atom RT: SU 2 sends atomic, response returns ONLY to SU 2 */
		@(posedge clk); #1;
		c_at_v[2] = 1'b1;
		@(posedge clk); #1;
		c_at_v[2] = 1'b0;
		cyc = 0;
		while (!p_at_v && cyc < 10) begin @(posedge clk); #1; cyc = cyc + 1; end
		if (!p_at_v || p_at_a != 32'd30) begin $display("FAIL atom_req: v=%b a=%0d", p_at_v, p_at_a); errors = errors + 1; end
		p_at_rsp_v = 1'b1; p_at_old = 32'h88776655;
		@(posedge clk); #1;
		p_at_rsp_v = 1'b0;
		if (c_at_rsp_v != 4'b0100 || c_at_old != 32'h88776655) begin
			$display("FAIL atom_rsp: v=%b old=%x", c_at_rsp_v, c_at_old);
			errors = errors + 1;
		end

		if (errors == 0)
			$display("PASS atg_gfx_dist");
		else
			$display("FAIL atg_gfx_dist (%0d errors)", errors);
		$finish;
	end
	wire p_vl_fl_dummy = p_fl_avail;
endmodule

`default_nettype wire
