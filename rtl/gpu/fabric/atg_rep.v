/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rep: Integrated 4-channel pipeline repeater for 2D horizontal/vertical
 * NoC links across multi-SU dies (docs/noc_and_mmu_architecture.md §4.2).
 *
 * Contains STAGES pipeline stages (default 1) across 4 channels:
 *   1. Upward NoC request flit channel (am_skid, dn_req -> up_req)
 *   2. Downward NoC response flit channel (am_skid, up_rsp -> dn_rsp)
 *   3. Downward control broadcast FF slice (st_*, kicks, inv, scrub, session_id)
 *   4. Upward status/fault FF slice (busy, scrub_busy, fault, fault_addr, fault_stage)
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rep #(
	parameter FW = 512,
	parameter RFW = 534,
	parameter STAGES = 1
) (
	input wire clk,
	input wire rst_n,
	input wire core_rst_n,
	input wire flush,

	/* Channel 1: Upward NoC Request (child/tile -> spine/root) */
	input wire dn_req_valid,
	output wire dn_req_ready,
	input wire [FW-1:0] dn_req_data,
	input wire dn_req_last,
	output wire up_req_valid,
	input wire up_req_ready,
	output wire [FW-1:0] up_req_data,
	output wire up_req_last,

	/* Channel 2: Downward NoC Response (spine/root -> child/tile) */
	input wire up_rsp_valid,
	output wire up_rsp_ready,
	input wire [RFW-1:0] up_rsp_data,
	output wire dn_rsp_valid,
	input wire dn_rsp_ready,
	output wire [RFW-1:0] dn_rsp_data,
	output wire rsp_idle,

	/* Channel 3: Downward Control Broadcast (spine -> child/tile) */
	input wire in_st_we,
	input wire [8:0] in_st_idx,
	input wire [31:0] in_st_wdata,
	input wire in_cs_kick,
	input wire in_cs_mesh,
	input wire in_lc_kick,
	input wire [3:0] in_inv,
	input wire in_scrub,
	input wire [3:0] in_session_id,
	output wire out_st_we,
	output wire [8:0] out_st_idx,
	output wire [31:0] out_st_wdata,
	output wire out_cs_kick,
	output wire out_cs_mesh,
	output wire out_lc_kick,
	output wire [3:0] out_inv,
	output wire out_scrub,
	output wire [3:0] out_session_id,

	/* Channel 4: Upward Status / Fault Slice (child/tile -> spine) */
	input wire in_busy,
	input wire in_scrub_busy,
	input wire in_fault,
	input wire [31:0] in_fault_addr,
	input wire [3:0] in_fault_stage,
	output wire out_busy,
	output wire out_scrub_busy,
	output wire out_fault,
	output wire [31:0] out_fault_addr,
	output wire [3:0] out_fault_stage
);
	localparam CTRL_W = 1 + 9 + 32 + 1 + 1 + 1 + 4 + 1 + 4; /* 54 bits */
	localparam STAT_W = 1 + 1 + 1 + 32 + 4;                 /* 39 bits */

	wire rst_noc_n = rst_n && !flush;

	generate
	if (STAGES == 0) begin : g_bypass
		assign up_req_valid    = dn_req_valid;
		assign dn_req_ready    = up_req_ready;
		assign up_req_data     = dn_req_data;
		assign up_req_last     = dn_req_last;
		assign dn_rsp_valid    = up_rsp_valid;
		assign up_rsp_ready    = dn_rsp_ready;
		assign dn_rsp_data     = up_rsp_data;
		assign rsp_idle        = 1'b1;

		assign out_st_we       = in_st_we;
		assign out_st_idx      = in_st_idx;
		assign out_st_wdata    = in_st_wdata;
		assign out_cs_kick     = in_cs_kick;
		assign out_cs_mesh     = in_cs_mesh;
		assign out_lc_kick     = in_lc_kick;
		assign out_inv         = in_inv;
		assign out_scrub       = in_scrub;
		assign out_session_id  = in_session_id;

		assign out_busy        = in_busy;
		assign out_scrub_busy  = in_scrub_busy;
		assign out_fault       = in_fault;
		assign out_fault_addr  = in_fault_addr;
		assign out_fault_stage = in_fault_stage;
		wire unused_byp = &{1'b0, clk, rst_noc_n, core_rst_n};
	end else begin : g_pipe
		wire [STAGES:0] req_v, req_r, req_l;
		wire [FW-1:0]   req_d [0:STAGES];
		wire [STAGES:0] rsp_v, rsp_r;
		wire [RFW-1:0]  rsp_d [0:STAGES];
		wire [STAGES-1:0] st_rsp_idle;

		wire [CTRL_W-1:0] ctrl_w [0:STAGES];
		wire [STAT_W-1:0] stat_w [0:STAGES];
		reg  [CTRL_W-1:0] ctrl_r [0:STAGES-1];
		reg  [STAT_W-1:0] stat_r [0:STAGES-1];

		assign ctrl_w[0] = {in_st_we, in_st_idx, in_st_wdata, in_cs_kick, in_cs_mesh, in_lc_kick, in_inv, in_scrub, in_session_id};
		assign stat_w[0] = {in_busy, in_scrub_busy, in_fault, in_fault_addr, in_fault_stage};

		assign req_v[0]     = dn_req_valid;
		assign dn_req_ready = req_r[0];
		assign req_d[0]     = dn_req_data;
		assign req_l[0]     = dn_req_last;
		assign up_req_valid = req_v[STAGES];
		assign req_r[STAGES] = up_req_ready;
		assign up_req_data  = req_d[STAGES];
		assign up_req_last  = req_l[STAGES];

		assign rsp_v[0]     = up_rsp_valid;
		assign up_rsp_ready = rsp_r[0];
		assign rsp_d[0]     = up_rsp_data;
		assign dn_rsp_valid = rsp_v[STAGES];
		assign rsp_r[STAGES] = dn_rsp_ready;
		assign dn_rsp_data  = rsp_d[STAGES];
		assign rsp_idle     = &st_rsp_idle;

		genvar gs;
		for (gs = 0; gs < STAGES; gs = gs + 1) begin : g_stg
			am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_req_skid (
				.clk(clk), .rst_n(rst_noc_n),
				.in_valid(req_v[gs]), .in_ready(req_r[gs]),
				.in_data({req_l[gs], req_d[gs]}),
				.out_valid(req_v[gs+1]), .out_ready(req_r[gs+1]),
				.out_data({req_l[gs+1], req_d[gs+1]})
			);

			am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_rsp_skid (
				.clk(clk), .rst_n(rst_noc_n),
				.in_valid(rsp_v[gs]), .in_ready(rsp_r[gs]),
				.in_data(rsp_d[gs]),
				.out_valid(rsp_v[gs+1]), .out_ready(rsp_r[gs+1]),
				.out_data(rsp_d[gs+1])
			);
			assign st_rsp_idle[gs] = !rsp_v[gs+1];

			assign ctrl_w[gs+1] = ctrl_r[gs];
			assign stat_w[gs+1] = stat_r[gs];

			always @(posedge clk or negedge core_rst_n) begin
				if (!core_rst_n) begin
					ctrl_r[gs] <= {CTRL_W{1'b0}};
					stat_r[gs] <= {STAT_W{1'b0}};
				end else begin
					ctrl_r[gs] <= ctrl_w[gs];
					stat_r[gs] <= stat_w[gs];
				end
			end
		end

		assign {out_st_we, out_st_idx, out_st_wdata, out_cs_kick, out_cs_mesh,
		        out_lc_kick, out_inv, out_scrub, out_session_id} = ctrl_r[STAGES-1];
		assign {out_busy, out_scrub_busy, out_fault, out_fault_addr, out_fault_stage} = stat_r[STAGES-1];
	end
	endgenerate
endmodule

`default_nettype wire
