/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_icache: The SU's instruction cache: 2 KiB direct-mapped (256
 * instructions), lines of LINE_BYTES from the AMB, invalidated by
 * LOAD_PROGRAM / INVALIDATE[3].
 *
 * The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_icache.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_icache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter IC_BYTES = 2048	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire ic_req,
	output wire ic_ready,
	input wire [31:0] ic_addr,
	output wire ic_rvalid,
	output wire [63:0] ic_rdata,
	input wire inv,
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
	localparam NLINES = IC_BYTES / LINE_BYTES;
	localparam IX_W = $clog2(NLINES);
	localparam OFF_W = $clog2(IC_BYTES);
	localparam TAG_W = ADDR_W - OFF_W;
	localparam WPL = LINE_BYTES / 8;	/* instructions per line */
	localparam WS_W = WPL > 1 ? $clog2(WPL) : 1;
	localparam [1:0] S_IDLE = 2'd0, S_MREQ = 2'd1, S_MWAIT = 2'd2, S_RESP = 2'd3;

	localparam TAG_LO = TAG_W / 2;
	localparam TAG_HI = TAG_W - TAG_LO;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam N_SL = LB / 16;
	localparam N_DSL = LB / 64;
	localparam V_SL = (NLINES >= 16) ? (NLINES / 16) : 1;
	localparam V_SW = NLINES / V_SL;
	localparam N_TEQ = (TAG_W + 2) / 3;
	localparam N_LEQ = (LA_W + 2) / 3;

	wire rst_p = !rst_n;
	(* max_fanout = 12 *) reg [1:0] state;
	(* dont_touch = "true" *) reg [3:0] st_idle_m_r;
	(* dont_touch = "true" *) reg st_mwait_tlo_r, st_mwait_thi_r;
	wire [NLINES-1:0] valid;
	reg [TAG_LO-1:0] tags_lo [0:NLINES-1];
	reg [TAG_HI-1:0] tags_hi [0:NLINES-1];
	(* max_fanout = 12 *) reg [ADDR_W-LINE_SHIFT-1:0] mline;	/* the line being filled */
	(* dont_touch = "true" *) reg [IX_W-1:0] m_idx_d_r;
	wire [LB-1:0] fill;
	(* max_fanout = 12 *) reg inv_seen;

	wire st_mwait_nxt = (state == S_MREQ) ? req_ready : ((state == S_MWAIT) ? !(rsp_valid && !rsp_write) : 1'b0);
	wire st_mwait_nxt_d, st_mwait_nxt_f;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_mwn_d (.I0(st_mwait_nxt), .O(st_mwait_nxt_d));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_mwn_f (.I0(st_mwait_nxt), .O(st_mwait_nxt_f));
`else
	assign st_mwait_nxt_d = st_mwait_nxt;
	assign st_mwait_nxt_f = st_mwait_nxt;
`endif
	(* dont_touch = "true" *) reg [N_SL-1:0] st_mwait_f_r;
	always @(posedge clk) begin
		if (rst_p)
			st_mwait_f_r <= {N_SL{1'b0}};
		else
			st_mwait_f_r <= {N_SL{st_mwait_nxt_f}};
	end

	wire [31:0] ic_addr_tag = ic_addr;
	wire [31:0] ic_addr_ram_lo = ic_addr;
	wire [31:0] ic_addr_ram_hi = ic_addr;

	wire [IX_W-1:0] idx_v  = ic_addr_tag[OFF_W-1:LINE_SHIFT];
	wire [IX_W-1:0] idx_lo = ic_addr_tag[OFF_W-1:LINE_SHIFT];
	wire [IX_W-1:0] idx_hi = ic_addr_tag[OFF_W-1:LINE_SHIFT];
	wire [TAG_W-1:0] tag = ic_addr_tag[ADDR_W-1:OFF_W];
	wire [ADDR_W-LINE_SHIFT-1:0] line = ic_addr_tag[ADDR_W-1:LINE_SHIFT];
	wire [WS_W-1:0] wsel = WPL > 1 ? ic_addr_tag[LINE_SHIFT-1:3] : {WS_W{1'b0}};
	wire [TAG_W-1:0] tag_rd = {tags_hi[idx_hi], tags_lo[idx_lo]};

	/* Pure-LUT 3-bit chunk tag and line comparators (0 CARRY4s, 2 LUT levels) */
	(* keep = "true" *) wire [N_TEQ-1:0] hit_teq_g;
	(* keep = "true" *) wire [N_LEQ-1:0] fill_leq_g;
	genvar gteq, gleq;
	generate
		for (gteq = 0; gteq < N_TEQ; gteq = gteq + 1) begin : g_teq
			localparam TB = gteq * 3;
			localparam TW_C = (TB + 3 <= TAG_W) ? 3 : (TAG_W - TB);
			assign hit_teq_g[gteq] = (tag_rd[TB +: TW_C] == tag[TB +: TW_C]);
		end
		for (gleq = 0; gleq < N_LEQ; gleq = gleq + 1) begin : g_leq
			localparam LB_B = gleq * 3;
			localparam LW_C = (LB_B + 3 <= LA_W) ? 3 : (LA_W - LB_B);
			assign fill_leq_g[gleq] = (line[LB_B +: LW_C] == mline[LB_B +: LW_C]);
		end
	endgenerate
	wire hit_idle_a = (state == S_IDLE) && valid[idx_v] && (&hit_teq_g[N_TEQ/2-1:0]);
	wire hit_idle_b = (state == S_IDLE) && (&hit_teq_g[N_TEQ-1:N_TEQ/2]);
	wire hit_m_a    = valid[idx_v] && (&hit_teq_g[N_TEQ/2-1:0]);
	wire hit_m_b    = &hit_teq_g[N_TEQ-1:N_TEQ/2];
	(* keep = "true" *) wire fill_eq_0 = &fill_leq_g[N_LEQ/2-1:0];
	(* keep = "true" *) wire fill_eq_1 = (state == S_RESP) && (&fill_leq_g[N_LEQ-1:N_LEQ/2]);
	wire from_fill = fill_eq_0 && fill_eq_1;
	assign ic_ready = (hit_idle_a && hit_idle_b) || from_fill;
	wire take = ic_req && ((hit_idle_a && hit_idle_b) || from_fill);

	/* The answer, 2 cycles after the request (BRAM rline + dedicated fabric rline_pipe, Rule 4). */
	(* shreg_extract = "no", max_fanout = 12 *) reg rv, rv_pipe, rfill, rfill_pipe;
	(* shreg_extract = "no", max_fanout = 12 *) reg [WS_W-1:0] rsel, rsel_pipe;
	wire [LB-1:0] rline_pipe;
	wire [LB-1:0] fill_pipe;
	assign ic_rvalid = rv_pipe;
	wire [LB-1:0] src;

	genvar gdsl, gsl, grs, gvs, gvi;
	generate
		for (gdsl = 0; gdsl < N_DSL; gdsl = gdsl + 1) begin : g_data_sl
			(* ram_style = "block" *) reg [63:0] data_sl [0:NLINES-1];
			reg [63:0] rline_sl;
			(* dont_touch = "true" *) reg [63:0] rline_pipe_sl;
			(* dont_touch = "true" *) reg st_mwait_d_sl;
			(* dont_touch = "true" *) reg [IX_W-1:0] m_idx_d_sl;
			wire data_we_sl = st_mwait_d_sl && rsp_valid && !rsp_write && !rsp_error && !inv_seen && !inv;
			wire miss_d_raw = st_idle_m_r[gdsl % 4] && ic_req && !(hit_m_a && hit_m_b);
			wire miss_d_sl;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_miss_d (.I0(miss_d_raw), .O(miss_d_sl));
`else
			assign miss_d_sl = miss_d_raw;
`endif
			wire [31:0] ic_addr_ram = (gdsl < 4) ? ic_addr_ram_lo : ic_addr_ram_hi;
			always @(posedge clk) begin
				if (data_we_sl)
					data_sl[m_idx_d_sl] <= rsp_rdata[gdsl*64 +: 64];
				if (take)
					rline_sl <= data_sl[ic_addr_ram[OFF_W-1:LINE_SHIFT]];
				rline_pipe_sl <= rline_sl;
				if (rst_p) begin
					st_mwait_d_sl <= 1'b0;
					m_idx_d_sl <= {IX_W{1'b0}};
				end else begin
					if (miss_d_sl)
						m_idx_d_sl <= line[IX_W-1:0];
					st_mwait_d_sl <= st_mwait_nxt_d;
				end
			end
			assign rline_pipe[gdsl*64 +: 64] = rline_pipe_sl;
		end
		for (gsl = 0; gsl < N_SL; gsl = gsl + 1) begin : g_ic_sl
			(* shreg_extract = "no" *) reg [15:0] fill_sl, fill_pipe_sl;
			(* dont_touch = "true" *) reg rfill_sl;
			wire fill_we_sl_raw = st_mwait_f_r[gsl] && rsp_valid && !rsp_write;
			wire fill_we_sl;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fwe (.I0(fill_we_sl_raw), .O(fill_we_sl));
`else
			assign fill_we_sl = fill_we_sl_raw;
`endif
			always @(posedge clk) begin
				if (fill_we_sl)
					fill_sl <= rsp_error ? 16'd0 : rsp_rdata[gsl*16 +: 16];
				fill_pipe_sl <= fill_sl;
				if (rst_p) begin
					rfill_sl <= 1'b0;
				end else begin
					rfill_sl <= rfill;
				end
			end
			assign fill[gsl*16 +: 16] = fill_sl;
			assign fill_pipe[gsl*16 +: 16] = fill_pipe_sl;
			assign src[gsl*16 +: 16] = rfill_sl ? fill_pipe_sl : rline_pipe[gsl*16 +: 16];
		end
		for (grs = 0; grs < 8; grs = grs + 1) begin : g_rdata_sl
			(* dont_touch = "true" *) reg [WS_W-1:0] rsel_sl;
			always @(posedge clk) begin
				if (rst_p)
					rsel_sl <= {WS_W{1'b0}};
				else
					rsel_sl <= rsel;
			end
			wire [63:0] src_w = src[rsel_sl*64 +: 64];
			assign ic_rdata[grs*8 +: 8] = src_w[grs*8 +: 8];
		end
		for (gvs = 0; gvs < V_SL; gvs = gvs + 1) begin : g_val_sl
			wire [35:0] m_idx_pad = {{(36-IX_W){1'b0}}, mline[IX_W-1:0]};
			(* keep = "true" *) wire v_clr_sl = rst_p || inv;
			(* keep = "true" *) wire v_set_sl = (state == S_MWAIT) && rsp_valid && !rsp_write && !rsp_error && !inv_seen &&
				(m_idx_pad[35:4] == gvs);
			for (gvi = 0; gvi < V_SW; gvi = gvi + 1) begin : g_val_bit
				reg valid_bit;
				always @(posedge clk) begin
					if (v_clr_sl)
						valid_bit <= 1'b0;
					else if (v_set_sl && (m_idx_pad[3:0] == gvi[3:0]))
						valid_bit <= 1'b1;
				end
				assign valid[gvs*V_SW + gvi] = valid_bit;
			end
		end
	endgenerate

	(* keep = "true" *) wire [IX_W-1:0] m_idx_lo = mline[IX_W-1:0];
	(* keep = "true" *) wire [IX_W-1:0] m_idx_hi = mline[IX_W-1:0];
	wire tag_we_lo = st_mwait_tlo_r && rsp_valid && !rsp_write && !rsp_error && !inv_seen && !inv;
	wire tag_we_hi = st_mwait_thi_r && rsp_valid && !rsp_write && !rsp_error && !inv_seen && !inv;
	always @(posedge clk) begin
		if (tag_we_lo)
			tags_lo[m_idx_lo] <= mline[IX_W +: TAG_LO];
		if (tag_we_hi)
			tags_hi[m_idx_hi] <= mline[IX_W + TAG_LO +: TAG_HI];
	end

	assign req_valid = state == S_MREQ;
	assign req_write = 1'b0;
	assign req_line = mline;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = 8'd0;

	wire miss_0 = st_idle_m_r[0] && ic_req && !(hit_m_a && hit_m_b);
	wire miss_1 = st_idle_m_r[1] && ic_req && !(hit_m_a && hit_m_b);
	wire miss_2 = st_idle_m_r[2] && ic_req && !(hit_m_a && hit_m_b);
	wire miss_3 = st_idle_m_r[3] && ic_req && !(hit_m_a && hit_m_b);

	always @(posedge clk) begin
		if (rst_p) begin
			state <= S_IDLE;
			st_idle_m_r <= 4'b1111;
			st_mwait_tlo_r <= 1'b0;
			st_mwait_thi_r <= 1'b0;
			rv <= 1'b0;
			rv_pipe <= 1'b0;
			rfill <= 1'b0;
			rfill_pipe <= 1'b0;
			rsel <= {WS_W{1'b0}};
			rsel_pipe <= {WS_W{1'b0}};
			inv_seen <= 1'b0;
			mline <= {(ADDR_W-LINE_SHIFT){1'b0}};
			m_idx_d_r <= {IX_W{1'b0}};
		end else begin
			rv <= take;
			rv_pipe <= rv;
			rfill_pipe <= rfill;
			rsel_pipe <= rsel;
			if (take) begin
				rfill <= from_fill;
				rsel <= wsel;
			end
			if (miss_0)
				mline[8:0] <= line[8:0];
			if (miss_1)
				mline[17:9] <= line[17:9];
			if (miss_2)
				mline[LA_W-1:18] <= line[LA_W-1:18];
			if (miss_3)
				m_idx_d_r <= line[IX_W-1:0];
			case (state)
			S_IDLE:
				if (miss_3) begin
					state <= S_MREQ;
					st_idle_m_r <= 4'b0000;
					inv_seen <= 1'b0;
				end
			S_MREQ:
				if (req_ready) begin
					state <= S_MWAIT;
					st_mwait_tlo_r <= 1'b1;
					st_mwait_thi_r <= 1'b1;
				end
			S_MWAIT:
				if (rsp_valid && !rsp_write) begin
					state <= S_RESP;
					st_mwait_tlo_r <= 1'b0;
					st_mwait_thi_r <= 1'b0;
				end
			default: begin	/* S_RESP: one cycle for the waiting request */
				state <= S_IDLE;
				st_idle_m_r <= 4'b1111;
			end
			endcase
			if (inv) begin
				inv_seen <= 1'b1;
			end
		end
	end

	wire unused_ok = &{1'b0, rsp_tag, ic_addr[2:0], fill, fill_pipe, rfill_pipe, rsel_pipe, m_idx_d_r, (TAG_W == 0)};
endmodule

`default_nettype wire
