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
 * format (4..16 bytes, any byte alignment; with ATTR_DST[k][31:24] the
 * VkFormat's 1..16 bytes, atg_fmt_info).  ATTR_LIMIT[k] (0x1D0 + k): with
 * [31], an attribute whose bytes pass [30:0] (stride * element + size,
 * computed without overflow) is not read and goes out with af_oob.  The
 * bytes come from two line entries (fully associative, kept until the
 * warp's last attribute: the vertex buffers do not change under a draw);
 * an attribute that crosses a line uses both.  Misses are read one request at a time (tag = entry,
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
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
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
	output wire af_oob,
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
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;

	/* STATE (design §2.3): FIRST_INSTANCE 0x027, ATTR[k]_BASE 0x030 + 2k,
	 * ATTR[k]_DESC 0x031 + 2k, ATTR_DST[k] 0x1C0 + k, ATTR_LIMIT[k] 0x1D0 + k. */

	reg [31:0] s_finst;
	reg [31:0] a_base [0:15];
	reg [20:0] a_desc [0:15];	/* DESC[20:0]: stride, format, per-instance */
	reg [7:0] a_div [0:15];	/* DESC[31:24] */
	reg [15:0] en;
	reg [7:0] a_vk [0:15];	/* ATTR_DST[31:24]: the VkFormat, 0 = DESC[19:16] */
	reg [31:0] a_lim [0:15];
	wire [8:0] s_off;
	wire s_off_bo_unused, num_bo_unused, bend_co_unused, l2_co_unused, osum_co_unused, el_co_unused, ad_co_unused;	/* not used */

	/* The STATE index's place in the attribute range. */
	am_sub #(.W(9)) soff (.a(st_idx), .b(GHCI_S_ATTR), .bi(1'b0), .d(s_off), .bo(s_off_bo_unused));
	wire s_attr = st_idx >= GHCI_S_ATTR && st_idx < GHCI_S_ATTR + 9'd32;
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			s_finst <= 32'd0;
			en <= 16'd0;
			for (i = 0; i < 16; i = i + 1) begin
				a_base[i] <= 32'd0;
				a_desc[i] <= 21'd0;
				a_div[i] <= 8'd0;
				a_vk[i] <= 8'd0;
				a_lim[i] <= 32'd0;
			end
		end else if (st_we) begin
			if (st_idx == GHCI_S_FIRST_INSTANCE)
				s_finst <= st_wdata;
			if (s_attr && !s_off[0])
				a_base[s_off[4:1]] <= st_wdata;
			if (s_attr && s_off[0]) begin
				a_desc[s_off[4:1]] <= st_wdata[20:0];
				a_div[s_off[4:1]] <= st_wdata[31:24];
			end
			if (st_idx[8:4] == GHCI_S_ATTR_DST[8:4]) begin
				en[st_idx[3:0]] <= st_wdata != 32'd0;
				a_vk[st_idx[3:0]] <= st_wdata[31:24];
			end
			if (st_idx[8:4] == GHCI_S_ATTR_LIMIT[8:4])
				a_lim[st_idx[3:0]] <= st_wdata;
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

	/* Bytes of a format (design §2.3 ATTR_DESC[19:16]; reserved: 4), or of
	 * the VkFormat (a value without an entry, or a compressed block: 4). */
	wire [7:0] vk = a_vk[k];
	wire [67:0] vk_inf = atg_fmt_info(vk);
	reg [4:0] size;
	always @(*)
		if (vk != 8'd0)
			size = vk_inf[0] && !vk_inf[14] ? vk_inf[5:1] : 5'd4;
		else
			case (fmt)
			4'd1, 4'd7, 4'd9: size = 5'd8;
			4'd2: size = 5'd12;
			4'd3: size = 5'd16;
			default: size = 5'd4;
			endcase
	wire [31:0] lim = a_lim[k];

	/* Per-instance element: the instance less FIRST_INSTANCE, divided, with a one-entry memo. */
	wire [31:0] num;
	reg m_v;
	reg [31:0] m_num, m_q;
	reg [7:0] m_div;
	reg d_start;
	wire d_busy_unused, d_done;
	wire [31:0] d_q, d_r_unused;

	am_sub #(.W(32)) nsub (.a(v_inst), .b(s_finst), .bi(1'b0), .d(num), .bo(num_bo_unused));
	am_div #(.W(32), .CW(6)) dv (
		.clk(clk), .rst_n(rst_n), .start(d_start), .a(num), .b({24'd0, div}), .busy(d_busy_unused),
		.done(d_done), .q(d_q), .r(d_r_unused)
	);

	reg [31:0] elem;
	reg [31:0] addr;
	reg [47:0] boff;	/* stride * element, the attribute's offset in its buffer */
	reg oob;
	/* The attribute's end, offset + size, in 49 bits: it cannot wrap. */
	wire [48:0] bend;

	am_add #(.W(49)) bnd (.a({1'b0, boff}), .b({44'd0, size}), .ci(1'b0), .s(bend), .co(bend_co_unused));
`ifdef MUT_ATTR_LIMIT_GE
	wire past = bend >= {18'd0, lim[30:0]};
`else
	wire past = bend > {18'd0, lim[30:0]};
`endif

	/*
	 * Multi-stream line buffer (Phase 032):
	 * 4 streams (Position, Normal, Color, TexCoord, etc. mapped as s = k[1:0]),
	 * 8 entries per stream (32 entries total, 1 KiB total).
	 * Eliminates cross-attribute buffer thrashing and read starvation.
	 */
	reg [LA_W-1:0] s_tag [0:31];
	reg [LB-1:0]   s_dat [0:31];
	reg [31:0]     s_val;
	reg [31:0]     s_pnd;
	reg [2:0]      s_rr [0:3];

	function [2:0] inc3;
		input [2:0] v;
		case (v)
		3'd0: inc3 = 3'd1;
		3'd1: inc3 = 3'd2;
		3'd2: inc3 = 3'd3;
		3'd3: inc3 = 3'd4;
		3'd4: inc3 = 3'd5;
		3'd5: inc3 = 3'd6;
		3'd6: inc3 = 3'd7;
		default: inc3 = 3'd0;
		endcase
	endfunction

	function [7:0] dec8;
		input [2:0] idx;
		case (idx)
		3'd0: dec8 = 8'b00000001;
		3'd1: dec8 = 8'b00000010;
		3'd2: dec8 = 8'b00000100;
		3'd3: dec8 = 8'b00001000;
		3'd4: dec8 = 8'b00010000;
		3'd5: dec8 = 8'b00100000;
		3'd6: dec8 = 8'b01000000;
		3'd7: dec8 = 8'b10000000;
		default: dec8 = 8'b00000000;
		endcase
	endfunction

	function [2:0] prio8;
		input [7:0] m;
		casez (m)
		8'b???????1: prio8 = 3'd0;
		8'b??????10: prio8 = 3'd1;
		8'b?????100: prio8 = 3'd2;
		8'b????1000: prio8 = 3'd3;
		8'b???10000: prio8 = 3'd4;
		8'b??100000: prio8 = 3'd5;
		8'b?1000000: prio8 = 3'd6;
		8'b10000000: prio8 = 3'd7;
		default: prio8 = 3'd0;
		endcase
	endfunction

	wire [1:0] s = k[1:0];
	wire [LA_W-1:0] l1 = addr[ADDR_W-1:LINE_SHIFT];
	wire [LA_W-1:0] l2;	/* the next line */

	am_add #(.W(LA_W)) nl (.a(l1), .b({LA_W{1'b0}}), .ci(1'b1), .s(l2), .co(l2_co_unused));
	wire [LINE_SHIFT-1:0] off = addr[LINE_SHIFT-1:0];
	/* off + size <= 2 * LINE_BYTES - 1: the line is crossed when the sum is above LINE_BYTES. */
	wire [LINE_SHIFT:0] osum;

	am_add #(.W(LINE_SHIFT + 1)) os (.a({1'b0, off}), .b({{(LINE_SHIFT-4){1'b0}}, size}),
		.ci(1'b0), .s(osum), .co(osum_co_unused));
	wire xline = osum[LINE_SHIFT] && osum[LINE_SHIFT-1:0] != {LINE_SHIFT{1'b0}};

	/* Tag match for all 32 entries */
	wire [31:0] tag_m1, tag_m2;
	genvar gi;
	generate
		for (gi = 0; gi < 32; gi = gi + 1) begin: g_tag_match
			assign tag_m1[gi] = s_tag[gi] == l1;
			assign tag_m2[gi] = s_tag[gi] == l2;
		end
	endgenerate

	wire [4:0] sb = {s, 3'b000};
	wire [7:0] s_val_8  = s_val[sb +: 8];
	wire [7:0] s_pnd_8  = s_pnd[sb +: 8];
	wire [7:0] tag_m1_8 = tag_m1[sb +: 8];
	wire [7:0] tag_m2_8 = tag_m2[sb +: 8];

	wire [7:0] hit1_mask = s_val_8 & tag_m1_8;
	wire [7:0] pnd1_mask = s_pnd_8 & tag_m1_8;
	wire [7:0] hit2_mask = s_val_8 & tag_m2_8;
	wire [7:0] pnd2_mask = s_pnd_8 & tag_m2_8;
	wire [7:0] free_mask = ~(s_val_8 | s_pnd_8);

	wire h1_hit = |hit1_mask;
	wire p1_pnd = |pnd1_mask;
	wire h2_hit = |hit2_mask;
	wire p2_pnd = |pnd2_mask;

	wire match1 = |(hit1_mask | pnd1_mask);
	wire [2:0] m1_idx = prio8(hit1_mask | pnd1_mask);
	wire match2 = |(hit2_mask | pnd2_mask);
	wire [2:0] m2_idx = prio8(hit2_mask | pnd2_mask);

	wire [7:0] prot1 = match1 ? dec8(m1_idx) : 8'd0;
	wire [7:0] prot2 = match2 ? dec8(m2_idx) : 8'd0;
	wire [7:0] free_for_1 = free_mask & ~prot2;
	wire [7:0] free_for_2 = free_mask & ~prot1;

	wire [2:0] rr0 = s_rr[s];
	wire [2:0] rr1 = inc3(rr0);
	wire [2:0] rr2 = inc3(rr1);

	wire [2:0] vic1 = (rr0 == m2_idx && match2) ? rr1 : rr0;
	wire [2:0] vic2 = (rr0 == m1_idx && match1) ? rr1 :
	                  ((vic1 == rr0) ? rr1 : rr2);

	wire [2:0] sel1_calc = match1 ? m1_idx : (|free_for_1 ? prio8(free_for_1) : vic1);
	wire [7:0] free_for_2_adj = free_for_2 & ~dec8(sel1_calc);
	wire [2:0] sel2_calc = match2 ? m2_idx :
		(|free_for_2_adj ? prio8(free_for_2_adj) :
		((vic2 == sel1_calc) ? inc3(vic2) : vic2));

	reg [2:0] sel1, sel2;
	reg miss1, miss2;

	reg rq_pend;
	reg [7:0] rq_tag;
	reg [LA_W-1:0] rq_line;
	assign req_valid = rq_pend;
	assign req_write = 1'b0;
	assign req_line = rq_line;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = rq_tag;
	wire rd_rsp = rsp_valid && !rsp_write;

	wire [4:0] rsp_idx = {rsp_tag[4:3], rsp_tag[2:0]};
	wire [4:0] e_sel1 = {s, sel1};
	wire [4:0] e_sel2 = {s, sel2};
	wire [4:0] miss_idx = {s, miss1 ? sel1 : sel2};

	wire [2*LB-1:0] pair = {s_dat[e_sel2], s_dat[e_sel1]};
	wire [2*LB-1:0] pair_sh;

	/* The attribute's bytes from the pair of lines. */
	am_shift #(.W(2 * LB), .SW(LINE_SHIFT + 3)) ps (.a(pair), .amt({off, 3'b000}), .left(1'b0),
		.arith(1'b0), .y(pair_sh));

	/*
	 * FIRST_INSTANCE plus the element: the memo's quotient (ELEM) or the
	 * division's (DIV), one adder; the element times the stride, one
	 * multiplier, for the offset and the address.
	 */
	wire [31:0] el_s;
	wire [47:0] el_x;
	wire [31:0] ad_s;

	am_add #(.W(32)) el (.a(s_finst), .b(st == ST_DIV ? d_q : m_q), .ci(1'b0), .s(el_s),
		.co(el_co_unused));
	am_mul #(.AW(32), .BW(16), .SIGNED(0), .LAT(0)) ml (.clk(clk), .en(1'b1), .a(elem),
		.b(stride), .p(el_x));
	am_add #(.W(32)) ad (.a(a_base[k]), .b(el_x[31:0]), .ci(1'b0), .s(ad_s), .co(ad_co_unused));

	assign vb_ready = st == ST_IDLE;
	assign af_valid = st == ST_EMIT || st == ST_NONE;
	assign af_attr = st == ST_NONE ? 4'd0 : k;
	assign af_lane = v_lane;
	assign af_raw = st == ST_NONE || oob ? 128'd0 : pair_sh[127:0];
	assign af_oob = st == ST_EMIT && oob;
	assign af_last = v_last && (st == ST_NONE || rem_next == 16'd0);
	assign busy = st != ST_IDLE;

	integer si, sei;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= ST_IDLE;
			s_val <= 32'd0;
			s_pnd <= 32'd0;
			for (si = 0; si < 4; si = si + 1)
				s_rr[si] <= 3'd0;
			for (sei = 0; sei < 32; sei = sei + 1) begin
				s_tag[sei] <= {LA_W{1'b0}};
				s_dat[sei] <= {LB{1'b0}};
			end
			m_v <= 1'b0;
			rq_pend <= 1'b0;
			oob <= 1'b0;
			d_start <= 1'b0;
			sel1 <= 3'd0;
			sel2 <= 3'd0;
			miss1 <= 1'b0;
			miss2 <= 1'b0;
		end else begin
			d_start <= 1'b0;
			if (rd_rsp) begin
				s_dat[rsp_idx] <= rsp_error ? {LB{1'b0}} : rsp_rdata;
				s_val[rsp_idx] <= 1'b1;
				s_pnd[rsp_idx] <= 1'b0;
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
					elem <= el_s;
					st <= ST_MUL;
				end else begin
					d_start <= 1'b1;
					st <= ST_DIV;
				end
			ST_DIV:
				/* am_div: one quotient bit per cycle; done with the quotient. */
				if (d_done) begin
					m_v <= 1'b1;
					m_num <= num;
					m_div <= div;
					m_q <= d_q;
					elem <= el_s;
					st <= ST_MUL;
				end
			ST_MUL: begin
				boff <= el_x;
				addr <= ad_s;
				st <= ST_PLAN;
			end
			ST_PLAN: begin
				/* Outside ATTR_LIMIT: no read, no entry changes. */
				oob <= lim[31] && past;
				if (lim[31] && past)
					st <= ST_EMIT;
				else begin
					/* Choose entries for line 1 and line 2 */
					sel1 <= sel1_calc;
					sel2 <= sel2_calc;
					miss1 <= !h1_hit && !p1_pnd;
					miss2 <= xline && !h2_hit && !p2_pnd;

					if (h1_hit && (!xline || h2_hit)) begin
						/* Full cache hit: immediate emit! */
						st <= ST_EMIT;
					end else if (!(!h1_hit && !p1_pnd) && !(xline && !h2_hit && !p2_pnd)) begin
						/* Already pending in flight: wait in DATA */
						st <= ST_DATA;
					end else begin
						/* Issue missing read requests */
						st <= ST_REQ;
					end
				end
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
					rq_tag <= {3'd0, s, miss1 ? sel1 : sel2};
					rq_line <= miss1 ? l1 : l2;
					s_pnd[miss_idx] <= 1'b1;
					s_tag[miss_idx] <= miss1 ? l1 : l2;
					s_val[miss_idx] <= 1'b0;
					if (miss1 ? (sel1 == rr0) : (sel2 == rr0))
						s_rr[s] <= rr1;
				end else
					st <= ST_DATA;
			ST_DATA:
				if (s_val[e_sel1] && (!xline || s_val[e_sel2]))
					st <= ST_EMIT;
			ST_EMIT:
				if (af_ready) begin
					rem <= rem_next;
					if (rem_next != 16'd0)
						st <= ST_ELEM;
					else begin
						st <= ST_IDLE;
						if (v_last) begin
							s_val <= 32'd0;
							s_pnd <= 32'd0;
						end
					end
				end
			default:
				if (af_ready) begin
					st <= ST_IDLE;
					if (v_last) begin
						s_val <= 32'd0;
						s_pnd <= 32'd0;
					end
				end
			endcase
		end
	end

	wire unused_ok = &{1'b0, rsp_tag[7:5], s_off[8:5], pair_sh[2*LB-1:128], vk_inf[67:15],
		vk_inf[13:6]};
endmodule

`default_nettype wire
