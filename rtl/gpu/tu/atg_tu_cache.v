/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cache: 4-way Set-Associative, 4-bank L1 texture cache.
 *
 * 8 KiB (KC705), 4 ways, 4 banks. 4 texels per cycle concurrent read
 * with zero bank conflicts for 2x2 bilinear footprints.
 * Tree-PLRU eviction policy per set.
 * Invalidate via inv (INVALIDATE[1] / DRAW).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cache #(
	parameter ADDR_W     = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter TC_BYTES   = 8192,	/* Size in bytes: 8 KiB (4 ways) */
	parameter WAYS       = 4,
	/* verilator lint_off UNUSEDPARAM */
	parameter NBANKS     = 4
	/* verilator lint_on UNUSEDPARAM */
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
	localparam NSETS = NL / WAYS;
	localparam IW = $clog2(NSETS);
	localparam TW = ADDR_W - LINE_SHIFT - IW;
	localparam WW = LINE_SHIFT - 2;	/* word in the line */

	localparam [2:0] IDLE       = 3'd0,
	                 LANE_CHECK = 3'd1,
	                 MREQ       = 3'd2,
	                 MWAIT      = 3'd3,
	                 LANE_READ  = 3'd4,
	                 OUT        = 3'd5;

	/* 4 Banks of RAM arrays (Simple Dual Port BRAM inference) */
	reg [LB-1:0] data_b0 [0:NSETS-1][0:WAYS-1];
	reg [LB-1:0] data_b1 [0:NSETS-1][0:WAYS-1];
	reg [LB-1:0] data_b2 [0:NSETS-1][0:WAYS-1];
	reg [LB-1:0] data_b3 [0:NSETS-1][0:WAYS-1];

	reg [TW-1:0] tags [0:NSETS-1][0:WAYS-1];
	reg [WAYS-1:0] vld [0:NSETS-1];
	reg [2:0] plru [0:NSETS-1];

	reg [2:0] st;
	reg [1:0] lane;
	reg drop;
	reg [ADDR_W-LINE_SHIFT-1:0] mline;
	reg [1:0] miss_slot;
	reg [3:0] slot_err;
	reg [511:0] ta_addr_q;

	/* Registered BRAM outputs for the 4 banks */
	reg [LB-1:0] bank_q0;
	reg [LB-1:0] bank_q1;
	reg [LB-1:0] bank_q2;
	reg [LB-1:0] bank_q3;

	/* Quad controls */
	wire bil = tc_ctl[0];
	wire h565 = tc_ctl[19];
	wire [1:0] tsz = tc_ctl[24:23];
	wire [1:0] lsl = (tc_ctl[26:25] == 2'd1) ? 2'd1 :
	                 (tc_ctl[26:25] == 2'd2) ? 2'd3 : 2'd0;

	/* Border raw texel by format ({ctl[8], ctl[1]}) and class (ctl[7:6]) */
	wire [31:0] bwhite = h565 ? 32'h0000FFFF :
	                     !tc_ctl[8] ? 32'hFFFFFFFF :
	                     tc_ctl[1]  ? 32'h3F800000 : 32'h00FFFFFF;
	wire [31:0] braw = (tc_ctl[7:6] == 2'd2) ? bwhite :
	                   (tc_ctl[7:6] == 2'd1 && !tc_ctl[8] && !h565) ? 32'hFF000000 : 32'd0;

	/* 4 slot addresses for current lane */
	wire [ADDR_W-1:0] a0 = ta_addr_q[{lane, 2'b00, 5'b00000} +: 32];
	wire [ADDR_W-1:0] a1 = ta_addr_q[{lane, 2'b01, 5'b00000} +: 32];
	wire [ADDR_W-1:0] a2 = ta_addr_q[{lane, 2'b10, 5'b00000} +: 32];
	wire [ADDR_W-1:0] a3 = ta_addr_q[{lane, 2'b11, 5'b00000} +: 32];

	wire border0 = tc_bord[{lane, 2'b00}];
	wire border1 = tc_bord[{lane, 2'b01}];
	wire border2 = tc_bord[{lane, 2'b10}];
	wire border3 = tc_bord[{lane, 2'b11}];

	wire [WW-1:0] pw0 = a0[2 +: WW];
	wire [WW-1:0] pw1 = a1[2 +: WW];
	wire [WW-1:0] pw2 = a2[2 +: WW];
	wire [WW-1:0] pw3 = a3[2 +: WW];

	wire [1:0] pby0 = a0[1:0];
	wire [1:0] pby1 = a1[1:0];
	wire [1:0] pby2 = a2[1:0];
	wire [1:0] pby3 = a3[1:0];

	wire [3:0] use_slot;
	assign use_slot[0] = tc_mask[lane];
	assign use_slot[1] = tc_mask[lane] && (bil || (tc_ctl[26:25] != 2'd0));
	assign use_slot[2] = tc_mask[lane] && (bil || (tc_ctl[26:25] == 2'd2));
	assign use_slot[3] = tc_mask[lane] && (bil || (tc_ctl[26:25] == 2'd2));

	/* Set indices and tags for the 4 slots */
	wire [IW-1:0] s0_set = a0[LINE_SHIFT +: IW];
	wire [IW-1:0] s1_set = a1[LINE_SHIFT +: IW];
	wire [IW-1:0] s2_set = a2[LINE_SHIFT +: IW];
	wire [IW-1:0] s3_set = a3[LINE_SHIFT +: IW];

	wire [TW-1:0] s0_tag = a0[ADDR_W-1 -: TW];
	wire [TW-1:0] s1_tag = a1[ADDR_W-1 -: TW];
	wire [TW-1:0] s2_tag = a2[ADDR_W-1 -: TW];
	wire [TW-1:0] s3_tag = a3[ADDR_W-1 -: TW];

	/* Tag hit detection across 4 ways */
	wire s0_hit0 = vld[s0_set][0] && (tags[s0_set][0] == s0_tag);
	wire s0_hit1 = vld[s0_set][1] && (tags[s0_set][1] == s0_tag);
	wire s0_hit2 = vld[s0_set][2] && (tags[s0_set][2] == s0_tag);
	wire s0_hit3 = vld[s0_set][3] && (tags[s0_set][3] == s0_tag);
	wire s0_hit  = s0_hit0 || s0_hit1 || s0_hit2 || s0_hit3;
	wire [1:0] s0_way = s0_hit3 ? 2'd3 : s0_hit2 ? 2'd2 : s0_hit1 ? 2'd1 : 2'd0;

	wire s1_hit0 = vld[s1_set][0] && (tags[s1_set][0] == s1_tag);
	wire s1_hit1 = vld[s1_set][1] && (tags[s1_set][1] == s1_tag);
	wire s1_hit2 = vld[s1_set][2] && (tags[s1_set][2] == s1_tag);
	wire s1_hit3 = vld[s1_set][3] && (tags[s1_set][3] == s1_tag);
	wire s1_hit  = s1_hit0 || s1_hit1 || s1_hit2 || s1_hit3;
	wire [1:0] s1_way = s1_hit3 ? 2'd3 : s1_hit2 ? 2'd2 : s1_hit1 ? 2'd1 : 2'd0;

	wire s2_hit0 = vld[s2_set][0] && (tags[s2_set][0] == s2_tag);
	wire s2_hit1 = vld[s2_set][1] && (tags[s2_set][1] == s2_tag);
	wire s2_hit2 = vld[s2_set][2] && (tags[s2_set][2] == s2_tag);
	wire s2_hit3 = vld[s2_set][3] && (tags[s2_set][3] == s2_tag);
	wire s2_hit  = s2_hit0 || s2_hit1 || s2_hit2 || s2_hit3;
	wire [1:0] s2_way = s2_hit3 ? 2'd3 : s2_hit2 ? 2'd2 : s2_hit1 ? 2'd1 : 2'd0;

	wire s3_hit0 = vld[s3_set][0] && (tags[s3_set][0] == s3_tag);
	wire s3_hit1 = vld[s3_set][1] && (tags[s3_set][1] == s3_tag);
	wire s3_hit2 = vld[s3_set][2] && (tags[s3_set][2] == s3_tag);
	wire s3_hit3 = vld[s3_set][3] && (tags[s3_set][3] == s3_tag);
	wire s3_hit  = s3_hit0 || s3_hit1 || s3_hit2 || s3_hit3;
	wire [1:0] s3_way = s3_hit3 ? 2'd3 : s3_hit2 ? 2'd2 : s3_hit1 ? 2'd1 : 2'd0;

	/* Miss determination */
	wire s0_miss = use_slot[0] && !border0 && !s0_hit && !slot_err[0];
	wire s1_miss = use_slot[1] && !border1 && !s1_hit && !slot_err[1];
	wire s2_miss = use_slot[2] && !border2 && !s2_hit && !slot_err[2];
	wire s3_miss = use_slot[3] && !border3 && !s3_hit && !slot_err[3];
	wire any_miss = s0_miss || s1_miss || s2_miss || s3_miss;

	wire [1:0] miss_slot_next = s0_miss ? 2'd0 :
	                            s1_miss ? 2'd1 :
	                            s2_miss ? 2'd2 : 2'd3;

	wire [ADDR_W-LINE_SHIFT-1:0] miss_line_next =
		(miss_slot_next == 2'd0) ? a0[ADDR_W-1:LINE_SHIFT] :
		(miss_slot_next == 2'd1) ? a1[ADDR_W-1:LINE_SHIFT] :
		(miss_slot_next == 2'd2) ? a2[ADDR_W-1:LINE_SHIFT] :
		                           a3[ADDR_W-1:LINE_SHIFT];

	/* 4 Banks read concurrently for the 4 slots */
	wire [IW-1:0] b0_set = s0_set;
	wire [1:0]    b0_way = s0_way;
	wire [IW-1:0] b1_set = s1_set;
	wire [1:0]    b1_way = s1_way;
	wire [IW-1:0] b2_set = s2_set;
	wire [1:0]    b2_way = s2_way;
	wire [IW-1:0] b3_set = s3_set;
	wire [1:0]    b3_way = s3_way;

	/* BRAM Read */
	always @(posedge clk) begin
		bank_q0 <= data_b0[b0_set][b0_way];
		bank_q1 <= data_b1[b1_set][b1_way];
		bank_q2 <= data_b2[b2_set][b2_way];
		bank_q3 <= data_b3[b3_set][b3_way];
	end

	/* Crossbar output to slots */
	wire [LB-1:0] slot_line0 = bank_q0;
	wire [LB-1:0] slot_line1 = bank_q1;
	wire [LB-1:0] slot_line2 = bank_q2;
	wire [LB-1:0] slot_line3 = bank_q3;

	/* Function for texel word extraction without arithmetic operators */
	function [31:0] extract_tex;
		input [LB-1:0] line_in;
		input [WW-1:0] w_idx;
		input [1:0] b_idx;
		input pb;
		input [31:0] braw_val;
		input [1:0] tsz_val;
		input h565_val;
		reg [31:0] wd;
		reg [15:0] hw;
		reg [7:0]  by;
		begin
			wd = line_in[{w_idx, 5'b00000} +: 32];
			hw = b_idx[1] ? wd[31:16] : wd[15:0];
			case (b_idx)
			2'd0: by = wd[7:0];
			2'd1: by = wd[15:8];
			2'd2: by = wd[23:16];
			2'd3: by = wd[31:24];
			endcase
			if (pb)
				extract_tex = braw_val;
			else if (tsz_val == 2'd2)
				extract_tex = {24'd0, by};
			else if (h565_val || tsz_val == 2'd1)
				extract_tex = {16'd0, hw};
			else
				extract_tex = wd;
		end
	endfunction

	wire [31:0] tex0 = extract_tex(slot_line0, pw0, pby0, border0, braw, tsz, h565);
	wire [31:0] tex1 = extract_tex(slot_line1, pw1, pby1, border1, braw, tsz, h565);
	wire [31:0] tex2 = extract_tex(slot_line2, pw2, pby2, border2, braw, tsz, h565);
	wire [31:0] tex3 = extract_tex(slot_line3, pw3, pby3, border3, braw, tsz, h565);

	/* Tree-PLRU helper functions */
	function [1:0] get_victim;
		input [3:0] v;
		input [2:0] p;
		begin
			if (!v[0]) get_victim = 2'd0;
			else if (!v[1]) get_victim = 2'd1;
			else if (!v[2]) get_victim = 2'd2;
			else if (!v[3]) get_victim = 2'd3;
			else if (!p[0]) get_victim = p[1] ? 2'd1 : 2'd0;
			else get_victim = p[2] ? 2'd3 : 2'd2;
		end
	endfunction

	function [2:0] update_plru;
		input [2:0] p;
		input [1:0] w;
		begin
			case (w)
			2'd0: update_plru = {p[2], 1'b1, 1'b1};
			2'd1: update_plru = {p[2], 1'b0, 1'b1};
			2'd2: update_plru = {1'b1, p[1], 1'b0};
			2'd3: update_plru = {1'b0, p[1], 1'b0};
			default: update_plru = p;
			endcase
		end
	endfunction

	wire [1:0] nxt_lane;
	wire nxt_lane_co_unused;
	am_add #(.W(2)) u_inc_lane (.a(lane), .b(2'd1), .ci(1'b0), .s(nxt_lane), .co(nxt_lane_co_unused));

	assign ta_ready = st == IDLE;
	assign tc_valid = st == OUT;
	assign req_valid = st == MREQ;
	assign req_write = 1'b0;
	assign req_line = mline;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = 8'd0;

	wire [IW-1:0] mline_set = mline[IW-1:0];
	wire [1:0] fill_way = get_victim(vld[mline_set], plru[mline_set]);

	integer j, s_init;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			lane <= 2'd0;
			drop <= 1'b0;
			mline <= {(ADDR_W-LINE_SHIFT){1'b0}};
			miss_slot <= 2'd0;
			slot_err <= 4'd0;
			for (s_init = 0; s_init < NSETS; s_init = s_init + 1) begin
				vld[s_init] <= {WAYS{1'b0}};
				plru[s_init] <= 3'd0;
			end
		end else begin
			case (st)
			IDLE: if (ta_valid) begin
				ta_addr_q <= ta_addr;
				tc_bord <= ta_bord;
				for (j = 0; j < 16; j = j + 1)
					tc_lo[{j[3:0], 1'b0} +: 2] <= ta_addr[{j[3:0], 5'b00000} +: 2];
				tc_wts <= ta_wts;
				tc_tag <= ta_tag;
				tc_mask <= ta_mask;
				tc_ctl <= ta_ctl;
				tc_value <= ta_value;
				tc_last <= ta_last;
				tc_texels <= 512'd0;
				lane <= 2'd0;
				slot_err <= 4'd0;
				st <= ta_ctl[2] ? OUT : LANE_CHECK;
			end
			LANE_CHECK: begin
				if (!tc_mask[lane]) begin
					/* Lane masked out */
					if (lane == 2'd3)
						st <= OUT;
					else begin
						lane <= nxt_lane;
						slot_err <= 4'd0;
					end
				end else if (any_miss) begin
					mline <= miss_line_next;
					miss_slot <= miss_slot_next;
					drop <= 1'b0;
					st <= MREQ;
				end else begin
					/* All active non-border slots HIT: read from 4 banks */
					st <= LANE_READ;
				end
			end
			MREQ: if (req_ready) begin
				st <= MWAIT;
			end
			MWAIT: if (rsp_valid) begin
				if (rsp_error) begin
					/* Error region: texel stays 0, mark slot */
					if (a0[ADDR_W-1:LINE_SHIFT] == mline) slot_err[0] <= 1'b1;
					if (a1[ADDR_W-1:LINE_SHIFT] == mline) slot_err[1] <= 1'b1;
					if (a2[ADDR_W-1:LINE_SHIFT] == mline) slot_err[2] <= 1'b1;
					if (a3[ADDR_W-1:LINE_SHIFT] == mline) slot_err[3] <= 1'b1;
					st <= LANE_CHECK;
				end else begin
					data_b0[mline_set][fill_way] <= rsp_rdata;
					data_b1[mline_set][fill_way] <= rsp_rdata;
					data_b2[mline_set][fill_way] <= rsp_rdata;
					data_b3[mline_set][fill_way] <= rsp_rdata;
					tags[mline_set][fill_way] <= mline[ADDR_W-LINE_SHIFT-1 -: TW];
					vld[mline_set][fill_way] <= !drop && !inv;
					plru[mline_set] <= update_plru(plru[mline_set], fill_way);
					st <= LANE_CHECK;
				end
			end
			LANE_READ: begin
				/* Extract 4 texels from BRAM outputs */
				tc_texels[{lane, 2'b00, 5'b00000} +: 32] <= (use_slot[0] && !slot_err[0]) ? tex0 : 32'd0;
				tc_texels[{lane, 2'b01, 5'b00000} +: 32] <= (use_slot[1] && !slot_err[1]) ? tex1 : 32'd0;
				tc_texels[{lane, 2'b10, 5'b00000} +: 32] <= (use_slot[2] && !slot_err[2]) ? tex2 : 32'd0;
				tc_texels[{lane, 2'b11, 5'b00000} +: 32] <= (use_slot[3] && !slot_err[3]) ? tex3 : 32'd0;

				/* Update Tree-PLRU */
				if (use_slot[0] && !border0 && s0_hit)
					plru[s0_set] <= update_plru(plru[s0_set], s0_way);
				if (use_slot[1] && !border1 && s1_hit && (s1_set != s0_set || !use_slot[0] || border0 || !s0_hit))
					plru[s1_set] <= update_plru(plru[s1_set], s1_way);
				if (use_slot[2] && !border2 && s2_hit &&
				    (s2_set != s0_set || !use_slot[0] || border0 || !s0_hit) &&
				    (s2_set != s1_set || !use_slot[1] || border1 || !s1_hit))
					plru[s2_set] <= update_plru(plru[s2_set], s2_way);
				if (use_slot[3] && !border3 && s3_hit &&
				    (s3_set != s0_set || !use_slot[0] || border0 || !s0_hit) &&
				    (s3_set != s1_set || !use_slot[1] || border1 || !s1_hit) &&
				    (s3_set != s2_set || !use_slot[2] || border2 || !s2_hit))
					plru[s3_set] <= update_plru(plru[s3_set], s3_way);

				slot_err <= 4'd0;
				if (lane == 2'd3)
					st <= OUT;
				else begin
					lane <= nxt_lane;
					st <= LANE_CHECK;
				end
			end
			OUT: if (tc_ready) begin
				st <= IDLE;
			end
			default: st <= IDLE;
			endcase

			if (inv) begin
				for (s_init = 0; s_init < NSETS; s_init = s_init + 1)
					vld[s_init] <= {WAYS{1'b0}};
				drop <= 1'b1;
			end
		end
	end

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, nxt_lane_co_unused,
	                   miss_slot, a0[ADDR_W-1:LINE_SHIFT], lsl};
endmodule

`default_nettype wire
