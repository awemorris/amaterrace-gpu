/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_pack_tb: 2-stage pipelined unit testbench for atg_fmt_pack (LAT = 2).
 * Verifies exact 2-cycle latency across all 256 formats with sim/vec/fmt_pack.txt,
 * pipeline streaming, and pipeline stall/enable control.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_pack_tb;
	`include "atg_fmt_info.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg en = 1'b1;
	always #5 clk = !clk;

	function [2047:0] all_fmts;
		input integer unused_n;
		integer i;
		for (i = 0; i < 256; i = i + 1)
			all_fmts[8 * i +: 8] = i[7:0];
	endfunction
	localparam [2047:0] ALL = all_fmts(0);

	reg [7:0] in_fmt = 8'd0;
	reg [3:0] in_wm = 4'd0;
	reg [127:0] in_c = 128'd0;
	wire [63:0] in_un, in_hf;
	wire [255:0] out_o;

	wire [67:0] u_inf = atg_fmt_info(in_fmt);
	genvar gk;
	generate
	for (gk = 0; gk < 4; gk = gk + 1) begin : g_conv
		atg_fmt_f2unorm u_un (
			.f(in_c[32 * gk +: 32]),
			.w(u_inf[11:9] == ATG_FMT_SRGB ? 6'd8 : u_inf[23 + 13 * gk +: 6]),
			.u(in_un[16 * gk +: 16])
		);
		am_fp_f2h #(.LAT(0)) u_hf (
			.f(in_c[32 * gk +: 32]),
			.h(in_hf[16 * gk +: 16])
		);
	end
	endgenerate

	atg_fmt_pack #(.N(256), .FMTS(ALL), .LAT(2)) dut (
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.c(in_c),
		.un(in_un),
		.hf(in_hf),
		.fmt(in_fmt),
		.wm(in_wm),
		.o(out_o)
	);

	integer fd, code, n, errors, total;
	reg [7:0] v_fmt;
	reg [3:0] v_wm;
	reg [31:0] v_c0, v_c1, v_c2, v_c3;
	reg [127:0] v_raw, v_keep;

	/* Pipeline scoreboarding queue (2 stages) */
	reg [255:0] want_q [0:2];
	reg vld_q [0:2];
	reg [7:0] fmt_q [0:2];

	task open_vec;
		input [8*32-1:0] name;
		begin
			fd = $fopen(name, "r");
			if (fd == 0) begin
				$display("FAIL atg_fmt_pack: no %0s", name);
				$finish;
			end
		end
	endtask

	initial begin
		errors = 0;
		total = 0;
		n = 0;
		want_q[0] = 256'd0; want_q[1] = 256'd0; want_q[2] = 256'd0;
		vld_q[0] = 1'b0;  vld_q[1] = 1'b0;  vld_q[2] = 1'b0;
		fmt_q[0] = 8'd0;  fmt_q[1] = 8'd0;  fmt_q[2] = 8'd0;

		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		open_vec("sim/vec/fmt_pack.txt");
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h %h %h %h %h %h %h %h\n",
				v_fmt, v_wm, v_c0, v_c1, v_c2, v_c3, v_raw, v_keep);
			if (code == 8) begin
				in_fmt <= v_fmt;
				in_wm <= v_wm;
				in_c <= {v_c3, v_c2, v_c1, v_c0};

				/* Advance scoreboard queue on clock edge */
				@(posedge clk);
				if (vld_q[1]) begin
					if (out_o !== want_q[1]) begin
						errors = errors + 1;
						if (errors < 10)
							$display("FAIL atg_fmt_pack: fmt %0d out %h %h, want %h %h",
								fmt_q[1], out_o[255:128], out_o[127:0],
								want_q[1][255:128], want_q[1][127:0]);
					end
				end
				want_q[1] <= want_q[0];
				vld_q[1]  <= vld_q[0];
				fmt_q[1]  <= fmt_q[0];

				want_q[0] <= {v_keep, v_raw};
				vld_q[0]  <= 1'b1;
				fmt_q[0]  <= v_fmt;
				n = n + 1;
			end
		end
		$fclose(fd);

		/* Drain remaining pipeline stages */
		repeat (3) begin
			@(posedge clk);
			if (vld_q[1]) begin
				if (out_o !== want_q[1]) begin
					errors = errors + 1;
					if (errors < 10)
						$display("FAIL atg_fmt_pack: drain fmt %0d out %h %h, want %h %h",
							fmt_q[1], out_o[255:128], out_o[127:0],
							want_q[1][255:128], want_q[1][127:0]);
				end
			end
			want_q[1] <= want_q[0];
			vld_q[1]  <= vld_q[0];
			fmt_q[1]  <= fmt_q[0];

			want_q[0] <= 256'd0;
			vld_q[0]  <= 1'b0;
		end

		if (errors == 0 && n > 6000)
			$display("PASS atg_fmt_pack.pipeline (%0d pixels, LAT=2)", n);
		else
			$display("FAIL atg_fmt_pack.pipeline: %0d errors in %0d pixels", errors, n);
		total = total + errors + (n > 6000 ? 0 : 1);

		/* Test pipeline freeze (en = 0) */
		begin : b_freeze
			reg [255:0] frozen_out;
			in_fmt <= 8'd37; // RGBA8_UNORM
			in_wm <= 4'hF;
			in_c <= {32'h3F800000, 32'h3F800000, 32'h3F800000, 32'h3F800000};
			@(posedge clk);
			@(posedge clk);
			@(posedge clk);
			frozen_out = out_o;
			en <= 1'b0;
			in_c <= 128'd0;
			repeat (4) @(posedge clk);
			if (out_o !== frozen_out) begin
				$display("FAIL atg_fmt_pack: output changed while en=0");
				total = total + 1;
			end else
				$display("PASS atg_fmt_pack.stall");
			en <= 1'b1;
			@(posedge clk);
		end

		if (total == 0)
			$display("PASS atg_fmt_pack");
		else
			$display("FAIL atg_fmt_pack: %0d total errors", total);
		$finish;
	end
endmodule

`default_nettype wire
