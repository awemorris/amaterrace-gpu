/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_rt_to_amb: Spine-side NoC flit trunk to AMB bridge (counterpart to
 * am_amb_to_rt).
 *
 * Unpacks 1-flit (read) or 2-flit (write) NoC packets arriving from a trunk
 * of atg_su_fabric_n* into an AMB client port for am_mmu_bridge / atg_mc.
 * Up to 64 outstanding transactions are tracked by a 6-bit allocated tag
 * (stored route[RW-1:0] and original 8-bit tag in distributed RAM), allowing
 * arbitrary out-of-order returns and lossless response delivery via a
 * 64-entry response FIFO + output am_skid.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_rt_to_amb #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter RW = 5,
	parameter FW = LINE_BYTES * 8,
	parameter RFW = LINE_BYTES * 8 + 10 + RW
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	/* Trunk NoC flit port (from atg_su_fabric_n*) */
	input wire t_req_valid,
	output wire t_req_ready,
	input wire [FW-1:0] t_req_data,
	input wire t_req_last,
	output wire t_rsp_valid,
	input wire t_rsp_ready,
	output wire [RFW-1:0] t_rsp_data,

	/* Downstream AMB port (to am_mmu_bridge / atg_mc) */
	output wire m_req_valid,
	input wire m_req_ready,
	output wire m_req_write,
	output wire m_req_exec,
	output wire [ADDR_W-LINE_SHIFT-1:0] m_req_line,
	output wire [LINE_BYTES-1:0] m_req_be,
	output wire [LINE_BYTES*8-1:0] m_req_wdata,
	output wire [7:0] m_req_tag,
	output wire m_req_chk,
	output wire m_req_tbl,
	output wire [5:0] m_req_slot,
	output wire [3:0] m_req_session,
	input wire m_rsp_valid,
	input wire m_rsp_write,
	input wire [7:0] m_rsp_tag,
	input wire [LINE_BYTES*8-1:0] m_rsp_rdata,
	input wire m_rsp_error
);
	localparam LAW = ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam EXTHW = 30 + RW + LAW + LINE_BYTES + 7;
	localparam M_REQ_W = 1 + 1 + LAW + LINE_BYTES + LINE_BITS + 8 + 1 + 1 + 6 + 4;

	wire rst_int_n = rst_n && !flush;

	/* Input skid buffer */
	wire sk_v, sk_r, sk_last;
	wire [FW-1:0] sk_data;

	am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_in_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(t_req_valid), .in_ready(t_req_ready),
		.in_data({t_req_last, t_req_data}),
		.out_valid(sk_v), .out_ready(sk_r),
		.out_data({sk_last, sk_data})
	);

	/* 64-entry slot ID allocator (seed 0..63, then recycle via FIFO) */
	reg [6:0] seed_ptr;
	wire [6:0] seed_next;
	wire unused_seed_co;
	am_add #(.W(7)) u_seed_add (
		.a(seed_ptr), .b(7'd0), .ci(1'b1), .s(seed_next), .co(unused_seed_co)
	);
	wire seed_done = seed_ptr[6];

	wire ff_out_v;
	wire [5:0] ff_out_sid;
	wire unused_ff_in_rdy;
	wire [6:0] unused_ff_cnt;
	wire alloc_fire;

	am_fifo #(.W(6), .DEPTH_LOG2(6)) u_free_fifo (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(m_rsp_valid), .in_ready(unused_ff_in_rdy), .in_data(m_rsp_tag[5:0]),
		.out_valid(ff_out_v), .out_ready(alloc_fire && seed_done), .out_data(ff_out_sid),
		.count(unused_ff_cnt)
	);

	wire alloc_avail = !seed_done || ff_out_v;
	wire [5:0] alloc_sid = !seed_done ? seed_ptr[5:0] : ff_out_sid;

	/* Header / data assembly */
	reg hdr_seen;
	reg [EXTHW-1:0] hdr_r;
	reg [5:0] sid_r;

	wire m_sk_in_v, m_sk_in_r;
	wire [EXTHW-1:0] hdr_sel = hdr_seen ? hdr_r : sk_data[EXTHW-1:0];
	wire [5:0] sid_sel = hdr_seen ? sid_r : alloc_sid;

	/* Unpack header fields per am_amb_to_rt */
	localparam OFF_TAG     = 4;
	localparam OFF_ROUTE   = 20;
	localparam OFF_LINE    = 20 + RW;
	localparam OFF_BE      = 20 + RW + LAW;
	localparam OFF_TBL     = 20 + RW + LAW + LINE_BYTES;
	localparam OFF_SLOT    = OFF_TBL + 1;
	localparam OFF_SESS    = OFF_TBL + 11;
	localparam OFF_EXEC    = OFF_TBL + 15;

	wire        h_write   = hdr_sel[1];
	wire        h_chk     = hdr_sel[3];
	wire [7:0]  h_tag     = sk_data[OFF_TAG +: 8];
	wire [RW-1:0] h_route = sk_data[OFF_ROUTE +: RW];
	wire [LAW-1:0] h_line = hdr_sel[OFF_LINE +: LAW];
	wire [LINE_BYTES-1:0] h_be = hdr_sel[OFF_BE +: LINE_BYTES];
	wire        h_tbl     = hdr_sel[OFF_TBL];
	wire [5:0]  h_slot    = hdr_sel[OFF_SLOT +: 6];
	wire [3:0]  h_sess    = hdr_sel[OFF_SESS +: 4];
	wire [1:0]  h_exec_t  = hdr_sel[OFF_EXEC +: 2];
	wire        h_exec    = (h_exec_t == 2'b10);

	assign alloc_fire = sk_v && !hdr_seen && alloc_avail && (sk_last ? m_sk_in_r : 1'b1);
	assign sk_r = hdr_seen ? m_sk_in_r : (alloc_avail && (sk_last ? m_sk_in_r : 1'b1));
	assign m_sk_in_v = sk_v && (hdr_seen || (sk_last && alloc_avail));

	wire [LINE_BITS-1:0] wdata_sel = hdr_seen ? sk_data : {LINE_BITS{1'b0}};
	wire [M_REQ_W-1:0] m_sk_in_data = {
		h_write, h_exec, h_line, h_be, wdata_sel,
		{2'b00, sid_sel}, h_chk, h_tbl, h_slot, h_sess
	};

	am_skid #(.WIDTH(M_REQ_W), .RST_DATA(0)) u_out_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(m_sk_in_v), .in_ready(m_sk_in_r),
		.in_data(m_sk_in_data),
		.out_valid(m_req_valid), .out_ready(m_req_ready),
		.out_data({
			m_req_write, m_req_exec, m_req_line, m_req_be, m_req_wdata,
			m_req_tag, m_req_chk, m_req_tbl, m_req_slot, m_req_session
		})
	);

	/* Metadata RAM: {route[RW-1:0], orig_tag[7:0]} */
	(* ram_style = "distributed" *) reg [RW+8-1:0] mem_meta [0:63];

	always @(posedge clk) begin
		if (alloc_fire)
			mem_meta[alloc_sid] <= {h_route, h_tag};
	end

	always @(posedge clk or negedge rst_int_n) begin
		if (!rst_int_n) begin
			seed_ptr <= 7'd0;
			hdr_seen <= 1'b0;
			hdr_r <= {EXTHW{1'b0}};
			sid_r <= 6'd0;
		end else begin
			if (alloc_fire && !seed_done)
				seed_ptr <= seed_next;
			if (sk_v && sk_r) begin
				if (!hdr_seen && !sk_last) begin
					hdr_seen <= 1'b1;
					hdr_r <= sk_data[EXTHW-1:0];
					sid_r <= alloc_sid;
				end else if (hdr_seen) begin
					hdr_seen <= 1'b0;
				end
			end
		end
	end

	/* Lossless 64-entry response FIFO + output skid */
	wire [RW+8-1:0] rsp_meta = mem_meta[m_rsp_tag[5:0]];
	wire [RW-1:0]   rsp_route = rsp_meta[8 +: RW];
	wire [7:0]      rsp_orig_tag = rsp_meta[7:0];
	wire [RFW-1:0]  rsp_flit_in = {m_rsp_rdata, rsp_route, rsp_orig_tag, m_rsp_error, m_rsp_write};

	wire rf_out_v, rf_out_r;
	wire [RFW-1:0] rf_out_d;
	wire unused_rf_in_rdy;
	wire [6:0] unused_rf_cnt;

	am_fifo #(.W(RFW), .DEPTH_LOG2(6)) u_rsp_fifo (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(m_rsp_valid), .in_ready(unused_rf_in_rdy), .in_data(rsp_flit_in),
		.out_valid(rf_out_v), .out_ready(rf_out_r), .out_data(rf_out_d),
		.count(unused_rf_cnt)
	);

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_rsp_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(rf_out_v), .in_ready(rf_out_r),
		.in_data(rf_out_d),
		.out_valid(t_rsp_valid), .out_ready(t_rsp_ready),
		.out_data(t_rsp_data)
	);

	wire unused_ok = &{1'b0, sk_data, m_rsp_tag[7:6], unused_seed_co, unused_ff_in_rdy,
		unused_ff_cnt, unused_rf_in_rdy, unused_rf_cnt};
endmodule

`default_nettype wire
