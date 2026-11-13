/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dcache: The SU's data cache: 1 KiB direct-mapped (32 lines of 32
 * bytes), write-through, read-allocate, flash-invalidated; between the
 * LSU's line requests and the MC.
 *
 * One request at a time (u_req_ready only in IDLE).  Read hit: the
 * response the next cycle.  Read miss: the line is read from the MC,
 * filled (unless inv came meanwhile or the MC answered an error) and
 * returned.  Write: through to the MC with the byte enables; a line that
 * is present when the MC answers is updated with the written bytes; the
 * response follows the MC's.  inv clears every valid bit at once.  The
 * response carries the request's tag; m_req_tag is 0 (one outstanding).
 *
 * States: IDLE →(hit)→ RESP → IDLE; IDLE →(miss / write)→ MREQ
 * →(m_req_ready)→ MWAIT →(m_rsp)→ RESP → IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dcache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DC_BYTES = 1024	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire inv,
	/* AMB client port (design §4.1) */
	input wire u_req_valid,
	output wire u_req_ready,
	input wire u_req_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] u_req_line,
	input wire [LINE_BYTES-1:0] u_req_be,
	input wire [LINE_BYTES*8-1:0] u_req_wdata,
	input wire [7:0] u_req_tag,
	output wire u_rsp_valid,
	output wire u_rsp_write,
	output wire [7:0] u_rsp_tag,
	output wire [LINE_BYTES*8-1:0] u_rsp_rdata,
	output wire u_rsp_error,
	/* AMB client port (design §4.1) */
	output wire m_req_valid,
	input wire m_req_ready,
	output wire m_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] m_req_line,
	output wire [LINE_BYTES-1:0] m_req_be,
	output wire [LINE_BYTES*8-1:0] m_req_wdata,
	output wire [7:0] m_req_tag,
	input wire m_rsp_valid,
	input wire m_rsp_write,
	input wire [7:0] m_rsp_tag,
	input wire [LINE_BYTES*8-1:0] m_rsp_rdata,
	input wire m_rsp_error
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam NL = DC_BYTES / LINE_BYTES;
	localparam IW = NL > 1 ? $clog2(NL) : 1;
	localparam TW = LA_W - IW;
	localparam [2:0] IDLE = 3'd0, MREQ = 3'd1, MWAIT = 3'd2, RESP = 3'd3, HIT_WAIT = 3'd4;

	localparam TW0 = TW / 4;
	localparam TW1 = TW / 4;
	localparam TW2 = TW / 4;
	localparam TW3 = TW - TW0 - TW1 - TW2;
	localparam LA_LO = LA_W / 2;
	localparam LA_HI = LA_W - LA_LO;
	localparam LB_HALF = LB / 2;
	localparam N_SL = LB / 16;
	localparam V_SL = (NL >= 8) ? (NL / 8) : 1;
	localparam V_SW = NL / V_SL;
	localparam N_TEQ = (TW + 2) / 3;

	wire rst_p = !rst_n;
	(* max_fanout = 12 *) reg [2:0] st;
	wire [NL-1:0] valid;
	reg [TW0-1:0] tags_0 [0:NL-1];
	reg [TW1-1:0] tags_1 [0:NL-1];
	reg [TW2-1:0] tags_2 [0:NL-1];
	reg [TW3-1:0] tags_3 [0:NL-1];
	(* ram_style = "block" *) reg [LB_HALF-1:0] data_lo [0:NL-1];
	(* ram_style = "block" *) reg [LB_HALF-1:0] data_hi [0:NL-1];
	/* The request in progress. */
	(* max_fanout = 12 *) reg q_write, q_drop;
	(* shreg_extract = "no", max_fanout = 12 *) reg [LA_LO-1:0] q_line_lo;
	(* shreg_extract = "no", max_fanout = 12 *) reg [LA_HI-1:0] q_line_hi;
	wire [LA_W-1:0] q_line = {q_line_hi, q_line_lo};
	(* keep = "true", max_fanout = 12 *) reg [IW-1:0] q_idx_d_lo, q_idx_d_hi;
	(* keep = "true", max_fanout = 12 *) reg [IW-1:0] q_idx_r0_r, q_idx_r1_r, q_idx_r2_r, q_idx_r3_r;
	(* keep = "true", max_fanout = 12 *) reg [IW-1:0] q_idx_w0_r, q_idx_w1_r, q_idx_w2_r, q_idx_w3_r;
	wire [LINE_BYTES-1:0] q_be;
	wire [LB-1:0] q_wdata;
	(* max_fanout = 12 *) reg [7:0] q_tag;
	/* The response. */
	(* max_fanout = 12 *) reg r_write, r_error;
	wire [LB-1:0] r_rdata;

	wire [LA_W-1:0] u_req_line_tag;
	wire [LA_W-1:0] u_req_line_reg;
	wire [IW-1:0] u_idx_v0, u_idx_v1;
