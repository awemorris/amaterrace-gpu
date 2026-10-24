/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dec_tab: the RISC-V-opcode half of atg_su_dec's opcode table
 * (design §3.4.1; atg_su_dec_tabc has custom-0..3).  From
 * the major opcode, funct3, funct7, the rs2 field, the sub field and the
 * R4 fmt bits it gives whether the encoding is defined, its immediate
 * format, unit, operation (include/atg_su_uop.vh), latency class, the
 * operands it uses, and the optional sets it needs.  Combinational; the
 * operand-range checks and the uop are atg_su_dec's.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dec_tab (
	input wire [6:0] opc,
	input wire [2:0] f3,
	input wire [6:0] f7,
	input wire [4:0] rs2f,
	input wire [4:0] sub,
	input wire [1:0] fmt2,	/* word0[26:25]: the R4 fmt/funct2 */
	output reg def,	/* the opcode/funct/sub combination is defined */
	output reg [2:0] fmt,	/* 0 none, 1 I, 2 S, 3 B, 4 U */
	output reg [3:0] unit,
	output reg [7:0] op,
	output reg [2:0] cls,
	output reg use1,
	output reg use2,
	output reg use3,
	output reg wrd,
	output reg pair,
	output reg side,
	output reg need_pk,
	output reg need_sg,
	output reg need_sa,
	output reg tex	/* texl/texb/texf: four destinations */
);
`include "atg_su_uop.vh"

	localparam [2:0] FM_N = 3'd0, FM_I = 3'd1, FM_S = 3'd2, FM_B = 3'd3, FM_U = 3'd4;
	/* rm: 0-4 and 7 (no CSR: dynamic is RNE); fround: 0-3. */
	wire rm_ok = f3 != 3'd5 && f3 != 3'd6;

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
			/* sub 0 sw, 1 sw.x (the EXEC lanes: scratch memory); others undefined */
			def = f3 == 3'd2 && sub <= 5'd1;
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
			def = rm_ok && fmt2 == 2'd0;
			op = ATG_FPU_FMADD + {6'd0, opc[3:2]};
		end
		default: ;
		endcase
	end

	wire unused_ok = &{1'b0, sub};
endmodule

`default_nettype wire
