/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dec_tabc: the custom-0..3 half of atg_su_dec's opcode table
 * (design §3.4.1; atg_su_dec_tab has the RISC-V opcodes).  From
 * the major opcode, funct3, funct7, the rs2 field, the sub field and the
 * R4 fmt bits it gives whether the encoding is defined, its immediate
 * format, unit, operation (include/atg_su_uop.vh), latency class, the
 * operands it uses, and the optional sets it needs.  Combinational; the
 * operand-range checks and the uop are atg_su_dec's.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dec_tabc (
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

	localparam [2:0] FM_N = 3'd0, FM_I = 3'd1, FM_S = 3'd2;

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
				def = fmt2 == 2'd0;
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
				def = fmt2 == 2'd0;
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

	wire unused_ok = &{1'b0, rs2f};
endmodule

`default_nettype wire
