/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_split: one AXI4 slave (s_*) to two AXI4 masters (m0_*, m1_*) by
 * address (ws288 p039; spec/library/bus/am_axi_split.md).  A burst whose start
 * address is in [BASE0, BASE0 + SIZE0) goes to m0, else one in [BASE1,
 * BASE1 + SIZE1) to m1 (range 0 first; SIZE 0 = no range); any other is
 * answered here with DECERR (a write after its last beat, a read with
 * AxLEN + 1 beats of zeros).  A burst must not leave its range (ranges on
 * 4 KiB boundaries: AXI bursts do not cross 4 KiB).  The data width, the
 * IDs and the clock are not changed.
 *
 * Order (AXI): the transactions of one ID and direction in flight all go
 * to one destination; a request of an ID that has transactions in flight
 * at another destination (DECERR included) waits until they are answered,
 * so the responses of each ID come back in order.  2^CNT_W - 1 of them per
 * ID and direction at most.  W follows the order of the AWs: an AW taken
 * from s_* puts its destination in a queue of 2^WQ_LOG2, and its beats go
 * there, also before the destination took the AW (a slave may wait for
 * WVALID before AWREADY).  Responses: B from m0, m1 and the DECERR queue
 * in turn; R one burst at a time (a source keeps R until its RLAST), so
 * the bursts on s_* never interleave.  AW and AR pass through a register
 * stage each (a new one is taken when the stage is empty or leaving).
 * Carried: id, addr, len, size, burst, cache, prot (no lock, qos, region).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_split #(
	parameter A_W = 32,
	parameter D_W = 64,
	parameter ID_W = 1,
	parameter [A_W-1:0] BASE0 = {A_W{1'b0}},
	parameter [A_W-1:0] SIZE0 = {A_W{1'b0}},
	parameter [A_W-1:0] BASE1 = {A_W{1'b0}},
	parameter [A_W-1:0] SIZE1 = {A_W{1'b0}},
	parameter CNT_W = 3,	/* transactions in flight per ID and direction < 2^CNT_W */
	parameter WQ_LOG2 = 2	/* AWs whose beats are not all through */
) (
	input wire clk,
	input wire rst_n,

	input wire [ID_W-1:0] s_awid,
	input wire [A_W-1:0] s_awaddr,
	input wire [7:0] s_awlen,
	input wire [2:0] s_awsize,
	input wire [1:0] s_awburst,
	input wire [3:0] s_awcache,
	input wire [2:0] s_awprot,
	input wire s_awvalid,
	output wire s_awready,
	input wire [D_W-1:0] s_wdata,
	input wire [D_W/8-1:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [ID_W-1:0] s_bid,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [ID_W-1:0] s_arid,
	input wire [A_W-1:0] s_araddr,
	input wire [7:0] s_arlen,
	input wire [2:0] s_arsize,
	input wire [1:0] s_arburst,
	input wire [3:0] s_arcache,
	input wire [2:0] s_arprot,
	input wire s_arvalid,
	output wire s_arready,
	output wire [ID_W-1:0] s_rid,
	output wire [D_W-1:0] s_rdata,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,

	output wire [ID_W-1:0] m0_awid,
	output wire [A_W-1:0] m0_awaddr,
	output wire [7:0] m0_awlen,
	output wire [2:0] m0_awsize,
	output wire [1:0] m0_awburst,
	output wire [3:0] m0_awcache,
	output wire [2:0] m0_awprot,
	output wire m0_awvalid,
	input wire m0_awready,
	output wire [D_W-1:0] m0_wdata,
	output wire [D_W/8-1:0] m0_wstrb,
	output wire m0_wlast,
	output wire m0_wvalid,
	input wire m0_wready,
	input wire [ID_W-1:0] m0_bid,
	input wire [1:0] m0_bresp,
	input wire m0_bvalid,
	output wire m0_bready,
	output wire [ID_W-1:0] m0_arid,
	output wire [A_W-1:0] m0_araddr,
	output wire [7:0] m0_arlen,
	output wire [2:0] m0_arsize,
	output wire [1:0] m0_arburst,
	output wire [3:0] m0_arcache,
	output wire [2:0] m0_arprot,
	output wire m0_arvalid,
	input wire m0_arready,
	input wire [ID_W-1:0] m0_rid,
	input wire [D_W-1:0] m0_rdata,
	input wire [1:0] m0_rresp,
	input wire m0_rlast,
	input wire m0_rvalid,
	output wire m0_rready,

	output wire [ID_W-1:0] m1_awid,
	output wire [A_W-1:0] m1_awaddr,
	output wire [7:0] m1_awlen,
	output wire [2:0] m1_awsize,
	output wire [1:0] m1_awburst,
	output wire [3:0] m1_awcache,
	output wire [2:0] m1_awprot,
	output wire m1_awvalid,
	input wire m1_awready,
	output wire [D_W-1:0] m1_wdata,
	output wire [D_W/8-1:0] m1_wstrb,
	output wire m1_wlast,
	output wire m1_wvalid,
	input wire m1_wready,
	input wire [ID_W-1:0] m1_bid,
	input wire [1:0] m1_bresp,
	input wire m1_bvalid,
	output wire m1_bready,
	output wire [ID_W-1:0] m1_arid,
	output wire [A_W-1:0] m1_araddr,
	output wire [7:0] m1_arlen,
	output wire [2:0] m1_arsize,
	output wire [1:0] m1_arburst,
	output wire [3:0] m1_arcache,
	output wire [2:0] m1_arprot,
	output wire m1_arvalid,
	input wire m1_arready,
	input wire [ID_W-1:0] m1_rid,
	input wire [D_W-1:0] m1_rdata,
	input wire [1:0] m1_rresp,
	input wire m1_rlast,
	input wire m1_rvalid,
	output wire m1_rready
);
	localparam [A_W:0] END0 = {1'b0, BASE0} + {1'b0, SIZE0};
	localparam [A_W:0] END1 = {1'b0, BASE1} + {1'b0, SIZE1};
	localparam [1:0] T_ERR = 2'd2;
	/* An AW or AR stage: {id, addr, len, size, burst, cache, prot}. */
	localparam AXW = ID_W + A_W + 8 + 3 + 2 + 4 + 3;

	function [1:0] dest;
		input [A_W-1:0] a;
		begin
			/* a >= BASE as {a, 1} > {BASE, 0} (no constant compare for BASE 0) */
			if (SIZE0 != {A_W{1'b0}} && {a, 1'b1} > {BASE0, 1'b0} && {1'b0, a} < END0)
				dest = 2'd0;
			else if (SIZE1 != {A_W{1'b0}} && {a, 1'b1} > {BASE1, 1'b0} && {1'b0, a} < END1)
				dest = 2'd1;
			else
				dest = T_ERR;
		end
	endfunction

	/* The transactions in flight per ID: writes from the AW taken to the B
	 * given, reads from the AR to the last R beat. */
	wire aw_new, ar_new, b_done, r_done, aw_ok, ar_ok;
`ifdef MUT_SPLIT_NOWAIT
	wire aw_id_ok = 1'b1, ar_id_ok = 1'b1;
`else
	wire aw_id_ok = aw_ok, ar_id_ok = ar_ok;
`endif
	wire [1:0] aw_t_in = dest(s_awaddr);
	wire [1:0] ar_t_in = dest(s_araddr);

	am_axi_idtrack #(.ID_W(ID_W), .CNT_W(CNT_W)) wtr (
		.clk(clk), .rst_n(rst_n), .take(aw_new), .take_id(s_awid), .take_dst(aw_t_in),
		.done(b_done), .done_id(s_bid), .q_id(s_awid), .q_dst(aw_t_in), .ok(aw_ok)
	);
	am_axi_idtrack #(.ID_W(ID_W), .CNT_W(CNT_W)) rtr (
		.clk(clk), .rst_n(rst_n), .take(ar_new), .take_id(s_arid), .take_dst(ar_t_in),
		.done(r_done), .done_id(s_rid), .q_id(s_arid), .q_dst(ar_t_in), .ok(ar_ok)
	);

	/* ---------------------------------------------------- AW and W */

	reg aw_v;
	reg [1:0] aw_t;
	reg [AXW-1:0] aw_p;
	wire wq_in_ready, wq_out_valid;
	wire [1:0] w_t;
	wire [ID_W-1:0] w_id;
	wire eb_in_ready;

	/* The stage leaves: its destination took it (DECERR: at once). */
	wire aw_go = aw_v && (aw_t == 2'd0 ? m0_awready : aw_t == 2'd1 ? m1_awready : 1'b1);
	assign s_awready = rst_n && (!aw_v || aw_go) && wq_in_ready && aw_id_ok;
	assign aw_new = s_awvalid && s_awready;

	always @(posedge clk) begin
		if (!rst_n) begin
			aw_v <= 1'b0;
			aw_t <= 2'd0;
			aw_p <= {AXW{1'b0}};
		end else if (aw_new) begin
			aw_v <= 1'b1;
			aw_t <= aw_t_in;
			aw_p <= {s_awid, s_awaddr, s_awlen, s_awsize, s_awburst, s_awcache, s_awprot};
		end else if (aw_go) begin
			aw_v <= 1'b0;
		end
	end

	assign {m0_awid, m0_awaddr, m0_awlen, m0_awsize, m0_awburst, m0_awcache, m0_awprot} = aw_p;
	assign {m1_awid, m1_awaddr, m1_awlen, m1_awsize, m1_awburst, m1_awcache, m1_awprot} = aw_p;
	assign m0_awvalid = aw_v && aw_t == 2'd0;
	assign m1_awvalid = aw_v && aw_t == 2'd1;

	/* The destinations of the bursts whose beats are owed, in AW order. */
	wire [WQ_LOG2:0] wq_count;
	wire w_ok = s_wvalid && wq_out_valid;
	wire w_err = w_t == T_ERR;
	wire w_fire = w_ok && (w_t == 2'd0 ? m0_wready : w_t == 2'd1 ? m1_wready :
		!s_wlast || eb_in_ready);

	am_fifo #(.W(2 + ID_W), .DEPTH_LOG2(WQ_LOG2)) wq (
		.clk(clk), .rst_n(rst_n), .in_valid(aw_new), .in_ready(wq_in_ready),
		.in_data({aw_t_in, s_awid}), .out_valid(wq_out_valid),
		.out_ready(w_fire && s_wlast), .out_data({w_t, w_id}), .count(wq_count)
	);

	assign s_wready = wq_out_valid && (w_t == 2'd0 ? m0_wready : w_t == 2'd1 ? m1_wready :
		!s_wlast || eb_in_ready);
	assign m0_wdata = s_wdata;
	assign m0_wstrb = s_wstrb;
	assign m0_wlast = s_wlast;
`ifdef MUT_SPLIT_WAFTER
	assign m0_wvalid = w_ok && w_t == 2'd0 && !(aw_v && aw_t == 2'd0);
`else
	assign m0_wvalid = w_ok && w_t == 2'd0;
`endif
	assign m1_wdata = s_wdata;
	assign m1_wstrb = s_wstrb;
	assign m1_wlast = s_wlast;
`ifdef MUT_SPLIT_WAFTER
	assign m1_wvalid = w_ok && w_t == 2'd1 && !(aw_v && aw_t == 2'd1);
`else
	assign m1_wvalid = w_ok && w_t == 2'd1;
`endif

	/* The DECERR writes' responses, after their last beat. */
	wire eb_valid;
	wire [ID_W-1:0] eb_id;
	wire [WQ_LOG2:0] eb_count;
	wire eb_take;

	am_fifo #(.W(ID_W), .DEPTH_LOG2(WQ_LOG2)) eb (
		.clk(clk), .rst_n(rst_n), .in_valid(w_fire && s_wlast && w_err),
		.in_ready(eb_in_ready), .in_data(w_id), .out_valid(eb_valid), .out_ready(eb_take),
		.out_data(eb_id), .count(eb_count)
	);

	/* ------------------------------------------------------------ B */

	/* The source shown on s_b*: 0 m0, 1 m1, 2 DECERR, in turn. */
	wire [2:0] b_v = {eb_valid, m1_bvalid, m0_bvalid};
	wire [1:0] b_sel;

	am_arb3 barb (.clk(clk), .rst_n(rst_n), .v(b_v), .fire(b_done), .last(1'b1), .sel(b_sel));

	assign s_bvalid = b_sel == 2'd0 ? b_v[0] : b_sel == 2'd1 ? b_v[1] : b_v[2];
	assign s_bid = b_sel == 2'd0 ? m0_bid : b_sel == 2'd1 ? m1_bid : eb_id;
	assign s_bresp = b_sel == 2'd0 ? m0_bresp : b_sel == 2'd1 ? m1_bresp : 2'b11;
	assign m0_bready = s_bready && b_sel == 2'd0;
	assign m1_bready = s_bready && b_sel == 2'd1;
	assign eb_take = s_bready && b_sel == 2'd2;
	assign b_done = s_bvalid && s_bready;

	/* ---------------------------------------------------- AR and R */

	reg ar_v;
	reg [1:0] ar_t;
	reg [AXW-1:0] ar_p;
	reg er_v;	/* a DECERR read being answered */
	reg [ID_W-1:0] er_id;
	reg [7:0] er_left;	/* beats after the one shown */
	wire er_beat;

	wire ar_go = ar_v && (ar_t == 2'd0 ? m0_arready : ar_t == 2'd1 ? m1_arready : !er_v);
	assign s_arready = rst_n && (!ar_v || ar_go) && ar_id_ok;
	assign ar_new = s_arvalid && s_arready;

	always @(posedge clk) begin
		if (!rst_n) begin
			ar_v <= 1'b0;
			ar_t <= 2'd0;
			ar_p <= {AXW{1'b0}};
		end else if (ar_new) begin
			ar_v <= 1'b1;
			ar_t <= ar_t_in;
			ar_p <= {s_arid, s_araddr, s_arlen, s_arsize, s_arburst, s_arcache, s_arprot};
		end else if (ar_go) begin
			ar_v <= 1'b0;
		end
	end

	assign {m0_arid, m0_araddr, m0_arlen, m0_arsize, m0_arburst, m0_arcache, m0_arprot} = ar_p;
	assign {m1_arid, m1_araddr, m1_arlen, m1_arsize, m1_arburst, m1_arcache, m1_arprot} = ar_p;
	assign m0_arvalid = ar_v && ar_t == 2'd0;
	assign m1_arvalid = ar_v && ar_t == 2'd1;

	wire [ID_W-1:0] arp_id = ar_p[AXW-1 -: ID_W];
	wire [7:0] arp_len = ar_p[AXW-ID_W-A_W-1 -: 8];
	wire [7:0] er_left_n;
	wire unused_er_co;

	am_sub #(.W(8)) er_sub (.a(er_left), .b(8'd1), .bi(1'b0), .d(er_left_n), .bo(unused_er_co));

	always @(posedge clk) begin
		if (!rst_n) begin
			er_v <= 1'b0;
			er_id <= {ID_W{1'b0}};
			er_left <= 8'd0;
		end else if (ar_go && ar_t == T_ERR) begin
			er_v <= 1'b1;
			er_id <= arp_id;
			er_left <= arp_len;
		end else if (er_beat) begin
			if (er_left == 8'd0)
				er_v <= 1'b0;
			else
				er_left <= er_left_n;
		end
	end

	/* The source shown on s_r*, kept for a whole burst. */
	wire [2:0] r_v = {er_v, m1_rvalid, m0_rvalid};
	wire [1:0] r_sel;
	wire r_fire = s_rvalid && s_rready;

	am_arb3 rarb (.clk(clk), .rst_n(rst_n), .v(r_v), .fire(r_fire), .last(s_rlast), .sel(r_sel));

	assign s_rvalid = r_sel == 2'd0 ? r_v[0] : r_sel == 2'd1 ? r_v[1] : r_v[2];
	assign s_rid = r_sel == 2'd0 ? m0_rid : r_sel == 2'd1 ? m1_rid : er_id;
	assign s_rdata = r_sel == 2'd0 ? m0_rdata : r_sel == 2'd1 ? m1_rdata : {D_W{1'b0}};
	assign s_rresp = r_sel == 2'd0 ? m0_rresp : r_sel == 2'd1 ? m1_rresp : 2'b11;
	assign s_rlast = r_sel == 2'd0 ? m0_rlast : r_sel == 2'd1 ? m1_rlast : er_left == 8'd0;
	assign m0_rready = s_rready && r_sel == 2'd0;
	assign m1_rready = s_rready && r_sel == 2'd1;
	assign er_beat = s_rready && r_sel == 2'd2 && er_v;
	assign r_done = r_fire && s_rlast;

	wire unused_ok = &{1'b0, wq_count, eb_count, unused_er_co};
endmodule

`default_nettype wire
