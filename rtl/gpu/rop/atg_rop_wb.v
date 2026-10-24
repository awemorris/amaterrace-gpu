/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wb: ROP write-back: a small write-combining buffer of
 * render-target lines; reads the destination line when blending, sends
 * pixels through atg_rop_blend, writes lines back; drains when idle.
 *
 * Two line entries, entry r for row r of the quad (quads have even y, so
 * a line never sits in both).  A miss writes the old line back (its dirty
 * bytes only) and reads the new one when its old pixels are needed (blend
 * on, or a WRITE_MASK without every channel of RT_FORMAT).  After 16 idle
 * cycles the dirty lines are written and both entries emptied (the next
 * draw must not blend with lines another block may have changed); busy
 * stays up until then.  One quad at a time.
 *
 * Multisampling (MS_CTRL[3:0] = 2, docs/ghci.md section 12.11): sample s of
 * pixel x is at (4 x + s) ps of the row, so a quad's row is still one line
 * (2 pixels × 4 samples); the quad goes through atg_rop_blend once per
 * sample s (the lanes whose sample s survived), each pass on the lanes'
 * sample-s pixels.  See spec/gpu/rop/atg_rop_wb.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_wb #(
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
	/* From atg_rop_ds */
	input wire d_valid,
	output wire d_ready,
	input wire [31:0] d_xy,
	input wire [15:0] d_smask,	/* bit 4 l + s: sample s of lane l */
	input wire [511:0] d_color,
	/* atg_rop_blend */
	output reg b_valid,
	output wire [511:0] b_src,
	output wire [127:0] b_dst,
	output wire [3:0] b_mask,
	input wire b_rvalid,
	input wire [127:0] b_pix,
	output wire busy,
	/* AMB client port (design §4.1) */
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] req_line,
	output reg [LINE_BYTES-1:0] req_be,
	output reg [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"
	localparam LA_W = ADDR_W - LINE_SHIFT;

	/* STATE: RT_BASE 0x070, RT_STRIDE 0x071, RT_FORMAT 0x072, BLEND 0x07A, WRITE_MASK 0x07C. */
	reg [31:0] rt_base, rt_stride;
	reg [1:0] fmt;
	reg blend_on;
	reg [3:0] wm;
	reg ms4;
	always @(posedge clk)
		if (!rst_n) begin
			ms4 <= 1'b0;
			rt_base <= 32'd0;
			rt_stride <= 32'd0;
			fmt <= 2'd0;
			blend_on <= 1'b0;
			wm <= 4'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_BASE)
				rt_base <= st_wdata;
			if (st_idx == GHCI_S_RT_STRIDE)
				rt_stride <= st_wdata;
			if (st_idx == GHCI_S_RT_FORMAT)
				fmt <= st_wdata[1:0];
			if (st_idx == GHCI_S_BLEND)
				blend_on <= st_wdata[0];
			if (st_idx == GHCI_S_WRITE_MASK)
				wm <= st_wdata[3:0];
			if (st_idx == GHCI_S_MS_CTRL)
				ms4 <= st_wdata[3:0] == 4'd2;
		end
	wire px16 = fmt == 2'd2;
	wire need_read = blend_on || (px16 ? wm[2:0] != 3'b111 : wm != 4'hF);

	/* The two entries. */
	reg ev [0:1];
	reg [LA_W-1:0] etag [0:1];
	reg [LINE_BYTES*8-1:0] edat [0:1];
	reg [LINE_BYTES-1:0] edirty [0:1];
	wire [LINE_BYTES*8-1:0] edat0 = edat[0], edat1 = edat[1];

	localparam [3:0] S_IDLE = 4'd0, S_ROW = 4'd1, S_LOOK = 4'd2, S_EVW = 4'd3, S_FILL = 4'd4,
		S_BLEND = 4'd5, S_BWAIT = 4'd6, S_FLUSH = 4'd7, S_FLW = 4'd8;
	reg [3:0] st;
	reg r;	/* row / entry */
	reg wait_rsp;
	reg [4:0] idle;
	reg [31:0] xy;
	reg [15:0] mask;
	reg [1:0] sb;	/* the sample of this blend pass */
	wire [3:0] smk = {mask[{2'd3, sb}], mask[{2'd2, sb}], mask[{2'd1, sb}], mask[{2'd0, sb}]};
	reg [511:0] color;
	reg [31:0] addr;
	reg [LINE_SHIFT-1:0] off [0:1];	/* the quad's first pixel in each row's line */
	wire [LINE_SHIFT-1:0] off0 = off[0], off1 = off[1];
	integer l;

	/* The quad's destination pixels and the merge positions. */
	reg [127:0] dst;
	reg [4*LINE_SHIFT-1:0] po;	/* byte offset of lane l at [LINE_SHIFT l] */
	reg [LINE_SHIFT-1:0] pl;
	always @(*)
		for (l = 0; l < 4; l = l + 1) begin
			pl = (l >= 2 ? off1 : off0) +
				((l & 1) != 0 ? (ms4 ? (px16 ? 8 : 16) : (px16 ? 2 : 4)) : 0) +
				(px16 ? {{(LINE_SHIFT-3){1'b0}}, sb, 1'b0} : {{(LINE_SHIFT-4){1'b0}}, sb, 2'b00});
			po[LINE_SHIFT * l +: LINE_SHIFT] = pl;
			dst[32 * l +: 32] = l >= 2 ? edat1[8 * pl +: 32] : edat0[8 * pl +: 32];
			if (px16)
				dst[32 * l + 16 +: 16] = 16'd0;
		end
	assign b_src = color;
	assign b_dst = dst;
	assign b_mask = smk;

	assign d_ready = st == S_IDLE;
	assign busy = st != S_IDLE || ev[0] || ev[1];
	assign req_tag = 8'd0;

	/* One AMB request at a time: rq starts it, the state waits for !req_valid && !wait_rsp. */
	task rq;
		input w;
		input [LA_W-1:0] line;
		input [LINE_BYTES-1:0] be;
		input [LINE_BYTES*8-1:0] data;
		begin
			req_valid <= 1'b1;
			req_write <= w;
			req_line <= line;
			req_be <= be;
			req_wdata <= data;
		end
	endtask

	always @(posedge clk) begin
		b_valid <= 1'b0;
		if (req_valid && req_ready) begin
			req_valid <= 1'b0;
			wait_rsp <= 1'b1;
		end
		if (rsp_valid)
			wait_rsp <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			req_valid <= 1'b0;
			wait_rsp <= 1'b0;
			ev[0] <= 1'b0;
			ev[1] <= 1'b0;
			edirty[0] <= {LINE_BYTES{1'b0}};
			edirty[1] <= {LINE_BYTES{1'b0}};
			idle <= 5'd0;
		end else case (st)
		S_IDLE:
			if (d_valid) begin
				xy <= d_xy;
				mask <= d_smask;
				sb <= 2'd0;
				color <= d_color;
				r <= 1'b0;
				idle <= 5'd0;
				st <= S_ROW;
			end else if (idle != 5'd16)
				idle <= idle + 5'd1;
			else if (ev[0] || ev[1]) begin
				r <= 1'b0;
				st <= S_FLUSH;
			end
		S_ROW:
			if (mask[8 * r +: 8] != 8'd0) begin
				addr <= rt_base + ({16'd0, xy[31:16]} + {31'd0, r}) * rt_stride +
					(ms4 ? (px16 ? {13'd0, xy[15:0], 3'b000} : {12'd0, xy[15:0], 4'b0000}) :
					(px16 ? {15'd0, xy[15:0], 1'b0} : {14'd0, xy[15:0], 2'b00}));
				st <= S_LOOK;
			end else if (r)
				st <= S_BLEND;
			else
				r <= 1'b1;
		S_LOOK: begin
			off[r] <= addr[LINE_SHIFT-1:0];
			if (ev[r] && etag[r] == addr[ADDR_W-1:LINE_SHIFT]) begin
				st <= r ? S_BLEND : S_ROW;
				r <= 1'b1;
			end else if (ev[r] && edirty[r] != {LINE_BYTES{1'b0}}) begin
				rq(1'b1, etag[r], edirty[r], edat[r]);
				st <= S_EVW;
			end else begin
				if (need_read)
					rq(1'b0, addr[ADDR_W-1:LINE_SHIFT], {LINE_BYTES{1'b0}}, edat[r]);
				st <= S_FILL;
			end
		end
		S_EVW:
			if (!req_valid && !wait_rsp) begin
				edirty[r] <= {LINE_BYTES{1'b0}};
				if (need_read)
					rq(1'b0, addr[ADDR_W-1:LINE_SHIFT], {LINE_BYTES{1'b0}}, edat[r]);
				st <= S_FILL;
			end
		S_FILL:
			/* the line (read when needed; its response arrives with rsp_valid) */
			if (!need_read || (!req_valid && wait_rsp && rsp_valid)) begin
				edat[r] <= need_read ? rsp_rdata : {(LINE_BYTES * 8){1'b0}};
				ev[r] <= 1'b1;
				etag[r] <= addr[ADDR_W-1:LINE_SHIFT];
				edirty[r] <= {LINE_BYTES{1'b0}};
				st <= r ? S_BLEND : S_ROW;
				r <= 1'b1;
			end
		S_BLEND: begin
			b_valid <= 1'b1;
			st <= S_BWAIT;
		end
		S_BWAIT:
			if (b_rvalid) begin
				for (l = 0; l < 4; l = l + 1)
					if (smk[l]) begin
						if (px16) begin
							edat[l >> 1][8 * po[LINE_SHIFT * l +: LINE_SHIFT] +: 16] <= b_pix[32 * l +: 16];
							edirty[l >> 1][po[LINE_SHIFT * l +: LINE_SHIFT] +: 2] <= 2'b11;
						end else begin
							edat[l >> 1][8 * po[LINE_SHIFT * l +: LINE_SHIFT] +: 32] <= b_pix[32 * l +: 32];
							edirty[l >> 1][po[LINE_SHIFT * l +: LINE_SHIFT] +: 4] <= 4'hF;
						end
					end
				if (!ms4 || sb == 2'd3)
					st <= S_IDLE;
				else begin
					sb <= sb + 2'd1;
					st <= S_BLEND;
				end
			end
		S_FLUSH:
			/* entry r: write its dirty bytes, then empty it */
			if (ev[r] && edirty[r] != {LINE_BYTES{1'b0}}) begin
				rq(1'b1, etag[r], edirty[r], edat[r]);
				st <= S_FLW;
			end else begin
				ev[r] <= 1'b0;
				r <= 1'b1;
				if (r) begin
					idle <= 5'd0;
					st <= S_IDLE;
				end
			end
		default:	/* S_FLW */
			if (!req_valid && !wait_rsp) begin
				edirty[r] <= {LINE_BYTES{1'b0}};
				st <= S_FLUSH;
			end
		endcase
	end

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_error};
endmodule

`default_nettype wire
