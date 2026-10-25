/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_seq_dec: atg_cp_seq's decoders, combinational
 * (spec/gpu/cp/atg_cp_seq_dec.md).
 *
 * Header (hdr): h_known (class 0 or 1 and a known op), h_absent (the op's
 * unit is absent: fault 2; also DISP_SET and FLIP without HAS_DISP or from
 * the firmware's micro-op FIFO, hdr_fw), h_need (payload dwords the op
 * needs; SET_REG and DISP_SET: n rounded up to even, so that an odd n is
 * short).
 *
 * Payload (the dword in hand, in_data, at p of the current op): pay_bad is
 * an index of SET_REG (even p) outside 0x000-0x2FF, or an offset of
 * DISP_SET (even p) that is not one of its registers (docs/ghci.md section
 * 7.3: CTRL 0x10, FB_STRIDE 0x28, FB_SIZE 0x2C, the timing and SYNC_POL
 * 0x30-0x50, PCLK_SEL 0x58, CURSOR_POS 0xA4, CURSOR_CTRL 0xA8; FB_NEXT is
 * FLIP's): fault 3 with fault_addr = the dword.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_seq_dec #(
	parameter [7:0] UNITS = 8'h03,	/* Present blocks, STATUS busy-bit order */
	parameter HAS_VSYNC = 0,	/* WAIT_VSYNC is present */
	parameter HAS_DISP = 0	/* a DISP2 controller: DISP_SET and FLIP are present */
) (
	input wire [31:0] hdr,
	input wire hdr_fw,
	output reg h_known,
	output reg h_absent,
	output reg [7:0] h_need,
	input wire vendor,
	input wire [5:0] op,
	input wire [7:0] p,
	input wire [31:0] in_data,
	output wire pay_bad
);
	localparam [5:0] OP_NOP = 6'd0;
	localparam [5:0] OP_SET_REG = 6'd1;
	localparam [5:0] OP_BLIT = 6'd2;
	localparam [5:0] OP_DRAW = 6'd3;
	localparam [5:0] OP_DISPATCH = 6'd4;
	localparam [5:0] OP_FENCE = 6'd5;
	localparam [5:0] OP_WAIT_IDLE = 6'd6;
	localparam [5:0] OP_LOAD_CONST = 6'd7;
	localparam [5:0] OP_LOAD_PROGRAM = 6'd8;
	localparam [5:0] OP_WAIT_FENCE = 6'd9;
	localparam [5:0] OP_PERF_RESET = 6'd10;
	localparam [5:0] OP_WAIT_VSYNC = 6'd11;
	localparam [5:0] OP_INVALIDATE = 6'd12;
	localparam [5:0] OP_RESULT = 6'd13;
	localparam [5:0] OP_QUERY = 6'd14;
	localparam [5:0] OP_DISP_SET = 6'd15;
	localparam [5:0] OP_FLIP = 6'd16;
	localparam [5:0] VOP_DRAW_RAW = 6'd0;
	localparam [5:0] VOP_DBG_MARK = 6'd1;

	wire h_vendor = hdr[30];
	wire [5:0] h_op = hdr[29:24];
	wire [7:0] h_n = hdr[7:0];

	/* n rounded up to even (the pairs of SET_REG and DISP_SET). */
	wire [7:0] h_n_even;
	wire h_n_co_unused;

	am_add #(.W(8)) a_even (
		.a(h_n), .b(8'd0), .ci(h_n[0]), .s(h_n_even), .co(h_n_co_unused)
	);

	always @(*) begin
		h_known = 1'b1;
		h_absent = 1'b0;
		h_need = 8'd0;
		if (hdr[31]) begin
			h_known = 1'b0;
		end else if (h_vendor) begin
			case (h_op)
			VOP_DRAW_RAW: begin
				h_need = 8'd9;
				h_absent = !UNITS[3];
			end
			VOP_DBG_MARK: h_need = 8'd1;
			default: h_known = 1'b0;
			endcase
		end else begin
			case (h_op)
			OP_NOP, OP_WAIT_IDLE, OP_PERF_RESET, OP_INVALIDATE: ;
			OP_BLIT: h_absent = !UNITS[1];
			OP_SET_REG: h_need = h_n_even;	/* pairs: odd n is short */
			OP_DRAW: h_absent = !UNITS[2];
			OP_DISPATCH: begin
				h_need = 8'd3;
				h_absent = !UNITS[6];
			end
			OP_FENCE, OP_WAIT_FENCE: h_need = 8'd2;
			OP_LOAD_CONST: begin
				h_need = 8'd3;
				h_absent = !UNITS[6];
			end
			OP_LOAD_PROGRAM: h_need = 8'd1;
			OP_WAIT_VSYNC: h_absent = HAS_VSYNC == 0;
			OP_RESULT: h_need = 8'd3;
			OP_QUERY: begin
				h_need = 8'd1;
				h_absent = !UNITS[4];
			end
			OP_DISP_SET: begin
				h_need = h_n_even;
				h_absent = HAS_DISP == 0 || hdr_fw;
			end
			OP_FLIP: begin
				h_need = 8'd4;
				h_absent = HAS_DISP == 0 || hdr_fw;
			end
			default: h_known = 1'b0;
			endcase
		end
	end

	/* The payload's index or offset dwords. */
	wire is_set = !vendor && op == OP_SET_REG;
	wire is_dset = !vendor && op == OP_DISP_SET;
	wire [7:0] off = in_data[7:0];
	wire off_ok = in_data[31:8] == 24'd0 && off[1:0] == 2'd0 &&
		(off == 8'h10 || off == 8'h28 || off == 8'h2C || (off >= 8'h30 && off <= 8'h50) ||
		off == 8'h58 || off == 8'hA4 || off == 8'hA8);

	assign pay_bad = !p[0] && (is_set && (in_data[31:10] != 22'd0 || in_data[9:8] == 2'b11) ||
		is_dset && !off_ok);

	wire unused_ok = &{1'b0, h_n_co_unused, hdr[23:8], p[7:1]};
endmodule

`default_nettype wire
