/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_noc_sub16: Aggregates N (0..16) AMB router packet links into 1 parent
 * link using 1 or 2 pipeline stages of atg_rt2 / atg_rt3 / atg_rt4.
 *
 * Route consumption on downward response flits:
 *   - 0..1 children: 0 route bits consumed (passthrough / idle)
 *   - 2..4 children: 1 router at RBIT1 (uses route bits at RBIT1 +: 2)
 *   - 5..16 children: Level-2 routers (RBIT2 +: 2) -> Level-1 router (RBIT1 +: 2)
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_noc_sub16 #(
	parameter N = 4,
	parameter FW = 512,
	parameter RFW = 534,
	parameter RBIT1 = 12,
	parameter RBIT2 = 14
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	input wire [(N > 0 ? N : 1)-1:0] c_req_valid,
	output wire [(N > 0 ? N : 1)-1:0] c_req_ready,
	input wire [(N > 0 ? N : 1)*FW-1:0] c_req_data,
	input wire [(N > 0 ? N : 1)-1:0] c_req_last,

	output wire p_req_valid,
	input wire p_req_ready,
	output wire [FW-1:0] p_req_data,
	output wire p_req_last,

	input wire p_rsp_valid,
	output wire p_rsp_ready,
	input wire [RFW-1:0] p_rsp_data,

	output wire [(N > 0 ? N : 1)-1:0] c_rsp_valid,
	input wire [(N > 0 ? N : 1)-1:0] c_rsp_ready,
	output wire [(N > 0 ? N : 1)*RFW-1:0] c_rsp_data,

	output wire rsp_idle
);
	localparam NG = (N > 4) ? ((N + 3) / 4) : 1;

	generate
	if (N == 0) begin : g_empty
		assign c_req_ready = 1'b0;
		assign p_req_valid = 1'b0;
		assign p_req_data = {FW{1'b0}};
		assign p_req_last = 1'b0;
		assign p_rsp_ready = 1'b1;
		assign c_rsp_valid = 1'b0;
		assign c_rsp_data = {RFW{1'b0}};
		assign rsp_idle = 1'b1;
		wire unused_empty = &{1'b0, clk, rst_n, flush, c_req_valid, c_req_data,
			c_req_last, p_req_ready, p_rsp_valid, p_rsp_data, c_rsp_ready};
	end else if (N == 1) begin : g_one
		assign p_req_valid = c_req_valid[0];
		assign c_req_ready[0] = p_req_ready;
		assign p_req_data = c_req_data[FW-1:0];
		assign p_req_last = c_req_last[0];
		assign c_rsp_valid[0] = p_rsp_valid;
		assign p_rsp_ready = c_rsp_ready[0];
		assign c_rsp_data[RFW-1:0] = p_rsp_data;
		assign rsp_idle = 1'b1;
		wire unused_one = &{1'b0, clk, rst_n, flush};
	end else if (N == 2) begin : g_two
		atg_rt2 #(.FW(FW), .RFW(RFW), .RBIT(RBIT1)) u_rt (
			.clk(clk), .rst_n(rst_n), .flush(flush),
			.c0_req_valid(c_req_valid[0]), .c0_req_ready(c_req_ready[0]),
			.c0_req_data(c_req_data[0*FW +: FW]), .c0_req_last(c_req_last[0]),
			.c1_req_valid(c_req_valid[1]), .c1_req_ready(c_req_ready[1]),
			.c1_req_data(c_req_data[1*FW +: FW]), .c1_req_last(c_req_last[1]),
			.p_req_valid(p_req_valid), .p_req_ready(p_req_ready),
			.p_req_data(p_req_data), .p_req_last(p_req_last),
			.p_rsp_valid(p_rsp_valid), .p_rsp_ready(p_rsp_ready), .p_rsp_data(p_rsp_data),
			.c0_rsp_valid(c_rsp_valid[0]), .c0_rsp_ready(c_rsp_ready[0]),
			.c0_rsp_data(c_rsp_data[0*RFW +: RFW]),
			.c1_rsp_valid(c_rsp_valid[1]), .c1_rsp_ready(c_rsp_ready[1]),
			.c1_rsp_data(c_rsp_data[1*RFW +: RFW]),
			.rsp_idle(rsp_idle)
		);
	end else if (N == 3) begin : g_three
		atg_rt3 #(.FW(FW), .RFW(RFW), .RBIT(RBIT1)) u_rt (
			.clk(clk), .rst_n(rst_n), .flush(flush),
			.c0_req_valid(c_req_valid[0]), .c0_req_ready(c_req_ready[0]),
			.c0_req_data(c_req_data[0*FW +: FW]), .c0_req_last(c_req_last[0]),
			.c1_req_valid(c_req_valid[1]), .c1_req_ready(c_req_ready[1]),
			.c1_req_data(c_req_data[1*FW +: FW]), .c1_req_last(c_req_last[1]),
			.c2_req_valid(c_req_valid[2]), .c2_req_ready(c_req_ready[2]),
			.c2_req_data(c_req_data[2*FW +: FW]), .c2_req_last(c_req_last[2]),
			.p_req_valid(p_req_valid), .p_req_ready(p_req_ready),
			.p_req_data(p_req_data), .p_req_last(p_req_last),
			.p_rsp_valid(p_rsp_valid), .p_rsp_ready(p_rsp_ready), .p_rsp_data(p_rsp_data),
			.c0_rsp_valid(c_rsp_valid[0]), .c0_rsp_ready(c_rsp_ready[0]),
			.c0_rsp_data(c_rsp_data[0*RFW +: RFW]),
			.c1_rsp_valid(c_rsp_valid[1]), .c1_rsp_ready(c_rsp_ready[1]),
			.c1_rsp_data(c_rsp_data[1*RFW +: RFW]),
			.c2_rsp_valid(c_rsp_valid[2]), .c2_rsp_ready(c_rsp_ready[2]),
			.c2_rsp_data(c_rsp_data[2*RFW +: RFW]),
			.rsp_idle(rsp_idle)
		);
	end else if (N == 4) begin : g_four
		atg_rt4 #(.FW(FW), .RFW(RFW), .RBIT(RBIT1)) u_rt (
			.clk(clk), .rst_n(rst_n), .flush(flush),
			.c0_req_valid(c_req_valid[0]), .c0_req_ready(c_req_ready[0]),
			.c0_req_data(c_req_data[0*FW +: FW]), .c0_req_last(c_req_last[0]),
			.c1_req_valid(c_req_valid[1]), .c1_req_ready(c_req_ready[1]),
			.c1_req_data(c_req_data[1*FW +: FW]), .c1_req_last(c_req_last[1]),
			.c2_req_valid(c_req_valid[2]), .c2_req_ready(c_req_ready[2]),
			.c2_req_data(c_req_data[2*FW +: FW]), .c2_req_last(c_req_last[2]),
			.c3_req_valid(c_req_valid[3]), .c3_req_ready(c_req_ready[3]),
			.c3_req_data(c_req_data[3*FW +: FW]), .c3_req_last(c_req_last[3]),
			.p_req_valid(p_req_valid), .p_req_ready(p_req_ready),
			.p_req_data(p_req_data), .p_req_last(p_req_last),
			.p_rsp_valid(p_rsp_valid), .p_rsp_ready(p_rsp_ready), .p_rsp_data(p_rsp_data),
			.c0_rsp_valid(c_rsp_valid[0]), .c0_rsp_ready(c_rsp_ready[0]),
			.c0_rsp_data(c_rsp_data[0*RFW +: RFW]),
			.c1_rsp_valid(c_rsp_valid[1]), .c1_rsp_ready(c_rsp_ready[1]),
			.c1_rsp_data(c_rsp_data[1*RFW +: RFW]),
			.c2_rsp_valid(c_rsp_valid[2]), .c2_rsp_ready(c_rsp_ready[2]),
			.c2_rsp_data(c_rsp_data[2*RFW +: RFW]),
			.c3_rsp_valid(c_rsp_valid[3]), .c3_rsp_ready(c_rsp_ready[3]),
			.c3_rsp_data(c_rsp_data[3*RFW +: RFW]),
			.rsp_idle(rsp_idle)
		);
	end else begin : g_two_level
		wire [NG-1:0] g_req_v, g_req_r, g_req_l;
		wire [NG*FW-1:0] g_req_d;
		wire [NG-1:0] g_rsp_v, g_rsp_r;
		wire [NG*RFW-1:0] g_rsp_d;
		wire [NG-1:0] g_rsp_idle;
		wire l1_rsp_idle;

		genvar gg;
		for (gg = 0; gg < NG; gg = gg + 1) begin : g_l2
			localparam BASE = gg * 4;
			localparam KSZ = (BASE + 4 <= N) ? 4 : (N - BASE);
			if (KSZ == 1) begin : g_k1
				assign g_req_v[gg] = c_req_valid[BASE];
				assign c_req_ready[BASE] = g_req_r[gg];
				assign g_req_d[gg*FW +: FW] = c_req_data[BASE*FW +: FW];
				assign g_req_l[gg] = c_req_last[BASE];
				assign c_rsp_valid[BASE] = g_rsp_v[gg];
				assign g_rsp_r[gg] = c_rsp_ready[BASE];
				assign c_rsp_data[BASE*RFW +: RFW] = g_rsp_d[gg*RFW +: RFW];
				assign g_rsp_idle[gg] = 1'b1;
			end else if (KSZ == 2) begin : g_k2
				atg_rt2 #(.FW(FW), .RFW(RFW), .RBIT(RBIT2)) u_l2_rt2 (
					.clk(clk), .rst_n(rst_n), .flush(flush),
					.c0_req_valid(c_req_valid[BASE+0]), .c0_req_ready(c_req_ready[BASE+0]),
					.c0_req_data(c_req_data[(BASE+0)*FW +: FW]), .c0_req_last(c_req_last[BASE+0]),
					.c1_req_valid(c_req_valid[BASE+1]), .c1_req_ready(c_req_ready[BASE+1]),
					.c1_req_data(c_req_data[(BASE+1)*FW +: FW]), .c1_req_last(c_req_last[BASE+1]),
					.p_req_valid(g_req_v[gg]), .p_req_ready(g_req_r[gg]),
					.p_req_data(g_req_d[gg*FW +: FW]), .p_req_last(g_req_l[gg]),
					.p_rsp_valid(g_rsp_v[gg]), .p_rsp_ready(g_rsp_r[gg]), .p_rsp_data(g_rsp_d[gg*RFW +: RFW]),
					.c0_rsp_valid(c_rsp_valid[BASE+0]), .c0_rsp_ready(c_rsp_ready[BASE+0]),
					.c0_rsp_data(c_rsp_data[(BASE+0)*RFW +: RFW]),
					.c1_rsp_valid(c_rsp_valid[BASE+1]), .c1_rsp_ready(c_rsp_ready[BASE+1]),
					.c1_rsp_data(c_rsp_data[(BASE+1)*RFW +: RFW]),
					.rsp_idle(g_rsp_idle[gg])
				);
			end else if (KSZ == 3) begin : g_k3
				atg_rt3 #(.FW(FW), .RFW(RFW), .RBIT(RBIT2)) u_l2_rt3 (
					.clk(clk), .rst_n(rst_n), .flush(flush),
					.c0_req_valid(c_req_valid[BASE+0]), .c0_req_ready(c_req_ready[BASE+0]),
					.c0_req_data(c_req_data[(BASE+0)*FW +: FW]), .c0_req_last(c_req_last[BASE+0]),
					.c1_req_valid(c_req_valid[BASE+1]), .c1_req_ready(c_req_ready[BASE+1]),
					.c1_req_data(c_req_data[(BASE+1)*FW +: FW]), .c1_req_last(c_req_last[BASE+1]),
					.c2_req_valid(c_req_valid[BASE+2]), .c2_req_ready(c_req_ready[BASE+2]),
					.c2_req_data(c_req_data[(BASE+2)*FW +: FW]), .c2_req_last(c_req_last[BASE+2]),
					.p_req_valid(g_req_v[gg]), .p_req_ready(g_req_r[gg]),
					.p_req_data(g_req_d[gg*FW +: FW]), .p_req_last(g_req_l[gg]),
					.p_rsp_valid(g_rsp_v[gg]), .p_rsp_ready(g_rsp_r[gg]), .p_rsp_data(g_rsp_d[gg*RFW +: RFW]),
					.c0_rsp_valid(c_rsp_valid[BASE+0]), .c0_rsp_ready(c_rsp_ready[BASE+0]),
					.c0_rsp_data(c_rsp_data[(BASE+0)*RFW +: RFW]),
					.c1_rsp_valid(c_rsp_valid[BASE+1]), .c1_rsp_ready(c_rsp_ready[BASE+1]),
					.c1_rsp_data(c_rsp_data[(BASE+1)*RFW +: RFW]),
					.c2_rsp_valid(c_rsp_valid[BASE+2]), .c2_rsp_ready(c_rsp_ready[BASE+2]),
					.c2_rsp_data(c_rsp_data[(BASE+2)*RFW +: RFW]),
					.rsp_idle(g_rsp_idle[gg])
				);
			end else begin : g_k4
				atg_rt4 #(.FW(FW), .RFW(RFW), .RBIT(RBIT2)) u_l2_rt4 (
					.clk(clk), .rst_n(rst_n), .flush(flush),
					.c0_req_valid(c_req_valid[BASE+0]), .c0_req_ready(c_req_ready[BASE+0]),
					.c0_req_data(c_req_data[(BASE+0)*FW +: FW]), .c0_req_last(c_req_last[BASE+0]),
					.c1_req_valid(c_req_valid[BASE+1]), .c1_req_ready(c_req_ready[BASE+1]),
					.c1_req_data(c_req_data[(BASE+1)*FW +: FW]), .c1_req_last(c_req_last[BASE+1]),
					.c2_req_valid(c_req_valid[BASE+2]), .c2_req_ready(c_req_ready[BASE+2]),
					.c2_req_data(c_req_data[(BASE+2)*FW +: FW]), .c2_req_last(c_req_last[BASE+2]),
					.c3_req_valid(c_req_valid[BASE+3]), .c3_req_ready(c_req_ready[BASE+3]),
					.c3_req_data(c_req_data[(BASE+3)*FW +: FW]), .c3_req_last(c_req_last[BASE+3]),
					.p_req_valid(g_req_v[gg]), .p_req_ready(g_req_r[gg]),
					.p_req_data(g_req_d[gg*FW +: FW]), .p_req_last(g_req_l[gg]),
					.p_rsp_valid(g_rsp_v[gg]), .p_rsp_ready(g_rsp_r[gg]), .p_rsp_data(g_rsp_d[gg*RFW +: RFW]),
					.c0_rsp_valid(c_rsp_valid[BASE+0]), .c0_rsp_ready(c_rsp_ready[BASE+0]),
					.c0_rsp_data(c_rsp_data[(BASE+0)*RFW +: RFW]),
					.c1_rsp_valid(c_rsp_valid[BASE+1]), .c1_rsp_ready(c_rsp_ready[BASE+1]),
					.c1_rsp_data(c_rsp_data[(BASE+1)*RFW +: RFW]),
					.c2_rsp_valid(c_rsp_valid[BASE+2]), .c2_rsp_ready(c_rsp_ready[BASE+2]),
					.c2_rsp_data(c_rsp_data[(BASE+2)*RFW +: RFW]),
					.c3_rsp_valid(c_rsp_valid[BASE+3]), .c3_rsp_ready(c_rsp_ready[BASE+3]),
					.c3_rsp_data(c_rsp_data[(BASE+3)*RFW +: RFW]),
					.rsp_idle(g_rsp_idle[gg])
				);
			end
		end

		if (NG == 2) begin : g_l1_rt2
			atg_rt2 #(.FW(FW), .RFW(RFW), .RBIT(RBIT1)) u_l1 (
				.clk(clk), .rst_n(rst_n), .flush(flush),
				.c0_req_valid(g_req_v[0]), .c0_req_ready(g_req_r[0]),
				.c0_req_data(g_req_d[0*FW +: FW]), .c0_req_last(g_req_l[0]),
				.c1_req_valid(g_req_v[1]), .c1_req_ready(g_req_r[1]),
				.c1_req_data(g_req_d[1*FW +: FW]), .c1_req_last(g_req_l[1]),
				.p_req_valid(p_req_valid), .p_req_ready(p_req_ready),
				.p_req_data(p_req_data), .p_req_last(p_req_last),
				.p_rsp_valid(p_rsp_valid), .p_rsp_ready(p_rsp_ready), .p_rsp_data(p_rsp_data),
				.c0_rsp_valid(g_rsp_v[0]), .c0_rsp_ready(g_rsp_r[0]),
				.c0_rsp_data(g_rsp_d[0*RFW +: RFW]),
				.c1_rsp_valid(g_rsp_v[1]), .c1_rsp_ready(g_rsp_r[1]),
				.c1_rsp_data(g_rsp_d[1*RFW +: RFW]),
				.rsp_idle(l1_rsp_idle)
			);
		end else if (NG == 3) begin : g_l1_rt3
			atg_rt3 #(.FW(FW), .RFW(RFW), .RBIT(RBIT1)) u_l1 (
				.clk(clk), .rst_n(rst_n), .flush(flush),
				.c0_req_valid(g_req_v[0]), .c0_req_ready(g_req_r[0]),
				.c0_req_data(g_req_d[0*FW +: FW]), .c0_req_last(g_req_l[0]),
				.c1_req_valid(g_req_v[1]), .c1_req_ready(g_req_r[1]),
				.c1_req_data(g_req_d[1*FW +: FW]), .c1_req_last(g_req_l[1]),
				.c2_req_valid(g_req_v[2]), .c2_req_ready(g_req_r[2]),
				.c2_req_data(g_req_d[2*FW +: FW]), .c2_req_last(g_req_l[2]),
				.p_req_valid(p_req_valid), .p_req_ready(p_req_ready),
				.p_req_data(p_req_data), .p_req_last(p_req_last),
				.p_rsp_valid(p_rsp_valid), .p_rsp_ready(p_rsp_ready), .p_rsp_data(p_rsp_data),
				.c0_rsp_valid(g_rsp_v[0]), .c0_rsp_ready(g_rsp_r[0]),
				.c0_rsp_data(g_rsp_d[0*RFW +: RFW]),
				.c1_rsp_valid(g_rsp_v[1]), .c1_rsp_ready(g_rsp_r[1]),
				.c1_rsp_data(g_rsp_d[1*RFW +: RFW]),
				.c2_rsp_valid(g_rsp_v[2]), .c2_rsp_ready(g_rsp_r[2]),
				.c2_rsp_data(g_rsp_d[2*RFW +: RFW]),
				.rsp_idle(l1_rsp_idle)
			);
		end else begin : g_l1_rt4
			atg_rt4 #(.FW(FW), .RFW(RFW), .RBIT(RBIT1)) u_l1 (
				.clk(clk), .rst_n(rst_n), .flush(flush),
				.c0_req_valid(g_req_v[0]), .c0_req_ready(g_req_r[0]),
				.c0_req_data(g_req_d[0*FW +: FW]), .c0_req_last(g_req_l[0]),
				.c1_req_valid(g_req_v[1]), .c1_req_ready(g_req_r[1]),
				.c1_req_data(g_req_d[1*FW +: FW]), .c1_req_last(g_req_l[1]),
				.c2_req_valid(g_req_v[2]), .c2_req_ready(g_req_r[2]),
				.c2_req_data(g_req_d[2*FW +: FW]), .c2_req_last(g_req_l[2]),
				.c3_req_valid(g_req_v[3]), .c3_req_ready(g_req_r[3]),
				.c3_req_data(g_req_d[3*FW +: FW]), .c3_req_last(g_req_l[3]),
				.p_req_valid(p_req_valid), .p_req_ready(p_req_ready),
				.p_req_data(p_req_data), .p_req_last(p_req_last),
				.p_rsp_valid(p_rsp_valid), .p_rsp_ready(p_rsp_ready), .p_rsp_data(p_rsp_data),
				.c0_rsp_valid(g_rsp_v[0]), .c0_rsp_ready(g_rsp_r[0]),
				.c0_rsp_data(g_rsp_d[0*RFW +: RFW]),
				.c1_rsp_valid(g_rsp_v[1]), .c1_rsp_ready(g_rsp_r[1]),
				.c1_rsp_data(g_rsp_d[1*RFW +: RFW]),
				.c2_rsp_valid(g_rsp_v[2]), .c2_rsp_ready(g_rsp_r[2]),
				.c2_rsp_data(g_rsp_d[2*RFW +: RFW]),
				.c3_rsp_valid(g_rsp_v[3]), .c3_rsp_ready(g_rsp_r[3]),
				.c3_rsp_data(g_rsp_d[3*RFW +: RFW]),
				.rsp_idle(l1_rsp_idle)
			);
		end
		assign rsp_idle = l1_rsp_idle && (&g_rsp_idle);
	end
	endgenerate
endmodule

`default_nettype wire
