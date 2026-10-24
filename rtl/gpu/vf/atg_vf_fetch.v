/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_fetch: VF attribute fetch: for each vertex of a warp and each
 * enabled attribute k (ATTR[k]_BASE/DESC), computes the address
 * (per-vertex or per-instance with divisor) and reads the attribute's
 * bytes through the AMB.
 *
 * One vertex at a time from vb; for it, the enabled attributes in
 * ascending k (attribute k is enabled when its ATTR_DST word is not 0),
 * one at a time: element = index (per-vertex), or FIRST_INSTANCE +
 * (inst - FIRST_INSTANCE) / divisor (per-instance; divisor 0: FIRST_INSTANCE,
 * Vulkan's rule; a sequential divider with a one-entry memo for divisors
 * above 1), address = ATTR_BASE + stride * element, the size from the
 * format (4..16 bytes, any byte alignment).  The bytes come from two line
 * entries (fully associative, kept until the warp's last attribute: the
 * vertex buffers do not change under a draw); an attribute that crosses a
 * line uses both.  Misses are read one request at a time (tag = entry,
 * at most two in flight); an error response reads as 0.  af goes out
 * lane-major, af_last on the last attribute of the vertex with vb_last.  A
 * warp whose vertices have no enabled attribute still sends one af (attr 0,
 * disabled, af_last) so that atg_vf_conv ends the warp.
 * See spec/gpu/vf/atg_vf_fetch.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_fetch #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Vertices of a warp (atg_vf_asm → atg_vf_fetch) */
	input wire vb_valid,
	output wire vb_ready,
	input wire [31:0] vb_index,
	input wire [31:0] vb_inst,
	input wire [4:0] vb_lane,
	input wire vb_last,
	/* Attribute data (atg_vf_fetch → atg_vf_conv) */
	output wire af_valid,
	input wire af_ready,
	output wire [3:0] af_attr,
	output wire [4:0] af_lane,
	output wire [127:0] af_raw,
	output wire af_last,
	output wire busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;

	/* STATE (design §2.3): FIRST_INSTANCE 0x027, ATTR[k]_BASE 0x030 + 2k,
	 * ATTR[k]_DESC 0x031 + 2k, ATTR_DST[k] 0x1C0 + k. */
	localparam [8:0] S_FIRST_INSTANCE = 9'h027;
	localparam [8:0] S_ATTR = 9'h030;
	localparam [8:0] S_ATTR_DST = 9'h1C0;

	reg [31:0] s_finst;
	reg [31:0] a_base [0:15];
	reg [20:0] a_desc [0:15];	/* DESC[20:0]: stride, format, per-instance */
	reg [7:0] a_div [0:15];	/* DESC[31:24] */
	reg [15:0] en;
	wire [8:0] s_off = st_idx - S_ATTR;
	wire s_attr = st_idx >= S_ATTR && st_idx < S_ATTR + 9'd32;
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			s_finst <= 32'd0;
			en <= 16'd0;
			for (i = 0; i < 16; i = i + 1) begin
				a_base[i] <= 32'd0;
				a_desc[i] <= 21'd0;
				a_div[i] <= 8'd0;
			end
		end else if (st_we) begin
			if (st_idx == S_FIRST_INSTANCE)
				s_finst <= st_wdata;
			if (s_attr && !s_off[0])
				a_base[s_off[4:1]] <= st_wdata;
			if (s_attr && s_off[0]) begin
				a_desc[s_off[4:1]] <= st_wdata[20:0];
				a_div[s_off[4:1]] <= st_wdata[31:24];
			end
			if (st_idx[8:4] == S_ATTR_DST[8:4])
				en[st_idx[3:0]] <= st_wdata[7:0] != 8'd0;
		end

	localparam [3:0] ST_IDLE = 4'd0, ST_ELEM = 4'd1, ST_DIV = 4'd2, ST_MUL = 4'd3,
		ST_PLAN = 4'd4, ST_REQ = 4'd5, ST_DATA = 4'd6, ST_EMIT = 4'd7, ST_NONE = 4'd8;
	reg [3:0] st;

	/* The vertex. */
	reg [31:0] v_idx, v_inst;
	reg [4:0] v_lane;
	reg v_last;
	reg [15:0] rem;	/* enabled attributes not yet sent */

	/* The attribute: the lowest bit of rem. */
	reg [3:0] k;
	always @(*) begin
		k = 4'd0;
		for (i = 15; i >= 0; i = i - 1)
			if (rem[i])
				/* verilator lint_off WIDTHTRUNC */
				k = i;
				/* verilator lint_on WIDTHTRUNC */
	end
	wire [15:0] rem_next = rem & ~(16'd1 << k);
	wire [15:0] stride = a_desc[k][15:0];
	wire [3:0] fmt = a_desc[k][19:16];
	wire per_inst = a_desc[k][20];
	wire [7:0] div = a_div[k];

	/* Bytes of a format (design §2.3 ATTR_DESC[19:16]; reserved: 4). */
	reg [4:0] size;
	always @(*)
		case (fmt)
		4'd1, 4'd7, 4'd9: size = 5'd8;
		4'd2: size = 5'd12;
		4'd3: size = 5'd16;
		default: size = 5'd4;
		endcase

	/* Per-instance element: divider with a one-entry memo. */
	wire [31:0] num = v_inst - s_finst;
	reg m_v;
	reg [31:0] m_num, m_q;
	reg [7:0] m_div;
	reg [31:0] d_n;
	reg [30:0] d_q;
	reg [7:0] d_r;
	reg [4:0] d_cnt;
	wire [8:0] d_rs = {d_r, d_n[31]};
	wire d_ge = d_rs >= {1'b0, div};

	reg [31:0] elem;
	reg [31:0] addr;

	/* Two line entries. */
	reg [LA_W-1:0] e_tag0, e_tag1;
	reg [LB-1:0] e_dat0, e_dat1;
	reg [1:0] e_v;
	reg rr;	/* the next victim */
	reg sel1, sel2, miss1, miss2;
	wire [LA_W-1:0] l1 = addr[ADDR_W-1:LINE_SHIFT];
	wire [LA_W-1:0] l2 = l1 + {{(LA_W-1){1'b0}}, 1'b1};
	wire [LINE_SHIFT-1:0] off = addr[LINE_SHIFT-1:0];
	/* off + size <= 2 * LINE_BYTES - 1: the line is crossed when the sum is above LINE_BYTES. */
	wire [LINE_SHIFT:0] osum = {1'b0, off} + {{(LINE_SHIFT-4){1'b0}}, size};
	wire xline = osum[LINE_SHIFT] && osum[LINE_SHIFT-1:0] != {LINE_SHIFT{1'b0}};
	wire h1_0 = e_v[0] && e_tag0 == l1, h1_1 = e_v[1] && e_tag1 == l1;
	wire h2_0 = e_v[0] && e_tag0 == l2, h2_1 = e_v[1] && e_tag1 == l2;

	reg rq_pend, rq_tag;
	reg [LA_W-1:0] rq_line;
	assign req_valid = rq_pend;
	assign req_write = 1'b0;
	assign req_line = rq_line;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = {7'd0, rq_tag};
	wire rd_rsp = rsp_valid && !rsp_write;

	wire [2*LB-1:0] pair = {sel2 ? e_dat1 : e_dat0, sel1 ? e_dat1 : e_dat0};
	wire [2*LB-1:0] pair_sh = pair >> {off, 3'b000};

	assign vb_ready = st == ST_IDLE;
	assign af_valid = st == ST_EMIT || st == ST_NONE;
	assign af_attr = st == ST_NONE ? 4'd0 : k;
	assign af_lane = v_lane;
	assign af_raw = st == ST_NONE ? 128'd0 : pair_sh[127:0];
	assign af_last = v_last && (st == ST_NONE || rem_next == 16'd0);
	assign busy = st != ST_IDLE;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= ST_IDLE;
			e_v <= 2'b00;
			rr <= 1'b0;
			m_v <= 1'b0;
			rq_pend <= 1'b0;
		end else begin
			if (rd_rsp) begin
				if (rsp_tag[0])
					e_dat1 <= rsp_error ? {LB{1'b0}} : rsp_rdata;
				else
					e_dat0 <= rsp_error ? {LB{1'b0}} : rsp_rdata;
				e_v[rsp_tag[0]] <= 1'b1;
			end
			case (st)
			ST_IDLE:
				if (vb_valid) begin
					v_idx <= vb_index;
					v_inst <= vb_inst;
					v_lane <= vb_lane;
					v_last <= vb_last;
					rem <= en;
					if (en != 16'd0)
						st <= ST_ELEM;
					else if (vb_last)
						st <= ST_NONE;
				end
			ST_ELEM:
				if (!per_inst) begin
					elem <= v_idx;
					st <= ST_MUL;
				end else if (div == 8'd0) begin
					elem <= s_finst;
					st <= ST_MUL;
				end else if (div == 8'd1) begin
					elem <= v_inst;
					st <= ST_MUL;
				end else if (m_v && m_num == num && m_div == div) begin
					elem <= s_finst + m_q;
					st <= ST_MUL;
				end else begin
					d_n <= num;
					d_q <= 31'd0;
					d_r <= 8'd0;
					d_cnt <= 5'd0;
					st <= ST_DIV;
				end
			ST_DIV: begin
				/* One quotient bit per cycle, from bit 31. */
				d_r <= d_ge ? d_rs[7:0] - div : d_rs[7:0];
				d_q <= {d_q[29:0], d_ge};
				d_n <= {d_n[30:0], 1'b0};
				d_cnt <= d_cnt + 5'd1;
				if (d_cnt == 5'd31) begin
					m_v <= 1'b1;
					m_num <= num;
					m_div <= div;
					m_q <= {d_q[30:0], d_ge};
					elem <= s_finst + {d_q[30:0], d_ge};
					st <= ST_MUL;
				end
			end
			ST_MUL: begin
				addr <= a_base[k] + elem * {16'd0, stride};
				st <= ST_PLAN;
			end
			ST_PLAN: begin
				/* Choose the entries of line 1 (and line 2 when crossing). */
				miss1 <= !h1_0 && !h1_1;
				miss2 <= xline && !h2_0 && !h2_1;
				if (h1_0 || h1_1)
					sel1 <= h1_1;
				else if (xline && (h2_0 || h2_1))
					sel1 <= !h2_1;
				else
					sel1 <= xline ? 1'b0 : rr;
				if (h2_0 || h2_1)
					sel2 <= h2_1;
				else if (h1_0 || h1_1)
					sel2 <= !h1_1;
				else
					sel2 <= 1'b1;
				if (!h1_0 && !h1_1 && !xline)
					rr <= !rr;
				st <= ST_REQ;
			end
			ST_REQ:
				/* The misses, one request at a time. */
				if (rq_pend) begin
					if (req_ready) begin
						rq_pend <= 1'b0;
						if (miss1)
							miss1 <= 1'b0;
						else
							miss2 <= 1'b0;
					end
				end else if (miss1 || miss2) begin
					rq_pend <= 1'b1;
					rq_tag <= miss1 ? sel1 : sel2;
					rq_line <= miss1 ? l1 : l2;
					e_v[miss1 ? sel1 : sel2] <= 1'b0;
					if (miss1 ? sel1 : sel2)
						e_tag1 <= miss1 ? l1 : l2;
					else
						e_tag0 <= miss1 ? l1 : l2;
				end else
					st <= ST_DATA;
			ST_DATA:
				if (e_v[sel1] && (!xline || e_v[sel2]))
					st <= ST_EMIT;
			ST_EMIT:
				if (af_ready) begin
					rem <= rem_next;
					if (rem_next != 16'd0)
						st <= ST_ELEM;
					else begin
						st <= ST_IDLE;
						if (v_last)
							e_v <= 2'b00;
					end
				end
			default:
				if (af_ready) begin
					st <= ST_IDLE;
					e_v <= 2'b00;
				end
			endcase
		end
	end

	wire unused_ok = &{1'b0, rsp_tag[7:1], s_off[8:5], pair_sh[2*LB-1:128]};
endmodule

`default_nettype wire
