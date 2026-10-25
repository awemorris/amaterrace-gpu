/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_gate: an AXI4 path (s_* to m_*) that a level input opens and
 * closes (ws288 p040; spec/common/am_axi_gate.md).  Open, the transactions
 * pass through unchanged (combinational, no added cycle).  Closed, they
 * are answered here and m_* sees nothing: a write takes its beats and
 * answers B OKAY after WLAST, a read answers AxLEN + 1 beats of zeros with
 * OKAY and RLAST on the last.  The data width, the IDs and the clock are
 * not changed.
 *
 * Each direction has its own mode (open or closed), which follows en only
 * while that direction has no transaction in flight; a request that finds
 * its mode different from en waits until the earlier transactions are
 * answered, so no response of the one mode passes one of the other.  A
 * write's beats are taken only after its AW (AXI lets a slave wait for
 * AWVALID before WREADY).  Closed, one transaction per direction at a time.
 * Open, 2^CNT_W - 1 transactions per direction in flight at most.
 * Carried: id, addr, len, size, burst.  en must be synchronous to clk.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_gate #(
	parameter A_W = 32,
	parameter D_W = 128,
	parameter ID_W = 4,
	parameter CNT_W = 4,	/* transactions in flight per direction < 2^CNT_W */
	parameter [0:0] OPEN_AT_RESET = 1'b1	/* the mode after rst_n */
) (
	input wire clk,
	input wire rst_n,
	input wire en,	/* 1: open, 0: closed */

	input wire [ID_W-1:0] s_awid,
	input wire [A_W-1:0] s_awaddr,
	input wire [7:0] s_awlen,
	input wire [2:0] s_awsize,
	input wire [1:0] s_awburst,
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
	input wire s_arvalid,
	output wire s_arready,
	output wire [ID_W-1:0] s_rid,
	output wire [D_W-1:0] s_rdata,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,

	output wire [ID_W-1:0] m_awid,
	output wire [A_W-1:0] m_awaddr,
	output wire [7:0] m_awlen,
	output wire [2:0] m_awsize,
	output wire [1:0] m_awburst,
	output wire m_awvalid,
	input wire m_awready,
	output wire [D_W-1:0] m_wdata,
	output wire [D_W/8-1:0] m_wstrb,
	output wire m_wlast,
	output wire m_wvalid,
	input wire m_wready,
	input wire [ID_W-1:0] m_bid,
	input wire [1:0] m_bresp,
	input wire m_bvalid,
	output wire m_bready,
	output wire [ID_W-1:0] m_arid,
	output wire [A_W-1:0] m_araddr,
	output wire [7:0] m_arlen,
	output wire [2:0] m_arsize,
	output wire [1:0] m_arburst,
	output wire m_arvalid,
	input wire m_arready,
	input wire [ID_W-1:0] m_rid,
	input wire [D_W-1:0] m_rdata,
	input wire [1:0] m_rresp,
	input wire m_rlast,
	input wire m_rvalid,
	output wire m_rready
);
	localparam [CNT_W-1:0] FULL = {CNT_W{1'b1}};

	/* ---- Writes ---- */

	reg w_open;	/* the write direction's mode */
	reg [CNT_W-1:0] w_cnt;	/* AWs taken whose B is not given back yet */
	reg [CNT_W:0] w_lead;	/* W bursts begun less AWs taken (two's complement) */
	reg w_mid;	/* a W burst is begun and its WLAST not taken */
	reg aw_hold, w_hold;	/* m_awvalid / m_wvalid offered and not taken: kept */
	reg [ID_W-1:0] w_id;	/* closed: the write being answered */
	reg w_bpend;	/* closed: its WLAST is taken, its B is offered */

	wire w_ahead = !w_lead[CNT_W] && w_lead != {(CNT_W + 1){1'b0}};	/* W before its AW */
	wire w_behind = w_lead[CNT_W];	/* an AW waits for its beats */

	/*
	 * Open: an AW goes on while en is 1, or when its beats went on before
	 * it (en fell meanwhile), or when it was offered already.  A W burst
	 * begins while en is 1 or after its AW; its later beats always go on.
	 * Closed: one write at a time, its beats after its AW.
	 */
	wire aw_ok_open = w_cnt != FULL && (en || w_ahead || aw_hold);
	wire aw_ok_closed = !en && w_cnt == {CNT_W{1'b0}};
	wire w_ok_open = w_mid || w_behind || en || w_hold;
	wire w_ok_closed = (w_mid || w_behind) && !w_bpend;
	wire aw_take = s_awvalid && s_awready;
	wire w_take = s_wvalid && s_wready;
	wire w_first = w_take && !w_mid;
	wire wl_take = w_take && s_wlast;
	wire b_take = s_bvalid && s_bready;

	assign m_awid = s_awid;
	assign m_awaddr = s_awaddr;
	assign m_awlen = s_awlen;
	assign m_awsize = s_awsize;
	assign m_awburst = s_awburst;
	assign m_awvalid = s_awvalid && w_open && aw_ok_open;
	assign s_awready = w_open ? aw_ok_open && m_awready : aw_ok_closed;

	assign m_wdata = s_wdata;
	assign m_wstrb = s_wstrb;
	assign m_wlast = s_wlast;
	assign m_wvalid = s_wvalid && w_open && w_ok_open;
	assign s_wready = w_open ? w_ok_open && m_wready : w_ok_closed;

	assign s_bid = w_open ? m_bid : w_id;
	assign s_bresp = w_open ? m_bresp : 2'b00;
	assign s_bvalid = w_open ? m_bvalid : w_bpend;
	assign m_bready = w_open && s_bready;

	/* The counts: +1 and -1 in one adder each. */
	wire [CNT_W-1:0] w_cnt_n;
	wire [CNT_W:0] w_lead_n;
	wire w_cnt_co, w_lead_co;	/* the counts stay in range */

	am_add #(.W(CNT_W)) w_cnt_add (
		.a(w_cnt), .b({{(CNT_W - 1){b_take && !aw_take}}, aw_take ^ b_take}), .ci(1'b0),
		.s(w_cnt_n), .co(w_cnt_co)
	);
	am_add #(.W(CNT_W + 1)) w_lead_add (
		.a(w_lead), .b({{CNT_W{aw_take && !w_first}}, aw_take ^ w_first}), .ci(1'b0),
		.s(w_lead_n), .co(w_lead_co)
	);

	/* Nothing in flight, nothing offered, nothing begun: the mode may change. */
	wire w_idle = w_cnt == {CNT_W{1'b0}} && w_lead == {(CNT_W + 1){1'b0}} && !w_mid &&
		!aw_take && !w_take && !aw_hold && !w_hold;

	always @(posedge clk) begin
		if (!rst_n) begin
			w_open <= OPEN_AT_RESET;
			w_cnt <= {CNT_W{1'b0}};
			w_lead <= {(CNT_W + 1){1'b0}};
			w_mid <= 1'b0;
			aw_hold <= 1'b0;
			w_hold <= 1'b0;
			w_id <= {ID_W{1'b0}};
			w_bpend <= 1'b0;
		end else begin
			w_cnt <= w_cnt_n;
			w_lead <= w_lead_n;
			aw_hold <= m_awvalid && !m_awready;
			w_hold <= m_wvalid && !m_wready;
			if (wl_take)
				w_mid <= 1'b0;
			else if (w_take)
				w_mid <= 1'b1;
`ifdef MUT_GATE_NOWAIT
			w_open <= en;
`else
			if (w_idle)
				w_open <= en;
`endif
			if (!w_open && aw_take)
				w_id <= s_awid;
			if (!w_open && wl_take)
				w_bpend <= 1'b1;
			else if (!w_open && b_take)
				w_bpend <= 1'b0;
		end
	end

	/* ---- Reads ---- */

	reg r_open;	/* the read direction's mode */
	reg [CNT_W-1:0] r_cnt;	/* ARs taken whose RLAST is not given back yet */
	reg [ID_W-1:0] r_id;	/* closed: the read being answered */
	reg [7:0] r_len;	/* its AxLEN */
	reg [7:0] r_beat;	/* its beats given back */
	reg r_busy;	/* closed: a read is being answered */
	reg ar_hold;	/* m_arvalid offered and not taken: kept */

	wire ar_ok_open = r_cnt != FULL && (en || ar_hold);
	wire ar_ok_closed = !en && r_cnt == {CNT_W{1'b0}};
	wire ar_take = s_arvalid && s_arready;
	wire r_take = s_rvalid && s_rready;
	wire rl_take = r_take && s_rlast;
	wire r_last_here = r_beat == r_len;

	assign m_arid = s_arid;
	assign m_araddr = s_araddr;
	assign m_arlen = s_arlen;
	assign m_arsize = s_arsize;
	assign m_arburst = s_arburst;
	assign m_arvalid = s_arvalid && r_open && ar_ok_open;
	assign s_arready = r_open ? ar_ok_open && m_arready : ar_ok_closed;

	assign s_rid = r_open ? m_rid : r_id;
	assign s_rdata = r_open ? m_rdata : {D_W{1'b0}};
	assign s_rresp = r_open ? m_rresp : 2'b00;
	assign s_rlast = r_open ? m_rlast : r_last_here;
	assign s_rvalid = r_open ? m_rvalid : r_busy;
	assign m_rready = r_open && s_rready;

	wire [CNT_W-1:0] r_cnt_n;
	wire [7:0] r_beat_n;
	wire r_cnt_co, r_beat_co;

	am_add #(.W(CNT_W)) r_cnt_add (
		.a(r_cnt), .b({{(CNT_W - 1){rl_take && !ar_take}}, ar_take ^ rl_take}), .ci(1'b0),
		.s(r_cnt_n), .co(r_cnt_co)
	);
	am_add #(.W(8)) r_beat_add (
		.a(r_beat), .b(8'd1), .ci(1'b0), .s(r_beat_n), .co(r_beat_co)
	);

	always @(posedge clk) begin
		if (!rst_n) begin
			r_open <= OPEN_AT_RESET;
			r_cnt <= {CNT_W{1'b0}};
			r_id <= {ID_W{1'b0}};
			r_len <= 8'd0;
			r_beat <= 8'd0;
			r_busy <= 1'b0;
			ar_hold <= 1'b0;
		end else begin
			r_cnt <= r_cnt_n;
			ar_hold <= m_arvalid && !m_arready;
`ifdef MUT_GATE_NOWAIT
			r_open <= en;
`else
			if (r_cnt == {CNT_W{1'b0}} && !ar_take && !ar_hold)
				r_open <= en;
`endif
			if (!r_open && ar_take) begin
				r_id <= s_arid;
				r_len <= s_arlen;
				r_beat <= 8'd0;
				r_busy <= 1'b1;
			end else if (!r_open && r_take) begin
				r_beat <= r_beat_n;
				if (r_last_here)
					r_busy <= 1'b0;
			end
		end
	end

	wire unused_ok = &{1'b0, w_cnt_co, w_lead_co, r_cnt_co, r_beat_co};
endmodule

`default_nettype wire
