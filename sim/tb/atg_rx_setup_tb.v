/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_setup_tb: 160 triangles (raw screen-space and clip-space ones
 * with weights; small, large and off-screen; scissor; every CULL value; a
 * zero-area one) through atg_rx_setup, the sp_tri compared with the
 * reference model's (sim/vec/rx_setup.txt from tools/rx-vectors.py) in
 * three groups: the edges and the bbox, the facing and culling, the
 * planes; the same comparison of all 768 bits (the kind 2 in [766:765])
 * is the vec-diff check that the CAPS[30] setup keeps the earlier
 * triangles bit for bit.  Then sim/vec/rx_setup2.txt (tools/rx-setup-
 * vectors.py, the model's setup2): lines, points, the viewport's rectangle
 * and depth bias, each with its STATE writes; every output (two for a line
 * or a point) and sp_last compared.  sp_ready is random.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_setup_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg cl_valid = 1'b0, cl_last = 1'b0, sp_ready = 1'b0;
	reg [701:0] cl_tri = 0;
	reg mesh_valid = 1'b0, mesh_last = 1'b0;
	reg [701:0] mesh_tri = 0;
	reg [15:0] mesh_id = 0;
	wire cl_ready, mesh_ready, sp_valid, sp_last, busy;
	wire [767:0] sp_tri;

	atg_rx_setup dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .cl_valid(cl_valid), .cl_ready(cl_ready), .cl_tri(cl_tri),
		.cl_last(cl_last),
		.mesh_valid(mesh_valid), .mesh_ready(mesh_ready), .mesh_tri(mesh_tri),
		.mesh_last(mesh_last), .mesh_id(mesh_id),
		.sp_valid(sp_valid), .sp_ready(sp_ready), .sp_tri(sp_tri),
		.sp_last(sp_last), .busy(busy));

	integer fd, code, n, i, seed, cycles, maxc;
	integer e_edges = 0, e_cull = 0, e_planes = 0, e_other = 0, e_vd = 0;
	integer e_s [0:3];
	integer sect, nout, j, lst, nprim;
	reg [8:0] sidx;
	reg [31:0] sval;
	reg [701:0] cv;
	reg [7:0] tag;
	reg [31:0] w [0:9];
	reg [699:0] tv;
	reg [767:0] exp_sp;
	reg [8:0] idx [0:9];

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

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		idx[0] = 9'h050; idx[1] = 9'h051; idx[2] = 9'h052; idx[3] = 9'h053;
		idx[4] = 9'h054; idx[5] = 9'h055; idx[6] = 9'h056; idx[7] = 9'h057;
		idx[8] = 9'h058; idx[9] = 9'h073;
		fd = $fopen("sim/vec/rx_setup.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rx_setup: no sim/vec/rx_setup.txt");
			$finish;
		end
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);
		n = 0;
		maxc = 0;
		code = 12;
		while (!$feof(fd) && code == 12) begin
			code = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h\n", w[0], w[1], w[2], w[3],
				w[4], w[5], w[6], w[7], w[8], w[9], tv, exp_sp);
			if (code == 12) begin
			for (i = 0; i < 10; i = i + 1)
				st_put(idx[i], w[i]);
			cl_valid <= 1'b1;
			cl_tri <= {2'd2, tv};
			cl_last <= n[0];
			cycles = 0;
			@(posedge clk);
			while (!cl_ready) begin
				@(posedge clk);
				cycles = cycles + 1;
			end
			cl_valid <= 1'b0;
			cl_tri <= {2'd2, ~tv};	/* not used after it is taken */
			while (!(sp_valid && sp_ready)) begin
				sp_ready <= ($random(seed) & 3) == 0;
				@(posedge clk);
				cycles = cycles + 1;
			end
			sp_ready <= 1'b0;
			if (cycles > maxc)
				maxc = cycles;
			if (sp_tri[351:0] !== exp_sp[351:0]) begin
				e_edges = e_edges + 1;
				if (e_edges < 6)
					$display("FAIL atg_rx_setup: case %0d edges/bbox\n got %h\n exp %h", n,
						sp_tri[351:0], exp_sp[351:0]);
			end
			if (sp_tri[767:736] !== {exp_sp[767], 2'd2, exp_sp[764:736]}) begin
				e_cull = e_cull + 1;
				if (e_cull < 6)
					$display("FAIL atg_rx_setup: case %0d flags got %h exp %h", n,
						sp_tri[767:736], exp_sp[767:736]);
			end
			if (sp_tri[735:352] !== exp_sp[735:352]) begin
				e_planes = e_planes + 1;
				if (e_planes < 6)
					$display("FAIL atg_rx_setup: case %0d planes\n got %h\n exp %h", n,
						sp_tri[735:352], exp_sp[735:352]);
			end
			if (sp_tri !== {exp_sp[767], 2'd2, exp_sp[764:0]})
				e_vd = e_vd + 1;
			if (sp_last !== n[0]) begin
				e_other = e_other + 1;
				$display("FAIL atg_rx_setup: case %0d sp_last %b", n, sp_last);
			end
			n = n + 1;
			end
		end
		$fclose(fd);
		@(posedge clk);
		if (busy || n != 160) begin
			e_other = e_other + 1;
			$display("FAIL atg_rx_setup: busy %b after %0d cases", busy, n);
		end
		$display("atg_rx_setup: %0d triangles, at most %0d cycles each", n, maxc);
		if (e_edges == 0 && e_other == 0)
			$display("PASS atg_rx_setup.edges");
		if (e_cull == 0 && e_other == 0)
			$display("PASS atg_rx_setup.cull");
		if (e_planes == 0 && e_other == 0)
			$display("PASS atg_rx_setup.planes");
		if (e_vd == 0 && e_other == 0)
			$display("PASS vecdiff.rx_setup");

		/* the CAPS[30] cases */
		for (i = 0; i < 4; i = i + 1)
			e_s[i] = 0;
		nprim = 0;
		fd = $fopen("sim/vec/rx_setup2.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_rx_setup: no sim/vec/rx_setup2.txt");
			$finish;
		end
		code = 1;
		while (code > 0) begin
			code = $fscanf(fd, "%c", tag);
			if (tag == "S") begin
				code = $fscanf(fd, " %h %h\n", sidx, sval);
				st_put(sidx, sval);
			end else if (tag == "T") begin
				code = $fscanf(fd, " %d %h %d\n", sect, cv, nout);
				cl_valid <= 1'b1;
				cl_tri <= cv;
				cl_last <= nprim[0];
				@(posedge clk);
				while (!cl_ready)
					@(posedge clk);
				cl_valid <= 1'b0;
				cl_tri <= ~cv;
				for (j = 0; j < nout; j = j + 1) begin
					code = $fscanf(fd, "O %h %d\n", exp_sp, lst);
					cycles = 0;
					while (!(sp_valid && sp_ready) && cycles < 20000) begin
						sp_ready <= ($random(seed) & 3) == 0;
						@(posedge clk);
						cycles = cycles + 1;
					end
					sp_ready <= 1'b0;
					if (sp_tri !== exp_sp || sp_last !== (lst != 0 && nprim[0])) begin
						e_s[sect] = e_s[sect] + 1;
						if (e_s[0] + e_s[1] + e_s[2] + e_s[3] < 8)
							$display("FAIL atg_rx_setup: primitive %0d (section %0d) output %0d last %b\n got %h\n exp %h",
								nprim, sect, j, sp_last, sp_tri, exp_sp);
					end
					@(posedge clk);
				end
				repeat (3) @(posedge clk);
				if (busy || sp_valid) begin
					e_s[sect] = e_s[sect] + 1;
					$display("FAIL atg_rx_setup: primitive %0d: more outputs than %0d", nprim,
						nout);
					while (busy) begin
						sp_ready <= 1'b1;
						@(posedge clk);
					end
					sp_ready <= 1'b0;
				end
				nprim = nprim + 1;
			end else
				code = 0;
		end
		$fclose(fd);

		/* Direct Mesh Stream test: Option 4 Static MUX */
		repeat (5) @(posedge clk);
		if (!mesh_ready) begin
			$display("FAIL: mesh_ready should be 1 when IDLE and cl_valid=0");
			$finish;
		end
		/* Feed a raw screen-space triangle via mesh stream */
		mesh_valid <= 1'b1;
		mesh_last <= 1'b1;
		mesh_id <= 16'h1234;
		mesh_tri <= {2'd0, 1'b1, 27'h0, {21{32'h3F800000}}};
		@(posedge clk);
		mesh_valid <= 1'b0;
		mesh_last <= 1'b0;
		cycles = 0;
		while (!sp_valid && cycles < 1000) begin
			@(posedge clk);
			cycles = cycles + 1;
		end
		if (!sp_valid) begin
			$display("FAIL: mesh stream did not produce sp_valid");
			$finish;
		end
		if (!sp_last) begin
			$display("FAIL: mesh stream did not preserve sp_last");
			$finish;
		end
		sp_ready <= 1'b1;
		@(posedge clk);
		sp_ready <= 1'b0;
		$display("PASS atg_rx_setup.mesh_stream");

		$display("atg_rx_setup: %0d CAPS[30] primitives", nprim);
		if (e_s[0] == 0)
			$display("PASS atg_rx_setup.line");
		if (e_s[1] == 0)
			$display("PASS atg_rx_setup.point");
		if (e_s[2] == 0)
			$display("PASS atg_rx_setup.viewport");
		if (e_s[3] == 0)
			$display("PASS atg_rx_setup.bias");
		if (e_edges + e_cull + e_planes + e_other + e_vd + e_s[0] + e_s[1] + e_s[2] +
			e_s[3] == 0 && nprim > 0)
			$display("PASS atg_rx_setup");
		$finish;
	end
endmodule

`default_nettype wire
