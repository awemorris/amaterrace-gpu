/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wb: ROP write-back: a small write-combining buffer of
 * render-target lines; reads the destination line when its old pixels are
 * needed, sends the pixels through a blend path, writes lines back; drains
 * when idle.
 *
 * A beat is one colour attachment of a quad (d_rt; CAPS[30] up to 4).
 * atg_rop_wpix holds the attachments' state and places the beat's pixels:
 * a quad's row is one line, or with 4 samples and 2 S ps above LINE_BYTES
 * several whole lines (base, stride and the alignment of docs/ghci.md
 * section 8.5; a row that crosses a line is reported in simulation).  A
 * beat without colour (d_nocol) or with nothing to write (o_drop) is taken
 * and dropped.
 *
 * Two line entries, entry r for row r of the quad (quads have even y, so
 * a line never sits in both).  A miss writes the old line back (its dirty
 * bytes only) and reads the new one when its old pixels are needed
 * (o_read); a line kept without reading serves only beats that need no
 * read.  One row on one line: both rows' lines are found first, then one
 * pass per sample through the path (the lanes whose sample survived).
 * Several lines: line by line, one pass each.  Paths (atg_rop_wpix): 0
 * atg_rop_blend (b_*), 1 atg_rop_fblend (in atg_rop_wpix), 2 the packing
 * only; the new bytes of each slot merge into its entry.  After 16 idle
 * cycles the dirty lines are written and both entries emptied (the next
 * draw must not blend with lines another block may have changed); busy
 * stays up until then.  One beat at a time.  See
 * spec/gpu/rop/atg_rop_wb.md.
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
	input wire [1:0] d_rt,	/* the beat's attachment */
	input wire d_nocol,	/* a beat without colour */
	/* atg_rop_blend */
	output reg b_valid,
	output wire [511:0] b_src,
	output wire [127:0] b_dst,
	output wire [3:0] b_mask,
	output wire [1:0] b_rt,
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
	localparam LA_W = ADDR_W - LINE_SHIFT;

	/* The two entries. */
	reg ev [0:1];
	reg erd [0:1];	/* the line was read */
	reg [LA_W-1:0] etag [0:1];
	reg [LINE_BYTES*8-1:0] edat [0:1];
	reg [LINE_BYTES-1:0] edirty [0:1];
	wire [LINE_BYTES*8-1:0] edat0 = edat[0], edat1 = edat[1];
	wire [LINE_BYTES-1:0] edirty0 = edirty[0], edirty1 = edirty[1];

	localparam [3:0] S_IDLE = 4'd0, S_ROW = 4'd1, S_LOOK = 4'd2, S_EVW = 4'd3, S_FILL = 4'd4,
		S_BLEND = 4'd5, S_BWAIT = 4'd6, S_FLUSH = 4'd7, S_FLW = 4'd8;
	reg [3:0] st;
	reg r;	/* row / entry */
	reg [1:0] j;	/* line of the row (several lines) */
	reg [1:0] g;	/* pass (one line per row: the sample) */
	reg wait_rsp;
	reg [4:0] idle;
	reg [31:0] xy;
	reg [15:0] mask;
	reg [511:0] color;
	reg [1:0] rt;
	reg [31:0] addr;
	reg [LINE_SHIFT-1:0] off [0:1];	/* the quad's first byte in each row's line */
	reg f_go;

	/* The pixels (atg_rop_wpix). */
	wire [31:0] p_addr;
	wire [1:0] p_nl, p_np, p_path;
	wire p_multi, p_drop, p_read, p_lw, f_done;
	wire [3:0] p_mask, p_ent;
	wire [511:0] p_res;
	wire [4*LINE_SHIFT-1:0] p_soff;
	wire [4:0] p_ps;
	wire f_take = st == S_BWAIT && p_path == 2'd1 && f_done;
	atg_rop_wpix #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) wpix (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.i_xy(xy), .i_rt(rt), .i_smask(mask), .i_color(color), .i_r(r), .i_j(j), .i_g(g),
		.i_line0(edat0), .i_line1(edat1), .i_off0(off[0]), .i_off1(off[1]),
		.b_pix(b_pix), .f_go(f_go), .f_done(f_done), .f_take(f_take),
		.o_addr(p_addr), .o_nl(p_nl), .o_np(p_np), .o_multi(p_multi), .o_drop(p_drop),
		.o_read(p_read), .o_path(p_path), .o_lw(p_lw), .o_mask(p_mask), .o_bsrc(b_src),
		.o_bdst(b_dst), .o_res(p_res), .o_ent(p_ent), .o_soff(p_soff), .o_ps(p_ps)
	);
	assign b_mask = p_mask;
	assign b_rt = rt;
	wire p_ready = p_path == 2'd2 || (p_path == 2'd0 && b_rvalid) || f_done;
	wire hit = ev[r] && etag[r] == addr[ADDR_W-1:LINE_SHIFT] && (erd[r] || !p_read);
	integer l, b;

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

	/* The next row or line with pixels (S_ROW), or the passes. */
	task next_row;
		begin
			if (p_multi && j != p_nl)
				j <= j + 2'd1;
			else if (!r) begin
				r <= 1'b1;
				j <= 2'd0;
			end else if (p_multi)
				st <= S_IDLE;
			else begin
				g <= 2'd0;
				st <= S_BLEND;
			end
		end
	endtask
	/* The line is in its entry: on to the next row (one line) or its pass. */
	task line_in;
		begin
			if (p_multi) begin
				g <= 2'd0;
				st <= S_BLEND;
			end else begin
				st <= r ? S_BLEND : S_ROW;
				r <= 1'b1;
				g <= 2'd0;
			end
		end
	endtask
	/* After a pass. */
	task pass_done;
		begin
			if (!p_multi && g != p_np) begin
				g <= g + 2'd1;
				st <= S_BLEND;
			end else if (!p_multi)
				st <= S_IDLE;
			else begin
				st <= S_ROW;
				next_row;
			end
		end
	endtask

	/* The entries with the pass's new bytes merged (taken in S_BWAIT): slot
	 * l's p_ps bytes from byte p_soff of entry p_ent, a later slot over an
	 * earlier one, bytes past the line dropped.  Each slot's bytes are
	 * shifted to their place in a line, so that every byte of an entry
	 * chooses among the four slots only. */
	reg [LINE_BYTES*8-1:0] m_dat0, m_dat1;
	reg [LINE_BYTES-1:0] m_dirty0, m_dirty1;
	reg [LINE_BYTES*8+127:0] m_sh;	/* slot l's bytes at their place */
	reg [LINE_BYTES+15:0] m_be;	/* and their byte enables */
	always @(*) begin
		m_dat0 = edat0;
		m_dat1 = edat1;
		m_dirty0 = edirty0;
		m_dirty1 = edirty1;
		for (l = 0; l < 4; l = l + 1) begin
			m_sh = {{(LINE_BYTES*8){1'b0}}, p_res[128 * l +: 128]} <<
				{p_soff[LINE_SHIFT * l +: LINE_SHIFT], 3'b000};
			m_be = {{LINE_BYTES{1'b0}}, p_ps[4] ? 16'hFFFF : (16'd1 << p_ps[3:0]) - 16'd1} <<
				p_soff[LINE_SHIFT * l +: LINE_SHIFT];
			if (p_mask[l])
				for (b = 0; b < LINE_BYTES; b = b + 1)
					if (m_be[b]) begin
						if (p_ent[l]) begin
							m_dat1[8 * b +: 8] = m_sh[8 * b +: 8];
							m_dirty1[b] = 1'b1;
						end else begin
							m_dat0[8 * b +: 8] = m_sh[8 * b +: 8];
							m_dirty0[b] = 1'b1;
						end
					end
		end
	end

	always @(posedge clk) begin
		b_valid <= 1'b0;
		f_go <= 1'b0;
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
			erd[0] <= 1'b0;
			erd[1] <= 1'b0;
			edirty[0] <= {LINE_BYTES{1'b0}};
			edirty[1] <= {LINE_BYTES{1'b0}};
			idle <= 5'd0;
			rt <= 2'd0;
		end else case (st)
		S_IDLE:
			if (d_valid) begin
				xy <= d_xy;
				mask <= d_smask;
				color <= d_color;
				rt <= d_rt;
				r <= 1'b0;
				j <= 2'd0;
				g <= 2'd0;
				idle <= 5'd0;
				if (!d_nocol)
					st <= S_ROW;
			end else if (idle != 5'd16)
				idle <= idle + 5'd1;
			else if (ev[0] || ev[1]) begin
				r <= 1'b0;
				st <= S_FLUSH;
			end
		S_ROW:
			if (p_drop)
				st <= S_IDLE;
			else if (p_lw) begin
				addr <= p_addr;
				st <= S_LOOK;
			end else
				next_row;
		S_LOOK: begin
			off[r] <= addr[LINE_SHIFT-1:0];
			if (hit)
				line_in;
			else if (ev[r] && edirty[r] != {LINE_BYTES{1'b0}}) begin
				rq(1'b1, etag[r], edirty[r], edat[r]);
				st <= S_EVW;
			end else begin
				if (p_read)
					rq(1'b0, addr[ADDR_W-1:LINE_SHIFT], {LINE_BYTES{1'b0}}, edat[r]);
				st <= S_FILL;
			end
		end
		S_EVW:
			if (!req_valid && !wait_rsp) begin
				edirty[r] <= {LINE_BYTES{1'b0}};
				if (p_read)
					rq(1'b0, addr[ADDR_W-1:LINE_SHIFT], {LINE_BYTES{1'b0}}, edat[r]);
				st <= S_FILL;
			end
		S_FILL:
			/* the line (read when needed; its response arrives with rsp_valid) */
			if (!p_read || (!req_valid && wait_rsp && rsp_valid)) begin
				edat[r] <= p_read ? rsp_rdata : {(LINE_BYTES * 8){1'b0}};
				ev[r] <= 1'b1;
				erd[r] <= p_read;
				etag[r] <= addr[ADDR_W-1:LINE_SHIFT];
				edirty[r] <= {LINE_BYTES{1'b0}};
				line_in;
			end
		S_BLEND:
			/* a pass without pixels is skipped */
			if (p_mask == 4'd0)
				pass_done;
			else begin
				b_valid <= p_path == 2'd0;
				f_go <= p_path == 2'd1;
				st <= S_BWAIT;
			end
		S_BWAIT:
			if (p_ready) begin
				edat[0] <= m_dat0;
				edat[1] <= m_dat1;
				edirty[0] <= m_dirty0;
				edirty[1] <= m_dirty1;
				pass_done;
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

`ifndef SYNTHESIS
	/* A quad's row on one line stays in it; several lines start a line. */
	always @(posedge clk)
		if (rst_n && st == S_ROW && !p_drop && p_lw &&
		    (p_multi ? p_addr[LINE_SHIFT-1:0] != {LINE_SHIFT{1'b0}} :
		    {{(32-LINE_SHIFT){1'b0}}, p_addr[LINE_SHIFT-1:0]} + 32'd2 * ({30'd0, p_np} + 32'd1) * {27'd0, p_ps} >
		    LINE_BYTES))
			$display("FAIL atg_rop_wb: attachment %0d row at %h crosses a line", rt, p_addr);
`endif

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_error, m_sh[LINE_BYTES*8 +: 128],
		m_be[LINE_BYTES +: 16]};
endmodule

`default_nettype wire
