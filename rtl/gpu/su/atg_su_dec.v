/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dec: Decodes a 64-bit GSI1 instruction (design §3.3, §3.4) into
 * the SU micro-op of include/atg_su_uop.vh: unit, operation, operand
 * numbers (7 bits), immediate, modifiers, latency class, destination
 * count, and the ISA-fault flag.
 *
 * d_* -> u_*: one pipeline register with valid/ready (d_ready when the
 * register is empty or u_ready takes it).  An undefined or disallowed
 * instruction gives a uop with only ILL set (unit NONE); atg_su_sb faults
 * on it.  The op codes are those of include/atg_su_uop.vh; tools/gsi1asm.py
 * holds the same table (its --dec-table output is this module's reference).
 * The opcode table is in the children atg_su_dec_tab and atg_su_dec_tabc.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dec #(
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter NREGS = 32,	/* GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq) */
	parameter PACKED = 0,	/* 16-bit packed arithmetic present (else those opcodes are ISA faults; packh/unpackh always present) */
	parameter SUBGROUP = 0,	/* shfl/vote/ballot present (CAPS[24]) */
	parameter HAS_SA = 0,	/* rq/sactl/qstat/sastat/qtag usable (always 0 in v1) */
	parameter MS4 = 0,	/* texsz.s present (CAPS[29]) */
	parameter PIPE_TAB = 0	/* 1: 2-stage decode pipeline for high-frequency synthesis */
) (
	input wire clk,
	input wire rst_n,
	input wire d_valid,
	output wire d_ready,
	input wire [WARP_W-1:0] d_warp,
	input wire [15:0] d_pc,
	input wire [63:0] d_instr,
	output reg u_valid,
	input wire u_ready,
	output reg [WARP_W-1:0] u_warp,
	output reg [15:0] u_pc,
	output wire [UOP_W-1:0] u_uop
);
`include "atg_su_uop.vh"

	/* Formats: which immediate the instruction has. */
	localparam [2:0] FM_I = 3'd1, FM_S = 3'd2, FM_B = 3'd3, FM_U = 3'd4;

	wire [31:0] d_w0 = d_instr[31:0];
	wire [31:0] d_w1 = d_instr[63:32];
	wire [6:0] d_opc = d_w0[6:0];
	wire [2:0] d_f3 = d_w0[14:12];
	wire [6:0] d_f7 = d_w0[31:25];
	wire [4:0] d_rs2f = d_w0[24:20];
	wire [4:0] d_sub = d_w1[21:17];
	wire [6:0] d_rs1 = {d_w1[3:2], d_w0[19:15]};
	wire [31:0] d_hi = {{12{d_w1[31]}}, d_w1[31:22], 10'd0} << 2;

	/* The table lookup: the RISC-V opcodes and custom-0..3. */
	wire [28:0] tr, tc;
	(* keep = "true", max_fanout = 12 *) wire custom_lo = d_opc == 7'b0001011 || d_opc == 7'b0101011 || d_opc == 7'b1011011 ||
		d_opc == 7'b1111011;
	(* keep = "true", max_fanout = 12 *) wire custom_hi = d_opc == 7'b0001011 || d_opc == 7'b0101011 || d_opc == 7'b1011011 ||
		d_opc == 7'b1111011;
	atg_su_dec_tab tab (
		.opc(d_opc), .f3(d_f3), .f7(d_f7), .rs2f(d_rs2f), .sub(d_sub), .fmt2(d_w0[26:25]),
		.def(tr[0]), .fmt(tr[3:1]), .unit(tr[7:4]), .op(tr[15:8]), .cls(tr[18:16]),
		.use1(tr[19]), .use2(tr[20]), .use3(tr[21]), .wrd(tr[22]), .pair(tr[23]),
		.side(tr[24]), .need_pk(tr[25]), .need_sg(tr[26]), .need_sa(tr[27]), .tex(tr[28])
	);
	atg_su_dec_tabc tabc (
		.opc(d_opc), .f3(d_f3), .f7(d_f7), .rs2f(d_rs2f), .sub(d_sub), .fmt2(d_w0[26:25]),
		.def(tc[0]), .fmt(tc[3:1]), .unit(tc[7:4]), .op(tc[15:8]), .cls(tc[18:16]),
		.use1(tc[19]), .use2(tc[20]), .use3(tc[21]), .wrd(tc[22]), .pair(tc[23]),
		.side(tc[24]), .need_pk(tc[25]), .need_sg(tc[26]), .need_sa(tc[27]), .tex(tc[28])
	);
	wire [28:0] d_tab_out = {custom_hi ? tc[28:15] : tr[28:15], custom_lo ? tc[14:0] : tr[14:0]};
	wire [2:0] d_fmt = d_tab_out[3:1];

	/* Precompute rs1 + 2 and immediate adder in Stage 0 (0 post-CARRY LUTs when PIPE_TAB=1). */
	wire [6:0] d_rs1_2;
	wire r2_co_unused;
	am_add #(.W(7)) u_rs1_2 (.a(d_rs1), .b(7'd2), .ci(1'b0), .s(d_rs1_2), .co(r2_co_unused));

	/* In RISC-V / custom encoding, FM_S only occurs for STORE (0100011), sts (0001011 f3=1),
	 * and exp (0101011 f3=4); FM_B only occurs for BRANCH (1100011). */
	(* keep = "true", max_fanout = 16 *) wire d_is_b = (d_opc == 7'b1100011);
	(* keep = "true", max_fanout = 16 *) wire d_is_s = (d_opc == 7'b0100011) ||
		(d_opc == 7'b0001011 && d_f3 == 3'd1) ||
		(d_opc == 7'b0101011 && d_f3 == 3'd4);
	wire [31:0] d_lo_i = {{20{d_w0[31]}}, d_w0[31:20]};
	wire [31:0] d_lo_s = {{20{d_w0[31]}}, d_w0[31:25], d_w0[11:7]};
	wire [31:0] d_lo_b = {{21{d_w0[31]}}, d_w0[7], d_w0[30:25], d_w0[11:8]};
	wire [31:0] d_imm_isb;
	wire im_co_unused;
	am_add #(.W(32)) u_imm (
		.a( (PIPE_TAB != 0 ? d_is_s : (d_fmt == FM_S)) ? d_lo_s :
		    (PIPE_TAB != 0 ? d_is_b : (d_fmt == FM_B)) ? d_lo_b : d_lo_i ),
		.b(d_hi), .ci(1'b0), .s(d_imm_isb), .co(im_co_unused)
	);

	(* max_fanout = 12 *) reg s0_valid;
	(* max_fanout = 12 *) reg [WARP_W-1:0] s0_warp;
	(* max_fanout = 12 *) reg [15:0] s0_pc;
	(* max_fanout = 12 *) reg [31:0] s0_w0, s0_w1;
	(* max_fanout = 12 *) reg [28:0] s0_tab;
	(* max_fanout = 12 *) reg [6:0] s0_rs1_2;
	(* max_fanout = 12 *) reg [31:0] s0_imm_isb;

	(* keep = "true", max_fanout = 12 *) wire u_adv = !u_valid || u_ready;
	assign d_ready = (PIPE_TAB != 0) ? (!s0_valid || u_adv) : u_adv;

	(* keep = "true" *) wire s0_ce_0 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_1 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_2 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_3 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_4 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_5 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_6 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_7 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_8 = d_ready && d_valid;
	(* keep = "true" *) wire s0_ce_9 = d_ready && d_valid;

	(* keep = "true" *) wire rst_s0_0 = !rst_n;
	(* keep = "true" *) wire rst_s0_1 = !rst_n;
	(* keep = "true" *) wire rst_s0_2 = !rst_n;
	(* keep = "true" *) wire rst_s0_3 = !rst_n;
	(* keep = "true" *) wire rst_s0_4 = !rst_n;
	(* keep = "true" *) wire rst_s0_5 = !rst_n;
	(* keep = "true" *) wire rst_u_hdr = !rst_n;

	always @(posedge clk) begin
		if (rst_s0_0) begin
			s0_valid <= 1'b0;
			s0_warp <= {WARP_W{1'b0}};
			s0_rs1_2 <= 7'd0;
		end else begin
			if (d_ready)
				s0_valid <= d_valid;
			if (s0_ce_0) begin
				s0_warp <= d_warp;
				s0_rs1_2 <= d_rs1_2;
			end
		end
		if (rst_s0_1)
			s0_pc <= 16'd0;
		else if (s0_ce_1)
			s0_pc <= d_pc;

		if (rst_s0_2) begin
			s0_w0 <= 32'd0;
		end else begin
			if (s0_ce_2)
				s0_w0[15:0] <= d_w0[15:0];
			if (s0_ce_3)
				s0_w0[31:16] <= d_w0[31:16];
		end

		if (rst_s0_3) begin
			s0_w1 <= 32'd0;
		end else begin
			if (s0_ce_4)
				s0_w1[15:0] <= d_w1[15:0];
			if (s0_ce_5)
				s0_w1[31:16] <= d_w1[31:16];
		end

		if (rst_s0_4) begin
			s0_tab <= 29'd0;
		end else begin
			if (s0_ce_6)
				s0_tab[14:0] <= d_tab_out[14:0];
			if (s0_ce_7)
				s0_tab[28:15] <= d_tab_out[28:15];
		end

		if (rst_s0_5) begin
			s0_imm_isb <= 32'd0;
		end else begin
			if (s0_ce_8)
				s0_imm_isb[15:0] <= d_imm_isb[15:0];
			if (s0_ce_9)
				s0_imm_isb[31:16] <= d_imm_isb[31:16];
		end
	end

	wire [31:0] w0 = (PIPE_TAB != 0) ? s0_w0 : d_w0;
	wire [31:0] w1 = (PIPE_TAB != 0) ? s0_w1 : d_w1;
	wire [28:0] tab_out = (PIPE_TAB != 0) ? s0_tab : d_tab_out;
	wire [6:0] rs1_2 = (PIPE_TAB != 0) ? s0_rs1_2 : d_rs1_2;
	wire [31:0] imm_isb = (PIPE_TAB != 0) ? s0_imm_isb : d_imm_isb;

	wire [2:0] f3 = w0[14:12];
	wire [6:0] f7 = w0[31:25];
	wire [4:0] sub = w1[21:17];
	wire [6:0] rd = {w1[1:0], w0[11:7]};
	wire [6:0] rs1 = {w1[3:2], w0[19:15]};
	wire [6:0] rs2 = {w1[5:4], w0[24:20]};
	wire [6:0] rs3f = {w1[7:6], w0[31:27]};
	wire [31:0] imm_u = {w0[31:12], w1[13:2]};

	wire def, use1, use2, use3, wrd, pair, side, need_pk, need_sg, need_sa, tex;
	(* max_fanout = 12 *) wire [2:0] fmt, cls;
	wire [3:0] unit;
	wire [7:0] op;
	assign {tex, need_sa, need_sg, need_pk, side, pair, wrd, use3, use2, use1, cls, op, unit,
		fmt, def} = tab_out;

	/* Operand checks (design §3.4.1: registers beyond NREGS, rq without SA). */
	function src_bad;
		input [6:0] r;
		begin
			if (r == 7'd63)
				src_bad = HAS_SA == 0;
			else
				src_bad = r < 7'd64 && {25'd0, r} >= NREGS;
		end
	endfunction

	/* A texture .c or .3 form reads rs1+2 (Dref or the third coordinate) as
	 * its rs3; .3 with .c also rs1+3 (Dref). */
	wire tthree = tex && f7[5];
	wire tcmp = tex && (op[ATG_TEX_CFORM] || tthree);
	wire [6:0] rs3 = tcmp ? rs1_2 : rs3f;
	wire t4 = tthree && op[ATG_TEX_CFORM];
	wire [6:0] lim = t4 ? 7'd60 : 7'd61;
	wire cmp_bad = tcmp && (rs1 < 7'd64 ? ({25'd0, rs1} >= (t4 ? NREGS - 3 : NREGS - 2) ||
		rs1 >= lim) : (rs1 == 7'd94 || rs1 == 7'd95 || rs1 == 7'd126 || rs1 == 7'd127 ||
		(t4 && (rs1 == 7'd93 || rs1 == 7'd125))));
	/* A texture R form's texel offsets: word1 [25:22], [29:26], [13:10]. */
	wire [31:0] imm_t = {20'd0, w1[13:10], w1[29:26], w1[25:22]};
	wire [2:0] ndst = !wrd ? 3'd0 : tex ? 3'd4 : 3'd1;
	wire pair_bad = pair && (rs1 < 7'd64 ? ({25'd0, rs1} >= NREGS - 1 || rs1 >= 7'd62)
		: (rs1 == 7'd95 || rs1 == 7'd127));
	wire dst_bad = wrd && (rd >= 7'd64 ||
		(rd == 7'd63 ? (HAS_SA == 0 || cls != ATG_CLS_A || tex) :
		(tex ? ({25'd0, rd} >= NREGS - 3 || rd >= 7'd60) : ({25'd0, rd} >= NREGS))));
	/* texsz.s (texsz with op[6] and op[3]) needs MS4. */
	wire need_ms = unit == ATG_UNIT_TEX && op[1:0] == 2'd3 && op[6] && op[3];
	(* keep = "true", max_fanout = 12 *) wire ill = w0[1:0] != 2'b11 || !def || (need_pk && PACKED == 0) || (need_ms && MS4 == 0) ||
		(need_sg && SUBGROUP == 0) || (need_sa && HAS_SA == 0) ||
		(use1 && src_bad(rs1)) || (use2 && src_bad(rs2)) || (use3 && !tcmp && src_bad(rs3f)) ||
		pair_bad || cmp_bad || dst_bad;
	wire rqs = (use1 && rs1 == 7'd63) || (use2 && rs2 == 7'd63) || (use3 && rs3 == 7'd63);

	(* keep = "true" *) wire [2:0] fmt_lo = fmt;
	(* keep = "true" *) wire [2:0] fmt_hi = fmt;
	(* keep = "true" *) wire not_fmu_0 = (fmt != FM_U);
	(* keep = "true" *) wire not_fmu_1 = (fmt != FM_U);
	reg [31:0] imm;
	always @(*) begin
		case (fmt_lo)
		FM_I, FM_S, FM_B: imm[15:0] = imm_isb[15:0];
		FM_U: imm[15:0] = imm_u[15:0];
		default: imm[15:0] = tex ? imm_t[15:0] : 16'd0;
		endcase
		case (fmt_hi)
		FM_I, FM_S, FM_B: imm[31:16] = imm_isb[31:16];
		FM_U: imm[31:16] = imm_u[31:16];
		default: imm[31:16] = tex ? imm_t[31:16] : 16'd0;
		endcase
	end

	reg [UOP_W-1:0] uop_raw;
	always @(*) begin
		uop_raw = {UOP_W{1'b0}};
		uop_raw[ATG_UOP_UNIT +: 4] = unit;
		uop_raw[ATG_UOP_OP +: 8] = op;
		uop_raw[ATG_UOP_RD +: 7] = rd;
		uop_raw[ATG_UOP_IMM +: 32] = imm;
		uop_raw[ATG_UOP_CLS +: 3] = cls;
		uop_raw[ATG_UOP_NDST +: 3] = ndst;
		uop_raw[ATG_UOP_USE1] = use1;
		uop_raw[ATG_UOP_USE2] = use2;
		uop_raw[ATG_UOP_USE3] = use3;
		uop_raw[ATG_UOP_WRD] = wrd;
		uop_raw[ATG_UOP_PAIR] = pair;
		uop_raw[ATG_UOP_RQS] = rqs;
		uop_raw[ATG_UOP_RQD] = wrd && rd == 7'd63;
		uop_raw[ATG_UOP_SIDE] = side;
		if (not_fmu_0) begin
			uop_raw[ATG_UOP_RS1 +: 7] = rs1;
			uop_raw[ATG_UOP_RS2 +: 7] = rs2;
		end
		if (not_fmu_1) begin
			uop_raw[ATG_UOP_RS3 +: 7] = rs3;
			uop_raw[ATG_UOP_MOD +: 7] = w1[14:8];
			uop_raw[ATG_UOP_HSEL +: 2] = w1[16:15];
			uop_raw[ATG_UOP_SUB +: 5] = {sub[4] | tthree, sub[3:0]};
			uop_raw[ATG_UOP_RM +: 3] = f3;
			uop_raw[ATG_UOP_SAMP_SLOT +: 4] = tex ? w1[9:6] : 4'd0;
		end
	end

	wire [UOP_W-1:0] uop;
	localparam U_SL = (UOP_W + 15) / 16;
	genvar gus;
	generate
		for (gus = 0; gus < U_SL; gus = gus + 1) begin : g_uop_sl
			localparam SL_B = gus * 16;
			localparam SL_W = (SL_B + 16 <= UOP_W) ? 16 : (UOP_W - SL_B);
			(* keep = "true" *) wire rst_uop_sl = !rst_n;
			(* keep = "true" *) wire ill_sl = ill;
			(* keep = "true" *) wire u_ce_sl = u_adv && ((PIPE_TAB != 0) ? s0_valid : d_valid);
			wire [UOP_W-1:0] ill_vec = ({{(UOP_W-1){1'b0}}, 1'b1} << ATG_UOP_ILL);
			assign uop[SL_B +: SL_W] = ill_sl ? ill_vec[SL_B +: SL_W] : uop_raw[SL_B +: SL_W];
			reg [SL_W-1:0] u_uop_sl_r;
			always @(posedge clk) begin
				if (rst_uop_sl)
					u_uop_sl_r <= {SL_W{1'b0}};
				else if (u_ce_sl)
					u_uop_sl_r <= uop[SL_B +: SL_W];
			end
			assign u_uop[SL_B +: SL_W] = u_uop_sl_r;
		end
	endgenerate

	wire stg_valid = (PIPE_TAB != 0) ? s0_valid : d_valid;
	wire [WARP_W-1:0] stg_warp = (PIPE_TAB != 0) ? s0_warp : d_warp;
	wire [15:0] stg_pc = (PIPE_TAB != 0) ? s0_pc : d_pc;
	(* keep = "true" *) wire u_ce_hdr = u_adv && stg_valid;

	always @(posedge clk) begin
		if (rst_u_hdr) begin
			u_valid <= 1'b0;
			u_warp <= {WARP_W{1'b0}};
			u_pc <= 16'd0;
		end else begin
			if (u_adv)
				u_valid <= stg_valid;
			if (u_ce_hdr) begin
				u_warp <= stg_warp;
				u_pc <= stg_pc;
			end
		end
	end

	wire unused_ok = &{1'b0, r2_co_unused, im_co_unused, f7[6], f7[4:0]};
endmodule

`default_nettype wire
