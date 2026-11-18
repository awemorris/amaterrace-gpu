`timescale 1ns / 1ps
`default_nettype none

module test_fadd_full #(
	parameter LAT = 4
) (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	input wire i_sub,
	output wire o_valid,
	output wire [31:0] o_r
);

	/* Stage 1: unpack, detect specials, compare and swap */
	wire [31:0] b_in = {i_b[31] ^ i_sub, i_b[30:0]};
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = b_in[30:23];
	wire [23:0] ma = (ea == 8'd0) ? 24'd0 : {1'b1, i_a[22:0]};
	wire [23:0] mb = (eb == 8'd0) ? 24'd0 : {1'b1, b_in[22:0]};
	wire za = (ea == 8'd0);
	wire zb = (eb == 8'd0);

	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && b_in[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && b_in[22:0] == 23'd0;

	/* Exponent difference */
	wire [7:0] dab, dba;
	wire ea_lt_eb, dba_bo_unused;
	am_sub #(.W(8)) u_dab (.a(ea), .b(eb), .bi(1'b0), .d(dab), .bo(ea_lt_eb));
	am_sub #(.W(8)) u_dba (.a(eb), .b(ea), .bi(1'b0), .d(dba), .bo(dba_bo_unused));
	wire [7:0] exp_diff = ea_lt_eb ? dba : dab;

	wire mant_diff_bo;
	wire [22:0] mant_diff_unused;
	am_sub #(.W(23)) u_mant_cmp (.a(i_a[22:0]), .b(i_b[22:0]), .bi(1'b0), .d(mant_diff_unused), .bo(mant_diff_bo));
	wire mant_ge = !mant_diff_bo;
	wire a_big = (ea != eb) ? !ea_lt_eb : mant_ge;

	wire v1_w = rst_n && i_valid;
	wire sp1_w = nan_a || nan_b || (inf_a && inf_b && i_a[31] != b_in[31]) || inf_a || inf_b || (ma == 24'd0 && mb == 24'd0);
	wire [31:0] spv1_w = (nan_a || nan_b || (inf_a && inf_b && i_a[31] != b_in[31])) ? 32'h7FC00000 :
		inf_a ? {i_a[31], 8'hFF, 23'd0} :
		inf_b ? {b_in[31], 8'hFF, 23'd0} :
		(ma == 24'd0 && mb == 24'd0) ? {i_a[31] && b_in[31], 31'd0} : 32'd0;
	wire sx1_w = a_big ? i_a[31] : b_in[31];
	wire sub1_w = i_a[31] != b_in[31];
	wire [7:0] ex1_w = a_big ? ea : eb;
	wire [23:0] mx1_w = a_big ? ma : mb;
	wire [23:0] my1_w = a_big ? mb : ma;
	wire [7:0] d1_w = (za || zb) ? 8'd255 : exp_diff;
	wire sz1_w = sub1_w && (ea == eb) && (i_a[22:0] == b_in[22:0]);

	wire v1;
	wire sp1, sx1, sub1, sz1;
	wire [31:0] spv1;
	wire [7:0] ex1, d1;
	wire [23:0] mx1, my1;

	/* Stage 2: align the smaller operand */
	wire [26:0] shi = {my1, 3'b000};
	wire [26:0] shr;
	am_shift #(.W(27), .SW(5)) u_shr (.a(shi), .amt(d1[4:0]), .left(1'b0), .arith(1'b0), .y(shr));

	wire [3:0] my_nz;
	assign my_nz[0] = |my1[5:0];
	assign my_nz[1] = |my1[11:6];
	assign my_nz[2] = |my1[17:12];
	assign my_nz[3] = |my1[23:18];

	reg stk;
	integer k;
	always @(*) begin
		if (d1 >= 8'd27) begin
			stk = |my_nz;
		end else begin
			stk = 1'b0;
			for (k = 0; k < 27; k = k + 1)
				if (k < d1)
					stk = stk | shi[k];
		end
	end

	wire [9:0] ex2_p1_w, ex2_sub1_w;
	wire ex2_p1_co_unused, ex2_sub1_bo_unused;
	am_add #(.W(10)) u_ex2_p1 (.a({2'b00, ex1}), .b(10'd1), .ci(1'b0), .s(ex2_p1_w), .co(ex2_p1_co_unused));
	am_sub #(.W(10)) u_ex2_sub1 (.a({2'b00, ex1}), .b(10'd1), .bi(1'b0), .d(ex2_sub1_w), .bo(ex2_sub1_bo_unused));

	wire v2_w = rst_n && v1;
	wire sp2_w = sp1;
	wire [31:0] spv2_w = spv1;
	wire sx2_w = sx1;
	wire sub2_w = sub1;
	wire sz2_w = sz1;
	wire [7:0] ex2_w = ex1;
	wire [26:0] px2_w = {mx1, 3'b000};
	wire [26:0] py2_w = (d1 >= 8'd27) ? {26'd0, stk} : {shr[26:1], shr[0] | stk};

	wire v2;
	wire sp2, sx2, sub2, sz2;
	wire [31:0] spv2;
	wire [7:0] ex2;
	wire [9:0] ex2_p1, ex2_sub1;
	wire [26:0] px2, py2;

	/* Stage 3: add or subtract */
	wire [27:0] sum;
	wire sum_co_unused;
	am_addsub #(.W(28)) u_sum (.a({1'b0, px2}), .b({1'b0, py2}), .sub(sub2), .s(sum), .co(sum_co_unused));

	reg [4:0] lz;
	always @(*) begin
		lz = 5'd27;
		for (k = 0; k < 27; k = k + 1)
			if (sum[k])
				lz = 5'd26 - k[4:0];
	end

	wire [27:0] sum3_w = sum;
	wire [4:0] lz3_w = lz;
	wire sz3_w = sz2;
	wire sub2_3_w = sub2;
	wire [7:0] ex2_3_w = ex2;
	wire [9:0] ex2_p1_3_w = ex2_p1;
	wire [9:0] ex2_sub1_3_w = ex2_sub1;

	wire v3_w = rst_n && v2;
	wire sp3_w = sp2;
	wire [31:0] spv3_w = spv2;
	wire sx3_w = sx2;

	wire v3;
	wire sp3, sx3, sz3, sub2_3;
	wire [31:0] spv3;
	wire [27:0] sum3;
	(* max_fanout = 16 *) wire [4:0] lz3;
	wire [7:0] ex2_3;
	wire [9:0] ex2_p1_3, ex2_sub1_3;

	/* Stage 4: Dual-path normalisation & rounding */
	/* Close path */
	reg [26:0] nl_s1;
	always @(*) begin
		case (lz3[1:0])
		2'd0: nl_s1 = sum3[26:0];
		2'd1: nl_s1 = {sum3[25:0], 1'b0};
		2'd2: nl_s1 = {sum3[24:0], 2'b00};
		default: nl_s1 = {sum3[23:0], 3'b000};
		endcase
	end

	reg [26:0] nl;
	always @(*) begin
		case (lz3[4:2])
		3'd0: nl = nl_s1;
		3'd1: nl = {nl_s1[22:0], 4'd0};
		3'd2: nl = {nl_s1[18:0], 8'd0};
		3'd3: nl = {nl_s1[14:0], 12'd0};
		3'd4: nl = {nl_s1[10:0], 16'd0};
		3'd5: nl = {nl_s1[6:0], 20'd0};
		3'd6: nl = {nl_s1[2:0], 24'd0};
		default: nl = 27'd0;
		endcase
	end
	wire [22:0] close_m = nl[25:3];

	/* Boolean subtractor for close_e = ex2_3 - {3'd0, lz3} without CARRY4 */
	wire [4:0] b_lz = lz3;
	wire [7:0] a_ex = ex2_3;
	wire [7:0] close_e;
	wire [4:0] bo_low;
	assign bo_low[0] = ~a_ex[0] & b_lz[0];
	assign bo_low[1] = (~a_ex[1] & b_lz[1]) | ((~a_ex[1] | b_lz[1]) & bo_low[0]);
	assign bo_low[2] = (~a_ex[2] & b_lz[2]) | ((~a_ex[2] | b_lz[2]) & bo_low[1]);
	assign bo_low[3] = (~a_ex[3] & b_lz[3]) | ((~a_ex[3] | b_lz[3]) & bo_low[2]);
	assign bo_low[4] = (~a_ex[4] & b_lz[4]) | ((~a_ex[4] | b_lz[4]) & bo_low[3]);

	assign close_e[0] = a_ex[0] ^ b_lz[0];
	assign close_e[1] = a_ex[1] ^ b_lz[1] ^ bo_low[0];
	assign close_e[2] = a_ex[2] ^ b_lz[2] ^ bo_low[1];
	assign close_e[3] = a_ex[3] ^ b_lz[3] ^ bo_low[2];
	assign close_e[4] = a_ex[4] ^ b_lz[4] ^ bo_low[3];
	assign close_e[5] = a_ex[5] ^ bo_low[4];
	assign close_e[6] = a_ex[6] ^ (bo_low[4] & ~a_ex[5]);
	assign close_e[7] = a_ex[7] ^ (bo_low[4] & ~a_ex[5] & ~a_ex[6]);

	wire close_unf = (a_ex[7:5] == 3'd0) && (bo_low[4] || (a_ex[4:0] == b_lz));
	wire [31:0] close_r = close_unf ? {sx3, 31'd0} : {sx3, close_e, close_m};

	/* Far path: lz <= 1 or addition */
	wire far_c = sum3[27];
	wire far_norm = sum3[26];
	wire [23:0] far_m_unrounded = far_c ? sum3[27:4] : (far_norm ? sum3[26:3] : sum3[25:2]);
	wire far_inc = far_c ? (sum3[3] && (|sum3[2:0] || sum3[4])) :
	               far_norm ? (sum3[2] && (|sum3[1:0] || sum3[3])) :
	               (sum3[1] && (sum3[0] || sum3[2]));

	/* far_cout only possible when far_norm && &sum3[26:3] && far_inc */
	wire far_m0_cout = far_norm && (&sum3[26:3]) && (sum3[2] && (|sum3[1:0] || sum3[3]));

	wire [3:0] g_p;
	assign g_p[0] = &far_m_unrounded[5:0];
	assign g_p[1] = &far_m_unrounded[11:6];
	assign g_p[2] = &far_m_unrounded[17:12];
	assign g_p[3] = &far_m_unrounded[23:18];

	wire [3:0] g_cin;
	assign g_cin[0] = far_inc;
	assign g_cin[1] = far_inc & g_p[0];
	assign g_cin[2] = far_inc & g_p[0] & g_p[1];
	assign g_cin[3] = far_inc & g_p[0] & g_p[1] & g_p[2];

	wire [22:0] far_m_inc;
	genvar gi;
	generate
	for (gi = 0; gi < 23; gi = gi + 1) begin : g_fminc
		wire ci_g = g_cin[gi / 6];
		wire [gi % 6:0] slice = far_m_unrounded[(gi/6)*6 +: ((gi%6)+1)];
		assign far_m_inc[gi] = far_m0_cout ? 1'b0 : (slice[gi%6] ^ (ci_g & (&slice)));
	end
	endgenerate

	wire [7:0] far_e = (far_c || far_m0_cout) ? ex2_p1_3[7:0] : (far_norm ? ex2_3[7:0] : ex2_sub1_3[7:0]);
	wire far_ovf = (ex2_3 >= 8'd254) && (far_c || far_m0_cout);
	wire far_unf = (ex2_3 <= 8'd1) && (!far_c && !far_norm && !far_m0_cout);

	wire [31:0] far_r = far_ovf ? {sx3, 8'hFF, 23'd0} :
	                    far_unf ? {sx3, 31'd0} :
	                    {sx3, far_e, far_m_inc};

	wire is_close = sub2_3 && (lz3 >= 5'd2);

	wire o_valid_comb = rst_n && v3;
	wire [31:0] o_r_comb = sp3 ? spv3 :
		sz3 ? 32'd0 :
		is_close ? close_r : far_r;

	wire unused_bits = &{1'b0, nl[26], nl[2:0],
		dba_bo_unused, sum_co_unused, ex2_p1_co_unused,
		ex2_sub1_bo_unused, mant_diff_unused, ex2_p1_3[9:8], ex2_sub1_3[9:8]};

	generate
		if (LAT == 0) begin : g_lat0
			assign v1 = i_valid;
			assign sp1 = sp1_w;
			assign spv1 = spv1_w;
			assign sx1 = sx1_w;
			assign sub1 = sub1_w;
			assign sz1 = sz1_w;
			assign ex1 = ex1_w;
			assign mx1 = mx1_w;
			assign my1 = my1_w;
			assign d1 = d1_w;

			assign v2 = v1;
			assign sp2 = sp2_w;
			assign spv2 = spv2_w;
			assign sx2 = sx2_w;
			assign sub2 = sub2_w;
			assign sz2 = sz2_w;
			assign ex2 = ex2_w;
			assign ex2_p1 = ex2_p1_w;
			assign ex2_sub1 = ex2_sub1_w;
			assign px2 = px2_w;
			assign py2 = py2_w;

			assign v3 = v2;
			assign sp3 = sp3_w;
			assign spv3 = spv3_w;
			assign sx3 = sx3_w;
			assign sum3 = sum3_w;
			assign sz3 = sz3_w;
			assign lz3 = lz3_w;
			assign sub2_3 = sub2_3_w;
			assign ex2_3 = ex2_3_w;
			assign ex2_p1_3 = ex2_p1_3_w;
			assign ex2_sub1_3 = ex2_sub1_3_w;

			assign o_valid = o_valid_comb;
			assign o_r = o_r_comb;

			wire unused_clk = &{1'b0, clk, v1_w, v2_w, v3_w, unused_bits};
		end else begin : g_lat4
			reg r_v1, r_sp1, r_sx1, r_sub1, r_sz1;
			reg [31:0] r_spv1;
			reg [7:0] r_ex1, r_d1;
			reg [23:0] r_mx1, r_my1;

			always @(posedge clk) begin
				r_v1 <= v1_w;
				r_sp1 <= sp1_w;
				r_spv1 <= spv1_w;
				r_sx1 <= sx1_w;
				r_sub1 <= sub1_w;
				r_sz1 <= sz1_w;
				r_ex1 <= ex1_w;
				r_mx1 <= mx1_w;
				r_my1 <= my1_w;
				r_d1 <= d1_w;
			end

			assign v1 = r_v1;
			assign sp1 = r_sp1;
			assign spv1 = r_spv1;
			assign sx1 = r_sx1;
			assign sub1 = r_sub1;
			assign sz1 = r_sz1;
			assign ex1 = r_ex1;
			assign mx1 = r_mx1;
			assign my1 = r_my1;
			assign d1 = r_d1;

			reg r_v2, r_sp2, r_sx2, r_sub2, r_sz2;
			reg [31:0] r_spv2;
			reg [7:0] r_ex2;
			reg [9:0] r_ex2_p1, r_ex2_sub1;
			reg [26:0] r_px2, r_py2;

			always @(posedge clk) begin
				r_v2 <= v2_w;
				r_sp2 <= sp2_w;
				r_spv2 <= spv2_w;
				r_sx2 <= sx2_w;
				r_sub2 <= sub2_w;
				r_sz2 <= sz2_w;
				r_ex2 <= ex2_w;
				r_ex2_p1 <= ex2_p1_w;
				r_ex2_sub1 <= ex2_sub1_w;
				r_px2 <= px2_w;
				r_py2 <= py2_w;
			end

			assign v2 = r_v2;
			assign sp2 = r_sp2;
			assign spv2 = r_spv2;
			assign sx2 = r_sx2;
			assign sub2 = r_sub2;
			assign sz2 = r_sz2;
			assign ex2 = r_ex2;
			assign ex2_p1 = r_ex2_p1;
			assign ex2_sub1 = r_ex2_sub1;
			assign px2 = r_px2;
			assign py2 = r_py2;

			reg r_v3, r_sp3, r_sx3, r_sz3, r_sub2_3;
			reg [31:0] r_spv3;
			reg [27:0] r_sum3;
			(* max_fanout = 16 *) reg [4:0] r_lz3;
			reg [7:0] r_ex2_3;
			reg [9:0] r_ex2_p1_3, r_ex2_sub1_3;

			always @(posedge clk) begin
				r_v3        <= v3_w;
				r_sp3       <= sp3_w;
				r_spv3      <= spv3_w;
				r_sx3       <= sx3_w;
				r_sum3      <= sum3_w;
				r_sz3       <= sz3_w;
				r_lz3       <= lz3_w;
				r_sub2_3    <= sub2_3_w;
				r_ex2_3     <= ex2_3_w;
				r_ex2_p1_3  <= ex2_p1_3_w;
				r_ex2_sub1_3<= ex2_sub1_3_w;
			end

			assign v3       = r_v3;
			assign sp3      = r_sp3;
			assign spv3     = r_spv3;
			assign sx3      = r_sx3;
			assign sum3     = r_sum3;
			assign sz3      = r_sz3;
			assign lz3      = r_lz3;
			assign sub2_3   = r_sub2_3;
			assign ex2_3    = r_ex2_3;
			assign ex2_p1_3 = r_ex2_p1_3;
			assign ex2_sub1_3 = r_ex2_sub1_3;

			reg r_ovalid;
			(* extract_reset = "no" *) reg [31:0] r_or;

			always @(posedge clk) begin
				r_ovalid <= o_valid_comb;
				r_or     <= o_r_comb;
			end

			assign o_valid = r_ovalid;
			assign o_r     = r_or;
		end
	endgenerate
endmodule

`default_nettype wire
