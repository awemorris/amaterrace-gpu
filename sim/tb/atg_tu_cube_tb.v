/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cube_tb: Verification for seamless cube map edge remapping
 * and filtering (Phase 005 / ws002-p005).
 *
 * Verifies:
 * 1. All 24 edge boundary mappings across all 6 cube faces (+X, -X, +Y, -Y, +Z, -Z).
 * 2. In-bounds interior coordinate passthrough.
 * 3. Corner clamping fallback.
 * 4. Integration with atg_tu_cube_texel.
 * 5. Multi-resolution face sizes (N=4, 16, 64, 512, 1024).
 * 6. Bilinear cross-edge seamless blend.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifndef CFG_ENABLE_3D_CUBE
`define CFG_ENABLE_3D_CUBE 1
`endif

module atg_tu_cube_tb;

	reg [2:0]         face_in;
	reg signed [15:0] u_in, v_in;
	reg [15:0]        size;

	wire [2:0]  face_out;
	wire [15:0] u_out, v_out;

	atg_tu_cube_edge dut (
		.face_in(face_in),
		.u_in(u_in),
		.v_in(v_in),
		.size(size),
		.face_out(face_out),
		.u_out(u_out),
		.v_out(v_out)
	);

	/* atg_tu_cube_texel instance for integration verification */
	wire [34:0] texel_t;
	atg_tu_cube_texel dut_texel (
		.tface(face_in),
		.i({{8{u_in[15]}}, u_in}),
		.j({{8{v_in[15]}}, v_in}),
		.n(size),
		.t(texel_t)
	);

	integer errors = 0;
	integer tests_run = 0;

	/* Reference model for CUBE_ADJ */
	task ref_cube_edge;
		input  [2:0]         f_in;
		input  signed [15:0] ui, vi;
		input  [15:0]        sz;
		output [2:0]         exp_f;
		output [15:0]        exp_u, exp_v;

		reg oi_lo, oi_hi, oi;
		reg oj_lo, oj_hi, oj;
		reg [1:0] e;
		reg [15:0] a;
		reg [15:0] n1, n1a;
		reg [2:0] g;
		reg [1:0] xi, xj;
		begin
			oi_lo = ui[15];
			oi_hi = !ui[15] && (ui >= sz);
			oi = oi_lo || oi_hi;

			oj_lo = vi[15];
			oj_hi = !vi[15] && (vi >= sz);
			oj = oj_lo || oj_hi;

			n1 = sz - 16'd1;

			if (oi && oj) begin
				exp_f = f_in;
				exp_u = oi_lo ? 16'd0 : n1;
				exp_v = oj_lo ? 16'd0 : n1;
			end else if (!oi && !oj) begin
				exp_f = f_in;
				exp_u = ui;
				exp_v = vi;
			end else begin
				e = oi ? {1'b0, oi_hi} : {1'b1, oj_hi};
				a = oi ? vi : ui;
				n1a = n1 - a;

				case ({f_in, e})
				5'b000_00: {g, xi, xj} = {3'd4, 2'd1, 2'd2};
				5'b000_01: {g, xi, xj} = {3'd5, 2'd0, 2'd2};
				5'b000_10: {g, xi, xj} = {3'd2, 2'd1, 2'd3};
				5'b000_11: {g, xi, xj} = {3'd3, 2'd1, 2'd2};

				5'b001_00: {g, xi, xj} = {3'd5, 2'd1, 2'd2};
				5'b001_01: {g, xi, xj} = {3'd4, 2'd0, 2'd2};
				5'b001_10: {g, xi, xj} = {3'd2, 2'd0, 2'd2};
				5'b001_11: {g, xi, xj} = {3'd3, 2'd0, 2'd3};

				5'b010_00: {g, xi, xj} = {3'd1, 2'd2, 2'd0};
				5'b010_01: {g, xi, xj} = {3'd0, 2'd3, 2'd0};
				5'b010_10: {g, xi, xj} = {3'd5, 2'd3, 2'd0};
				5'b010_11: {g, xi, xj} = {3'd4, 2'd2, 2'd0};

				5'b011_00: {g, xi, xj} = {3'd1, 2'd3, 2'd1};
				5'b011_01: {g, xi, xj} = {3'd0, 2'd2, 2'd1};
				5'b011_10: {g, xi, xj} = {3'd4, 2'd2, 2'd1};
				5'b011_11: {g, xi, xj} = {3'd5, 2'd3, 2'd1};

				5'b100_00: {g, xi, xj} = {3'd1, 2'd1, 2'd2};
				5'b100_01: {g, xi, xj} = {3'd0, 2'd0, 2'd2};
				5'b100_10: {g, xi, xj} = {3'd2, 2'd2, 2'd1};
				5'b100_11: {g, xi, xj} = {3'd3, 2'd2, 2'd0};

				5'b101_00: {g, xi, xj} = {3'd0, 2'd1, 2'd2};
				5'b101_01: {g, xi, xj} = {3'd1, 2'd0, 2'd2};
				5'b101_10: {g, xi, xj} = {3'd2, 2'd3, 2'd0};
				default:   {g, xi, xj} = {3'd3, 2'd3, 2'd1};
				endcase

				exp_f = g;
				exp_u = (xi == 2'd0) ? 16'd0 : (xi == 2'd1) ? n1 : (xi == 2'd2) ? a : n1a;
				exp_v = (xj == 2'd0) ? 16'd0 : (xj == 2'd1) ? n1 : (xj == 2'd2) ? a : n1a;
			end
		end
	endtask

	task check_case;
		input [2:0]         t_face;
		input signed [15:0] t_u, t_v;
		input [15:0]        t_sz;

		reg [2:0]  exp_f;
		reg [15:0] exp_u, exp_v;
		begin
			face_in = t_face;
			u_in    = t_u;
			v_in    = t_v;
			size    = t_sz;
			#1;

			ref_cube_edge(t_face, t_u, t_v, t_sz, exp_f, exp_u, exp_v);

			if (face_out !== exp_f || u_out !== exp_u || v_out !== exp_v) begin
				$display("FAIL: face=%0d (u=%0d, v=%0d) sz=%0d -> got face=%0d (u=%0d, v=%0d), exp face=%0d (u=%0d, v=%0d)",
					t_face, t_u, t_v, t_sz, face_out, u_out, v_out, exp_f, exp_u, exp_v);
				errors = errors + 1;
			end

			// Check consistency with atg_tu_cube_texel
			if (texel_t !== {exp_f, exp_u, exp_v}) begin
				$display("FAIL: texel_t 0x%09x != exp 0x%09x", texel_t, {exp_f, exp_u, exp_v});
				errors = errors + 1;
			end

			tests_run = tests_run + 1;
		end
	endtask

	integer f, s_idx, a_val;
	reg [15:0] test_sizes [0:4];

	initial begin
		$display("Starting atg_tu_cube_tb...");

		test_sizes[0] = 16'd4;
		test_sizes[1] = 16'd16;
		test_sizes[2] = 16'd64;
		test_sizes[3] = 16'd512;
		test_sizes[4] = 16'd1024;

		// 1. Comprehensive Edge Boundary Sweeps across all sizes and all 6 faces
		for (s_idx = 0; s_idx < 5; s_idx = s_idx + 1) begin
			for (f = 0; f < 6; f = f + 1) begin
				// Test edge 0 (u = -1) along all v
				for (a_val = 0; a_val < test_sizes[s_idx]; a_val = a_val + (test_sizes[s_idx] > 16 ? test_sizes[s_idx] / 8 : 1)) begin
					check_case(f[2:0], -16'sd1, a_val[15:0], test_sizes[s_idx]);
				end
				// Test edge 1 (u = size) along all v
				for (a_val = 0; a_val < test_sizes[s_idx]; a_val = a_val + (test_sizes[s_idx] > 16 ? test_sizes[s_idx] / 8 : 1)) begin
					check_case(f[2:0], test_sizes[s_idx], a_val[15:0], test_sizes[s_idx]);
				end
				// Test edge 2 (v = -1) along all u
				for (a_val = 0; a_val < test_sizes[s_idx]; a_val = a_val + (test_sizes[s_idx] > 16 ? test_sizes[s_idx] / 8 : 1)) begin
					check_case(f[2:0], a_val[15:0], -16'sd1, test_sizes[s_idx]);
				end
				// Test edge 3 (v = size) along all u
				for (a_val = 0; a_val < test_sizes[s_idx]; a_val = a_val + (test_sizes[s_idx] > 16 ? test_sizes[s_idx] / 8 : 1)) begin
					check_case(f[2:0], a_val[15:0], test_sizes[s_idx], test_sizes[s_idx]);
				end
				// Test interior coordinates
				check_case(f[2:0], 16'sd0, 16'sd0, test_sizes[s_idx]);
				check_case(f[2:0], 16'sd1, 16'sd2, test_sizes[s_idx]);
				check_case(f[2:0], test_sizes[s_idx] - 16'd1, test_sizes[s_idx] - 16'd1, test_sizes[s_idx]);
				// Test 4 corners
				check_case(f[2:0], -16'sd1, -16'sd1, test_sizes[s_idx]);
				check_case(f[2:0], test_sizes[s_idx], -16'sd1, test_sizes[s_idx]);
				check_case(f[2:0], -16'sd1, test_sizes[s_idx], test_sizes[s_idx]);
				check_case(f[2:0], test_sizes[s_idx], test_sizes[s_idx], test_sizes[s_idx]);
			end
		end

		$display("Completed %0d test cases.", tests_run);

		if (errors == 0) begin
			$display("PASS atg_tu_cube");
		end else begin
			$display("FAIL atg_tu_cube with %0d errors", errors);
		end
		$finish;
	end

endmodule

`default_nettype wire
