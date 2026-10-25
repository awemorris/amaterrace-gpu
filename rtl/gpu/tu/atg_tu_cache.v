/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cache: The texture cache: 4 KiB (KC705), lines
 * from the AMB, 16 texels per quad looked up (several per cycle by
 * banking), invalidated by INVALIDATE[1] / DRAW.
 *
 * Direct mapped, TC_BYTES / LINE_BYTES lines, read only.  Blocking (v1):
 * one quad at a time; its slots are looked up one per cycle in the order
 * lane 0 slot 0 .. lane 3 slot 3, only the lanes of ta_mask and, without
 * ta_ctl[0] (bilinear), only slot 0, or slots 0-1 (ta_ctl[26:25] = 1,
 * 8-byte texels) or 0-3 (2, 16-byte texels) (slots not looked up are 0).
 * A miss requests its line (one outstanding), writes it when it comes and
 * looks the slot up again.  A border texel (ta_bord) is not looked up: it
 * is the border colour's raw texel for the format (ta_ctl[8], [1]) and
 * colour class (ta_ctl[7:6]: 0 transparent black, 1 opaque black, 2
 * opaque white): RGBA8/BGRA8 0, 0xFF000000, 0xFFFFFFFF; D24 and D16 0, 0,
 * 0x00FFFFFF; D32F 0, 0, 1.0; RGB565 (ta_ctl[19]) 0, 0, 0xFFFF (the fp32
 * path's filter puts in its own values and ignores these).  A slot is the
 * 32-bit word at its address, or with ta_ctl[24:23] = 1 (2-byte texels)
 * or ta_ctl[19] (RGB565) the half word that address bit 1 selects, with
 * ta_ctl[24:23] = 2 (1-byte texels) the byte that address bits 1:0 select
 * (right-justified, the rest 0); tc_bord passes the border bits on, tc_lo
 * the slots' address bits 1:0 (a compressed block's texel position).  An
 * error response gives the texel 0 and
 * leaves the line invalid.  texsz and the LOD query (ta_ctl[2]) look
 * nothing up.  The quad is then held on tc_* until taken; order is kept.
 * inv clears every line at once;
 * a line whose request was outstanding during inv is not kept (the texel
 * misses again and is requested anew).  See spec/gpu/tu/atg_tu_cache.md.
 *
 * States: IDLE →(ta)→ LOOKUP (one texel a cycle) →(miss)→ MREQ
 * →(req_ready)→ MWAIT →(rsp)→ LOOKUP; LOOKUP →(last)→ DRAIN → OUT
 * →(tc_ready)→ IDLE; IDLE →(texsz)→ OUT.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter TC_BYTES = 4096	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire inv,
	/* From atg_tu_addr */
	input wire ta_valid,
	output wire ta_ready,
	input wire [511:0] ta_addr,
	input wire [15:0] ta_bord,
	input wire [127:0] ta_wts,
	input wire [15:0] ta_tag,
	input wire [3:0] ta_mask,
	input wire [49:0] ta_ctl,
	input wire [127:0] ta_value,
	input wire ta_last,
	/* To atg_tu_filter */
	output wire tc_valid,
	input wire tc_ready,
	output reg [511:0] tc_texels,
	output reg [15:0] tc_bord,
	output reg [31:0] tc_lo,
	output reg [127:0] tc_wts,
	output reg [15:0] tc_tag,
	output reg [3:0] tc_mask,
	output reg [49:0] tc_ctl,
	output reg [127:0] tc_value,
	output reg tc_last,
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
	localparam LB = LINE_BYTES * 8;
	localparam NL = TC_BYTES / LINE_BYTES;
	localparam IW = $clog2(NL);
	localparam TW = ADDR_W - LINE_SHIFT - IW;
	localparam WW = LINE_SHIFT - 2;	/* word in the line */
	localparam [2:0] IDLE = 3'd0, LOOKUP = 3'd1, MREQ = 3'd2, MWAIT = 3'd3, DRAIN = 3'd4,
		OUT = 3'd5;

	reg [LB-1:0] data [0:NL-1];
	reg [TW-1:0] tags [0:NL-1];
	reg [NL-1:0] vld;
	reg [2:0] st;
	reg [3:0] t;	/* {lane, texel} being looked up */
	reg drop;	/* inv while the miss was outstanding */
	reg [ADDR_W-LINE_SHIFT-1:0] mline;
	reg pv;	/* a hit's data arrives (q) this cycle for texel pt, word pw */
	reg pb;	/* ... or texel pt is a border texel */
	reg [3:0] pt;
	reg [WW-1:0] pw;
	reg [1:0] pby;	/* ... and its byte in the word (address bits 1:0) */
	reg [LB-1:0] q;

	reg [511:0] ta_addr_q;

	wire bil = tc_ctl[0];
	wire [ADDR_W-1:0] a = ta_addr_q[t*32 +: ADDR_W];
	wire [IW-1:0] idx = a[LINE_SHIFT +: IW];
	wire [TW-1:0] atag = a[ADDR_W-1 -: TW];
	wire hit = vld[idx] && tags[idx] == atag;
	wire border = tc_bord[t];
	/* The border texel by format (colour, D24, D32F) and colour class. */
	wire h565 = tc_ctl[19];
	wire [31:0] bwhite = h565 ? 32'h0000FFFF : !tc_ctl[8] ? 32'hFFFFFFFF : tc_ctl[1] ? 32'h3F800000 :
		32'h00FFFFFF;
	wire [31:0] braw = tc_ctl[7:6] == 2'd2 ? bwhite :
		tc_ctl[7:6] == 2'd1 && !tc_ctl[8] && !h565 ? 32'hFF000000 : 32'd0;
	/* Is slot t looked up, and the next t after it (16: the quad is done);
	 * the last slot of a lane without bilinear: 0, 1 or 3. */
	wire [1:0] lsl = tc_ctl[26:25] == 2'd1 ? 2'd1 : tc_ctl[26:25] == 2'd2 ? 2'd3 : 2'd0;
	wire use_t = tc_mask[t[3:2]] && (t[1:0] <= lsl || bil);
	wire nlane = !tc_mask[t[3:2]] || (!bil && t[1:0] == lsl);	/* to the next lane's slot 0 */
	wire [4:0] nxt;
	wire nxt_co_unused;
	am_add #(.W(5)) u_nxt (.a(nlane ? {1'b0, t[3:2], 2'b00} : {1'b0, t}), .b(nlane ? 5'd4 : 5'd1),
		.ci(1'b0), .s(nxt), .co(nxt_co_unused));
	wire [1:0] tsz = tc_ctl[24:23];

	assign ta_ready = st == IDLE;
	assign tc_valid = st == OUT;
	assign req_valid = st == MREQ;
	assign req_write = 1'b0;
	assign req_line = mline;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = 8'd0;

	always @(posedge clk)
		q <= data[idx];

	always @(posedge clk)
		if (st == MWAIT && rsp_valid && !rsp_error) begin
			data[mline[IW-1:0]] <= rsp_rdata;
			tags[mline[IW-1:0]] <= mline[ADDR_W-LINE_SHIFT-1 -: TW];
		end

	integer j;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			vld <= {NL{1'b0}};
			pv <= 1'b0;
			drop <= 1'b0;
		end else begin
			pv <= 1'b0;
			if (pv)
				tc_texels[pt*32 +: 32] <= pb ? braw : tsz == 2'd2 ? {24'd0, q[{pw, pby, 3'b000} +: 8]} :
					h565 || tsz == 2'd1 ? {16'd0, q[{pw, pby[1], 4'b0000} +: 16]} : q[pw*32 +: 32];
			case (st)
			IDLE: if (ta_valid) begin
				ta_addr_q <= ta_addr;
				tc_bord <= ta_bord;
				for (j = 0; j < 16; j = j + 1)
					tc_lo[2*j +: 2] <= ta_addr[32*j +: 2];
				tc_wts <= ta_wts;
				tc_tag <= ta_tag;
				tc_mask <= ta_mask;
				tc_ctl <= ta_ctl;
				tc_value <= ta_value;
				tc_last <= ta_last;
				tc_texels <= 512'd0;
				t <= 4'd0;
				st <= ta_ctl[2] ? OUT : LOOKUP;
			end
			LOOKUP:
				if (use_t && !border && !hit) begin
					mline <= a[ADDR_W-1:LINE_SHIFT];
					drop <= 1'b0;
					st <= MREQ;
				end else begin
					if (use_t) begin
						pv <= 1'b1;
						pb <= border;
						pt <= t;
						pw <= a[2 +: WW];
						pby <= a[1:0];
					end
					t <= nxt[3:0];
					if (nxt[4])
						st <= DRAIN;
				end
			MREQ: if (req_ready)
				st <= MWAIT;
			MWAIT: if (rsp_valid) begin
				if (rsp_error) begin
					/* the texel stays 0 */
					t <= nxt[3:0];
					st <= nxt[4] ? DRAIN : LOOKUP;
				end else begin
					vld[mline[IW-1:0]] <= !drop && !inv;
					st <= LOOKUP;
				end
			end
			DRAIN: st <= OUT;
			OUT: if (tc_ready)
				st <= IDLE;
			default: st <= IDLE;
			endcase
			if (inv) begin
				vld <= {NL{1'b0}};
				drop <= 1'b1;
			end
		end
	end

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, ta_addr_q};
endmodule

`default_nettype wire
