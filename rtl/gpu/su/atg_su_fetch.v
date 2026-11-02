/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fetch: Instruction fetch: takes a (warp, pc, address) from the
 * scheduler, reads the 64-bit instruction from the I$ and hands it to the
 * decoder.
 *
 * The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_fetch.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fetch #(
	parameter WARP_W = 2	/* log2(NWARPS) */
) (
	input wire clk,
	input wire rst_n,
	/* From atg_su_sched */
	input wire f_valid,
	output wire f_ready,
	input wire [WARP_W-1:0] f_warp,
	input wire [15:0] f_pc,
	input wire [31:0] f_addr,
	/* I$ port (atg_su_icache) */
	output wire ic_req,
	input wire ic_ready,
	output wire [31:0] ic_addr,
	input wire ic_rvalid,
	input wire [63:0] ic_rdata,
	/* To atg_su_dec */
	output wire d_valid,
	input wire d_ready,
	output wire [WARP_W-1:0] d_warp,
	output wire [15:0] d_pc,
	output wire [63:0] d_instr
);
	/* Two in-flight fetches in order: {warp, pc} at request, the
	 * instruction on ic_rvalid; the head leaves when it has its data.
	 * Force slice registers to prevent Distributed RAM inference and cut 1.5ns decode delay. */
	(* ram_style = "registers" *) reg [WARP_W-1:0] q_warp [0:1];
	(* ram_style = "registers" *) reg [15:0] q_pc [0:1];
	(* max_fanout = 12 *) reg [1:0] q_have;
	(* keep = "true", max_fanout = 12 *) reg [1:0] rp;
	(* keep = "true", max_fanout = 12 *) reg [1:0] wp, fp;	/* request, read and fill pointers (mod 4, index bit 0) */
	wire [1:0] used;
	wire [1:0] wp_next;
	wire [1:0] fp_next;
	wire [1:0] rp_next;
	wire us_bo_unused, wp_co_unused, fp_co_unused, rp_co_unused;
	am_sub #(.W(2)) u_used (.a(wp), .b(rp), .bi(1'b0), .d(used), .bo(us_bo_unused));
	am_add #(.W(2)) u_wp (.a(wp), .b(2'd0), .ci(1'b1), .s(wp_next), .co(wp_co_unused));
	am_add #(.W(2)) u_fp (.a(fp), .b(2'd0), .ci(1'b1), .s(fp_next), .co(fp_co_unused));
	am_add #(.W(2)) u_rp (.a(rp), .b(2'd0), .ci(1'b1), .s(rp_next), .co(rp_co_unused));
	(* dont_touch = "true" *) wire room = (wp[0] == rp[0]) ? (wp[1] == rp[1]) : 1'b1;

	(* dont_touch = "true" *) wire ic_req_w = f_valid && (wp[0] == rp[0] ? wp[1] == rp[1] : 1'b1);
	assign ic_req = ic_req_w;
	assign ic_addr = f_addr;
	(* dont_touch = "true" *) wire f_ready_w = room && ic_ready;
	assign f_ready = f_ready_w;
	(* dont_touch = "true" *) wire push_0 = f_valid && !wp[0] && f_ready_w;
	(* dont_touch = "true" *) wire push_1 = f_valid && wp[0] && f_ready_w;
	(* dont_touch = "true" *) wire push_w = f_valid && f_ready_w;
	(* dont_touch = "true" *) wire fill_0 = ic_rvalid && !fp[0];
	(* dont_touch = "true" *) wire fill_1 = ic_rvalid && fp[0];

	(* dont_touch = "true" *) wire rst_p = !rst_n;
	wire h = rp[0];
	(* dont_touch = "true" *) reg rp0_pc;
	wire rp0_pc_lo, rp0_pc_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rpc_l (.I0(rp0_pc), .O(rp0_pc_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rpc_h (.I0(rp0_pc), .O(rp0_pc_hi));
`else
	assign rp0_pc_lo = rp0_pc;
	assign rp0_pc_hi = rp0_pc;
`endif
	assign d_valid = used != 2'd0 && q_have[h];
	assign d_warp = q_warp[h];
	assign d_pc = {
		rp0_pc_hi ? q_pc[1][15:8] : q_pc[0][15:8],
		rp0_pc_lo ? q_pc[1][7:0]  : q_pc[0][7:0]
	};
	(* keep = "true", max_fanout = 12 *) wire pop = d_valid && d_ready;

	genvar gqs;
	generate
		for (gqs = 0; gqs < 8; gqs = gqs + 1) begin : g_qins_sl
			(* dont_touch = "true" *) reg fp0_sl;
			(* dont_touch = "true" *) reg rp0_sl;
			wire fill0_sl = ic_rvalid && !fp0_sl;
			wire fill1_sl = ic_rvalid && fp0_sl;
			(* shreg_extract = "no" *) reg [7:0] q_ins0_r, q_ins1_r;
			always @(posedge clk) begin
				if (fill0_sl)
					q_ins0_r <= ic_rdata[gqs*8 +: 8];
				if (fill1_sl)
					q_ins1_r <= ic_rdata[gqs*8 +: 8];
				if (rst_p) begin
					fp0_sl <= 1'b0;
					rp0_sl <= 1'b0;
				end else begin
					if (ic_rvalid)
						fp0_sl <= fp_next[0];
					if (pop)
						rp0_sl <= rp_next[0];
				end
			end
			assign d_instr[gqs*8 +: 8] = rp0_sl ? q_ins1_r : q_ins0_r;
		end
	endgenerate

	always @(posedge clk) begin
		if (push_0) begin
			q_warp[0] <= f_warp;
			q_pc[0]   <= f_pc;
		end
		if (push_1) begin
			q_warp[1] <= f_warp;
			q_pc[1]   <= f_pc;
		end
		if (rst_p) begin
			wp <= 2'd0;
			rp <= 2'd0;
			rp0_pc <= 1'b0;
			fp <= 2'd0;
			q_have <= 2'b00;
		end else begin
			if (push_w)
				wp <= wp_next;
			if (fill_0)
				q_have[0] <= 1'b1;
			else if (f_valid && !wp[0] && f_ready_w)
				q_have[0] <= 1'b0;
			if (fill_1)
				q_have[1] <= 1'b1;
			else if (f_valid && wp[0] && f_ready_w)
				q_have[1] <= 1'b0;
			if (ic_rvalid)
				fp <= fp_next;
			if (pop) begin
				rp <= rp_next;
				rp0_pc <= rp_next[0];
			end
		end
	end
endmodule

`default_nettype wire
