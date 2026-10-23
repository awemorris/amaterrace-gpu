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
 * spec/dc/atg_dc_tgen.md.
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
	output wire [11:0] line
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

	/* The bounds, registered. */
	reg [11:0] ha, hss, hse, hlast, va, vss, vse, vlast, bar_w;
	reg [1:0] pol;

	always @(posedge clk) begin
		ha <= t_ha;
		hss <= t_ha + t_hfp;
		hse <= t_ha + t_hfp + t_hs;
		hlast <= t_ha + t_hfp + t_hs + t_hbp - 12'd1;
		va <= t_va;
		vss <= t_va + t_vfp;
		vse <= t_va + t_vfp + t_vs;
		vlast <= t_va + t_vfp + t_vs + t_vbp - 12'd1;
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

	/* TEST_PATTERN and FORMAT are taken while stopped and at each vsync,
	 * so a write of CTRL that clears them with ENABLE (whose am_sync is two
	 * cycles slower) does not change the frame being shown. */
	reg tp;
	reg [1:0] fmt;

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

	always @(posedge clk) begin
		if (!rst_n || !enable) begin
			h <= 12'd0;
			v <= vss;
			bx <= 12'd0;
			bar <= 3'd0;
			running <= 1'b0;
		end else if (!running) begin
			running <= 1'b1;
		end else if (h == hlast) begin
			h <= 12'd0;
			v <= v == vlast ? 12'd0 : v + 12'd1;
			bx <= 12'd0;
			bar <= 3'd0;
		end else begin
			h <= h + 12'd1;
			if (bx == bar_w - 12'd1) begin
				bx <= 12'd0;
				bar <= bar + 3'd1;
			end else begin
				bx <= bx + 12'd1;
			end
		end
	end

	/* A memory pixel to RGB888. */
	function [23:0] convert;
		input [1:0] f;
		input [23:0] w;	/* the alpha byte is not shown */
		begin
			case (f)
			2'd1: convert = {w[7:0], w[15:8], w[23:16]};
			2'd2: convert = {w[15:11], w[15:13], w[10:5], w[10:9], w[4:0], w[4:2]};
			default: convert = w[23:0];
			endcase
		end
	endfunction

	reg [23:0] pattern;

	always @(*) begin
		if (h == 12'd0 || h == ha - 12'd1 || v == 12'd0 || v == va - 12'd1)
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
			if (!running || !de_c)
				rgb <= 24'd0;
			else if (tp)
				rgb <= pattern;
			else if (px_valid)
				rgb <= convert(fmt, px_data[23:0]);
			else
				rgb <= 24'd0;
			if (running && h == 12'd0 && v == vss)
				vsync_toggle <= !vsync_toggle;
			if (running && h == 12'd0 && v == vse)
				frame_toggle <= !frame_toggle;
			if (running && take && !px_valid)
				underflow_toggle <= !underflow_toggle;
		end
	end

	wire unused_ok = &{1'b0, px_data[31:24], timing[287:258], timing[255:236], timing[223:204],
		timing[191:172], timing[159:140], timing[127:108], timing[95:76], timing[63:44],
		timing[31:12]};
endmodule

`default_nettype wire
