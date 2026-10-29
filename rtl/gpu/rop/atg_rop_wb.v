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

`include "atg_config.vh"

`ifndef CFG_ROP_MRT_COUNT
`define CFG_ROP_MRT_COUNT 1
`endif

module atg_rop_wb #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter MRT_COUNT = `CFG_ROP_MRT_COUNT
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
	input wire [2:0] d_rt,	/* the beat's attachment (Phase 003: MRT 8) */
	input wire d_nocol,	/* a beat without colour */
	/* atg_rop_blend */
	output wire b_valid,
	output wire [511:0] b_src,
	output wire [127:0] b_dst,
	output wire [3:0] b_mask,
	output wire [2:0] b_rt,
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
		S_BLEND = 4'd5, S_BWAIT = 4'd6, S_FLUSH = 4'd7, S_FLW = 4'd8, S_ROW_WAIT = 4'd9;
	reg [3:0] st;
	reg r;	/* row / entry */
	reg [1:0] j;	/* line of the row (several lines) */
	reg [1:0] g;	/* pass (one line per row: the sample) */
	reg wait_rsp;
	reg [4:0] idle;
	wire [1:0] j1, g1;	/* j + 1, g + 1, idle + 1 */
	wire [4:0] idle1;
	wire j1_co_unused, g1_co_unused, i1_co_unused;
	am_add #(.W(2)) u_j1 (.a(j), .b(2'd0), .ci(1'b1), .s(j1), .co(j1_co_unused));
	am_add #(.W(2)) u_g1 (.a(g), .b(2'd0), .ci(1'b1), .s(g1), .co(g1_co_unused));
	am_add #(.W(5)) u_idle1 (.a(idle), .b(5'd0), .ci(1'b1), .s(idle1), .co(i1_co_unused));
	reg [31:0] xy;
	reg [15:0] mask;
	reg [511:0] color;
	reg [2:0] rt;
	reg [31:0] addr;
	reg [LINE_SHIFT-1:0] off [0:1];	/* the quad's first byte in each row's line */
	reg f_go;
	reg fsm_b_valid;

	/* The pixels (atg_rop_wpix). */
	wire [31:0] p_addr, p_addr1;
	wire [31:0] p_row_base0, p_row_base1, p_stride, p_xoff_j;
	wire [1:0] p_nl, p_np, p_path;
	wire p_multi, p_drop, p_read, p_lw, f_done;
	wire [3:0] p_mask, p_ent;
	wire [511:0] p_res;
	wire [4*LINE_SHIFT-1:0] p_soff;
	wire [4:0] p_ps;
	wire [31:0] p_xoff;
	wire [2:0] p_xsh;
	wire f_take = st == S_BWAIT && p_path == 2'd1 && f_done;

	reg [31:0] wb_row_base0, wb_row_base1;
	wire [31:0] wb_row_base1_comb;
	wire wb_rb1_co;
	am_add #(.W(32)) u_wb_rb1 (.a(wb_row_base0), .b(p_stride), .ci(1'b0), .s(wb_row_base1_comb), .co(wb_rb1_co));
	wire [31:0] cur_row_base = r ? wb_row_base1 : wb_row_base0;
	wire [31:0] wb_addr_comb;
	wire wb_addr_co;
	am_add #(.W(32)) u_wb_addr (.a(cur_row_base), .b(p_xoff_j), .ci(1'b0), .s(wb_addr_comb), .co(wb_addr_co));

	wire [31:0] eff_xy = (st == S_IDLE) ? d_xy : xy;
	wire [15:0] eff_mask = (st == S_IDLE) ? d_smask : mask;
	wire [511:0] eff_color = (st == S_IDLE) ? d_color : color;
	wire eff_r = (st == S_IDLE) ? 1'b0 : r;
	wire [1:0] eff_j = (st == S_IDLE) ? 2'd0 : j;
	wire [1:0] eff_g = (st == S_IDLE) ? 2'd0 : g;

	/* Line Tracking and Cached Row Base */
	reg line_match_valid;
	reg [2:0] line_rt;
	reg [15:0] line_y;
	reg [31:0] cached_row_base0;
	reg [31:0] cached_row_base1;
	reg [2:0] cached_xsh;
	(* max_fanout = 4 *) reg [2:0] cached_xsh_off;
	reg cached_drop;
	reg cached_multi;
	reg [1:0] cached_np;
	reg [1:0] cached_path;
	reg cached_read;
	reg [4:0] cached_ps;

	/* Streaming address and offset calculation */
	wire [31:0] str_xoff;
	am_shift #(.W(32), .SW(3)) u_str_xoff (
		.a({16'd0, d_xy[15:0]}),
		.amt(cached_xsh),
		.left(1'b1),
		.arith(1'b0),
		.y(str_xoff)
	);

	wire [LA_W-1:0] str_tag0, str_tag1;
	wire str_a0_co, str_a1_co;
	am_add #(.W(LA_W)) u_str_a0 (.a(cached_row_base0[ADDR_W-1:LINE_SHIFT]), .b(str_xoff[ADDR_W-1:LINE_SHIFT]), .ci(1'b0), .s(str_tag0), .co(str_a0_co));
	am_add #(.W(LA_W)) u_str_a1 (.a(cached_row_base1[ADDR_W-1:LINE_SHIFT]), .b(str_xoff[ADDR_W-1:LINE_SHIFT]), .ci(1'b0), .s(str_tag1), .co(str_a1_co));

	/* Fast line-offset calculation for streaming */
	wire [LINE_SHIFT-1:0] str_line_off;
	am_shift #(.W(LINE_SHIFT), .SW(3)) u_str_loff (
		.a(d_xy[LINE_SHIFT-1:0]),
		.amt(cached_xsh_off),
		.left(1'b1),
		.arith(1'b0),
		.y(str_line_off)
	);

	wire [LINE_SHIFT-1:0] cur_off0 = str_line_off;
	wire [LINE_SHIFT-1:0] cur_off1 = str_line_off;

	wire [LINE_SHIFT-1:0] eff_off0 = (st == S_IDLE) ? cur_off0 : off[0];
	wire [LINE_SHIFT-1:0] eff_off1 = (st == S_IDLE) ? cur_off1 : off[1];



	wire [511:0] p_bsrc;
	wire [127:0] p_bdst;
	reg [511:0] r_bsrc;
	reg [127:0] r_bdst;
	reg [3:0] r_bmask;
	reg [4*LINE_SHIFT-1:0] r_bsoff;
	reg [3:0] r_bent;
	reg [4:0] r_bps;
	assign b_src = (st == S_IDLE) ? d_color : r_bsrc;
	assign b_dst = (st == S_IDLE) ? p_bdst : r_bdst;

	atg_rop_wpix #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) wpix (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.i_xy(eff_xy), .i_rt(rt), .i_smask(eff_mask), .i_color(eff_color),
		.i_r(eff_r), .i_j(eff_j), .i_g(eff_g),
		.i_line0(edat0), .i_line1(edat1), .i_off0(eff_off0), .i_off1(eff_off1),
		.b_pix(b_pix), .f_go(f_go), .f_done(f_done), .f_take(f_take),
		.o_addr(p_addr), .o_addr1(p_addr1), .o_nl(p_nl), .o_np(p_np), .o_multi(p_multi), .o_drop(p_drop),
		.o_read(p_read), .o_path(p_path), .o_lw(p_lw), .o_mask(p_mask), .o_bsrc(p_bsrc),
		.o_bdst(p_bdst), .o_res(p_res), .o_ent(p_ent), .o_soff(p_soff), .o_ps(p_ps),
		.o_row_base0(p_row_base0), .o_row_base1(p_row_base1),
		.o_xoff(p_xoff), .o_xsh(p_xsh),
		.o_stride(p_stride), .o_xoff_j(p_xoff_j)
	);

	/* Hazard Tracker and Pixel Lock CAM */
	wire alloc_ready;
	wire [3:0] alloc_id;
	reg release_valid;
	reg [3:0] release_id;

	/* Cache Hit Detection and Streaming Qualification */
	wire hit_rt = (d_rt == line_rt);
	wire hit_y = (d_xy[31:16] == line_y);
	wire hit0 = ev[0] && (etag[0] == str_tag0) && (erd[0] || !cached_read);
	wire hit1 = ev[1] && (etag[1] == str_tag1) && (erd[1] || !cached_read);
	wire stream_hit = line_match_valid && hit_rt && hit_y && hit0 && hit1;
	wire stream_drop = (hit_rt && cached_drop) || d_nocol || (d_smask == 16'd0);
	wire stream_ok = stream_hit && !cached_multi && (cached_np == 2'd0) && (cached_path == 2'd0) && alloc_ready;
	wire do_stream = (st == S_IDLE) && d_valid && stream_ok && !stream_drop;

	/* Pipeline shift register (3 stages for atg_rop_blend LAT=3) */
	reg [2:0] pipe_v;
	reg [3:0] pipe_id [0:2];
	reg [4*LINE_SHIFT-1:0] pipe_soff [0:2];
	reg [3:0] pipe_mask [0:2];
	reg [3:0] pipe_ent [0:2];
	reg [4:0] pipe_ps [0:2];
	wire pipe_busy = (pipe_v != 3'd0);

	atg_rop_hazard #(
		.NUM_ENTRIES(16),
		.TAG_W(33)
	) u_hazard (
		.clk(clk),
		.rst_n(rst_n),
		.alloc_valid(do_stream),
		.alloc_ready(alloc_ready),
		.alloc_tag({d_rt, d_xy[31:17], d_xy[15:1]}),
		.alloc_id(alloc_id),
		.release_valid(release_valid),
		.release_id(release_id)
	);

	wire [3:0] s0_mask = {d_smask[12], d_smask[8], d_smask[4], d_smask[0]};
	assign b_valid = (st == S_IDLE) ? do_stream : fsm_b_valid;
	assign b_mask = (st == S_IDLE) ? s0_mask : r_bmask;
	assign b_rt = rt;
	wire p_ready = p_path == 2'd2 || (p_path == 2'd0 && b_rvalid) || f_done;
	wire hit = ev[r] && etag[r] == addr[ADDR_W-1:LINE_SHIFT] && (erd[r] || !p_read);
	integer l, b;

	assign d_ready = (st == S_IDLE) &&
		(stream_drop ? 1'b1 :
		 stream_ok   ? 1'b1 :
		 pipe_busy   ? 1'b0 :
		 alloc_ready);
	assign busy = (st != S_IDLE) || ev[0] || ev[1] || pipe_busy;
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
				j <= j1;
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
				if (r && !p_multi) begin
					line_match_valid <= 1'b1;
					line_rt <= rt;
					line_y <= xy[31:16];
					cached_row_base0 <= wb_row_base0;
					cached_row_base1 <= wb_row_base1;
					cached_xsh <= p_xsh;
					cached_xsh_off <= p_xsh;
					cached_drop <= p_drop;
					cached_multi <= p_multi;
					cached_np <= p_np;
					cached_path <= p_path;
					cached_read <= p_read;
					cached_ps <= p_ps;
				end
			end
		end
	endtask
	/* After a pass. */
	task pass_done;
		begin
			if (!p_multi && g != p_np) begin
				g <= g1;
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
	 * earlier one.  The offsets are multiples of p_ps (the base, stride and
	 * alignment of docs/ghci.md section 8.5; the low bits of one that is not
	 * are ignored), so a slot's pixel is the whole of its p_ps-byte unit of
	 * the line: the pixel repeated over 16 bytes gives every byte of the line
	 * its byte (byte b: b mod 16), and each byte of an entry chooses among
	 * the four slots only. */
	wire stream_commit = pipe_v[2] && b_rvalid;
	wire [3:0] c_mask = stream_commit ? pipe_mask[2] : r_bmask;
	wire [4*LINE_SHIFT-1:0] c_soff = stream_commit ? pipe_soff[2] : r_bsoff;
	wire [3:0] c_ent = stream_commit ? pipe_ent[2] : r_bent;
	wire [4:0] c_ps = stream_commit ? pipe_ps[2] : r_bps;
	wire [511:0] c_res = stream_commit ?
		{96'd0, b_pix[96 +: 32], 96'd0, b_pix[64 +: 32], 96'd0, b_pix[32 +: 32], 96'd0, b_pix[0 +: 32]} : p_res;

	reg [LINE_BYTES*8-1:0] m_dat0, m_dat1;
	reg [LINE_BYTES-1:0] m_dirty0, m_dirty1;
	reg [127:0] m_rep;	/* slot l's pixel repeated */
	reg [LINE_SHIFT-1:0] m_bo;
	/* the low bits of an offset within its unit: p_ps - 1 */
	wire [3:0] m_lm = {c_ps[4], c_ps[4] | c_ps[3], c_ps[4] | c_ps[3] | c_ps[2],
		c_ps[4] | c_ps[3] | c_ps[2] | c_ps[1]};
	wire [LINE_SHIFT-1:0] m_lmw = {{(LINE_SHIFT-4){1'b0}}, m_lm};
	always @(*) begin
		m_dat0 = edat0;
		m_dat1 = edat1;
		m_dirty0 = edirty0;
		m_dirty1 = edirty1;
		m_rep = 128'd0;
		m_bo = {LINE_SHIFT{1'b0}};
		for (l = 0; l < 4; l = l + 1) begin
			m_rep = c_ps[4] ? c_res[128 * l +: 128] : c_ps[3] ? {2{c_res[128 * l +: 64]}} :
				c_ps[2] ? {4{c_res[128 * l +: 32]}} : c_ps[1] ? {8{c_res[128 * l +: 16]}} :
				{16{c_res[128 * l +: 8]}};
			if (c_mask[l])
				for (b = 0; b < LINE_BYTES; b = b + 1) begin
					m_bo = b[LINE_SHIFT-1:0];
					if (((m_bo ^ c_soff[LINE_SHIFT * l +: LINE_SHIFT]) & ~m_lmw) ==
					    {LINE_SHIFT{1'b0}}) begin
						if (c_ent[l]) begin
							m_dat1[8 * b +: 8] = m_rep[8 * (b % 16) +: 8];
							m_dirty1[b] = 1'b1;
						end else begin
							m_dat0[8 * b +: 8] = m_rep[8 * (b % 16) +: 8];
							m_dirty0[b] = 1'b1;
						end
					end
				end
		end
	end

	always @(posedge clk) begin
		fsm_b_valid <= 1'b0;
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
			line_match_valid <= 1'b0;
			line_rt <= 3'd0;
			line_y <= 16'd0;
			wb_row_base0 <= 32'd0;
			wb_row_base1 <= 32'd0;
			r_bsrc <= 512'd0;
			r_bdst <= 128'd0;
			r_bmask <= 4'd0;
			r_bsoff <= {4*LINE_SHIFT{1'b0}};
			r_bent <= 4'd0;
			r_bps <= 5'd0;
			cached_row_base0 <= 32'd0;
			cached_row_base1 <= 32'd0;
			cached_xsh <= 3'd0;
			cached_xsh_off <= 3'd0;
			cached_drop <= 1'b0;
			cached_multi <= 1'b0;
			cached_np <= 2'd0;
			cached_path <= 2'd0;
			cached_read <= 1'b0;
			cached_ps <= 5'd0;
			idle <= 5'd0;
			rt <= 3'd0;
			pipe_v <= 3'd0;
			release_valid <= 1'b0;
			release_id <= 4'd0;
		end else begin
			release_valid <= 1'b0;
			if (st_we)
				line_match_valid <= 1'b0;
			pipe_v[0] <= do_stream;
			pipe_v[1] <= pipe_v[0];
			pipe_v[2] <= pipe_v[1];

			if (do_stream) begin
				pipe_id[0] <= alloc_id;
				pipe_soff[0] <= p_soff;
				pipe_mask[0] <= s0_mask;
				pipe_ent[0] <= 4'b1100;
				pipe_ps[0] <= cached_ps;
			end
			if (pipe_v[0]) begin
				pipe_id[1] <= pipe_id[0];
				pipe_soff[1] <= pipe_soff[0];
				pipe_mask[1] <= pipe_mask[0];
				pipe_ent[1] <= pipe_ent[0];
				pipe_ps[1] <= pipe_ps[0];
			end
			if (pipe_v[1]) begin
				pipe_id[2] <= pipe_id[1];
				pipe_soff[2] <= pipe_soff[1];
				pipe_mask[2] <= pipe_mask[1];
				pipe_ent[2] <= pipe_ent[1];
				pipe_ps[2] <= pipe_ps[1];
			end

			if (stream_commit) begin
				edat[0] <= m_dat0;
				edat[1] <= m_dat1;
				edirty[0] <= m_dirty0;
				edirty[1] <= m_dirty1;
				release_valid <= 1'b1;
				release_id <= pipe_id[2];
			end

			case (st)
			S_IDLE: begin
				rt <= line_rt;
				if (d_valid && d_ready) begin
					idle <= 5'd0;
					if (stream_drop) begin
						/* drop */
					end else if (stream_ok) begin
						/* stream */
					end else begin
						xy <= d_xy;
						mask <= d_smask;
						color <= d_color;
						rt <= d_rt;
						r <= 1'b0;
						j <= 2'd0;
						g <= 2'd0;
						line_match_valid <= 1'b0;
						if (!d_nocol)
							st <= S_ROW_WAIT;
					end
				end else if (!pipe_busy) begin
					if (idle != 5'd16)
						idle <= idle1;
					else if (ev[0] || ev[1]) begin
						r <= 1'b0;
						st <= S_FLUSH;
					end
				end
			end
			S_ROW_WAIT: begin
				wb_row_base0 <= p_row_base0;
				st <= S_ROW;
			end
			S_ROW:
				if (p_drop)
					st <= S_IDLE;
				else if (p_lw) begin
					addr <= wb_addr_comb;
					wb_row_base1 <= wb_row_base1_comb;
					st <= S_LOOK;
				end else begin
					wb_row_base1 <= wb_row_base1_comb;
					next_row;
				end
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
			S_EVW: begin
				line_match_valid <= 1'b0;
				if (!req_valid && !wait_rsp) begin
					edirty[r] <= {LINE_BYTES{1'b0}};
					if (p_read)
						rq(1'b0, addr[ADDR_W-1:LINE_SHIFT], {LINE_BYTES{1'b0}}, edat[r]);
					st <= S_FILL;
				end
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
					r_bsrc <= p_bsrc;
					r_bdst <= p_bdst;
					r_bmask <= p_mask;
					r_bsoff <= p_soff;
					r_bent <= p_ent;
					r_bps <= p_ps;
					fsm_b_valid <= p_path == 2'd0;
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
			S_FLUSH: begin
				line_match_valid <= 1'b0;
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
			end
			default:	/* S_FLW */
				if (!req_valid && !wait_rsp) begin
					edirty[r] <= {LINE_BYTES{1'b0}};
					st <= S_FLUSH;
				end
			endcase
		end
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

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_error, c_ps[0], (MRT_COUNT != 0),
		wb_rb1_co, wb_addr_co};
endmodule

`default_nettype wire
