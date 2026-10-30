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
	input wire is_ghci_in,
	output reg h_known,
	output reg h_absent,
	output reg [7:0] h_need,
	output reg h_short,
	output wire h_zero,
	output wire hdr_fault,
	output wire hdr_short,
	input wire vendor,
	input wire [7:0] op,
	input wire [7:0] p,
	input wire [31:0] in_data,
	output wire pay_bad
);
	localparam [7:0] OP_NOP = 8'd0;
	localparam [7:0] OP_SET_REG = 8'd1;
	localparam [7:0] OP_BLIT = 8'd2;
	localparam [7:0] OP_DRAW = 8'd3;
	localparam [7:0] OP_DISPATCH = 8'd4;
	localparam [7:0] OP_FENCE = 8'd5;
	localparam [7:0] OP_WAIT_IDLE = 8'd6;
	localparam [7:0] OP_LOAD_CONST = 8'd7;
	localparam [7:0] OP_LOAD_PROGRAM = 8'd8;
	localparam [7:0] OP_WAIT_FENCE = 8'd9;
	localparam [7:0] OP_PERF_RESET = 8'd10;
	localparam [7:0] OP_WAIT_VSYNC = 8'd11;
	localparam [7:0] OP_INVALIDATE = 8'd12;
	localparam [7:0] OP_RESULT = 8'd13;
	localparam [7:0] OP_QUERY = 8'd14;
	localparam [7:0] OP_DISP_SET = 8'd15;
	localparam [7:0] OP_FLIP = 8'd16;
	localparam [7:0] OP_BARRIER = 8'd20;
	localparam [7:0] OP_SEMAPHORE_SIGNAL = 8'd21;
	localparam [7:0] OP_SEMAPHORE_WAIT = 8'd22;

	/* GHCI 1.0 Structured Command Opcodes */
	localparam [7:0] CMD_VM_MAP                = 8'h10;
	localparam [7:0] CMD_VM_UNMAP              = 8'h11;
	localparam [7:0] CMD_SESSION_OPEN          = 8'h12;
	localparam [7:0] CMD_SESSION_CLOSE         = 8'h13;
	localparam [7:0] CMD_BIND_SESSION          = 8'h14;

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
	localparam [7:0] CMD_BEGIN_RENDER_PASS     = 8'h2b;
	localparam [7:0] CMD_END_RENDER_PASS       = 8'h2c;
	localparam [7:0] CMD_LOAD_CONST            = 8'h2d;
	localparam [7:0] CMD_DISPATCH_INDIRECT     = 8'h2e;

	localparam [7:0] CMD_DISPATCH              = 8'h30;
	localparam [7:0] CMD_BARRIER               = 8'h31;
	localparam [7:0] CMD_EXECUTE_COMMANDS      = 8'h32;
	localparam [7:0] CMD_FENCE                 = 8'h33;
	localparam [7:0] CMD_WAIT_FENCE            = 8'h34;
	localparam [7:0] CMD_WRITE_TIMESTAMP       = 8'h35;
	localparam [7:0] CMD_BEGIN_QUERY           = 8'h36;
	localparam [7:0] CMD_END_QUERY             = 8'h37;

	localparam [7:0] CMD_COPY_BUFFER           = 8'h40;
	localparam [7:0] CMD_COPY_IMAGE            = 8'h41;
	localparam [7:0] CMD_BLIT                  = 8'h42;
	localparam [7:0] CMD_FILL_BUFFER           = 8'h43;
	localparam [7:0] CMD_RESOLVE_IMAGE         = 8'h44;
	localparam [7:0] CMD_COPY_BUFFER_TO_IMAGE  = 8'h45;
	localparam [7:0] CMD_COPY_IMAGE_TO_BUFFER  = 8'h46;

	localparam [7:0] CMD_DISP_SET              = 8'h50;
	localparam [7:0] CMD_FLIP                  = 8'h51;

	localparam [7:0] VOP_DRAW_RAW = 8'd0;
	localparam [7:0] VOP_DBG_MARK = 8'd1;

	wire is_ghci = is_ghci_in;
	wire [7:0] ghci_n;
	wire ghci_n_bo;
	am_sub #(.W(8)) u_ghci_n (
		.a(hdr[15:8]), .b(8'd1), .bi(1'b0), .d(ghci_n), .bo(ghci_n_bo)
	);
	wire h_vendor = is_ghci ? 1'b0 : hdr[30];
	wire [7:0] h_op = is_ghci ? hdr[7:0] : {2'b00, hdr[29:24]};
	wire [7:0] h_n = hdr[7:0];

	/* n rounded up to even (the pairs of SET_REG and DISP_SET). */
	wire [7:0] h_n_even = {h_n[7:1], 1'b0};

	assign h_zero = is_ghci ? (hdr[15:8] == 8'd1) : (hdr[7:0] == 8'd0);

	always @(*) begin
		h_known = 1'b1;
		h_absent = 1'b0;
		h_need = 8'd0;
		h_short = 1'b0;
		if (hdr[31] && !is_ghci) begin
			h_known = 1'b0;
		end else if (h_vendor) begin
			case (h_op)
			VOP_DRAW_RAW: begin
				h_need = 8'd9;
				h_short = hdr[7:0] < 8'd9;
				h_absent = !UNITS[3];
			end
			VOP_DBG_MARK: begin
				h_need = 8'd1;
				h_short = hdr[7:0] < 8'd1;
			end
			default: h_known = 1'b0;
			endcase
		end else if (is_ghci) begin
			case (h_op)
			/* GHCI 1.0 Structured Commands */
			CMD_VM_MAP:                begin h_need = 8'd9;  h_short = hdr[15:8] <= 8'd9; end
			CMD_VM_UNMAP:              begin h_need = 8'd7;  h_short = hdr[15:8] <= 8'd7; end
			CMD_SESSION_OPEN:          begin h_need = 8'd3;  h_short = hdr[15:8] <= 8'd3; end
			CMD_SESSION_CLOSE:         begin h_need = 8'd1;  h_short = hdr[15:8] <= 8'd1; end
			CMD_BIND_SESSION:          begin h_need = 8'd1;  h_short = hdr[15:8] <= 8'd1; end
			CMD_BIND_PIPELINE:         begin h_need = 8'd2;  h_short = hdr[15:8] <= 8'd2; end
			CMD_BIND_VERTEX_BUFFERS:   begin h_need = ghci_n; h_short = 1'b0; end
			CMD_BIND_INDEX_BUFFER:     begin h_need = 8'd3;  h_short = hdr[15:8] <= 8'd3; end
			CMD_BIND_DESCRIPTOR_TABLE: begin h_need = 8'd3;  h_short = hdr[15:8] <= 8'd3; end
			CMD_SET_VIEWPORT:          begin h_need = 8'd6;  h_short = hdr[15:8] <= 8'd6; end
			CMD_SET_SCISSOR:           begin h_need = 8'd4;  h_short = hdr[15:8] <= 8'd4; end
			CMD_SET_DYNAMIC_STATE:     begin h_need = 8'd5;  h_short = hdr[15:8] <= 8'd5; end
			CMD_DRAW: begin
				h_need = 8'd4;
				h_short = hdr[15:8] <= 8'd4;
				h_absent = !UNITS[2];
			end
			CMD_DRAW_INDEXED: begin
				h_need = 8'd5;
				h_short = hdr[15:8] <= 8'd5;
				h_absent = !UNITS[2];
			end
			CMD_DRAW_INDIRECT: begin
				h_need = ghci_n;
				h_short = 1'b0;
				h_absent = !UNITS[2];
			end
			CMD_DRAW_MESH_TASKS: begin
				h_need = 8'd3;
				h_short = hdr[15:8] <= 8'd3;
				h_absent = !UNITS[6];
			end
			CMD_BEGIN_RENDER_PASS:     begin h_need = 8'd9;  h_short = hdr[15:8] <= 8'd9; end
			CMD_END_RENDER_PASS:       begin h_need = 8'd0;  h_short = 1'b0; end
			CMD_LOAD_CONST: begin
				h_need = ghci_n;
				h_short = 1'b0;
				h_absent = !UNITS[6];
			end
			CMD_DISPATCH_INDIRECT: begin
				h_need = 8'd5;
				h_short = hdr[15:8] <= 8'd5;
				h_absent = !UNITS[6];
			end
			CMD_DISPATCH: begin
				h_need = 8'd3;
				h_short = hdr[15:8] <= 8'd3;
				h_absent = !UNITS[6];
			end
			CMD_BARRIER:               begin h_need = 8'd3;  h_short = hdr[15:8] <= 8'd3; end
			CMD_EXECUTE_COMMANDS:      begin h_need = 8'd3;  h_short = hdr[15:8] <= 8'd3; end
			CMD_FENCE:                 begin h_need = 8'd5;  h_short = hdr[15:8] <= 8'd5; end
			CMD_WAIT_FENCE:            begin h_need = 8'd4;  h_short = hdr[15:8] <= 8'd4; end
			CMD_WRITE_TIMESTAMP:       begin h_need = 8'd3;  h_short = hdr[15:8] <= 8'd3; end
			CMD_BEGIN_QUERY: begin
				h_need = 8'd3;
				h_short = hdr[15:8] <= 8'd3;
				h_absent = !UNITS[4];
			end
			CMD_END_QUERY: begin
				h_need = 8'd3;
				h_short = hdr[15:8] <= 8'd3;
				h_absent = !UNITS[4];
			end
			CMD_COPY_BUFFER: begin
				h_need = 8'd7;
				h_short = hdr[15:8] <= 8'd7;
				h_absent = !UNITS[1];
			end
			CMD_COPY_IMAGE: begin
				h_need = 8'd10;
				h_short = hdr[15:8] <= 8'd10;
				h_absent = !UNITS[1];
			end
			CMD_BLIT: begin
				h_need = 8'd11;
				h_short = hdr[15:8] <= 8'd11;
				h_absent = !UNITS[1];
			end
			CMD_FILL_BUFFER: begin
				h_need = 8'd4;
				h_short = hdr[15:8] <= 8'd4;
				h_absent = !UNITS[1];
			end
			CMD_RESOLVE_IMAGE: begin
				h_need = 8'd10;
				h_short = hdr[15:8] <= 8'd10;
				h_absent = !UNITS[1];
			end
			CMD_COPY_BUFFER_TO_IMAGE: begin
				h_need = 8'd9;
				h_short = hdr[15:8] <= 8'd9;
				h_absent = !UNITS[1];
			end
			CMD_COPY_IMAGE_TO_BUFFER: begin
				h_need = 8'd9;
				h_short = hdr[15:8] <= 8'd9;
				h_absent = !UNITS[1];
			end
			CMD_DISP_SET: begin
				h_need = ghci_n;
				h_short = 1'b0;
				h_absent = HAS_DISP == 0 || hdr_fw;
			end
			CMD_FLIP: begin
				h_need = 8'd7;
				h_short = hdr[15:8] <= 8'd7;
				h_absent = HAS_DISP == 0 || hdr_fw;
			end
			default: h_known = 1'b0;
			endcase
		end else begin
			case (h_op)
			OP_NOP, OP_WAIT_IDLE, OP_PERF_RESET, OP_INVALIDATE: ;
			OP_BLIT: h_absent = !UNITS[1];
			OP_SET_REG: begin
				h_need = h_n_even;	/* pairs: odd n is short */
				h_short = hdr[0];
			end
			OP_DRAW: h_absent = !UNITS[2];
			OP_DISPATCH: begin
				h_need = 8'd3;
				h_short = hdr[7:0] < 8'd3;
				h_absent = !UNITS[6];
			end
			OP_FENCE, OP_WAIT_FENCE: begin
				h_need = 8'd2;
				h_short = hdr[7:0] < 8'd2;
			end
			OP_LOAD_CONST: begin
				h_need = 8'd3;
				h_short = hdr[7:0] < 8'd3;
				h_absent = !UNITS[6];
			end
			OP_LOAD_PROGRAM: begin
				h_need = 8'd1;
				h_short = hdr[7:0] < 8'd1;
			end
			OP_WAIT_VSYNC: h_absent = HAS_VSYNC == 0;
			OP_RESULT: begin
				h_need = 8'd3;
				h_short = hdr[7:0] < 8'd3;
			end
			OP_QUERY: begin
				h_need = 8'd1;
				h_short = hdr[7:0] < 8'd1;
				h_absent = !UNITS[4];
			end
			OP_DISP_SET: begin
				h_need = h_n_even;
				h_short = hdr[0];
				h_absent = HAS_DISP == 0 || hdr_fw;
			end
			OP_FLIP: begin
				h_need = 8'd4;
				h_short = hdr[7:0] < 8'd4;
				h_absent = HAS_DISP == 0 || hdr_fw;
			end
			OP_BARRIER: begin
				h_need = 8'd1;	/* payload: {accessMask[15:0], 8'd0, dstStageMask[7:0]} */
				h_short = hdr[7:0] < 8'd1;
			end
			OP_SEMAPHORE_SIGNAL, OP_SEMAPHORE_WAIT: begin
				h_need = 8'd4;	/* payload: addr[63:0], val[63:0] */
				h_short = hdr[7:0] < 8'd4;
			end
			default: h_known = 1'b0;
			endcase
		end
	end

	assign hdr_fault = !h_known || h_absent || h_short;
	assign hdr_short = h_short;

	/* The payload's index or offset dwords. */
	wire is_set = !vendor && op == OP_SET_REG;
	wire is_dset = !vendor && op == OP_DISP_SET;
	wire [7:0] off = in_data[7:0];
	wire off_ok = in_data[31:8] == 24'd0 && off[1:0] == 2'd0 &&
		(off == 8'h10 || off == 8'h28 || off == 8'h2C || (off >= 8'h30 && off <= 8'h50) ||
		off == 8'h58 || off == 8'hA4 || off == 8'hA8);

	assign pay_bad = !p[0] && (is_set && (in_data[31:10] != 22'd0 || in_data[9:8] == 2'b11) ||
		is_dset && !off_ok);

	wire unused_ok = &{1'b0, hdr[23:8], p[7:1], ghci_n_bo};
endmodule

`default_nettype wire
