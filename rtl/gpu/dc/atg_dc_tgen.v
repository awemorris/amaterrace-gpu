/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tgen: The DC's timing generator in the pixel clock: h/v counters,
 * DE/HSYNC/VSYNC, pixel pop from the FIFO, format conversion to RGB888,
 * the test pattern, frame start and vsync events.  See
 * spec/gpu/dc/atg_dc_tgen.md.
 *
 * A line is H_ACTIVE pixels, then the front porch, the sync and the back
 * porch; a frame is V_ACTIVE lines, then the same in lines.  Pixel (0, 0)
 * is the first active one.  SYNC_POL[0]/[1] = 1 makes HSYNC/VSYNC active
 * high.  The timing words are quasi-static (atg_dc_regs §7): the bounds
 * are registered once more here and must be stable while enable is 1.
 *
 * While enable is 0 the counters wait at the first pixel of the vsync line
 * (h = 0, v = V_ACTIVE + V_FP) and the outputs are idle (DE 0, syncs
 * inactive, black), so a frame always starts with a vsync: vsync_toggle
 * toggles at the start of each vsync, frame_toggle at the start of the
 * back porch (the DMA starts the frame there; it has the back porch to
 * fill the FIFO).  During the vsync lines the FIFO is drained: pixels left
 * from a frame the DMA did not finish in time (or that did not fit the
 * active area) are dropped, so each frame starts aligned.
 *
 * During DE a pixel is popped each cycle (not in TEST_PATTERN, which reads
 * no memory); an empty FIFO gives black and toggles underflow_toggle.
 * Formats: 0 BGRA8 (memory bytes B, G, R, A), 1 RGBA8, 2 RGB565 in the low
 * 16 bits (channels widened by repeating their top bits).
 *
 * The test pattern: eight vertical bars of H_ACTIVE / 8 pixels (white,
 * yellow, cyan, green, magenta, red, blue, black) and a white border of
 * one pixel around the active area.
 *
 * Outputs are registered: rgb, de, hs and vs of a pixel come out together
 * one cycle after its counters.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tgen (
	input wire clk,
	input wire rst_n,
	input wire enable,
	input wire test_pattern,
	input wire [1:0] format,
	input wire [287:0] timing,
	input wire px_valid,
	output wire px_ready,
	input wire [31:0] px_data,
	(* max_fanout = 16 *) output reg [23:0] rgb,
	(* max_fanout = 16 *) output reg de,
	(* max_fanout = 16 *) output reg hs,
	(* max_fanout = 16 *) output reg vs,
	(* max_fanout = 16 *) output reg frame_toggle,
	(* max_fanout = 16 *) output reg vsync_toggle,
	(* max_fanout = 16 *) output reg underflow_toggle,
	output wire [11:0] line,
	/* Extended WSI / VRR ports (ws002-p010) */
	input wire vrr_en,
	input wire flip_ready,
	input wire [11:0] vrr_vmax,
	output wire [11:0] col,
	output reg [29:0] rgb10
);
	/* The timing words (12 bits used of each). */
	wire [11:0] t_ha = timing[11:0];
	wire [11:0] t_hfp = timing[43:32];
	wire [11:0] t_hs = timing[75:64];
	wire [11:0] t_hbp = timing[107:96];
	wire [11:0] t_va = timing[139:128];
	wire [11:0] t_vfp = timing[171:160];
	wire [11:0] t_vs = timing[203:192];
	wire [11:0] t_vbp = timing[235:224];
	wire [1:0] t_pol = timing[257:256];

	(* keep = "true" *) wire rst_high = !rst_n;
	(* keep = "true" *) wire tgen_clr_rst = rst_high || !enable;

`ifdef SYNTH_KINTEX7
	reg vrr_en_q, flip_ready_q;
	reg [11:0] vrr_vmax_q;
	always @(posedge clk) begin
		vrr_en_q <= vrr_en;
		flip_ready_q <= flip_ready;
		vrr_vmax_q <= vrr_vmax;
	end
	wire d_vrr_en = vrr_en_q;
	wire d_flip_ready = flip_ready_q;
	wire [11:0] d_vrr_vmax = vrr_vmax_q;
`else
	wire d_vrr_en = vrr_en;
	wire d_flip_ready = flip_ready;
	wire [11:0] d_vrr_vmax = vrr_vmax;
