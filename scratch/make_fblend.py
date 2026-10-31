import re

with open('rtl/gpu/rop/atg_rop_fblend.v', 'r') as f:
    orig = f.read()

# Verify the target block in orig
old_block_start = "	reg [127:0] s0 [0:3];"
old_block_end = "	/* =========================================================================\n	 * STAGE 3B: fp32 Combine P +/- Q, Min/Max (Latency: 1 cycle)\n	 * ========================================================================= */"

idx1 = orig.find(old_block_start)
idx2 = orig.find(old_block_end)
print(f"idx1={idx1}, idx2={idx2}")

new_block = """	reg [127:0] s0 [0:3];
	reg [127:0] d0 [0:3];
	reg [127:0] kc0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt0_r;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm0_r, lanes0_r;
	reg v0_r, known0_r;

`ifdef SYNTH_KINTEX7
	(* equivalent_register_removal = "no" *) reg [22:0] blend0_l [0:3];
	genvar g_bl0;
	generate
	for (g_bl0 = 0; g_bl0 < 4; g_bl0 = g_bl0 + 1) begin : g_pipe_bl0
		always @(posedge clk) begin
			if (rst_sync)
				blend0_l[g_bl0] <= 23'd0;
			else if (pe_s0_lane[g_bl0])
				blend0_l[g_bl0] <= i_blend;
		end
	end
	endgenerate
	wire [22:0] blend0 = blend0_l[0];

	wire pe_s0_ctrl_a, pe_s0_ctrl_b, pe_s0_ctrl_c, pe_s0_ctrl_d;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0a (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0b (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0c (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_c));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c0d (.I0(pe_s0_ctrl), .O(pe_s0_ctrl_d));

	wire [7:0] pe_s0_kc_leaf;
	genvar g_kc;
	generate
	for (g_kc = 0; g_kc < 8; g_kc = g_kc + 1) begin : g_buf_kc
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_kc_b (
			.I0(pe_s0_ctrl_c), .O(pe_s0_kc_leaf[g_kc])
		);
		always @(posedge clk) begin
			if (rst_sync)
				kc0[16 * g_kc +: 16] <= 16'd0;
			else if (pe_s0_kc_leaf[g_kc])
				kc0[16 * g_kc +: 16] <= kc_w[16 * g_kc +: 16];
		end
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			wm0_r <= 4'd0;
			lanes0_r <= 4'd0;
		end else if (pe_s0_ctrl_b) begin
			wm0_r <= i_wm;
			lanes0_r <= i_lanes;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			v0_r <= 1'b0;
			known0_r <= 1'b0;
			fmt0_r <= 8'd0;
		end else if (pe_s0_ctrl_d) begin
			v0_r <= i_valid;
			known0_r <= d_known0;
			fmt0_r <= i_fmt;
		end
	end
`else
	reg [22:0] blend0;
	wire [22:0] blend0_l [0:3];
	genvar g_bl0;
	generate
	for (g_bl0 = 0; g_bl0 < 4; g_bl0 = g_bl0 + 1) begin : g_pipe_bl0
		assign blend0_l[g_bl0] = blend0;
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			v0_r <= 1'b0;
			known0_r <= 1'b0;
			blend0 <= 23'd0;
			fmt0_r <= 8'd0;
			wm0_r <= 4'd0;
			lanes0_r <= 4'd0;
			kc0 <= 128'd0;
		end else if (pe_s0_ctrl) begin
			v0_r <= i_valid;
			known0_r <= d_known0;
			blend0 <= i_blend;
			fmt0_r <= i_fmt;
			wm0_r <= i_wm;
			lanes0_r <= i_lanes;
			kc0 <= kc_w;
		end
	end
`endif

`ifdef SYNTH_KINTEX7
	wire [15:0] pe_s0_leaf [0:3];
	genvar g_s0, g_s0_c;
	generate
	for (g_s0 = 0; g_s0 < 4; g_s0 = g_s0 + 1) begin : g_pipe_s0
		for (g_s0_c = 0; g_s0_c < 16; g_s0_c = g_s0_c + 1) begin : g_buf_s0
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_s0_b (
				.I0(pe_s0_lane[g_s0]), .O(pe_s0_leaf[g_s0][g_s0_c])
			);
		end
		for (g_s0_c = 0; g_s0_c < 8; g_s0_c = g_s0_c + 1) begin : g_reg_s0
			always @(posedge clk) begin
				if (rst_sync) begin
					s0[g_s0][16 * g_s0_c +: 16] <= 16'd0;
					d0[g_s0][16 * g_s0_c +: 16] <= 16'd0;
				end else begin
					if (pe_s0_leaf[g_s0][g_s0_c])
						s0[g_s0][16 * g_s0_c +: 16] <= s_unclamped_w[g_s0][16 * g_s0_c +: 16];
					if (pe_s0_leaf[g_s0][8 + g_s0_c])
						d0[g_s0][16 * g_s0_c +: 16] <= d_unpacked_w[g_s0][16 * g_s0_c +: 16];
				end
			end
		end
	end
	endgenerate
`else
	genvar g_s0;
	generate
	for (g_s0 = 0; g_s0 < 4; g_s0 = g_s0 + 1) begin : g_pipe_s0
		always @(posedge clk) begin
			if (rst_sync) begin
				s0[g_s0] <= 128'd0;
				d0[g_s0] <= 128'd0;
			end else if (pe_s0_lane[g_s0]) begin
				s0[g_s0] <= s_unclamped_w[g_s0];
				d0[g_s0] <= d_unpacked_w[g_s0];
			end
		end
	end
	endgenerate
`endif

	/* =========================================================================
	 * STAGE 1: Factor Subtraction Term Launch (Latency: 1 cycle inside atg_rop_sub1)
	 * Operates from Stage 0 registered values (s0, d0, kc0, blend0_l), registering at Edge 2
	 * ========================================================================= */
	wire [31:0] sub_s_res [0:3][0:3];
	wire [31:0] sub_d_res [0:3][0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fac_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_fac_c
			wire is_alpha = (gc == 3);
			wire [3:0] f_s1 = is_alpha ? blend0_l[gl][15:12] : blend0_l[gl][4:1];
			wire [3:0] f_d1 = is_alpha ? blend0_l[gl][19:16] : blend0_l[gl][8:5];

			wire [31:0] sc1 = s0[gl][32 * gc +: 32];
			wire [31:0] dc1 = d0[gl][32 * gc +: 32];
			wire [31:0] sa1 = s0[gl][127:96];
			wire [31:0] da1 = d0[gl][127:96];
			wire [31:0] kcc1 = kc0[32 * gc +: 32];
			wire [31:0] ka1 = kc0[127:96];

			wire [31:0] xs1 = fval(f_s1, is_alpha, sc1, dc1, sa1, da1, kcc1, ka1);
			wire [31:0] xd1 = fval(f_d1, is_alpha, sc1, dc1, sa1, da1, kcc1, ka1);

			atg_rop_sub1 #(.LAT(1)) u_sub_s (.clk(clk), .rst_n(rst_n_net), .en(pe_s1_lane[gl]), .i_x(xs1), .o_r(sub_s_res[gl][gc]));
			atg_rop_sub1 #(.LAT(1)) u_sub_d (.clk(clk), .rst_n(rst_n_net), .en(pe_s1_lane[gl]), .i_x(xd1), .o_r(sub_d_res[gl][gc]));
		end
	end
	endgenerate

	/* =========================================================================
	 * STAGE 1 -> 2: Pipeline Registers (Latency: 1 cycle, aligns with sub_s/d_res)
	 * ========================================================================= */
	reg [127:0] s2 [0:3];
	reg [127:0] d2 [0:3];
	reg [127:0] kc2;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt2;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm2, lanes2;
	reg v2, known2;

`ifdef SYNTH_KINTEX7
	(* equivalent_register_removal = "no" *) reg [22:0] blend2_l [0:3];
	genvar g_bl2;
	generate
	for (g_bl2 = 0; g_bl2 < 4; g_bl2 = g_bl2 + 1) begin : g_pipe_bl2
		always @(posedge clk) begin
			if (rst_sync)
				blend2_l[g_bl2] <= 23'd0;
			else if (pe_s1_lane[g_bl2])
				blend2_l[g_bl2] <= blend0_l[g_bl2];
		end
	end
	endgenerate

	wire pe_s2a_ctrl_a, pe_s2a_ctrl_b;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2aa (.I0(pe_s1_ctrl), .O(pe_s2a_ctrl_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2ab (.I0(pe_s1_ctrl), .O(pe_s2a_ctrl_b));

	always @(posedge clk) begin
		if (rst_sync) begin
			v2 <= 1'b0;
			known2 <= 1'b0;
			fmt2 <= 8'd0;
			kc2 <= 128'd0;
		end else if (pe_s2a_ctrl_a) begin
			v2 <= v0_r;
			known2 <= known0_r;
			fmt2 <= fmt0_r;
			kc2 <= kc0;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			wm2 <= 4'd0;
			lanes2 <= 4'd0;
		end else if (pe_s2a_ctrl_b) begin
			wm2 <= wm0_r;
			lanes2 <= lanes0_r;
		end
	end

	wire [15:0] pe_s2a_leaf [0:3];
	genvar g_s2a, g_s2a_b, g_s2a_k;
	generate
	for (g_s2a = 0; g_s2a < 4; g_s2a = g_s2a + 1) begin : g_pipe_s2a
		for (g_s2a_b = 0; g_s2a_b < 16; g_s2a_b = g_s2a_b + 1) begin : g_leaf_s2a
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_l2a (
				.I0(pe_s1_lane[g_s2a]), .O(pe_s2a_leaf[g_s2a][g_s2a_b])
			);
		end
		for (g_s2a_k = 0; g_s2a_k < 8; g_s2a_k = g_s2a_k + 1) begin : g_reg_s2a
			always @(posedge clk) begin
				if (rst_sync) begin
					s2[g_s2a][16 * g_s2a_k +: 16] <= 16'd0;
					d2[g_s2a][16 * g_s2a_k +: 16] <= 16'd0;
				end else begin
					if (pe_s2a_leaf[g_s2a][g_s2a_k])
						s2[g_s2a][16 * g_s2a_k +: 16] <= s0[g_s2a][16 * g_s2a_k +: 16];
					if (pe_s2a_leaf[g_s2a][8 + g_s2a_k])
						d2[g_s2a][16 * g_s2a_k +: 16] <= d0[g_s2a][16 * g_s2a_k +: 16];
				end
			end
		end
	end
	endgenerate
`else
	reg [22:0] blend2;
	wire [22:0] blend2_l [0:3];
	genvar g_bl2;
	generate
	for (g_bl2 = 0; g_bl2 < 4; g_bl2 = g_bl2 + 1) begin : g_pipe_bl2
		assign blend2_l[g_bl2] = blend2;
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			v2 <= 1'b0;
			known2 <= 1'b0;
			blend2 <= 23'd0;
			fmt2 <= 8'd0;
			wm2 <= 4'd0;
			lanes2 <= 4'd0;
			kc2 <= 128'd0;
		end else if (pe_s1_ctrl) begin
			v2 <= v0_r;
			known2 <= known0_r;
			blend2 <= blend0;
			fmt2 <= fmt0_r;
			wm2 <= wm0_r;
			lanes2 <= lanes0_r;
			kc2 <= kc0;
		end
	end

	genvar g_s2a;
	generate
	for (g_s2a = 0; g_s2a < 4; g_s2a = g_s2a + 1) begin : g_pipe_s2a
		always @(posedge clk) begin
			if (rst_sync) begin
				s2[g_s2a] <= 128'd0;
				d2[g_s2a] <= 128'd0;
			end else if (pe_s1_lane[g_s2a]) begin
				s2[g_s2a] <= s0[g_s2a];
				d2[g_s2a] <= d0[g_s2a];
			end
		end
	end
	endgenerate
`endif

	/* =========================================================================
	 * STAGE 2: Factor Combination, Operand Selection & Multiplier Launch (Latency: 2 cycles)
	 * Operates on aligned sub_s_res / sub_d_res and registered Stage 1 values (s2, d2, kc2, blend2_l)
	 * Launches directly into 2-cycle multipliers u_mul_p and u_mul_q
	 * ========================================================================= */
	wire [127:0] fs_w [0:3];
	wire [127:0] fd_w [0:3];
	wire [127:0] p_in_a_w [0:3];
	wire [127:0] p_in_b_w [0:3];
	wire [127:0] q_in_a_w [0:3];
	wire [127:0] q_in_b_w [0:3];
	wire [127:0] bypass2_w [0:3];
	wire [3:0] sub_sel2_w;
	wire [3:0] use_pq2_w;

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_fac2_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_fac2_c
			wire is_alpha = (gc == 3);
			wire [3:0] f_s2 = is_alpha ? blend2_l[gl][15:12] : blend2_l[gl][4:1];
			wire [3:0] f_d2 = is_alpha ? blend2_l[gl][19:16] : blend2_l[gl][8:5];
			wire [2:0] op2_c = is_alpha ? blend2_l[gl][22:20] : blend2_l[gl][11:9];

			wire [31:0] sc2 = s2[gl][32 * gc +: 32];
			wire [31:0] dc2 = d2[gl][32 * gc +: 32];
			wire [31:0] sa2 = s2[gl][127:96];
			wire [31:0] da2 = d2[gl][127:96];
			wire [31:0] kcc2 = kc2[32 * gc +: 32];
			wire [31:0] ka2 = kc2[127:96];

			wire [31:0] xs2 = fval(f_s2, is_alpha, sc2, dc2, sa2, da2, kcc2, ka2);
			wire [31:0] xd2 = fval(f_d2, is_alpha, sc2, dc2, sa2, da2, kcc2, ka2);

			wire [31:0] fsc2 = needs_sub(f_s2, is_alpha) ?
				(f_s2 == 4'd14 ? fmin(sa2, sub_s_res[gl][gc]) : sub_s_res[gl][gc]) : xs2;
			wire [31:0] fdc2 = needs_sub(f_d2, is_alpha) ?
				(f_d2 == 4'd14 ? fmin(sa2, sub_d_res[gl][gc]) : sub_d_res[gl][gc]) : xd2;

			assign fs_w[gl][32 * gc +: 32] = fsc2;
			assign fd_w[gl][32 * gc +: 32] = fdc2;

			wire is_rev = (op2_c == 3'd2);
			assign p_in_a_w[gl][32 * gc +: 32] = is_rev ? dc2 : sc2;
			assign p_in_b_w[gl][32 * gc +: 32] = is_rev ? fdc2 : fsc2;
			assign q_in_a_w[gl][32 * gc +: 32] = is_rev ? sc2 : dc2;
			assign q_in_b_w[gl][32 * gc +: 32] = is_rev ? fsc2 : fdc2;

			wire [31:0] min_v = fmin(sc2, dc2);
			wire [31:0] max_v = fmax(sc2, dc2);
			assign bypass2_w[gl][32 * gc +: 32] = (!blend2_l[gl][0]) ? sc2 :
				(op2_c == 3'd3) ? min_v : max_v;
		end
	end
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_sub_sel
		wire is_alpha = (gc == 3);
		wire [2:0] op2_c = is_alpha ? blend2_l[0][22:20] : blend2_l[0][11:9];
		assign sub_sel2_w[gc] = (op2_c == 3'd1 || op2_c == 3'd2);
		assign use_pq2_w[gc] = blend2_l[0][0] && (op2_c != 3'd3 && op2_c != 3'd4);
	end
	endgenerate

	wire [127:0] p_w [0:3];
	wire [127:0] q_w [0:3];

	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_mul_l
		for (gc = 0; gc < 4; gc = gc + 1) begin : g_mul_c
			wire [31:0] p_res, q_res;
			atg_rop_fmul u_mul_p (.clk(clk), .rst_n(rst_n_net), .en(pe_mul[gl][gc]),
				.i_a(p_in_a_w[gl][32 * gc +: 32]), .i_b(p_in_b_w[gl][32 * gc +: 32]),
				.o_r(p_res));
			atg_rop_fmul u_mul_q (.clk(clk), .rst_n(rst_n_net), .en(pe_mul[gl][gc]),
				.i_a(q_in_a_w[gl][32 * gc +: 32]), .i_b(q_in_b_w[gl][32 * gc +: 32]),
				.o_r(q_res));
			assign p_w[gl][32 * gc +: 32] = p_res;
			assign q_w[gl][32 * gc +: 32] = q_res;
		end
	end
	endgenerate

	/* Pipeline matching registers (2 cycles delay matching multiplier) */
	reg [127:0] bypass1_m [0:3];
	reg [3:0] sub_sel1_m;
	reg [3:0] use_pq1_m;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt1_m;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm1_m, lanes1_m;
	reg v1_m, known1_m;

	reg [127:0] p3 [0:3];
	reg [127:0] q3 [0:3];
	reg [127:0] bypass3 [0:3];
	reg [3:0] sub_sel3;
	(* equivalent_register_removal = "no" *) reg [3:0] use_pq3_lo [0:3];
	(* equivalent_register_removal = "no" *) reg [3:0] use_pq3_hi [0:3];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] fmt3;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] wm3, lanes3;
	reg v3, known3;

`ifdef SYNTH_KINTEX7
	wire pe_s2_ctrl_a, pe_s2_ctrl_b, pe_s2_ctrl_c, pe_s2_ctrl_d;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2a (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2b (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2c (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_c));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pe_c2d (.I0(pe_s2_ctrl), .O(pe_s2_ctrl_d));

	always @(posedge clk) begin
		if (rst_sync) begin
			v1_m <= 1'b0;
			known1_m <= 1'b0;
			fmt1_m <= 8'd0;
			wm1_m <= 4'd0;
		end else if (pe_s2_ctrl_a) begin
			v1_m <= v2;
			known1_m <= known2;
			fmt1_m <= fmt2;
			wm1_m <= wm2;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			lanes1_m <= 4'd0;
			sub_sel1_m <= 4'd0;
			use_pq1_m <= 4'd0;
		end else if (pe_s2_ctrl_b) begin
			lanes1_m <= lanes2;
			sub_sel1_m <= sub_sel2_w;
			use_pq1_m <= use_pq2_w;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			v3 <= 1'b0;
			known3 <= 1'b0;
			fmt3 <= 8'd0;
			wm3 <= 4'd0;
		end else if (pe_s2_ctrl_c) begin
			v3 <= v1_m;
			known3 <= known1_m;
			fmt3 <= fmt1_m;
			wm3 <= wm1_m;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			lanes3 <= 4'd0;
			sub_sel3 <= 4'd0;
		end else if (pe_s2_ctrl_d) begin
			lanes3 <= lanes1_m;
			sub_sel3 <= sub_sel1_m;
		end
	end

	wire [2:0] pe_s2_mid [0:3];
	wire [32:0] pe_s2_leaf [0:3];
	genvar g_s2, g_s2_m, g_s2_b, g_s2_k;
	generate
	for (g_s2 = 0; g_s2 < 4; g_s2 = g_s2 + 1) begin : g_pipe_s2
		for (g_s2_m = 0; g_s2_m < 3; g_s2_m = g_s2_m + 1) begin : g_mid_s2
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_m2 (
				.I0(pe_s2_lane[g_s2]), .O(pe_s2_mid[g_s2][g_s2_m])
			);
		end
		for (g_s2_b = 0; g_s2_b < 33; g_s2_b = g_s2_b + 1) begin : g_leaf_s2
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_l2 (
				.I0(pe_s2_mid[g_s2][g_s2_b / 11]), .O(pe_s2_leaf[g_s2][g_s2_b])
			);
		end
		always @(posedge clk) begin
			if (rst_sync) begin
				use_pq3_lo[g_s2] <= 4'd0;
				use_pq3_hi[g_s2] <= 4'd0;
			end else if (pe_s2_leaf[g_s2][32]) begin
				use_pq3_lo[g_s2] <= use_pq1_m;
				use_pq3_hi[g_s2] <= use_pq1_m;
			end
		end
		for (g_s2_k = 0; g_s2_k < 8; g_s2_k = g_s2_k + 1) begin : g_reg_s2
			always @(posedge clk) begin
				if (rst_sync) begin
					bypass1_m[g_s2][16 * g_s2_k +: 16] <= 16'd0;
					p3[g_s2][16 * g_s2_k +: 16] <= 16'd0;
					q3[g_s2][16 * g_s2_k +: 16] <= 16'd0;
					bypass3[g_s2][16 * g_s2_k +: 16] <= 16'd0;
				end else begin
					if (pe_s2_leaf[g_s2][g_s2_k])
						bypass1_m[g_s2][16 * g_s2_k +: 16] <= bypass2_w[g_s2][16 * g_s2_k +: 16];
					if (pe_s2_leaf[g_s2][8 + g_s2_k])
						p3[g_s2][16 * g_s2_k +: 16] <= p_w[g_s2][16 * g_s2_k +: 16];
					if (pe_s2_leaf[g_s2][16 + g_s2_k])
						q3[g_s2][16 * g_s2_k +: 16] <= q_w[g_s2][16 * g_s2_k +: 16];
					if (pe_s2_leaf[g_s2][24 + g_s2_k])
						bypass3[g_s2][16 * g_s2_k +: 16] <= bypass1_m[g_s2][16 * g_s2_k +: 16];
				end
			end
		end
	end
	endgenerate
`else
	always @(posedge clk) begin
		if (rst_sync) begin
			v1_m <= 1'b0;
			known1_m <= 1'b0;
			fmt1_m <= 8'd0;
			wm1_m <= 4'd0;
			lanes1_m <= 4'd0;
			sub_sel1_m <= 4'd0;
			use_pq1_m <= 4'd0;
			v3 <= 1'b0;
			known3 <= 1'b0;
			fmt3 <= 8'd0;
			wm3 <= 4'd0;
			lanes3 <= 4'd0;
			sub_sel3 <= 4'd0;
		end else if (pe_s2_ctrl) begin
			v1_m <= v2;
			known1_m <= known2;
			fmt1_m <= fmt2;
			wm1_m <= wm2;
			lanes1_m <= lanes2;
			sub_sel1_m <= sub_sel2_w;
			use_pq1_m <= use_pq2_w;

			v3 <= v1_m;
			known3 <= known1_m;
			fmt3 <= fmt1_m;
			wm3 <= wm1_m;
			lanes3 <= lanes1_m;
			sub_sel3 <= sub_sel1_m;
		end
	end

	genvar g_s2;
	generate
	for (g_s2 = 0; g_s2 < 4; g_s2 = g_s2 + 1) begin : g_pipe_s2
		always @(posedge clk) begin
			if (rst_sync) begin
				use_pq3_lo[g_s2] <= 4'd0;
				use_pq3_hi[g_s2] <= 4'd0;
				bypass1_m[g_s2] <= 128'd0;
				p3[g_s2] <= 128'd0;
				q3[g_s2] <= 128'd0;
				bypass3[g_s2] <= 128'd0;
			end else if (pe_s2_lane[g_s2]) begin
				bypass1_m[g_s2] <= bypass2_w[g_s2];
				use_pq3_lo[g_s2] <= use_pq1_m;
				use_pq3_hi[g_s2] <= use_pq1_m;
				p3[g_s2] <= p_w[g_s2];
				q3[g_s2] <= q_w[g_s2];
				bypass3[g_s2] <= bypass1_m[g_s2];
			end
		end
	end
	endgenerate
`endif
"""

res = orig[:idx1] + new_block + orig[idx2:]
with open('scratch/atg_rop_fblend_test.v', 'w') as f:
    f.write(res)
print("Wrote scratch/atg_rop_fblend_test.v successfully")
