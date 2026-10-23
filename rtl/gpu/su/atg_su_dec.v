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
	localparam [2:0] FM_N = 3'd0, FM_I = 3'd1, FM_S = 3'd2, FM_B = 3'd3, FM_U = 3'd4;

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
	wire [31:0] imm_b = {{20{w0[31]}}, w0[7], w0[30:25], w0[11:8]} + hi;
	wire [31:0] imm_u = {w0[31:12], w1[13:2]};
	/* rm: 0-4 and 7 (no CSR: dynamic is RNE); fround: 0-3. */
	wire rm_ok = f3 != 3'd5 && f3 != 3'd6;

	/* The table lookup. */
	reg def;	/* the opcode/funct/sub combination is defined */
	reg [2:0] fmt;
	reg [3:0] unit;
	reg [7:0] op;
	reg [2:0] cls;
	reg use1, use2, use3, wrd, pair, side, need_pk, need_sg, need_sa, tex;

	always @(*) begin
		def = 1'b0;
		fmt = FM_N;
		unit = ATG_UNIT_NONE;
		op = 8'd0;
		cls = ATG_CLS_A;
		use1 = 1'b0;
		use2 = 1'b0;
		use3 = 1'b0;
		wrd = 1'b0;
		pair = 1'b0;
		side = 1'b0;
		need_pk = 1'b0;
		need_sg = 1'b0;
		need_sa = 1'b0;
		tex = 1'b0;
		case (opc)
		7'b0110011: begin	/* OP */
			use1 = 1'b1;
			use2 = 1'b1;
			wrd = 1'b1;
			unit = ATG_UNIT_ALU;
			case (f7)
			7'b0000000: begin
				def = 1'b1;
				case (f3)
				3'd0: op = {3'd0, ATG_ALU_ADD};
				3'd1: op = {3'd0, ATG_ALU_SLL};
				3'd2: op = {3'd0, ATG_ALU_SLT};
				3'd3: op = {3'd0, ATG_ALU_SLTU};
				3'd4: op = {3'd0, ATG_ALU_XOR};
				3'd5: op = {3'd0, ATG_ALU_SRL};
				3'd6: op = {3'd0, ATG_ALU_OR};
				default: op = {3'd0, ATG_ALU_AND};
				endcase
			end
			7'b0100000: begin
				def = f3 == 3'd0 || f3 == 3'd5 || f3 == 3'd7 || f3 == 3'd6 || f3 == 3'd4;
				case (f3)
				3'd0: op = {3'd0, ATG_ALU_SUB};
				3'd5: op = {3'd0, ATG_ALU_SRA};
				3'd7: op = {3'd0, ATG_ALU_ANDN};
				3'd6: op = {3'd0, ATG_ALU_ORN};
				default: op = {3'd0, ATG_ALU_XNOR};
				endcase
			end
			7'b0000001: begin
				def = 1'b1;
				if (f3[2]) begin
					unit = ATG_UNIT_DIV;
					cls = ATG_CLS_X;
					op = {6'd0, f3[1:0]};
				end else begin
					unit = ATG_UNIT_FPU;
					cls = ATG_CLS_F;
					op = ATG_FPU_MUL + {6'd0, f3[1:0]};
				end
			end
			7'b0000101: begin
				def = f3[2];
				case (f3[1:0])
				2'd0: op = {3'd0, ATG_ALU_MIN};
				2'd1: op = {3'd0, ATG_ALU_MINU};
				2'd2: op = {3'd0, ATG_ALU_MAX};
				default: op = {3'd0, ATG_ALU_MAXU};
				endcase
			end
			default: ;
			endcase
		end
		7'b0010011: begin	/* OP-IMM */
			fmt = FM_I;
			use1 = 1'b1;
			wrd = 1'b1;
			unit = ATG_UNIT_ALU;
			def = 1'b1;
			case (f3)
			3'd0: op = {3'b100, ATG_ALU_ADD};
			3'd2: op = {3'b100, ATG_ALU_SLT};
			3'd3: op = {3'b100, ATG_ALU_SLTU};
			3'd4: op = {3'b100, ATG_ALU_XOR};
			3'd6: op = {3'b100, ATG_ALU_OR};
			3'd7: op = {3'b100, ATG_ALU_AND};
			3'd1: begin
				op = {3'b100, ATG_ALU_SLL};
				def = f7 == 7'b0000000;
			end
			default: begin
				op = {3'b100, f7 == 7'b0100000 ? ATG_ALU_SRA : ATG_ALU_SRL};
				def = f7 == 7'b0000000 || f7 == 7'b0100000;
			end
			endcase
		end
		7'b0110111: begin	/* LUI / movi */
			fmt = FM_U;
			wrd = 1'b1;
			unit = ATG_UNIT_ALU;
			op = {3'd0, ATG_ALU_MOVI};
			def = 1'b1;
		end
		7'b0000011: begin	/* LOAD */
			fmt = FM_I;
			use1 = 1'b1;
			wrd = 1'b1;
			cls = ATG_CLS_M;
			def = f3 == 3'd2 || f3 == 3'd6;
			unit = f3 == 3'd6 ? ATG_UNIT_CBANK : ATG_UNIT_LSU;
			op = f3 == 3'd6 ? ATG_CBANK_LWC : ATG_LSU_LW;
		end
		7'b0100011: begin	/* STORE */
			fmt = FM_S;
			use1 = 1'b1;
			use2 = 1'b1;
			side = 1'b1;
			cls = ATG_CLS_M;
			unit = ATG_UNIT_LSU;
			op = ATG_LSU_SW;
			def = f3 == 3'd2;
		end
		7'b1100011: begin	/* BRANCH */
			fmt = FM_B;
			unit = ATG_UNIT_EXEC;
			op = {5'd0, f3};
			use1 = f3 <= 3'd2;
			def = f3 <= 3'd5;
		end
		7'b1010011: begin	/* OP-FP */
			unit = ATG_UNIT_FPU;
			cls = ATG_CLS_F;
			use1 = 1'b1;
			wrd = 1'b1;
			case (f7)
			7'b0000000, 7'b0000100, 7'b0001000: begin
				use2 = 1'b1;
				def = rm_ok;
				op = f7[3] ? ATG_FPU_FMUL : f7[2] ? ATG_FPU_FSUB : ATG_FPU_FADD;
			end
			7'b0010000: begin
				use2 = 1'b1;
				def = f3 == 3'd0;
				op = ATG_FPU_FSGNJ;
			end
			7'b0010100: begin
				use2 = 1'b1;
				def = f3 == 3'd0 || f3 == 3'd1;
				op = f3[0] ? ATG_FPU_FMAX : ATG_FPU_FMIN;
			end
			7'b0101100: begin
				unit = ATG_UNIT_XU;
				cls = ATG_CLS_X;
				def = rm_ok && rs2f == 5'd0;
				op = ATG_XU_FSQRT;
			end
			7'b1100000: begin
				def = rm_ok && rs2f[4:1] == 4'd0;
				op = rs2f[0] ? ATG_FPU_FCVTWUS : ATG_FPU_FCVTWS;
			end
			7'b1101000: begin
				def = rm_ok && rs2f[4:1] == 4'd0;
				op = rs2f[0] ? ATG_FPU_FCVTSWU : ATG_FPU_FCVTSW;
			end
			7'b1010000: begin
				use2 = 1'b1;
				def = f3[2] == 1'b0;
				case (f3[1:0])
				2'd2: op = ATG_FPU_FEQ;
				2'd1: op = ATG_FPU_FLT;
				2'd0: op = ATG_FPU_FLE;
				default: op = ATG_FPU_FNE;
				endcase
			end
			7'b0100000: begin
				def = f3[2] == 1'b0 && rs2f == 5'd4;
				op = ATG_FPU_FROUND;
			end
			default: ;
			endcase
		end
		7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin	/* MADD MSUB NMSUB NMADD */
			unit = ATG_UNIT_FPU;
			cls = ATG_CLS_F;
			use1 = 1'b1;
			use2 = 1'b1;
			use3 = 1'b1;
			wrd = 1'b1;
			def = rm_ok && w0[26:25] == 2'd0;
			op = ATG_FPU_FMADD + {6'd0, opc[3:2]};
		end
		7'b0001011: begin	/* custom-0: memory, synchronisation */
			def = f3 != 3'd3;
			case (f3)
			3'd0: begin
				fmt = FM_I;
				unit = ATG_UNIT_LDS;
				op = ATG_LDS_LDS;
				cls = ATG_CLS_M;
				use1 = 1'b1;
				wrd = 1'b1;
			end
			3'd1: begin
				fmt = FM_S;
				unit = ATG_UNIT_LDS;
				op = ATG_LDS_STS;
				cls = ATG_CLS_M;
				use1 = 1'b1;
				use2 = 1'b1;
				side = 1'b1;
			end
			3'd2: begin
				unit = ATG_UNIT_LSU;
				op = ATG_LSU_ATOM;
				cls = ATG_CLS_M;
				use1 = 1'b1;
				use2 = 1'b1;
				use3 = sub == 5'd10;
				wrd = 1'b1;
				side = 1'b1;
				def = sub <= 5'd10;
			end
			3'd4: begin
				fmt = FM_I;
				unit = ATG_UNIT_LSU;
				op = ATG_LSU_FENCE;
			end
			3'd5: begin
				unit = ATG_UNIT_EXEC;
				op = ATG_EXEC_BAR;
				def = f7 == 7'd0;
			end
			3'd6: begin
				fmt = FM_I;
				unit = ATG_UNIT_CTL;
				op = ATG_CTL_WAIT;
			end
			3'd7: begin
				unit = ATG_UNIT_EXEC;
				op = ATG_EXEC_END;
				def = f7 == 7'd0;
			end
			default: ;
			endcase
		end
		7'b0101011: begin	/* custom-1: texture, I/O, lanes */
			case (f3)
			3'd0, 3'd1, 3'd2: begin
				unit = ATG_UNIT_TEX;
				op = {6'd0, f3[1:0]};
				cls = ATG_CLS_T;
				use1 = 1'b1;
				use2 = 1'b1;
				wrd = 1'b1;
				pair = 1'b1;
				side = 1'b1;
				tex = 1'b1;
				def = f7 == 7'd0 && !sub[4];
			end
			3'd3: begin
				fmt = FM_I;
				unit = ATG_UNIT_TEX;
				op = ATG_TEX_TEXSZ;
				cls = ATG_CLS_T;
				use1 = 1'b1;
				wrd = 1'b1;
				side = 1'b1;
				def = !sub[4];
			end
			3'd4: begin
				fmt = FM_S;
				unit = ATG_UNIT_EXP;
				op = ATG_EXP_EXP;
				use2 = 1'b1;
				side = 1'b1;
				def = 1'b1;
			end
			3'd5: begin
				fmt = FM_I;
				unit = ATG_UNIT_LDA;
				op = ATG_LDA_LDA;
				wrd = 1'b1;
				def = 1'b1;
			end
			3'd6: begin
				unit = ATG_UNIT_LANE;
				op = ATG_LANE_QD;
				use1 = 1'b1;
				wrd = 1'b1;
				def = f7 == 7'd0 && sub <= 5'd5;
			end
			default: begin
				unit = ATG_UNIT_LANE;
				op = ATG_LANE_SHFL;
				use1 = 1'b1;
				use2 = 1'b1;
				wrd = 1'b1;
				need_sg = 1'b1;
				def = f7 == 7'd0 && sub <= 5'd4;
			end
			endcase
		end
		7'b1011011: begin	/* custom-2: 16-bit packed */
			unit = ATG_UNIT_PK;
			cls = ATG_CLS_F;
			use1 = 1'b1;
			use2 = 1'b1;
			wrd = 1'b1;
			need_pk = 1'b1;
			case (f3)
			3'd0, 3'd1, 3'd2: begin
				op = {6'd0, f3[1:0]};
				def = f7 == 7'd0;
			end
			3'd3: begin
				op = ATG_PK_FFMA2;
				use3 = 1'b1;
				def = w0[26:25] == 2'd0;
			end
			3'd4: begin
				op = f7[0] ? ATG_PK_FMAX2 : ATG_PK_FMIN2;
				def = f7[6:1] == 6'd0;
			end
			3'd5: begin
				op = ATG_PK_IADD2 + {6'd0, f7[1:0]};
				def = f7 <= 7'd2;
			end
			3'd6: begin
				op = ATG_PK_FCMPLT2 + {6'd0, f7[1:0]};
				def = f7 <= 7'd3;
			end
			default: begin
				case (f7)
				7'd0: begin
					op = ATG_PK_PACKH;
					need_pk = 1'b0;
					def = 1'b1;
				end
				7'd1: begin
					op = ATG_PK_UNPACKH;
					use2 = 1'b0;
					need_pk = 1'b0;
					def = sub <= 5'd1;
				end
				7'd2: begin
					op = ATG_PK_SWAPH;
					use2 = 1'b0;
					def = 1'b1;
				end
				default: ;
				endcase
			end
			endcase
		end
		7'b1111011: begin	/* custom-3: control, transcendentals, select, vote */
			case (f3)
			3'd0: begin
				unit = ATG_UNIT_ALU;
				op = {3'd0, ATG_ALU_SEL};
				use1 = 1'b1;
				use2 = 1'b1;
				use3 = 1'b1;
				wrd = 1'b1;
				def = w0[26:25] == 2'd0;
			end
			3'd1: begin
				unit = ATG_UNIT_EXEC;
				op = ATG_EXEC_SET + {6'd0, sub[1:0]};
				use1 = sub != 5'd3;
				wrd = sub == 5'd3;
				def = f7 == 7'd0 && sub <= 5'd3;
			end
			3'd2: begin
				unit = ATG_UNIT_EXEC;
				op = ATG_EXEC_KILL;
				use1 = 1'b1;
				def = f7 == 7'd0;
			end
			3'd3: begin
				use1 = 1'b1;
				wrd = 1'b1;
				def = f7 == 7'd0 && sub <= 5'd6;
				if (sub == 5'd6) begin
					unit = ATG_UNIT_FPU;
					op = ATG_FPU_FRACT;
					cls = ATG_CLS_F;
				end else begin
					unit = ATG_UNIT_XU;
					op = {5'd0, sub[2:0]};
					cls = ATG_CLS_X;
				end
			end
			3'd4: begin
				unit = ATG_UNIT_LANE;
				op = ATG_LANE_VOTE;
				use1 = 1'b1;
				wrd = 1'b1;
				need_sg = 1'b1;
				def = f7 == 7'd0 && sub <= 5'd1;
			end
			3'd5: begin
				unit = ATG_UNIT_LANE;
				op = ATG_LANE_BALLOT;
				use1 = 1'b1;
				wrd = 1'b1;
				need_sg = 1'b1;
				def = f7 == 7'd0;
			end
			3'd6: begin
				unit = ATG_UNIT_RQ;
				op = ATG_RQ_SACTL;
				use1 = 1'b1;
				need_sa = 1'b1;
				def = f7 == 7'd0;
			end
			default: def = f7 == 7'd0 && sub == 5'd0;	/* nop */
			endcase
		end
		default: ;
		endcase
	end

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
