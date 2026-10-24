/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_cpoly_tb: atg_rx_cpoly against the polygons of tools/rxmodel.py
 * (clip_cut; sim/vec/rx_cpoly.txt from tools/rx-clip-vectors.py).  Each
 * case loads a triangle or a line segment, then cuts it by one plane
 * ("planes"), by the seven planes in order ("seq", up to 10 vertices) or a
 * line by three planes ("line"); after each cut n_out and every vertex
 * (all 7 words) read back are compared with the model's.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_cpoly_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg [127:0] vp = 0;
	reg ld_we = 1'b0, ld_line = 1'b0, cmd_valid = 1'b0, cmd_first = 1'b0;
	reg [3:0] ld_idx = 0, ld_n = 0, rd_idx = 0;
	reg [223:0] ld_data = 0;
	reg [2:0] cmd_plane = 0;
	wire cmd_ready, done;
	wire [3:0] n_out;
	wire [223:0] rd_data;

	atg_rx_cpoly dut (.clk(clk), .rst_n(rst_n), .vp(vp), .ld_we(ld_we), .ld_idx(ld_idx),
		.ld_data(ld_data), .ld_n(ld_n), .ld_line(ld_line), .cmd_valid(cmd_valid),
		.cmd_ready(cmd_ready), .cmd_plane(cmd_plane), .cmd_first(cmd_first), .done(done),
		.n_out(n_out), .rd_idx(rd_idx), .rd_data(rd_data));

	integer fd, code, i, n, ln, sect, pl, tmo, ncut, nmax;
	integer e_s [0:2];
	reg [7:0] tag;
	reg [31:0] w [0:6];
	reg [31:0] v0, v1, v2, v3;
	reg [223:0] xv [0:9];
	reg first;

	task rdx;	/* one X line into xv[i] */
		input integer i_;
		begin
			code = $fscanf(fd, "X %h %h %h %h %h %h %h\n", w[0], w[1], w[2], w[3], w[4], w[5],
				w[6]);
			xv[i_] = {w[6], w[5], w[4], w[3], w[2], w[1], w[0]};
		end
	endtask

	initial begin
		for (i = 0; i < 3; i = i + 1)
			e_s[i] = 0;
		ncut = 0;
		nmax = 0;
		fd = $fopen("sim/vec/rx_cpoly.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rx_cpoly: no sim/vec/rx_cpoly.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		code = 1;
		first = 1'b0;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "V") begin
				code = $fscanf(fd, " %h %h %h %h\n", v0, v1, v2, v3);
				vp <= {v3, v2, v1, v0};
			end else if (tag == "L") begin
				code = $fscanf(fd, " %d %d\n", n, ln);
				for (i = 0; i < n; i = i + 1) begin
					rdx(i);
					ld_we <= 1'b1;
					ld_idx <= i;
					ld_data <= xv[i];
					@(posedge clk);
				end
				ld_we <= 1'b0;
				ld_n <= n;
				ld_line <= ln != 0;
				first = 1'b1;
			end else if (tag == "K") begin
				code = $fscanf(fd, " %d %d %d\n", sect, pl, n);
				for (i = 0; i < n; i = i + 1)
					rdx(i);
				cmd_valid <= 1'b1;
				cmd_plane <= pl;
				cmd_first <= first;
				@(posedge clk);
				while (!cmd_ready)
					@(posedge clk);
				cmd_valid <= 1'b0;
				first = 1'b0;
				tmo = 0;
				@(posedge clk);
				while (!done && tmo < 5000) begin
					@(posedge clk);
					tmo = tmo + 1;
				end
				ncut = ncut + 1;
				if (n > nmax)
					nmax = n;
				if (tmo >= 5000 || n_out !== n) begin
					$display("FAIL atg_rx_cpoly: cut %0d plane %0d: %0d vertices, want %0d",
						ncut, pl, n_out, n);
					e_s[sect] = e_s[sect] + 1;
				end else
					for (i = 0; i < n; i = i + 1) begin
						@(negedge clk);
						rd_idx <= i;
						@(posedge clk);
						@(negedge clk);
						if (rd_data !== xv[i]) begin
							$display("FAIL atg_rx_cpoly: cut %0d plane %0d vertex %0d\n got %h\n exp %h",
								ncut, pl, i, rd_data, xv[i]);
							e_s[sect] = e_s[sect] + 1;
						end
					end
			end else
				code = 0;
		end
		$fclose(fd);
		$display("atg_rx_cpoly: %0d cuts, up to %0d vertices", ncut, nmax);
		if (e_s[0] == 0)
			$display("PASS atg_rx_cpoly.planes");
		if (e_s[1] == 0)
			$display("PASS atg_rx_cpoly.seq");
		if (e_s[2] == 0)
			$display("PASS atg_rx_cpoly.line");
		if (e_s[0] + e_s[1] + e_s[2] == 0 && ncut > 0)
			$display("PASS atg_rx_cpoly");
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_rx_cpoly: timeout");
		$finish;
	end
endmodule

`default_nettype wire
