/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp_drain: the drain of atg_su_exp: picks the ended fragment warp
 * whose sequence number is the ROP's next one, sends its quads to the ROP
 * one beat per ex_ready, and releases the slots (xr_*).
 *
 * A quad goes out as one beat per colour attachment the warp exported
 * (d_rtw, ascending; d_rt names it), or as one beat without colour
 * (d_nocol) when the warp exported none.  d_first and d_lastb mark the
 * quad's first and last beat; ex_last is the last beat of the warp's last
 * quad (the quads with coverage, packed from lane 0).  atg_su_exp supplies
 * the selected warp's coverage and attachments (d_cov, d_rtw by d_warp)
 * and the beat's data (by d_warp, d_q, d_rt).
 *
 * States: IDLE →(an ended fragment warp whose number is ex_next)→ FIRST
 * (the first attachment) → DRAIN (one beat per ex_ready) →(last beat)→ RET
 * (xr_valid) → IDLE.  Vertex and compute warps release the cycle after
 * wc_end; a drain's release waits a cycle when both fall together.  See
 * spec/gpu/su/atg_su_exp_drain.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp_drain #(
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2	/* log2(NWARPS) */
) (
	input wire clk,
	input wire rst_n,
	/* The warps (snooped by atg_su_exp) */
	input wire fl_go,
	input wire [WARP_W-1:0] fl_slot,
	input wire [15:0] fl_seq,
	input wire wc_end,
	input wire [WARP_W-1:0] wc_warp,
	/* The draining warp (atg_su_exp's buffer, selected by d_warp) */
	input wire [31:0] d_cov,
	input wire [7:0] d_rtw,
	output reg [WARP_W-1:0] d_warp,
	output reg [2:0] d_q,
	output reg [2:0] d_rt,
	output wire d_first,
	output wire d_lastb,
	output wire d_nocol,
	/* To the ROP */
	output wire ex_valid,
	input wire ex_ready,
	output wire [15:0] ex_seq,
	output wire ex_last,
	input wire [15:0] ex_next,
	/* Slot release (atg_su_sched) */
	output wire xr_valid,
	output wire [WARP_W-1:0] xr_warp
);
	localparam [1:0] S_IDLE = 2'd0, S_FIRST = 2'd1, S_DRAIN = 2'd2, S_RET = 2'd3;

	/* the lowest attachment of m (0 when none) */
	function [2:0] low;
		input [7:0] m;
		low = m[0] ? 3'd0 : m[1] ? 3'd1 : m[2] ? 3'd2 : m[3] ? 3'd3 :
		      m[4] ? 3'd4 : m[5] ? 3'd5 : m[6] ? 3'd6 : m[7] ? 3'd7 : 3'd0;
	endfunction

	reg [NWARPS-1:0] frag, ended;
	reg [NWARPS*16-1:0] seq;
	reg [1:0] st;
	reg vx_v;	/* a vertex/compute warp's release, this cycle */
	reg [WARP_W-1:0] vx_w;

	/* the attachments above and below the beat's */
	reg [7:0] above_m, below_m;
	integer ab;
	always @(*)
		for (ab = 0; ab < 8; ab = ab + 1) begin
			above_m[ab] = ab > d_rt;
			below_m[ab] = ab < d_rt;
		end
	wire [7:0] above = d_rtw & above_m;
	wire [7:0] below = d_rtw & below_m;
	wire [2:0] dq1;
	wire dq_co_unused;
	am_add #(.W(3)) u_dq1 (.a(d_q), .b(3'd0), .ci(1'b1), .s(dq1), .co(dq_co_unused));
	wire qlast = d_q == 3'd7 || d_cov[{dq1, 2'b00} +: 4] == 4'd0;

	assign d_nocol = d_rtw == 8'd0;
	assign d_first = below == 8'd0;
	assign d_lastb = above == 8'd0;

	/* An ended fragment warp whose sequence number is the ROP's next one. */
	reg [WARP_W-1:0] cand;
	reg cand_v;
	integer w;
	always @(*) begin
		cand_v = 1'b0;
		cand = {WARP_W{1'b0}};
		for (w = NWARPS - 1; w >= 0; w = w - 1)
			if (frag[w] && ended[w] && seq[w*16 +: 16] == ex_next) begin
				cand_v = 1'b1;
				cand = w[WARP_W-1:0];
			end
	end

	assign ex_valid = st == S_DRAIN;
	assign ex_seq = seq[d_warp*16 +: 16];
	assign ex_last = qlast && d_lastb;
	assign xr_valid = vx_v || st == S_RET;
	assign xr_warp = vx_v ? vx_w : d_warp;

	always @(posedge clk) begin
		if (!rst_n) begin
			frag <= {NWARPS{1'b0}};
			ended <= {NWARPS{1'b0}};
			st <= S_IDLE;
			vx_v <= 1'b0;
			vx_w <= {WARP_W{1'b0}};
			d_warp <= {WARP_W{1'b0}};
			d_q <= 3'd0;
			d_rt <= 3'd0;
		end else begin
			vx_v <= wc_end && !frag[wc_warp];
			vx_w <= wc_warp;
			if (wc_end && frag[wc_warp])
				ended[wc_warp] <= 1'b1;
			if (fl_go) begin
				frag[fl_slot] <= 1'b1;
				ended[fl_slot] <= 1'b0;
				seq[fl_slot*16 +: 16] <= fl_seq;
			end
			case (st)
			S_IDLE:
				if (cand_v) begin
					d_warp <= cand;
					d_q <= 3'd0;
					st <= S_FIRST;
				end
			S_FIRST: begin
				d_rt <= low(d_rtw);
				st <= S_DRAIN;
			end
			S_DRAIN:
				if (ex_ready) begin
					if (!d_lastb)
						d_rt <= low(above);
					else if (qlast)
						st <= S_RET;
					else begin
						d_q <= dq1;
						d_rt <= low(d_rtw);
					end
				end
			default:	/* S_RET: the release (after a vertex warp's of this cycle) */
				if (!vx_v) begin
					frag[d_warp] <= 1'b0;
					ended[d_warp] <= 1'b0;
					st <= S_IDLE;
				end
			endcase
		end
	end
endmodule

`default_nettype wire
