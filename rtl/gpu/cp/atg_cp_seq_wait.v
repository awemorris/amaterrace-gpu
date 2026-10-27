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
 * pre_f for the fence unit) and after its kick (post).  Bit 0 of the busy
 * bits is the units' memory: requests of the units (and the CPU's DMA)
 * that the MC has not answered (atg_mc's unit_idle).  FENCE, WAIT_IDLE
 * (whatever its flags), RESULT and QUERY wait for it too: a unit's busy
 * may fall before its last response (the TU's) and the CPU's DMA writes
 * are not in a busy bit at all.
 *
 * A block's STATE does not change under its work, nor while work that
 * will read it is still upstream:
 *   BLT range                 the BLT
 *   VF (0x020-0x04F, 0x1C0-0x1DF: ATTR_DST and ATTR_LIMIT)  the VF
 *   RX and ROP ranges         the VF, the SUs, the RX and the ROP: the
 *                             ROP's busy covers only the sequence numbers
 *                             the RX has issued, so a draw still in the VF,
 *                             in a vertex warp or in the RX's setup would
 *                             otherwise see the next draw's state
 *   TU range                  the VF, the SUs, the RX and the TU (texels
 *                             are read by warps a draw upstream starts later)
 *   program range (0x190-0x1AF)  the VF, the SUs and the RX (the SU takes
 *                             VS_BASE, FS_BASE and the rest at a warp's start)
 * LOAD_CONST waits for the VF, the SUs and the RX before its kick (the
 * constants of a draw upstream are read by its warps), and for the SUs
 * after it; DISPATCH and LOAD_CONST payloads wait for the SUs, DRAW_RAW's
 * for the RX.
 *
 * Bit 8 (B_DISP, outside B_ALL and the 8-bit WAIT_IDLE mask) is
 * atg_cp_disp's wait (design §18.4): DISP_SET's register writes wait for
 * its host buffer, FLIP waits for its plane (and with flags[0] COMPLETE
 * for B_ALL first, as FENCE), DISP_SET with flags[0] waits for the
 * controller's idle after its kick.  DISP_SET's pairs go to 0x3C0 +
 * offset / 4 (sidx, set by atg_cp_seq), FLIP's four dwords to 0x3B8-0x3BB.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_seq_wait (
	input wire vendor,
	input wire [7:0] op,
	input wire [7:0] flags,
	input wire [7:0] p,
	input wire set_val,
	input wire [9:0] sidx,
	output reg pay_we,
	output reg [9:0] pay_idx,
	output reg [8:0] pay_wait,
	output reg [8:0] pre,
	output reg pre_f,
	output reg [8:0] post
);
	`include "ghci_regs.vh"

	/*
	 * DISPATCH's grid words (0x1E9 is not aligned for an OR of p); RAW
	 * (0x1E0, p < 9) and LC_REGION (0x1EC, p < 3) take p by an OR, their
	 * low bits being 0.
	 */
	localparam [8:0] S_GRID_Y = GHCI_S_GRID_X + 9'd1;
	localparam [8:0] S_GRID_Z = GHCI_S_GRID_X + 9'd2;
	localparam [7:0] OP_BLIT = 8'd2;
	localparam [7:0] OP_DRAW = 8'd3;
	localparam [7:0] OP_DISPATCH = 8'd4;
	localparam [7:0] OP_FENCE = 8'd5;
	localparam [7:0] OP_WAIT_IDLE = 8'd6;
	localparam [7:0] OP_LOAD_CONST = 8'd7;
	localparam [7:0] OP_RESULT = 8'd13;
	localparam [7:0] OP_QUERY = 8'd14;
	localparam [7:0] OP_DISP_SET = 8'd15;
	localparam [7:0] OP_FLIP = 8'd16;
	localparam [7:0] OP_BARRIER = 8'd20;
	localparam [7:0] OP_SEMAPHORE_SIGNAL = 8'd21;
	localparam [7:0] OP_SEMAPHORE_WAIT = 8'd22;

	/* GHCI 1.0 Structured Command Opcodes */
	localparam [7:0] CMD_BIND_PIPELINE         = 8'h20;
	localparam [7:0] CMD_BIND_VERTEX_BUFFERS   = 8'h21;
	localparam [7:0] CMD_BIND_INDEX_BUFFER     = 8'h22;
	localparam [7:0] CMD_BIND_DESCRIPTOR_TABLE = 8'h23;
	localparam [7:0] CMD_SET_VIEWPORT          = 8'h24;
	localparam [7:0] CMD_SET_SCISSOR           = 8'h25;
	localparam [7:0] CMD_SET_DYNAMIC_STATE     = 8'h26;
	localparam [7:0] CMD_DRAW                  = 8'h27;
	localparam [7:0] CMD_DRAW_INDEXED          = 8'h28;
	localparam [7:0] CMD_DRAW_INDIRECT         = 8'h29;
	localparam [7:0] CMD_DRAW_MESH_TASKS       = 8'h2a;
	localparam [7:0] CMD_DISPATCH              = 8'h30;
	localparam [7:0] CMD_BARRIER               = 8'h31;
	localparam [7:0] CMD_EXECUTE_COMMANDS      = 8'h32;
	localparam [7:0] CMD_FENCE                 = 8'h33;

	localparam [7:0] VOP_DRAW_RAW = 8'd0;
	localparam [7:0] VOP_DBG_MARK = 8'd1;

	localparam [7:0] B_BLT = 8'h02;
	localparam [7:0] B_VF = 8'h04;
	localparam [7:0] B_RX = 8'h08;
	localparam [7:0] B_ROP = 8'h10;
	localparam [7:0] B_TU = 8'h20;
	localparam [7:0] B_SU = 8'h40;
`ifdef MUT_SEQ_NOMEM
	localparam [7:0] B_MEM = 8'h00;	/* the earlier rule, for the TB's mutation check */
`else
	localparam [7:0] B_MEM = 8'h01;
`endif
	localparam [7:0] B_ALL = 8'hFE | B_MEM;
	localparam [8:0] B_DISP = 9'h100;
`ifdef MUT_SEQ_DRAWSTATE
	/* the earlier rules, for the TB's mutation check */
	localparam [7:0] B_RXROP = B_RX | B_ROP;
	localparam [7:0] B_ROPW = B_ROP;
	localparam [7:0] B_TUW = B_TU | B_SU | B_RX;
	localparam [7:0] B_PROGW = 8'd0;
	localparam [7:0] B_LCPRE = B_SU;
	localparam VF_1D = 0;	/* 0x1C0-0x1CF only */
`else
	localparam [7:0] B_RXROP = B_VF | B_SU | B_RX | B_ROP;
	localparam [7:0] B_ROPW = B_RXROP;
	localparam [7:0] B_TUW = B_VF | B_SU | B_RX | B_TU;
	localparam [7:0] B_PROGW = B_VF | B_SU | B_RX;
	localparam [7:0] B_LCPRE = B_VF | B_SU | B_RX;
	localparam VF_1D = 1;	/* also ATTR_LIMIT, 0x1D0-0x1DF */
`endif

	wire [8:0] s9 = sidx[8:0];

	always @(*) begin
		pay_we = 1'b0;
		pay_idx = 10'd0;
		pay_wait = 9'd0;
		if (set_val && sidx[9:8] == 2'b11) begin
			/* DISP_SET's register write (SET_REG's index is below 0x300). */
			pay_we = 1'b1;
			pay_idx = sidx;
			pay_wait = B_DISP;
		end else if (set_val) begin
			pay_we = 1'b1;
			pay_idx = sidx;
			/* 0x200-0x2FF: the vertex stage's texture slots, as the TU range. */
			pay_wait = {1'b0, sidx[9] ? B_TUW : s9 < GHCI_S_VF ? B_BLT : s9 < GHCI_S_RX ? B_VF :
				s9 < GHCI_S_ROP ? B_RXROP : s9 < GHCI_S_TU ? B_ROPW :
				s9 < GHCI_S_PROG ? B_TUW : s9 < GHCI_S_SA ? B_PROGW :
				(s9[8:5] == GHCI_S_ATTR_DST[8:5] && (VF_1D != 0 || !s9[4])) ? B_VF : 8'd0};
		end else if (vendor && op == VOP_DRAW_RAW && p < 8'd9) begin
			pay_we = 1'b1;
			pay_idx = {1'b0, GHCI_S_RAW | {5'd0, p[3:0]}};	/* 0x1E0 + p, p < 9 */
			pay_wait = {1'b0, B_RX};
		end else if (vendor && op == VOP_DBG_MARK && p == 8'd0) begin
			pay_we = 1'b1;
			pay_idx = {1'b0, GHCI_S_DBG_MARK};
		end else if (!vendor && (op == OP_DISPATCH || op == CMD_DISPATCH || op == CMD_DRAW_MESH_TASKS) && p < 8'd3) begin
			pay_we = 1'b1;
			pay_idx = {1'b0, p[1:0] == 2'd0 ? GHCI_S_GRID_X : p[1:0] == 2'd1 ? S_GRID_Y : S_GRID_Z};
			pay_wait = {1'b0, B_SU};
		end else if (!vendor && op == OP_LOAD_CONST && p < 8'd3) begin
			pay_we = 1'b1;
			pay_idx = {1'b0, GHCI_S_LC_REGION | {7'd0, p[1:0]}};	/* 0x1EC + p, p < 3 */
			pay_wait = {1'b0, B_SU};
		end else if (!vendor && op == OP_FLIP && p < 8'd4) begin
			/* FLIP's staging: plane, base, record, value (0x3B8-0x3BB). */
			pay_we = 1'b1;
			pay_idx = {8'b11101110, p[1:0]};
		end
	end

	always @(*) begin
		pre = 9'd0;
		pre_f = 1'b0;
		post = 9'd0;
		if (vendor) begin
			pre = {1'b0, op == VOP_DRAW_RAW ? B_RX : 8'd0};
		end else begin
			case (op)
			OP_BLIT: begin
				pre = {1'b0, B_BLT};
				post = {1'b0, flags[0] ? B_BLT : 8'd0};
			end
			OP_DRAW: pre = {1'b0, B_VF};
			OP_FENCE: pre = {1'b0, B_ALL};
			OP_WAIT_IDLE: pre = {1'b0, flags == 8'd0 ? B_ALL : flags | B_MEM};
			OP_BARRIER: pre = {1'b0, flags == 8'd0 ? B_ALL : flags | B_MEM};
			OP_SEMAPHORE_SIGNAL: begin
				pre = {1'b0, flags == 8'd0 ? B_ALL : flags | B_MEM};
				pre_f = 1'b1;
			end
			OP_SEMAPHORE_WAIT: begin
				pre_f = 1'b1;
			end
			OP_LOAD_CONST: begin
				pre = {1'b0, B_LCPRE};
				post = {1'b0, B_SU};
			end
			OP_RESULT: begin
				pre = {1'b0, B_ALL};
				pre_f = 1'b1;
			end
			/* QUERY: as RESULT; flags[0] (clear only) does not wait */
			OP_QUERY: begin
				pre = {1'b0, flags[0] ? 8'd0 : B_ALL};
				pre_f = !flags[0];
			end
			/* DISP_SET flags[0]: the controller's idle after the kick. */
			OP_DISP_SET: post = flags[0] ? B_DISP : 9'd0;
			/* FLIP: the plane free; flags[0] COMPLETE: every unit first. */
			`ifdef MUT_DISP_NOWAIT
			OP_FLIP: pre = B_DISP;
			`else
			OP_FLIP: pre = {1'b0, flags[0] ? B_ALL : 8'd0} | B_DISP;
			`endif
			/* GHCI 1.0 Structured Commands */
			CMD_BIND_PIPELINE: pre = {1'b0, B_PROGW};
			CMD_BIND_VERTEX_BUFFERS, CMD_BIND_INDEX_BUFFER: pre = {1'b0, B_VF};
			CMD_BIND_DESCRIPTOR_TABLE: pre = {1'b0, B_TUW};
			CMD_SET_VIEWPORT, CMD_SET_SCISSOR, CMD_SET_DYNAMIC_STATE: pre = {1'b0, B_RXROP};
			CMD_DRAW, CMD_DRAW_INDEXED, CMD_DRAW_INDIRECT: pre = {1'b0, B_VF};
			CMD_DISPATCH, CMD_DRAW_MESH_TASKS: pre = {1'b0, B_SU};
			CMD_BARRIER: pre = {1'b0, flags == 8'd0 ? B_ALL : flags | B_MEM};
			CMD_EXECUTE_COMMANDS: pre = 9'd0;
			CMD_FENCE: begin
				pre = {1'b0, B_ALL};
				pre_f = 1'b1;
			end
			default: ;
			endcase
		end
	end
endmodule

`default_nettype wire