`endif

	/* The bounds, registered. */
	reg [11:0] ha, hss, hse, hlast, va, vss, vse, vlast, bar_w;
	reg [1:0] pol;

`ifdef SYNTH_KINTEX7
	/* Pipelined timing computation (Rule 1: at most 1 adder per stage, CARRY4 <= 3) */
	wire [11:0] p1_hss_w, p1_hbp_m1_w, p1_vss_w, p1_vbp_m1_w;
	wire [3:0] p1_co_unused;
	am_add #(.W(12)) u_p1_hss (.a(t_ha),  .b(t_hfp),      .ci(1'b0), .s(p1_hss_w),    .co(p1_co_unused[0]));
	am_sub #(.W(12)) u_p1_hbp (.a(t_hbp), .b(12'd1),      .bi(1'b0), .d(p1_hbp_m1_w), .bo(p1_co_unused[1]));
	am_add #(.W(12)) u_p1_vss (.a(t_va),  .b(t_vfp),      .ci(1'b0), .s(p1_vss_w),    .co(p1_co_unused[2]));
	am_sub #(.W(12)) u_p1_vbp (.a(t_vbp), .b(12'd1),      .bi(1'b0), .d(p1_vbp_m1_w), .bo(p1_co_unused[3]));

	reg [11:0] p1_ha, p1_hss, p1_hs, p1_hbp_m1;
	reg [11:0] p1_va, p1_vss, p1_vs, p1_vbp_m1;
	reg [1:0]  p1_pol;
	always @(posedge clk) begin
		p1_ha     <= t_ha;
		p1_hss    <= p1_hss_w;
		p1_hs     <= t_hs;
		p1_hbp_m1 <= p1_hbp_m1_w;
		p1_va     <= t_va;
		p1_vss    <= p1_vss_w;
		p1_vs     <= t_vs;
		p1_vbp_m1 <= p1_vbp_m1_w;
		p1_pol    <= t_pol;
	end

	wire [11:0] p2_hse_w, p2_vse_w;
	wire [1:0] p2_co_unused;
	am_add #(.W(12)) u_p2_hse (.a(p1_hss), .b(p1_hs), .ci(1'b0), .s(p2_hse_w), .co(p2_co_unused[0]));
	am_add #(.W(12)) u_p2_vse (.a(p1_vss), .b(p1_vs), .ci(1'b0), .s(p2_vse_w), .co(p2_co_unused[1]));

	reg [11:0] p2_ha, p2_hss, p2_hse, p2_hbp_m1;
	reg [11:0] p2_va, p2_vss, p2_vse, p2_vbp_m1;
	reg [1:0]  p2_pol;
	always @(posedge clk) begin
		p2_ha     <= p1_ha;
		p2_hss    <= p1_hss;
		p2_hse    <= p2_hse_w;
		p2_hbp_m1 <= p1_hbp_m1;
		p2_va     <= p1_va;
		p2_vss    <= p1_vss;
		p2_vse    <= p2_vse_w;
		p2_vbp_m1 <= p1_vbp_m1;
		p2_pol    <= p1_pol;
	end

	wire [11:0] p3_hlast_w, p3_vlast_w;
	wire [1:0] p3_co_unused;
	am_add #(.W(12)) u_p3_hlast (.a(p2_hse), .b(p2_hbp_m1), .ci(1'b0), .s(p3_hlast_w), .co(p3_co_unused[0]));
	am_add #(.W(12)) u_p3_vlast (.a(p2_vse), .b(p2_vbp_m1), .ci(1'b0), .s(p3_vlast_w), .co(p3_co_unused[1]));

	always @(posedge clk) begin
		ha    <= p2_ha;
		hss   <= p2_hss;
		hse   <= p2_hse;
		hlast <= p3_hlast_w;
		va    <= p2_va;
		vss   <= p2_vss;
		vse   <= p2_vse;
		vlast <= p3_vlast_w;
		bar_w <= {3'd0, p2_ha[11:3]};
		pol   <= p2_pol;
	end
	wire [7:0] bnd_co_unused = {p1_co_unused, p2_co_unused, p3_co_unused};
`else
	/* The bounds: the sync's start and end and the last count of a line and of a frame. */
	wire [11:0] hss_c, hse_c, htot_c, hlast_c, vss_c, vse_c, vtot_c, vlast_c;
	wire [7:0] bnd_co_unused;

	am_add #(.W(12)) a_hss (.a(t_ha), .b(t_hfp), .ci(1'b0), .s(hss_c), .co(bnd_co_unused[0]));
	am_add #(.W(12)) a_hse (.a(hss_c), .b(t_hs), .ci(1'b0), .s(hse_c), .co(bnd_co_unused[1]));
	am_add #(.W(12)) a_htot (.a(hse_c), .b(t_hbp), .ci(1'b0), .s(htot_c), .co(bnd_co_unused[2]));
	am_sub #(.W(12)) s_hlast (.a(htot_c), .b(12'd1), .bi(1'b0), .d(hlast_c), .bo(bnd_co_unused[3]));
	am_add #(.W(12)) a_vss (.a(t_va), .b(t_vfp), .ci(1'b0), .s(vss_c), .co(bnd_co_unused[4]));
	am_add #(.W(12)) a_vse (.a(vss_c), .b(t_vs), .ci(1'b0), .s(vse_c), .co(bnd_co_unused[5]));
	am_add #(.W(12)) a_vtot (.a(vse_c), .b(t_vbp), .ci(1'b0), .s(vtot_c), .co(bnd_co_unused[6]));
	am_sub #(.W(12)) s_vlast (.a(vtot_c), .b(12'd1), .bi(1'b0), .d(vlast_c), .bo(bnd_co_unused[7]));

	always @(posedge clk) begin
		ha <= t_ha;
		hss <= hss_c;
		hse <= hse_c;
		hlast <= hlast_c;
		va <= t_va;
		vss <= vss_c;
		vse <= vse_c;
		vlast <= vlast_c;
		bar_w <= {3'd0, t_ha[11:3]};
		pol <= t_pol;
	end
`endif

	/* The counters, and the test pattern's bar and place in it.  running
	 * rises one cycle after enable with the counters still at the start of
	 * the vsync line. */
	(* extract_reset = "no" *) (* max_fanout = 16 *) reg [11:0] h, v, bx;
	(* extract_reset = "no" *) (* max_fanout = 16 *) reg [2:0] bar;
	(* max_fanout = 16 *) reg running;

	assign line = v;
	assign col = h;

	/* TEST_PATTERN and FORMAT are taken while stopped and at each vsync,
	 * so a write of CTRL that clears them with ENABLE (whose am_sync is two
	 * cycles slower) does not change the frame being shown. */
	(* max_fanout = 16 *) reg tp;
	(* max_fanout = 16 *) reg [1:0] fmt;

	/* The counters' next values, and the last column of a bar, of the screen and its last line. */
	wire [11:0] h_inc, v_inc, bx_inc;
	wire [2:0] bar_inc;
	wire [6:0] cnt_co_unused;

	am_add #(.W(12)) a_h (.a(h), .b(12'd0), .ci(1'b1), .s(h_inc), .co(cnt_co_unused[0]));
	am_add #(.W(12)) a_v (.a(v), .b(12'd0), .ci(1'b1), .s(v_inc), .co(cnt_co_unused[1]));
	am_add #(.W(12)) a_bx (.a(bx), .b(12'd0), .ci(1'b1), .s(bx_inc), .co(cnt_co_unused[2]));
	am_add #(.W(3)) a_bar (.a(bar), .b(3'd0), .ci(1'b1), .s(bar_inc), .co(cnt_co_unused[3]));

`ifdef SYNTH_KINTEX7
	wire [11:0] bar_last_w;
	am_sub #(.W(12)) s_barw (.a(bar_w), .b(12'd1), .bi(1'b0), .d(bar_last_w), .bo(cnt_co_unused[4]));
	reg [11:0] bar_last_r;
	always @(posedge clk)
		bar_last_r <= bar_last_w;
	wire [11:0] bar_last = bar_last_r;
`else
	wire [11:0] bar_last;
	am_sub #(.W(12)) s_barw (.a(bar_w), .b(12'd1), .bi(1'b0), .d(bar_last), .bo(cnt_co_unused[4]));
`endif

`ifdef SYNTH_KINTEX7
	wire [11:0] ha_last_w, va_last_w;
	am_sub #(.W(12)) s_ha (.a(ha), .b(12'd1), .bi(1'b0), .d(ha_last_w), .bo(cnt_co_unused[5]));
	am_sub #(.W(12)) s_va (.a(va), .b(12'd1), .bi(1'b0), .d(va_last_w), .bo(cnt_co_unused[6]));
	reg [11:0] ha_last_r, va_last_r;
	always @(posedge clk) begin
		ha_last_r <= ha_last_w;
		va_last_r <= va_last_w;
	end
	wire [11:0] ha_last = ha_last_r;
	wire [11:0] va_last = va_last_r;
`else
	wire [11:0] ha_last, va_last;
	am_sub #(.W(12)) s_ha (.a(ha), .b(12'd1), .bi(1'b0), .d(ha_last), .bo(cnt_co_unused[5]));
	am_sub #(.W(12)) s_va (.a(va), .b(12'd1), .bi(1'b0), .d(va_last), .bo(cnt_co_unused[6]));
`endif

`ifdef SYNTH_KINTEX7
	wire [11:0] diff_hlast = h ^ hlast;
	wire h_last_match = ~(|diff_hlast);
	wire [11:0] diff_halast = h ^ ha_last;
	wire h_act_end_match = ~(|diff_halast);

	wire [11:0] diff_vlast = v ^ vlast;
	reg v_last_match_r;
	always @(posedge clk)
		v_last_match_r <= ~(|diff_vlast);
	wire v_last_match = v_last_match_r;
	wire [11:0] diff_valast = v ^ va_last;
	wire v_act_end_match = ~(|diff_valast);

	reg h_act_r, v_act_r;
	always @(posedge clk) begin
		if (tgen_clr_rst) begin
			h_act_r <= 1'b0;
			v_act_r <= 1'b0;
		end else if (!running) begin
			h_act_r <= 1'b1;
			v_act_r <= 1'b0;
		end else begin
			if (h_last_match) begin
				h_act_r <= 1'b1;
				if (v_last_match)
					v_act_r <= 1'b1;
				else if (v_act_end_match)
					v_act_r <= 1'b0;
			end else if (h_act_end_match) begin
				h_act_r <= 1'b0;
			end
		end
	end
	wire h_act_r_a, h_act_r_b, h_act_r_c;
	wire v_act_r_a, v_act_r_b, v_act_r_c;
	LUT1 #(.INIT(2'b10)) u_buf_ha_a (.I0(h_act_r), .O(h_act_r_a));
	LUT1 #(.INIT(2'b10)) u_buf_ha_b (.I0(h_act_r), .O(h_act_r_b));
	LUT1 #(.INIT(2'b10)) u_buf_ha_c (.I0(h_act_r), .O(h_act_r_c));
	LUT1 #(.INIT(2'b10)) u_buf_va_a (.I0(v_act_r), .O(v_act_r_a));
	LUT1 #(.INIT(2'b10)) u_buf_va_b (.I0(v_act_r), .O(v_act_r_b));
	LUT1 #(.INIT(2'b10)) u_buf_va_c (.I0(v_act_r), .O(v_act_r_c));

	wire de_c = h_act_r_a && v_act_r_a;
	wire de_c_rgb = h_act_r_b && v_act_r_b;
	wire de_c_rgb10 = h_act_r_c && v_act_r_c;
`else
	wire de_c = h < ha && v < va;
	wire de_c_rgb = de_c;
	wire de_c_rgb10 = de_c;
	wire [11:0] diff_vlast = v ^ vlast;
	wire v_last_match = ~(|diff_vlast);
`endif
	wire hs_c = h >= hss && h < hse;
`ifdef SYNTH_KINTEX7
	reg vs_c_r;
	always @(posedge clk)
		vs_c_r <= (v >= vss && v < vse);
	wire vs_c = vs_c_r;
`else
	wire vs_c = v >= vss && v < vse;
`endif
	wire take = de_c && !tp;
	assign px_ready = running && px_valid && (take || vs_c);

	always @(posedge clk) begin
		if (!running || (h == 12'd0 && v == vss)) begin
			tp <= test_pattern;
			fmt <= format;
		end
	end

	reg vrr_flip_latched;
	(* extract_reset = "no" *) (* max_fanout = 16 *) reg [11:0] vrr_lines;
	wire [11:0] vrr_lines_inc;
	wire vrr_co_unused;
	am_add #(.W(12)) a_vrr_lines (.a(vrr_lines), .b(12'd0), .ci(1'b1), .s(vrr_lines_inc), .co(vrr_co_unused));

`ifdef SYNTH_KINTEX7
	reg [11:0] eff_vmax_r;
	always @(posedge clk)
		eff_vmax_r <= (d_vrr_vmax != 12'd0) ? d_vrr_vmax : vlast;
	wire [11:0] eff_vmax = eff_vmax_r;
`else
	wire [11:0] eff_vmax = (d_vrr_vmax != 12'd0) ? d_vrr_vmax : vlast;
`endif
`ifdef SYNTH_KINTEX7
	reg vrr_hold_r;
	always @(posedge clk) begin
		vrr_hold_r <= d_vrr_en && (~(|(v ^ vss))) && !d_flip_ready && !vrr_flip_latched && (vrr_lines < eff_vmax);
	end
	wire vrr_hold = vrr_hold_r;
	wire vrr_hold_v, vrr_hold_l, vrr_hold_t;
	LUT1 #(.INIT(2'b10)) u_buf_vh_v (.I0(vrr_hold), .O(vrr_hold_v));
	LUT1 #(.INIT(2'b10)) u_buf_vh_l (.I0(vrr_hold), .O(vrr_hold_l));
	LUT1 #(.INIT(2'b10)) u_buf_vh_t (.I0(vrr_hold), .O(vrr_hold_t));

	wire bx_match = ~(|(bx ^ bar_last));
	wire bx_match_b, bx_match_c;
	LUT1 #(.INIT(2'b10)) u_buf_bx_b (.I0(bx_match), .O(bx_match_b));
	LUT1 #(.INIT(2'b10)) u_buf_bx_c (.I0(bx_match), .O(bx_match_c));

	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_h0;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_h1;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_v;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_b;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_t;
	wire h_next_is_last = (h_inc == hlast);
	always @(posedge clk) begin
		if (tgen_clr_rst || !running) begin
			h_last_match_h0 <= 1'b0;
			h_last_match_h1 <= 1'b0;
			h_last_match_v  <= 1'b0;
			h_last_match_b  <= 1'b0;
			h_last_match_t  <= 1'b0;
		end else begin
			h_last_match_h0 <= h_next_is_last;
			h_last_match_h1 <= h_next_is_last;
			h_last_match_v  <= h_next_is_last;
			h_last_match_b  <= h_next_is_last;
			h_last_match_t  <= h_next_is_last;
		end
	end
`else
	wire vrr_hold = d_vrr_en && (v == vss) && !d_flip_ready && !vrr_flip_latched && (vrr_lines < eff_vmax);
	wire vrr_hold_v = vrr_hold;
	wire vrr_hold_l = vrr_hold;
	wire vrr_hold_t = vrr_hold;
	wire bx_match = bx == bar_last;
	wire bx_match_b = bx_match;
	wire bx_match_c = bx_match;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_h0;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_h1;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_v;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_b;
	(* keep = "true", equivalent_register_removal = "no" *) reg h_last_match_t;
	wire h_next_is_last = (h_inc == hlast);
	always @(posedge clk) begin
		if (tgen_clr_rst || !running) begin
			h_last_match_h0 <= 1'b0;
			h_last_match_h1 <= 1'b0;
			h_last_match_v  <= 1'b0;
			h_last_match_b  <= 1'b0;
			h_last_match_t  <= 1'b0;
		end else begin
			h_last_match_h0 <= h_next_is_last;
			h_last_match_h1 <= h_next_is_last;
			h_last_match_v  <= h_next_is_last;
			h_last_match_b  <= h_next_is_last;
			h_last_match_t  <= h_next_is_last;
		end
	end
`endif
	wire vrr_take = d_vrr_en && (v == vss) && h_last_match_t && !vrr_hold_t;

	always @(posedge clk) begin
		if (tgen_clr_rst) begin
			vrr_flip_latched <= 1'b0;
		end else begin
			if (d_flip_ready)
				vrr_flip_latched <= 1'b1;
			else if (vrr_take)
				vrr_flip_latched <= 1'b0;
		end
	end

	always @(posedge clk) begin
		if (tgen_clr_rst) begin
			h[5:0] <= 6'd0;
		end else if (!running) begin
			h[5:0] <= 6'd0;
		end else if (h_last_match_h0) begin
			h[5:0] <= 6'd0;
		end else begin
			h[5:0] <= h_inc[5:0];
		end
	end

	always @(posedge clk) begin
		if (tgen_clr_rst) begin
			h[11:6] <= 6'd0;
			running <= 1'b0;
		end else if (!running) begin
			running <= 1'b1;
			h[11:6] <= 6'd0;
		end else if (h_last_match_h1) begin
			h[11:6] <= 6'd0;
		end else begin
			h[11:6] <= h_inc[11:6];
		end
	end

	wire v_ce = tgen_clr_rst || (running && h_last_match_v);
	wire [11:0] nxt_v = (tgen_clr_rst || vrr_hold_v) ? vss : (v_last_match ? 12'd0 : v_inc);

	always @(posedge clk) begin
		if (v_ce)
			v <= nxt_v;
	end

	always @(posedge clk) begin
		if (tgen_clr_rst)
			vrr_lines <= 12'd0;
		else if (running && h_last_match_v)
			vrr_lines <= vrr_hold_l ? vrr_lines_inc : 12'd0;
	end

	(* keep = "true" *) wire bx_clr_rst = tgen_clr_rst || !running || h_last_match_b;
	always @(posedge clk) begin
		if (bx_clr_rst)
			bx <= 12'd0;
		else if (bx_match_b)
			bx <= 12'd0;
		else
			bx <= bx_inc;
	end

	always @(posedge clk) begin
		if (bx_clr_rst)
			bar <= 3'd0;
		else if (bx_match_c)
			bar <= bar_inc;
	end

	/* verilator lint_off UNUSEDSIGNAL */
	/* A memory pixel to RGB888. */
	function [23:0] convert;
		input [1:0] f;
		input [31:0] w;	/* full 32-bit pixel */
		begin
			case (f)
			2'd1: convert = {w[7:0], w[15:8], w[23:16]};
			2'd2: convert = {w[15:11], w[15:13], w[10:5], w[10:9], w[4:0], w[4:2]};
			2'd3: convert = {w[9:2], w[19:12], w[29:22]}; /* A2B10G10R10 */
			default: convert = w[23:0];
			endcase
		end
	endfunction

	/* A memory pixel to 10-bit RGB (30-bit: [29:20] R, [19:10] G, [9:0] B). */
	function [29:0] convert10;
		input [1:0] f;
		input [31:0] w;
		begin
			case (f)
			2'd0: convert10 = {{w[23:16], w[23:22]}, {w[15:8], w[15:14]}, {w[7:0], w[7:6]}}; /* BGRA8 */
			2'd1: convert10 = {{w[7:0], w[7:6]}, {w[15:8], w[15:14]}, {w[23:16], w[23:22]}}; /* RGBA8 */
			2'd2: convert10 = {{w[15:11], w[15:11]}, {w[10:5], w[10:7]}, {w[4:0], w[4:0]}}; /* RGB565 */
			2'd3: convert10 = {w[9:0], w[19:10], w[29:20]}; /* A2B10G10R10 */
			endcase
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	reg [23:0] pattern;

	always @(*) begin
`ifdef SYNTH_KINTEX7
		if (~(|h) || h_act_end_match || ~(|v) || v_act_end_match)
`else
		if (h == 12'd0 || h == ha_last || v == 12'd0 || v == va_last)
`endif
			pattern = 24'hFFFFFF;
		else
			case (bar)
			3'd0: pattern = 24'hFFFFFF;
			3'd1: pattern = 24'hFFFF00;
			3'd2: pattern = 24'h00FFFF;
			3'd3: pattern = 24'h00FF00;
			3'd4: pattern = 24'hFF00FF;
			3'd5: pattern = 24'hFF0000;
			3'd6: pattern = 24'h0000FF;
			default: pattern = 24'h000000;
			endcase
	end

`ifdef SYNTH_KINTEX7
	wire clr_rgb, clr_rgb10_lo, clr_rgb10_hi;
	LUT1 #(.INIT(2'b10)) u_buf_clr_rgb (.I0(!running || !de_c_rgb), .O(clr_rgb));
	LUT1 #(.INIT(2'b10)) u_buf_clr_10l (.I0(!running || !de_c_rgb10), .O(clr_rgb10_lo));
	LUT1 #(.INIT(2'b10)) u_buf_clr_10h (.I0(!running || !de_c_rgb10), .O(clr_rgb10_hi));
`else
	wire clr_rgb = !running || !de_c;
	wire clr_rgb10_lo = clr_rgb;
	wire clr_rgb10_hi = clr_rgb;
`endif
	wire [29:0] pattern10 = {{pattern[23:16], pattern[23:22]}, {pattern[15:8], pattern[15:14]}, {pattern[7:0], pattern[7:6]}};
	wire [29:0] px_data10 = convert10(fmt, px_data);

	always @(posedge clk) begin
		if (rst_high) begin
			rgb <= 24'd0;
			rgb10 <= 30'd0;
			de <= 1'b0;
			hs <= 1'b0;
			vs <= 1'b0;
			frame_toggle <= 1'b0;
			vsync_toggle <= 1'b0;
			underflow_toggle <= 1'b0;
		end else begin
			de <= running && de_c;
			hs <= (running && hs_c) == pol[0];
			vs <= (running && vs_c) == pol[1];
			if (clr_rgb) begin
				rgb <= 24'd0;
			end else if (tp) begin
				rgb <= pattern;
			end else if (px_valid) begin
				rgb <= convert(fmt, px_data);
			end else begin
				rgb <= 24'd0;
			end

			if (clr_rgb10_lo) begin
				rgb10[14:0] <= 15'd0;
			end else if (tp) begin
				rgb10[14:0] <= pattern10[14:0];
			end else if (px_valid) begin
				rgb10[14:0] <= px_data10[14:0];
			end else begin
				rgb10[14:0] <= 15'd0;
			end

			if (clr_rgb10_hi) begin
				rgb10[29:15] <= 15'd0;
			end else if (tp) begin
				rgb10[29:15] <= pattern10[29:15];
			end else if (px_valid) begin
				rgb10[29:15] <= px_data10[29:15];
			end else begin
				rgb10[29:15] <= 15'd0;
			end
			if (running && h == 12'd0 && v == vss)
				vsync_toggle <= !vsync_toggle;
			if (running && h == 12'd0 && v == vse)
				frame_toggle <= !frame_toggle;
			if (running && take && !px_valid)
				underflow_toggle <= !underflow_toggle;
		end
	end

	wire unused_ok = &{1'b0, bnd_co_unused, cnt_co_unused, vrr_co_unused,
		timing[287:258], timing[255:236], timing[223:204],
		timing[191:172], timing[159:140], timing[127:108], timing[95:76], timing[63:44],
		timing[31:12]};
endmodule

`default_nettype wire
