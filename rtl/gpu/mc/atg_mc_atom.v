/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_atom: The MC's atomic unit: one read-modify-write at a time for
 * the SUs' atomics (design §4.1): reads the line, applies the operation to
 * one word, writes the word back (byte enables of that word only), returns
 * the old value.  An MC client of its own (placed next to atg_mc in
 * atg_top).
 *
 * Requests (at_*, one per SU): valid/ready, the payload held until ready.
 * In IDLE the unit takes one requester, round-robin from the one after the
 * last taken (at_ready is that requester's bit, in the same cycle).  The
 * operation (at_op, atg_su_lsu's at_op = the atom sub of docs/ghci.md
 * §12.5): 0 and, 1 or, 2 xor, 3 xchg, 4 add, 5 sub, 6 smax, 7 smin,
 * 8 umax, 9 umin, 10 cmpxchg (at_a stored when the old value equals at_b);
 * 11-15 (never sent by the SU) store the old value back.  The response is
 * a one-cycle pulse on the requester's at_rsp_valid with at_old and
 * at_error (shared by all requesters, valid with the pulse), after the
 * write's response (so the SU's cm counter covers the BRESP).
 *
 * AMB: one request outstanding, tag 0; the read's response is matched by
 * rsp_write 0, the write's by rsp_write 1.  rsp_error on the read: no
 * write, at_error 1 and at_old 0 (the MC has raised the fault); rsp_error
 * on the write: at_error 1 with the old value.  Atomicity: other clients'
 * plain writes to the word between the read and the write are not
 * excluded in v1 (spec §4).
 *
 * States: IDLE →(request)→ RREQ →(req_ready)→ RWAIT →(read rsp)→ WREQ
 * →(req_ready)→ WWAIT →(write rsp)→ IDLE; RWAIT →(rsp_error)→ IDLE.
 * Behaviour: spec/gpu/mc/atg_mc_atom.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_atom #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter NATOM = 1,	/* Requesters (one per SU) */
	parameter AW = 1	/* clog2(NATOM), at least 1 */
) (
	input wire clk,
	input wire rst_n,
	/* Atomic requests (packed, SU 0 in the low bits) */
	input wire [NATOM-1:0] at_valid,
	output wire [NATOM-1:0] at_ready,
	input wire [NATOM*4-1:0] at_op,
	input wire [NATOM*30-1:0] at_addr,
	input wire [NATOM*32-1:0] at_a,
	input wire [NATOM*32-1:0] at_b,
	output reg [NATOM-1:0] at_rsp_valid,
	output reg [31:0] at_old,
	output reg at_error,
	output wire busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam WPL = LINE_BYTES / 4;
	localparam WW = LINE_SHIFT - 2;
	localparam [2:0] IDLE = 3'd0, RREQ = 3'd1, RWAIT = 3'd2, WREQ = 3'd3, WWAIT = 3'd4;


	reg [2:0] st;
	reg [AW-1:0] rr, rk;
	reg [3:0] rop;
	reg [LA_W-1:0] rline;
	reg [WW-1:0] rwi;
	reg [31:0] ra, rb, rold;

	/*
	 * The next requester: the first valid one after rr, round the ring:
	 * the lowest valid index above rr, else the lowest valid index.
	 */
	reg [AW-1:0] pick, hi_pick, lo_pick;
	reg any, hi_any;
	integer i;
	always @(*) begin
		hi_pick = {AW{1'b0}};
		lo_pick = {AW{1'b0}};
		hi_any = 1'b0;
		any = 1'b0;
		for (i = NATOM - 1; i >= 0; i = i - 1) begin
			if (at_valid[i]) begin
				lo_pick = i[AW-1:0];
				any = 1'b1;
				if (i > {{(32 - AW){1'b0}}, rr}) begin
					hi_pick = i[AW-1:0];
					hi_any = 1'b1;
				end
			end
		end
		pick = hi_any ? hi_pick : lo_pick;
	end

	wire take = st == IDLE && any;
	/* The picked requester's address (a constant part-select per requester). */
	reg [29:0] pick_addr;
	always @(*) begin
		pick_addr = 30'd0;
		for (i = 0; i < NATOM; i = i + 1)
			if ({{(32 - AW){1'b0}}, pick} == i)
				pick_addr = at_addr[i*30 +: 30];
	end
	wire [31:0] badr = {pick_addr, 2'b00};
	genvar g;
	generate
		for (g = 0; g < NATOM; g = g + 1) begin : g_ready
			assign at_ready[g] = take && pick == g;
		end
	endgenerate

	/* The old word in the read's line. */
	wire [31:0] rword = rsp_rdata[rwi*32 +: 32];

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			rr <= {AW{1'b0}};
			at_rsp_valid <= {NATOM{1'b0}};
			at_old <= 32'd0;
			at_error <= 1'b0;
		end else begin
			at_rsp_valid <= {NATOM{1'b0}};
			case (st)
			IDLE: if (take) begin
				rr <= pick;
				rk <= pick;
				rop <= at_op[pick*4 +: 4];
				rline <= badr[ADDR_W-1:LINE_SHIFT];
				rwi <= badr[LINE_SHIFT-1:2];
				ra <= at_a[pick*32 +: 32];
				rb <= at_b[pick*32 +: 32];
				st <= RREQ;
			end
			RREQ: if (req_ready)
				st <= RWAIT;
			RWAIT: if (rsp_valid && !rsp_write) begin
				if (rsp_error) begin
					at_rsp_valid[rk] <= 1'b1;
					at_old <= 32'd0;
					at_error <= 1'b1;
					st <= IDLE;
				end else begin
					rold <= rword;
					st <= WREQ;
				end
			end
			WREQ: if (req_ready)
				st <= WWAIT;
			WWAIT: if (rsp_valid && rsp_write) begin
				at_rsp_valid[rk] <= 1'b1;
				at_old <= rold;
				at_error <= rsp_error;
				st <= IDLE;
			end
			default: st <= IDLE;
			endcase
		end
	end

	assign busy = st != IDLE;
	assign req_valid = st == RREQ || st == WREQ;
	assign req_write = st == WREQ;
	assign req_line = rline;
	/* The written word's byte enables: word rwi of the line. */
	reg [LINE_BYTES-1:0] be_w;
	always @(*)
		for (i = 0; i < WPL; i = i + 1)
			be_w[i*4 +: 4] = {{(32 - WW){1'b0}}, rwi} == i ? 4'hF : 4'h0;
	assign req_be = st == WREQ ? be_w : {LINE_BYTES{1'b0}};

	/* The new value of the word: ADD and SUB share one adder-subtractor. */
	wire [31:0] as_s;
	wire as_co;
	reg [31:0] new_word;

	am_addsub #(.W(32)) as (.a(rold), .b(ra), .sub(rop == 4'd5), .s(as_s), .co(as_co));

	always @(*) begin
		case (rop)
		4'd0: new_word = rold & ra;
		4'd1: new_word = rold | ra;
		4'd2: new_word = rold ^ ra;
		4'd3: new_word = ra;
		4'd4: new_word = as_s;
		4'd5: new_word = as_s;
		4'd6: new_word = $signed(rold) > $signed(ra) ? rold : ra;
		4'd7: new_word = $signed(rold) < $signed(ra) ? rold : ra;
		4'd8: new_word = rold > ra ? rold : ra;
		4'd9: new_word = rold < ra ? rold : ra;
		4'd10: new_word = rold == rb ? ra : rold;
		default: new_word = rold;
		endcase
	end
	assign req_wdata = {WPL{new_word}};
	assign req_tag = 8'd0;

	wire unused_ok = &{1'b0, rsp_tag, badr[1:0], as_co};
endmodule

`default_nettype wire