`ifdef SYNTH_KINTEX7
	genvar grl;
	generate
		for (grl = 0; grl < LA_W; grl = grl + 1) begin : g_buf_rl
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_tag (.I0(u_req_line[grl]), .O(u_req_line_tag[grl]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_reg (.I0(u_req_line[grl]), .O(u_req_line_reg[grl]));
		end
		for (grl = 0; grl < IW; grl = grl + 1) begin : g_buf_v
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_v0 (.I0(u_req_line[grl]), .O(u_idx_v0[grl]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_v1 (.I0(u_req_line[grl]), .O(u_idx_v1[grl]));
		end
	endgenerate
`else
	assign u_req_line_tag = u_req_line;
	assign u_req_line_reg = u_req_line;
	assign u_idx_v0 = u_req_line[IW-1:0];
	assign u_idx_v1 = u_req_line[IW-1:0];
`endif

	(* keep = "true" *) wire [IW-1:0] u_idx_0 = u_req_line_tag[IW-1:0];
	(* keep = "true" *) wire [IW-1:0] u_idx_1 = u_req_line_tag[IW-1:0];
	(* keep = "true" *) wire [IW-1:0] u_idx_2 = u_req_line_tag[IW-1:0];
	(* keep = "true" *) wire [IW-1:0] u_idx_3 = u_req_line_tag[IW-1:0];
	wire [TW-1:0] u_tag_rd = {tags_3[u_idx_3], tags_2[u_idx_2], tags_1[u_idx_1], tags_0[u_idx_0]};
	wire [TW-1:0] u_tag_in = u_req_line_tag[LA_W-1:IW];
	(* keep = "true", max_fanout = 12 *) wire [IW-1:0] q_idx_v = q_line[IW-1:0];
	wire [TW-1:0] q_tag_rd = {tags_3[q_idx_r3_r], tags_2[q_idx_r2_r], tags_1[q_idx_r1_r], tags_0[q_idx_r0_r]};
	wire [TW-1:0] q_tag_in = q_line[LA_W-1:IW];

	/* Pure-LUT 3-bit chunk tag comparators (0 CARRY4s, 2 LUT levels) */
	(* keep = "true" *) wire [N_TEQ-1:0] u_teq_g;
	(* keep = "true" *) wire [N_TEQ-1:0] q_teq_g;
	genvar gteq;
	generate
		for (gteq = 0; gteq < N_TEQ; gteq = gteq + 1) begin : g_teq
			localparam TB = gteq * 3;
			localparam TW_C = (TB + 3 <= TW) ? 3 : (TW - TB);
			assign u_teq_g[gteq] = (u_tag_rd[TB +: TW_C] == u_tag_in[TB +: TW_C]);
			assign q_teq_g[gteq] = (q_tag_rd[TB +: TW_C] == q_tag_in[TB +: TW_C]);
		end
	endgenerate
	wire [1:0] val_u_pair = {
		valid[{1'b1, u_idx_v1[IW-2:0]}],
		valid[{1'b0, u_idx_v0[IW-2:0]}]
	};
	wire val_u = val_u_pair[u_idx_v0[IW-1]];
	(* keep = "true" *) wire u_hit_lo = val_u && (&u_teq_g[N_TEQ/2-1:0]);
	(* keep = "true" *) wire u_hit_hi = &u_teq_g[N_TEQ-1:N_TEQ/2];
	wire u_hit = u_hit_lo && u_hit_hi;
	(* keep = "true" *) wire q_hit_lo = valid[q_idx_v] && (&q_teq_g[N_TEQ/2-1:0]);
	(* keep = "true" *) wire q_hit_hi = &q_teq_g[N_TEQ-1:N_TEQ/2];
	wire q_hit = q_hit_lo && q_hit_hi;
	wire u_req_valid_ctl;
	wire u_req_valid_sl0;
	wire u_req_valid_sl1;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'h2)) u_buf_rq_ctl (.O(u_req_valid_ctl), .I0(u_req_valid));
	LUT1 #(.INIT(2'h2)) u_buf_rq_sl0 (.O(u_req_valid_sl0), .I0(u_req_valid));
	LUT1 #(.INIT(2'h2)) u_buf_rq_sl1 (.O(u_req_valid_sl1), .I0(u_req_valid));
`else
	assign u_req_valid_ctl = u_req_valid;
	assign u_req_valid_sl0 = u_req_valid;
	assign u_req_valid_sl1 = u_req_valid;
