/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_blend_tb: 3000 quads (each of BGRA8, RGBA8, RGB565; random
 * BLEND words, i.e. every factor and operation, and source-over; random
 * BLEND_CONST and WRITE_MASK; sources with NaN, infinities, negative,
 * above one and exact c/255 values) against the reference model
 * (sim/vec/rop_blend.txt from tools/rx-vectors.py), b_pix LAT cycles
 * after b_valid.  Then the same STATE for a burst of one quad per cycle.
 * Then sim/vec/rop_blend2.txt (tools/rop-vectors.py, CAPS[30]): the
 * attachment b_rt with its RT_FORMATS byte (R8, R8G8, A1R5G5B5 and the
 * earlier formats by VkFormat, a format the path does not have), BLEND1-3
 * and WRITE_MASK per attachment ("r8rg8"), and the fp32 constants with
 * ROP_CTRL[1] ("const").
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_blend_tb;
	localparam N = 3000;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg b_valid = 1'b0;
	reg [511:0] b_src = 0;
	reg [127:0] b_dst = 0;
	reg [3:0] b_mask = 0;
	reg [2:0] b_rt = 0;
	wire b_rvalid;
	wire [127:0] b_pix;

	atg_rop_blend #(.LAT(3)) dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .b_valid(b_valid), .b_src(b_src), .b_src1(512'd0), .b_has_src1(1'b0),
		.b_dst(b_dst), .b_mask(b_mask),
		.b_rt(b_rt), .b_rvalid(b_rvalid), .b_pix(b_pix));

	reg [3:0] v_fmt [0:N-1];
	reg [23:0] v_bl [0:N-1];
	reg [31:0] v_kc [0:N-1];
	reg [3:0] v_wm [0:N-1];
	reg [511:0] v_src [0:N-1];
	reg [127:0] v_dst [0:N-1];
	reg [3:0] v_m [0:N-1];
	reg [127:0] v_res [0:N-1];
	integer fd, code, n, i, j, e_fmt = 0, e_fac = 0, burst_n, bq, sect, rt, nq2;
	integer e_s [0:1];
	reg [7:0] tag;
	reg [8:0] sidx;
	reg [31:0] sval;
	reg [3:0] mk;
	reg [127:0] res2;
	reg [31:0] w [0:27];
	reg [31:0] wt;

	task st_put;
		input [8:0] i_;
		input [31:0] v;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= v;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	/* burst checker: results in issue order */
	integer exp_q [0:63];
	integer qh = 0, qt = 0;
	always @(posedge clk)
		if (b_rvalid && qh != qt) begin
			if (b_pix !== v_res[exp_q[qh % 64]]) begin
				e_fac = e_fac + 1;
				$display("FAIL atg_rop_blend: burst quad %0d %h, expected %h", exp_q[qh % 64], b_pix,
					v_res[exp_q[qh % 64]]);
			end
			qh = qh + 1;
		end

	initial begin
		fd = $fopen("sim/vec/rop_blend.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_blend: no sim/vec/rop_blend.txt");
			$finish;
		end
		for (n = 0; n < N; n = n + 1) begin
			code = $fscanf(fd, "%h %h %h %h", v_fmt[n], v_bl[n], v_kc[n], v_wm[n]);
			for (j = 0; j < 20; j = j + 1) begin
				code = $fscanf(fd, " %h", wt);
				w[j] = wt;
			end
			code = $fscanf(fd, " %h", v_m[n]);
			for (j = 20; j < 24; j = j + 1) begin
				code = $fscanf(fd, " %h", wt);
				w[j] = wt;
			end
			for (j = 0; j < 16; j = j + 1)
				v_src[n][32 * j +: 32] = w[j];
			for (j = 0; j < 4; j = j + 1) begin
				v_dst[n][32 * j +: 32] = w[16 + j];
				v_res[n][32 * j +: 32] = w[20 + j];
			end
		end
		$fclose(fd);
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		for (n = 0; n < N; n = n + 1) begin
			st_put(9'h072, {28'd0, v_fmt[n]});
			st_put(9'h07A, {8'd0, v_bl[n]});
			st_put(9'h07B, v_kc[n]);
			st_put(9'h07C, {28'd0, v_wm[n]});
			b_valid <= 1'b1;
			b_src <= v_src[n];
			b_dst <= v_dst[n];
			b_mask <= v_m[n];
			@(posedge clk);
			b_valid <= 1'b0;
			b_src <= 512'd0;
			@(posedge clk);
			@(posedge clk);
			#1;
			if (!b_rvalid || b_pix !== v_res[n]) begin
				if (v_bl[n][0] && v_fmt[n] != 4'd2)
					e_fac = e_fac + 1;
				else
					e_fmt = e_fmt + 1;
				if (e_fac + e_fmt < 10)
					$display("FAIL atg_rop_blend: quad %0d (fmt %0d blend %h wm %h mask %h) %h, expected %h",
						n, v_fmt[n], v_bl[n], v_wm[n], v_m[n], b_pix, v_res[n]);
			end
			@(posedge clk);
		end
		/* a burst with the last quad's STATE: every quad with that STATE */
		burst_n = 0;
		for (n = 0; n < N; n = n + 1)
			if (v_fmt[n] == v_fmt[N - 1] && v_bl[n] == v_bl[N - 1] && v_kc[n] == v_kc[N - 1] &&
			    v_wm[n] == v_wm[N - 1]) begin
				for (bq = 0; bq < 4; bq = bq + 1) begin
					exp_q[qt % 64] = n;
					qt = qt + 1;
					b_valid <= 1'b1;
					b_src <= v_src[n];
					b_dst <= v_dst[n];
					b_mask <= v_m[n];
					@(posedge clk);
					burst_n = burst_n + 1;
				end
			end
		b_valid <= 1'b0;
		repeat (5) @(posedge clk);
		if (qh != qt) begin
			e_fac = e_fac + 1;
			$display("FAIL atg_rop_blend: burst %0d of %0d", qh, qt);
		end
		/* CAPS[30] */
		e_s[0] = 0;
		e_s[1] = 0;
		nq2 = 0;
		fd = $fopen("sim/vec/rop_blend2.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rop_blend: no sim/vec/rop_blend2.txt");
			$finish;
		end
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "S") begin
				code = $fscanf(fd, " %h %h\n", sidx, sval);
				st_put(sidx, sval);
			end else if (tag == "Q") begin
				code = $fscanf(fd, " %d %d", sect, rt);
				for (j = 0; j < 20; j = j + 1) begin
					code = $fscanf(fd, " %h", wt);
					w[j] = wt;
				end
				code = $fscanf(fd, " %h", mk);
				for (j = 20; j < 24; j = j + 1) begin
					code = $fscanf(fd, " %h", wt);
					w[j] = wt;
				end
				code = $fscanf(fd, "%c", tag);
				b_valid <= 1'b1;
				b_rt <= rt;
				for (j = 0; j < 16; j = j + 1)
					b_src[32 * j +: 32] <= w[j];
				for (j = 0; j < 4; j = j + 1) begin
					b_dst[32 * j +: 32] <= w[16 + j];
					res2[32 * j +: 32] = w[20 + j];
				end
				b_mask <= mk;
				@(posedge clk);
				b_valid <= 1'b0;
				b_rt <= ~rt;	/* taken with b_valid only */
				@(posedge clk);
				@(posedge clk);
				#1;
				if (!b_rvalid || b_pix !== res2) begin
					e_s[sect] = e_s[sect] + 1;
					if (e_s[0] + e_s[1] < 8)
						$display("FAIL atg_rop_blend: CAPS[30] quad %0d (section %0d rt %0d) %h, expected %h",
							nq2, sect, rt, b_pix, res2);
				end
				nq2 = nq2 + 1;
				@(posedge clk);
			end else
				code = 0;
		end
		$fclose(fd);
		$display("atg_rop_blend: %0d CAPS[30] quads", nq2);
		if (e_fmt == 0)
			$display("PASS atg_rop_blend.formats");
		if (e_fac == 0)
			$display("PASS atg_rop_blend.factors");
		if (e_s[0] == 0 && nq2 > 0)
			$display("PASS atg_rop_blend.r8rg8");
		if (e_s[1] == 0 && nq2 > 0)
			$display("PASS atg_rop_blend.const");
		if (e_fmt + e_fac + e_s[0] + e_s[1] == 0 && nq2 > 0)
			$display("PASS atg_rop_blend");
		$finish;
	end
endmodule

`default_nettype wire
