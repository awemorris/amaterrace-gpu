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
	output reg [23:0] rgb,
	output reg de,
	output reg hs,
	output reg vs,
	output reg frame_toggle,
	output reg vsync_toggle,
	output reg underflow_toggle,
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

	/* The bounds, registered. */
	reg [11:0] ha, hss, hse, hlast, va, vss, vse, vlast, bar_w;
	reg [1:0] pol;

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

	/* The counters, and the test pattern's bar and place in it.  running
	 * rises one cycle after enable with the counters still at the start of
	 * the vsync line. */
	reg [11:0] h, v, bx;
	reg [2:0] bar;
	reg running;

	assign line = v;
	assign col = h;

	/* TEST_PATTERN and FORMAT are taken while stopped and at each vsync,
	 * so a write of CTRL that clears them with ENABLE (whose am_sync is two
	 * cycles slower) does not change the frame being shown. */
	reg tp;
	reg [1:0] fmt;

	/* The counters' next values, and the last column of a bar, of the screen and its last line. */
	wire [11:0] h_inc, v_inc, bx_inc, bar_last, ha_last, va_last;
	wire [2:0] bar_inc;
	wire [6:0] cnt_co_unused;

	am_add #(.W(12)) a_h (.a(h), .b(12'd0), .ci(1'b1), .s(h_inc), .co(cnt_co_unused[0]));
	am_add #(.W(12)) a_v (.a(v), .b(12'd0), .ci(1'b1), .s(v_inc), .co(cnt_co_unused[1]));
	am_add #(.W(12)) a_bx (.a(bx), .b(12'd0), .ci(1'b1), .s(bx_inc), .co(cnt_co_unused[2]));
	am_add #(.W(3)) a_bar (.a(bar), .b(3'd0), .ci(1'b1), .s(bar_inc), .co(cnt_co_unused[3]));
	am_sub #(.W(12)) s_barw (.a(bar_w), .b(12'd1), .bi(1'b0), .d(bar_last), .bo(cnt_co_unused[4]));
	am_sub #(.W(12)) s_ha (.a(ha), .b(12'd1), .bi(1'b0), .d(ha_last), .bo(cnt_co_unused[5]));
	am_sub #(.W(12)) s_va (.a(va), .b(12'd1), .bi(1'b0), .d(va_last), .bo(cnt_co_unused[6]));

	wire de_c = h < ha && v < va;
	wire hs_c = h >= hss && h < hse;
	wire vs_c = v >= vss && v < vse;
	wire take = de_c && !tp;
	assign px_ready = running && px_valid && (take || vs_c);

	always @(posedge clk) begin
		if (!running || (h == 12'd0 && v == vss)) begin
			tp <= test_pattern;
			fmt <= format;
		end
	end

	reg vrr_flip_latched;
	reg [11:0] vrr_lines;
	wire [11:0] vrr_lines_inc;
	wire vrr_co_unused;
	am_add #(.W(12)) a_vrr_lines (.a(vrr_lines), .b(12'd0), .ci(1'b1), .s(vrr_lines_inc), .co(vrr_co_unused));

	wire [11:0] eff_vmax = (vrr_vmax != 12'd0) ? vrr_vmax : vlast;
	wire vrr_hold = vrr_en && (v == vss) && !flip_ready && !vrr_flip_latched && (vrr_lines < eff_vmax);
	wire vrr_take = vrr_en && (v == vss) && (h == hlast) && !vrr_hold;

	always @(posedge clk) begin
		if (!rst_n || !enable) begin
			vrr_flip_latched <= 1'b0;
		end else begin
			if (flip_ready)
				vrr_flip_latched <= 1'b1;
			else if (vrr_take)
				vrr_flip_latched <= 1'b0;
		end
	end

	always @(posedge clk) begin
		if (!rst_n || !enable) begin
			h <= 12'd0;
			v <= vss;
			bx <= 12'd0;
			bar <= 3'd0;
			running <= 1'b0;
			vrr_lines <= 12'd0;
		end else if (!running) begin
			running <= 1'b1;
		end else if (h == hlast) begin
			h <= 12'd0;
			bx <= 12'd0;
			bar <= 3'd0;
			if (vrr_hold) begin
				v <= vss;
				vrr_lines <= vrr_lines_inc;
			end else begin
				v <= v == vlast ? 12'd0 : v_inc;
				vrr_lines <= 12'd0;
			end
		end else begin
			h <= h_inc;
			if (bx == bar_last) begin
				bx <= 12'd0;
				bar <= bar_inc;
			end else begin
				bx <= bx_inc;
			end
		end
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
		if (h == 12'd0 || h == ha_last || v == 12'd0 || v == va_last)
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

	always @(posedge clk) begin
		if (!rst_n) begin
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
			if (!running || !de_c) begin
				rgb <= 24'd0;
				rgb10 <= 30'd0;
			end else if (tp) begin
				rgb <= pattern;
				rgb10 <= {{pattern[23:16], pattern[23:22]}, {pattern[15:8], pattern[15:14]}, {pattern[7:0], pattern[7:6]}};
			end else if (px_valid) begin
				rgb <= convert(fmt, px_data);
				rgb10 <= convert10(fmt, px_data);
			end else begin
				rgb <= 24'd0;
				rgb10 <= 30'd0;
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