`endif

	(* keep = "true", max_fanout = 12 *) wire take = st == IDLE && u_req_valid_ctl;
	(* keep = "true", max_fanout = 12 *) wire take_d_lo = (st == IDLE) && u_req_valid_ctl;
	(* keep = "true", max_fanout = 12 *) wire take_d_hi = (st == IDLE) && u_req_valid_ctl;

	/* The data are read synchronously (block RAM): d_q is the request's
	 * line, read when it is taken; d_q_pipe is the dedicated fabric output
	 * register (Rule 4: 0 LUTs after BRAM DOUT). */
	reg [LB_HALF-1:0] d_q_lo, d_q_hi;
	(* dont_touch = "true" *) reg [LB-1:0] d_q_pipe;
	(* max_fanout = 12 *) reg r_hit;	/* the response is d_q_pipe (a read hit) */
	always @(posedge clk) begin
		if (take_d_lo)
			d_q_lo <= data_lo[u_req_line[IW-1:0]];
		if (take_d_hi)
			d_q_hi <= data_hi[u_req_line[IW-1:0]];
		d_q_pipe <= {d_q_hi, d_q_lo};
	end
	/* The line with the written bytes merged, plus 16-bit sliced registers/muxes. */
	wire [LB-1:0] q_old = d_q_pipe;
	wire [LB-1:0] merged;
	wire [LB-1:0] dc_wdata_in;
	genvar gsl, gvs, gvi;
	generate
		for (gsl = 0; gsl < N_SL; gsl = gsl + 1) begin : g_dc_sl
			(* shreg_extract = "no" *) reg [15:0] q_wdata_sl, r_rdata_sl;
			(* shreg_extract = "no" *) reg [1:0] q_be_sl;
			(* keep = "true", max_fanout = 12 *) wire take_sl = (st == IDLE) && ((gsl < 8) ? u_req_valid_sl0 : u_req_valid_sl1);
			(* keep = "true", max_fanout = 12 *) wire rsp_sl = (st == MWAIT) && m_rsp_valid;
			(* keep = "true", max_fanout = 12 *) wire r_hit_sl = r_hit;
			(* keep = "true", max_fanout = 12 *) wire q_wr_sl = q_write;
			always @(posedge clk) begin
				if (take_sl) begin
					q_wdata_sl <= u_req_wdata[gsl*16 +: 16];
					q_be_sl    <= u_req_be[gsl*2 +: 2];
				end
				if (rsp_sl)
					r_rdata_sl <= m_rsp_rdata[gsl*16 +: 16];
			end
			assign q_wdata[gsl*16 +: 16] = q_wdata_sl;
			assign q_be[gsl*2 +: 2]      = q_be_sl;
			assign r_rdata[gsl*16 +: 16] = r_rdata_sl;
			assign merged[gsl*16 +: 8] = q_be_sl[0] ? q_wdata_sl[7:0] : q_old[gsl*16 +: 8];
			assign merged[gsl*16 + 8 +: 8] = q_be_sl[1] ? q_wdata_sl[15:8] : q_old[gsl*16 + 8 +: 8];
			assign dc_wdata_in[gsl*16 +: 16] = q_wr_sl ? merged[gsl*16 +: 16] : m_rsp_rdata[gsl*16 +: 16];
			assign u_rsp_rdata[gsl*16 +: 16] = r_hit_sl ? d_q_pipe[gsl*16 +: 16] : r_rdata_sl;
		end
		for (gvs = 0; gvs < V_SL; gvs = gvs + 1) begin : g_val_sl
			(* keep = "true", max_fanout = 12 *) wire [IW-1:0] q_idx_v_sl = q_line[IW-1:0];
			wire [35:0] q_idx_pad = {{(36-IW){1'b0}}, q_idx_v_sl};
			(* keep = "true", max_fanout = 12 *) wire v_clr_sl = rst_p || inv;
			(* keep = "true", max_fanout = 12 *) wire v_set_sl = (st == MWAIT) && m_rsp_valid && !m_rsp_error && !q_drop && !q_write &&
				(q_idx_pad[35:3] == gvs);
			for (gvi = 0; gvi < V_SW; gvi = gvi + 1) begin : g_val_bit
				reg valid_bit;
				always @(posedge clk) begin
					if (v_clr_sl)
						valid_bit <= 1'b0;
					else if (v_set_sl && (q_idx_pad[2:0] == gvi[2:0]))
						valid_bit <= 1'b1;
				end
				assign valid[gvs*V_SW + gvi] = valid_bit;
			end
		end
	endgenerate

	(* keep = "true", max_fanout = 12 *) wire tag_we_0   = (st == MWAIT) && m_rsp_valid && !m_rsp_error && !q_drop && !inv && !q_write;
	(* keep = "true", max_fanout = 12 *) wire tag_we_1   = (st == MWAIT) && m_rsp_valid && !m_rsp_error && !q_drop && !inv && !q_write;
	(* keep = "true", max_fanout = 12 *) wire tag_we_2   = (st == MWAIT) && m_rsp_valid && !m_rsp_error && !q_drop && !inv && !q_write;
	(* keep = "true", max_fanout = 12 *) wire tag_we_3   = (st == MWAIT) && m_rsp_valid && !m_rsp_error && !q_drop && !inv && !q_write;
	(* keep = "true", max_fanout = 12 *) wire data_we_lo = (st == MWAIT) && m_rsp_valid && !m_rsp_error && !q_drop && !inv && (!q_write || q_hit);
	(* keep = "true", max_fanout = 12 *) wire data_we_hi = (st == MWAIT) && m_rsp_valid && !m_rsp_error && !q_drop && !inv && (!q_write || q_hit);
	always @(posedge clk) begin
		if (tag_we_0)
			tags_0[q_idx_w0_r] <= q_line[IW +: TW0];
		if (tag_we_1)
			tags_1[q_idx_w1_r] <= q_line[IW + TW0 +: TW1];
		if (tag_we_2)
			tags_2[q_idx_w2_r] <= q_line[IW + TW0 + TW1 +: TW2];
		if (tag_we_3)
			tags_3[q_idx_w3_r] <= q_line[IW + TW0 + TW1 + TW2 +: TW3];
		if (data_we_lo)
			data_lo[q_idx_d_lo] <= dc_wdata_in[LB_HALF-1:0];
		if (data_we_hi)
			data_hi[q_idx_d_hi] <= dc_wdata_in[LB-1:LB_HALF];
	end

	(* keep = "true", max_fanout = 12 *) wire dc_idle_ce_0 = (st == IDLE) && u_req_valid_ctl;
	(* keep = "true", max_fanout = 12 *) wire dc_idle_ce_1 = (st == IDLE) && u_req_valid_ctl;
	(* keep = "true", max_fanout = 12 *) wire dc_idle_ce_2 = (st == IDLE) && u_req_valid_ctl;
	(* keep = "true", max_fanout = 12 *) wire dc_idle_ce_3 = (st == IDLE) && u_req_valid_ctl;
	(* keep = "true", max_fanout = 12 *) wire dc_idle_ce_4 = (st == IDLE) && u_req_valid_ctl;

	always @(posedge clk) begin
		if (dc_idle_ce_0) begin
			q_line_lo <= u_req_line_reg[LA_LO-1:0];
			q_write   <= u_req_write;
		end
		if (dc_idle_ce_1) begin
			q_line_hi <= u_req_line_reg[LA_W-1:LA_LO];
		end
		if (dc_idle_ce_2) begin
			q_tag <= u_req_tag;
			q_idx_d_lo  <= u_req_line_reg[IW-1:0];
			q_idx_d_hi  <= u_req_line_reg[IW-1:0];
		end
		if (dc_idle_ce_3) begin
			q_idx_r0_r <= u_req_line_reg[IW-1:0];
			q_idx_r1_r <= u_req_line_reg[IW-1:0];
			q_idx_r2_r <= u_req_line_reg[IW-1:0];
		end
		if (dc_idle_ce_4) begin
			q_idx_r3_r <= u_req_line_reg[IW-1:0];
			q_idx_w0_r <= u_req_line_reg[IW-1:0];
			q_idx_w1_r <= u_req_line_reg[IW-1:0];
		end

		if (rst_p) begin
			st <= IDLE;
			q_drop <= 1'b0;
			r_write <= 1'b0;
			r_error <= 1'b0;
			r_hit <= 1'b0;
			q_idx_w2_r <= {IW{1'b0}};
			q_idx_w3_r <= {IW{1'b0}};
		end else begin
			case (st)
			IDLE: if (take) begin
				q_idx_w2_r <= u_req_line_reg[IW-1:0];
				q_idx_w3_r <= u_req_line_reg[IW-1:0];
				q_drop <= 1'b0;
				r_write <= u_req_write;
				r_error <= 1'b0;
				r_hit <= !u_req_write && u_hit;
				if (!u_req_write && u_hit)
					st <= HIT_WAIT;
				else
					st <= MREQ;
			end
			HIT_WAIT:
				st <= RESP;
			MREQ: if (m_req_ready)
				st <= MWAIT;
			MWAIT: if (m_rsp_valid) begin
				r_error <= m_rsp_error;
				st <= RESP;
			end
			default: st <= IDLE;
			endcase
			if (inv) begin
				q_drop <= 1'b1;
			end
		end
	end

	assign u_req_ready = st == IDLE;
	assign u_rsp_valid = st == RESP;
	assign u_rsp_write = r_write;
	assign u_rsp_tag = q_tag;
	assign u_rsp_error = r_error;
	assign m_req_valid = st == MREQ;
	assign m_req_write = q_write;
	assign m_req_line = q_line;
	assign m_req_be = q_be;
	assign m_req_wdata = q_wdata;
	assign m_req_tag = q_tag;

	wire unused_ok = &{1'b0, m_rsp_write, m_rsp_tag};
endmodule

`default_nettype wire
