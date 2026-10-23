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
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter NREGS = 32,	/* GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq) */
	parameter PACKED = 0,	/* 16-bit packed arithmetic present (else those opcodes are ISA faults; packh/unpackh always present) */
	parameter SUBGROUP = 0,	/* shfl/vote/ballot present (CAPS[24]) */
	parameter HAS_SA = 0	/* rq/sactl/qstat/sastat/qtag usable (always 0 in v1) */
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
	output reg [UOP_W-1:0] u_uop
);
`include "atg_su_uop.vh"

	/* Formats: which immediate the instruction has. */
	localparam [2:0] FM_I = 3'd1, FM_S = 3'd2, FM_B = 3'd3, FM_U = 3'd4;

	wire [31:0] w0 = d_instr[31:0];
	wire [31:0] w1 = d_instr[63:32];
	wire [6:0] opc = w0[6:0];
	wire [2:0] f3 = w0[14:12];
	wire [6:0] f7 = w0[31:25];
	wire [4:0] rs2f = w0[24:20];
	wire [4:0] sub = w1[21:17];
	wire [6:0] rd = {w1[1:0], w0[11:7]};
	wire [6:0] rs1 = {w1[3:2], w0[19:15]};
	wire [6:0] rs2 = {w1[5:4], w0[24:20]};
	wire [6:0] rs3 = {w1[7:6], w0[31:27]};
	wire [31:0] hi = {{12{w1[31]}}, w1[31:22], 10'd0} << 2;
	wire [31:0] imm_i = {{20{w0[31]}}, w0[31:20]} + hi;
	wire [31:0] imm_s = {{20{w0[31]}}, w0[31:25], w0[11:7]} + hi;
	wire [31:0] imm_b = {{21{w0[31]}}, w0[7], w0[30:25], w0[11:8]} + hi;
	wire [31:0] imm_u = {w0[31:12], w1[13:2]};

	/* The table lookup: the RISC-V opcodes and custom-0..3. */
	wire def, use1, use2, use3, wrd, pair, side, need_pk, need_sg, need_sa, tex;
	wire [2:0] fmt, cls;
	wire [3:0] unit;
	wire [7:0] op;
	wire [28:0] tr, tc;
	wire custom = opc == 7'b0001011 || opc == 7'b0101011 || opc == 7'b1011011 ||
		opc == 7'b1111011;
	atg_su_dec_tab tab (
		.opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .sub(sub), .fmt2(w0[26:25]),
		.def(tr[0]), .fmt(tr[3:1]), .unit(tr[7:4]), .op(tr[15:8]), .cls(tr[18:16]),
		.use1(tr[19]), .use2(tr[20]), .use3(tr[21]), .wrd(tr[22]), .pair(tr[23]),
		.side(tr[24]), .need_pk(tr[25]), .need_sg(tr[26]), .need_sa(tr[27]), .tex(tr[28])
	);
	atg_su_dec_tabc tabc (
		.opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .sub(sub), .fmt2(w0[26:25]),
		.def(tc[0]), .fmt(tc[3:1]), .unit(tc[7:4]), .op(tc[15:8]), .cls(tc[18:16]),
		.use1(tc[19]), .use2(tc[20]), .use3(tc[21]), .wrd(tc[22]), .pair(tc[23]),
		.side(tc[24]), .need_pk(tc[25]), .need_sg(tc[26]), .need_sa(tc[27]), .tex(tc[28])
	);
	assign {tex, need_sa, need_sg, need_pk, side, pair, wrd, use3, use2, use1, cls, op, unit,
		fmt, def} = custom ? tc : tr;

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

	wire [2:0] ndst = !wrd ? 3'd0 : tex ? 3'd4 : 3'd1;
	wire [7:0] rd_end = {1'b0, rd} + {5'd0, ndst};
	wire pair_bad = pair && (rs1 < 7'd64 ? ({25'd0, rs1} + 32'd1 >= NREGS || rs1 >= 7'd62)
		: (rs1 == 7'd95 || rs1 == 7'd127));
	wire dst_bad = wrd && (rd >= 7'd64 ||
		(rd == 7'd63 ? (HAS_SA == 0 || cls != ATG_CLS_A || tex) :
		({24'd0, rd_end} > NREGS || rd_end > 8'd63)));
	wire ill = w0[1:0] != 2'b11 || !def || (need_pk && PACKED == 0) ||
		(need_sg && SUBGROUP == 0) || (need_sa && HAS_SA == 0) ||
		(use1 && src_bad(rs1)) || (use2 && src_bad(rs2)) || (use3 && src_bad(rs3)) ||
		pair_bad || dst_bad;
	wire rqs = (use1 && rs1 == 7'd63) || (use2 && rs2 == 7'd63) || (use3 && rs3 == 7'd63);

	reg [31:0] imm;
	always @(*) begin
		case (fmt)
		FM_I: imm = imm_i;
		FM_S: imm = imm_s;
		FM_B: imm = imm_b;
		FM_U: imm = imm_u;
		default: imm = 32'd0;
		endcase
	end

	reg [UOP_W-1:0] uop;
	always @(*) begin
		uop = {UOP_W{1'b0}};
		if (ill) begin
			uop[ATG_UOP_ILL] = 1'b1;
		end else begin
			uop[ATG_UOP_UNIT +: 4] = unit;
			uop[ATG_UOP_OP +: 8] = op;
			uop[ATG_UOP_RD +: 7] = rd;
			uop[ATG_UOP_IMM +: 32] = imm;
			uop[ATG_UOP_CLS +: 3] = cls;
			uop[ATG_UOP_NDST +: 3] = ndst;
			uop[ATG_UOP_USE1] = use1;
			uop[ATG_UOP_USE2] = use2;
			uop[ATG_UOP_USE3] = use3;
			uop[ATG_UOP_WRD] = wrd;
			uop[ATG_UOP_PAIR] = pair;
			uop[ATG_UOP_RQS] = rqs;
			uop[ATG_UOP_RQD] = wrd && rd == 7'd63;
			uop[ATG_UOP_SIDE] = side;
			if (fmt != FM_U) begin
				uop[ATG_UOP_RS1 +: 7] = rs1;
				uop[ATG_UOP_RS2 +: 7] = rs2;
				uop[ATG_UOP_RS3 +: 7] = rs3;
				uop[ATG_UOP_MOD +: 7] = w1[14:8];
				uop[ATG_UOP_HSEL +: 2] = w1[16:15];
				uop[ATG_UOP_SUB +: 5] = sub;
				uop[ATG_UOP_RM +: 3] = f3;
			end
		end
	end

	assign d_ready = !u_valid || u_ready;

	always @(posedge clk) begin
		if (!rst_n) begin
			u_valid <= 1'b0;
			u_warp <= {WARP_W{1'b0}};
			u_pc <= 16'd0;
			u_uop <= {UOP_W{1'b0}};
		end else if (d_ready) begin
			u_valid <= d_valid;
			if (d_valid) begin
				u_warp <= d_warp;
				u_pc <= d_pc;
				u_uop <= uop;
			end
		end
	end
endmodule

`default_nettype wire
