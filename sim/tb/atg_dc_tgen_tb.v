/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tgen_tb: 640x480@60 (VESA DMT: H 640/16/96/48, V 480/10/2/33,
 * both syncs negative) and 1280x720 (CEA-861: H 1280/110/40/220, V
 * 720/5/5/20, positive) measured on the outputs; the event toggles' places
 * (vsync at the start of the sync, frame start at the back porch); the
 * pixels popped in order and converted in each format; the drain in the
 * vsync lines; the test pattern's bars and border; underflow (black and a
 * toggle per missing pixel).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tgen_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #2 clk = !clk;

	reg enable = 0, test_pattern = 0;
	reg [1:0] format = 2'd0;
	reg [287:0] timing = 288'd0;
	reg px_valid = 1'b1;
	wire px_ready;
	reg [31:0] px_data = 32'd0;
	wire [23:0] rgb;
	wire de, hs, vs, frame_toggle, vsync_toggle, underflow_toggle;
	wire [11:0] line;

	atg_dc_tgen dut (
		.clk(clk), .rst_n(rst_n), .enable(enable), .test_pattern(test_pattern),
		.format(format), .timing(timing),
		.px_valid(px_valid), .px_ready(px_ready), .px_data(px_data),
		.rgb(rgb), .de(de), .hs(hs), .vs(vs),
		.frame_toggle(frame_toggle), .vsync_toggle(vsync_toggle),
		.underflow_toggle(underflow_toggle), .line(line)
	);

	integer errors = 0;
	integer e0;
	integer k;

	task fail;
		input [8*60-1:0] what;
		input integer got;
		input integer want;
		begin
			errors = errors + 1;
			$display("FAIL atg_dc_tgen.%0s: %0d, expected %0d", what, got, want);
		end
	endtask

	task set_timing;
		input integer ha, hfp, hsw, hbp, va, vfp, vsw, vbp, pol;
		reg [31:0] w [0:8];
		integer i;
		begin
			w[0] = ha; w[1] = hfp; w[2] = hsw; w[3] = hbp;
			w[4] = va; w[5] = vfp; w[6] = vsw; w[7] = vbp; w[8] = pol;
			for (i = 0; i < 9; i = i + 1)
				timing[32*i +: 32] = w[i];
		end
	endtask

	/* The source: a counter, popped by px_ready. */
	reg count_src = 1'b1;
	always @(posedge clk)
		if (px_ready && count_src)
			px_data <= px_data + 32'd1;

	/* The observer: a pixel-clock counter and the edges of the outputs. */
	integer cyc = 0;
	reg de_q = 0, hs_q = 0, vs_q = 0;
	integer de_rise = 0, de_fall = 0, hs_act = 0, hs_inact = 0, de_len = 0, line_per = 0;
	integer vs_act = 0, vs_inact = 0, last_de_line_fall = 0, frame_per = 0, de_lines = 0;
	integer lines_in_frame = 0, act_lines = 0, act_lines_last = 0;
	integer vt_cyc = 0, ft_cyc = 0, vt_prev = 0, n_under = 0;
	reg hpol = 0, vpol = 0;
	reg ft_q = 0, vt_q = 0, ut_q = 0;

	always @(posedge clk) begin
		cyc <= cyc + 1;
		de_q <= de;
		hs_q <= hs;
		vs_q <= vs;
		ft_q <= frame_toggle;
		vt_q <= vsync_toggle;
		ut_q <= underflow_toggle;
		if (de && !de_q) begin
			if (de_rise != 0)
				line_per <= cyc - de_rise;
			de_rise <= cyc;
			act_lines <= act_lines + 1;
		end
		if (!de && de_q) begin
			de_fall <= cyc;
			de_len <= cyc - de_rise;
		end
		if (hs == hpol && hs_q != hpol) hs_act <= cyc;
		if (hs != hpol && hs_q == hpol) hs_inact <= cyc;
		if (vs == vpol && vs_q != vpol) begin
			vs_act <= cyc;
			if (vt_prev != 0)
				frame_per <= cyc - vt_prev;
			vt_prev <= cyc;
			act_lines_last <= act_lines;
			act_lines <= 0;
		end
		if (vs != vpol && vs_q == vpol) vs_inact <= cyc;
		if (frame_toggle != ft_q) ft_cyc <= cyc;
		if (vsync_toggle != vt_q) vt_cyc <= cyc;
		if (underflow_toggle != ut_q) n_under <= n_under + 1;
	end

	task check_mode;
		input [8*20-1:0] name;
		input integer ha, hfp, hsw, hbp, va, vfp, vsw, vbp;
		integer ht, vt;
		begin
			ht = ha + hfp + hsw + hbp;
			vt = va + vfp + vsw + vbp;
			/* Two frames, then measure. */
			wait (frame_per != 0);
			k = vs_act;
			wait (vs_act != k);
			k = vs_act;
			wait (vs_act != k);
			wait (vs_inact > vs_act);
			repeat (5) @(posedge clk);
			if (frame_per != ht * vt) fail({name, " frame period"}, frame_per, ht * vt);
			if (act_lines_last != va) fail({name, " active lines"}, act_lines_last, va);
			if (line_per != ht) fail({name, " line period"}, line_per, ht);
			if (de_len != ha) fail({name, " DE width"}, de_len, ha);
			if (hs_inact - hs_act != hsw && hs_act - hs_inact + ht != hsw)
				fail({name, " hsync width"}, hs_inact - hs_act, hsw);
			/* vsync: active for vsw lines, starting vfp lines after the line
			 * after the last active one (at its h = 0). */
			if (vs_inact - vs_act != vsw * ht) fail({name, " vsync width"}, vs_inact - vs_act, vsw * ht);
			if (vt_cyc != vs_act) fail({name, " vsync_toggle place"}, vt_cyc, vs_act);
			if (ft_cyc != vs_inact) fail({name, " frame_toggle place"}, ft_cyc, vs_inact);
		end
	endtask

	/* Measures hsync's place relative to DE once. */
	task check_hsync_place;
		input [8*20-1:0] name;
		input integer hfp;
		begin
			@(negedge de);
			@(posedge clk);
			wait (hs == hpol);
			@(posedge clk);
			#1;
			if (hs_act - de_fall != hfp) fail({name, " hsync front porch"}, hs_act - de_fall, hfp);
		end
	endtask

	integer x, y, prev;
	reg [31:0] first;
	reg [23:0] want;

	initial begin
		repeat (3) @(posedge clk);
		rst_n = 1;

		/* timing: 640x480, then 720p. */
		e0 = errors;
		set_timing(640, 16, 96, 48, 480, 10, 2, 33, 0);
		hpol = 0;
		vpol = 0;
		repeat (3) @(posedge clk);
		enable = 1;
		check_mode("640x480", 640, 16, 96, 48, 480, 10, 2, 33);
		check_hsync_place("640x480", 16);
		if (line !== 12'd0 && line > 12'd524) fail("line range", line, 0);
		enable = 0;
		@(posedge clk);
		set_timing(1280, 110, 40, 220, 720, 5, 5, 20, 3);
		hpol = 1;
		vpol = 1;
		frame_per = 0;
		vt_prev = 0;
		repeat (3) @(posedge clk);
		enable = 1;
		check_mode("720p", 1280, 110, 40, 220, 720, 5, 5, 20);
		check_hsync_place("720p", 110);
		enable = 0;
		if (errors == e0)
			$display("PASS atg_dc_tgen.timing");

		/* Pixels in order (format 0), the first frame starts aligned after
		 * the drain, conversions. */
		e0 = errors;
		set_timing(64, 4, 8, 4, 16, 2, 2, 3, 0);
		hpol = 0;
		vpol = 0;
		repeat (3) @(posedge clk);
		px_data = 32'h00100000;
		enable = 1;
		/* The first active pixel of the first frame is the source's value
		 * after the drain of the vsync lines (two lines of 80 cycles). */
		@(posedge de);
		@(negedge clk);
		first = {8'd0, rgb};
		for (y = 0; y < 16; y = y + 1) begin
			for (x = 0; x < 64; x = x + 1) begin
				if (rgb !== first[23:0] + y * 64 + x) begin
					fail("pixel order", rgb, first[23:0] + y * 64 + x);
					x = 64;
					y = 16;
				end
				@(negedge clk);
			end
			if (y < 15)
				@(posedge de);
			@(negedge clk);
		end
		if (first - 32'h00100000 != 32'd160) fail("drained pixels", first - 32'h00100000, 160);
		if (n_under != 0) fail("no underflow", n_under, 0);
		enable = 0;
		@(posedge clk);
		/* Formats on a constant source. */
		count_src = 0;
		for (k = 1; k < 3; k = k + 1) begin
			format = k;
			px_data = 32'h44_336699;
			@(posedge clk);
			enable = 1;
			@(posedge de);
			@(negedge clk);
			want = k == 1 ? 24'h996633 : {5'b01100, 3'b011, 6'b110100, 2'b11, 5'b11001, 3'b110};
			if (rgb !== want) fail("format", rgb, want);
			enable = 0;
			@(posedge clk);
		end
		format = 2'd0;
		count_src = 1;
		if (errors == e0)
			$display("PASS atg_dc_tgen.pixels");

		/* The test pattern on 640x480. */
		set_timing(640, 16, 96, 48, 480, 10, 2, 33, 0);
		test_pattern = 1;
		repeat (3) @(posedge clk);
		prev = px_data;
		enable = 1;
		@(posedge de);	/* line 0: the white border */
		@(negedge clk);
		if (rgb !== 24'hFFFFFF) fail("border top", rgb, 24'hFFFFFF);
		repeat (100) @(posedge de);	/* line 100 */
		@(negedge clk);
		if (rgb !== 24'hFFFFFF) fail("border left", rgb, 24'hFFFFFF);
		for (k = 0; k < 8; k = k + 1) begin
			repeat (k == 0 ? 40 : 80) @(negedge clk);
			case (k)
			0: want = 24'hFFFFFF;
			1: want = 24'hFFFF00;
			2: want = 24'h00FFFF;
			3: want = 24'h00FF00;
			4: want = 24'hFF00FF;
			5: want = 24'hFF0000;
			6: want = 24'h0000FF;
			default: want = 24'h000000;
			endcase
			if (rgb !== want) fail("bar colour", rgb, want);
		end
		repeat (39) @(negedge clk);	/* x = 639 */
		if (rgb !== 24'hFFFFFF || de !== 1'b1) fail("border right", rgb, 24'hFFFFFF);
		/* The FIFO is not popped in the active area (only drained). */
		k = px_data;
		@(negedge de);
		if (px_data !== k) fail("no pop in TEST_PATTERN", px_data - k, 0);
		enable = 0;
		test_pattern = 0;
		@(posedge clk);
		if (errors == e0)
			$display("PASS atg_dc_tgen.pattern");

		/* underflow: an empty FIFO for 10 pixels of the active area. */
		e0 = errors;
		set_timing(64, 4, 8, 4, 16, 2, 2, 3, 0);
		px_data = 32'h00ABCDEF;
		repeat (3) @(posedge clk);
		enable = 1;
		@(posedge de);
		repeat (3) @(posedge de);
		@(negedge clk);
		k = n_under;
		px_valid = 0;
		repeat (10) @(negedge clk);
		px_valid = 1;
		@(negedge clk);
		if (n_under - k != 10) fail("underflow toggles", n_under - k, 10);
		/* The pixel before the gap was coloured, the gap's are black. */
		px_valid = 0;
		@(negedge clk);
		@(negedge clk);
		if (rgb !== 24'd0) fail("underflow black", rgb, 0);
		px_valid = 1;
		enable = 0;
		@(posedge clk);
		if (errors == e0)
			$display("PASS atg_dc_tgen.underflow");

		if (errors == 0)
			$display("PASS atg_dc_tgen");
		$finish;
	end

	initial begin
		#40000000;
		$display("FAIL atg_dc_tgen timeout");
		$finish;
	end
endmodule

`default_nettype wire
