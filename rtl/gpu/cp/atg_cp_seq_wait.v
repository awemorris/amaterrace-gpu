/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_seq_wait: atg_cp_seq's waits, combinational: for the payload
 * dword in hand, whether and where it writes STATE and which busy bits
 * (STATUS order: [1] BLT, [2] VF, [3] RX, [4] ROP, [5] TU, [6] SU) hold
 * it; for the µop, which busy bits it waits for before its act (pre, and
 * pre_f for the fence unit) and after its kick (post).
 *
 * A block's STATE does not change under its work, nor while work that
 * will read it is still upstream:
 *   BLT range                 the BLT
 *   VF (0x020-0x04F, ATTR_DST 0x1C0-0x1CF)  the VF
 *   RX and ROP ranges         the VF, the SUs, the RX and the ROP: the
 *                             ROP's busy covers only the sequence numbers
 *                             the RX has issued, so a draw still in the VF,
 *                             in a vertex warp or in the RX's setup would
 *                             otherwise see the next draw's state
 *   TU range                  the TU, the SUs and the RX
 * DISPATCH and LOAD_CONST payloads wait for the SUs, DRAW_RAW's for the RX.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_seq_wait (
	input wire vendor,
	input wire [5:0] op,
	input wire [7:0] flags,
	input wire [7:0] p,
	input wire set_val,
	input wire [8:0] sidx,
	output reg pay_we,
	output reg [8:0] pay_idx,
	output reg [7:0] pay_wait,
	output reg [7:0] pre,
	output reg pre_f,
	output reg [7:0] post
);
	`include "ghci_regs.vh"

	localparam [5:0] OP_BLIT = 6'd2;
	localparam [5:0] OP_DRAW = 6'd3;
	localparam [5:0] OP_DISPATCH = 6'd4;
	localparam [5:0] OP_FENCE = 6'd5;
	localparam [5:0] OP_WAIT_IDLE = 6'd6;
	localparam [5:0] OP_LOAD_CONST = 6'd7;
	localparam [5:0] OP_RESULT = 6'd13;
	localparam [5:0] VOP_DRAW_RAW = 6'd0;
	localparam [5:0] VOP_DBG_MARK = 6'd1;

	localparam [7:0] B_BLT = 8'h02;
	localparam [7:0] B_VF = 8'h04;
	localparam [7:0] B_RX = 8'h08;
	localparam [7:0] B_ROP = 8'h10;
	localparam [7:0] B_TU = 8'h20;
	localparam [7:0] B_SU = 8'h40;
	localparam [7:0] B_ALL = 8'hFE;
`ifdef MUT_SEQ_DRAWSTATE
	localparam [7:0] B_RXROP = B_RX | B_ROP;
	localparam [7:0] B_ROPW = B_ROP;
`else
	localparam [7:0] B_RXROP = B_VF | B_SU | B_RX | B_ROP;
	localparam [7:0] B_ROPW = B_RXROP;
`endif

	always @(*) begin
		pay_we = 1'b0;
		pay_idx = 9'd0;
		pay_wait = 8'd0;
		if (set_val) begin
			pay_we = 1'b1;
			pay_idx = sidx;
			pay_wait = sidx < GHCI_S_VF ? B_BLT : sidx < GHCI_S_RX ? B_VF :
				sidx < GHCI_S_ROP ? B_RXROP : sidx < GHCI_S_TU ? B_ROPW :
				sidx < GHCI_S_PROG ? B_TU | B_SU | B_RX :
				sidx[8:4] == GHCI_S_ATTR_DST[8:4] ? B_VF : 8'd0;
		end else if (vendor && op == VOP_DRAW_RAW && p < 8'd9) begin
			pay_we = 1'b1;
			pay_idx = GHCI_S_RAW + {1'b0, p};
			pay_wait = B_RX;
		end else if (vendor && op == VOP_DBG_MARK && p == 8'd0) begin
			pay_we = 1'b1;
			pay_idx = GHCI_S_DBG_MARK;
		end else if (!vendor && op == OP_DISPATCH && p < 8'd3) begin
			pay_we = 1'b1;
			pay_idx = GHCI_S_GRID_X + {1'b0, p};
			pay_wait = B_SU;
		end else if (!vendor && op == OP_LOAD_CONST && p < 8'd3) begin
			pay_we = 1'b1;
			pay_idx = GHCI_S_LC_REGION + {1'b0, p};
			pay_wait = B_SU;
		end
	end

	always @(*) begin
		pre = 8'd0;
		pre_f = 1'b0;
		post = 8'd0;
		if (vendor) begin
			pre = op == VOP_DRAW_RAW ? B_RX : 8'd0;
		end else begin
			case (op)
			OP_BLIT: begin
				pre = B_BLT;
				post = flags[0] ? B_BLT : 8'd0;
			end
			OP_DRAW: pre = B_VF;
			OP_FENCE: pre = B_ALL;
			OP_WAIT_IDLE: pre = flags == 8'd0 ? B_ALL : flags & B_ALL;
			OP_LOAD_CONST: begin
				pre = B_SU;
				post = B_SU;
			end
			OP_RESULT: begin
				pre = B_ALL;
				pre_f = 1'b1;
			end
			default: ;
			endcase
		end
	end
endmodule

`default_nettype wire
