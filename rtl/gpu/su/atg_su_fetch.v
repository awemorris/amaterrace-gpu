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
	output wire [WARP_W-1:0] ic_warp,
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
	/* Four in-flight fetches in order (depth 4, pointer mod 8):
	 * {warp, pc, addr} buffered at request, issued to I$, instruction
	 * written on ic_rvalid; the head leaves when it has its data.
	 * Force slice registers to prevent Distributed RAM inference. */
	(* ram_style = "registers" *) reg [WARP_W-1:0] q_warp [0:3];
	(* ram_style = "registers" *) reg [15:0] q_pc [0:3];
	(* ram_style = "registers" *) reg [31:0] q_addr [0:3];
	(* max_fanout = 12 *) reg [3:0] q_have;
	(* keep = "true", max_fanout = 12 *) reg [2:0] rp;
	(* keep = "true", max_fanout = 12 *) reg [2:0] wp, fp;	/* request, read and fill pointers (mod 8, index bits [1:0]) */
	(* keep = "true", max_fanout = 12 *) reg [2:0] ip;	/* icache issue pointer */
	(* keep = "true", equivalent_register_removal = "no" *) reg [1:0] hip_addr_lo, hip_addr_hi;
	wire [2:0] used;
	wire [2:0] wp_next;
	wire [2:0] fp_next;
	wire [2:0] rp_next;
	wire [2:0] ip_next;
	wire us_bo_unused, wp_co_unused, fp_co_unused, rp_co_unused, ip_co_unused;
	am_sub #(.W(3)) u_used (.a(wp), .b(rp), .bi(1'b0), .d(used), .bo(us_bo_unused));
	am_add #(.W(3)) u_wp (.a(wp), .b(3'd0), .ci(1'b1), .s(wp_next), .co(wp_co_unused));
	am_add #(.W(3)) u_fp (.a(fp), .b(3'd0), .ci(1'b1), .s(fp_next), .co(fp_co_unused));
	am_add #(.W(3)) u_rp (.a(rp), .b(3'd0), .ci(1'b1), .s(rp_next), .co(rp_co_unused));
	am_add #(.W(3)) u_ip (.a(ip), .b(3'd0), .ci(1'b1), .s(ip_next), .co(ip_co_unused));

	wire full = (wp[1:0] == rp[1:0]) && (wp[2] != rp[2]);
	wire room = !full;

	/* Decouple f_ready from ic_ready: f_ready is asserted whenever queue has room */
	wire f_ready_w = room;
	assign f_ready = f_ready_w;
	wire push_w = f_valid && f_ready_w;
	wire push_0 = push_w && (wp[1:0] == 2'd0);
	wire push_1 = push_w && (wp[1:0] == 2'd1);
	wire push_2 = push_w && (wp[1:0] == 2'd2);
	wire push_3 = push_w && (wp[1:0] == 2'd3);

	/* I$ issue interface: driven from registered q_addr/q_warp */
	wire has_unissued = (ip != wp);
	wire ic_req_w = has_unissued;
	assign ic_req = ic_req_w;
	wire [1:0] hip = ip[1:0];
	assign ic_warp = q_warp[hip];
	assign ic_addr[15:0]  = q_addr[hip_addr_lo][15:0];
	assign ic_addr[31:16] = q_addr[hip_addr_hi][31:16];
	wire ip_advance = ic_req_w && ic_ready;

	(* dont_touch = "true" *) wire fill_0 = ic_rvalid && (fp[1:0] == 2'd0);
	(* dont_touch = "true" *) wire fill_1 = ic_rvalid && (fp[1:0] == 2'd1);
	(* dont_touch = "true" *) wire fill_2 = ic_rvalid && (fp[1:0] == 2'd2);
	(* dont_touch = "true" *) wire fill_3 = ic_rvalid && (fp[1:0] == 2'd3);

	wire rst_p = !rst_n;
	wire [1:0] h = rp[1:0];
	assign d_valid = (used != 3'd0) && q_have[h];
	assign d_warp = q_warp[h];
	assign d_pc = q_pc[h];
	(* keep = "true", max_fanout = 12 *) wire pop = d_valid && d_ready;

	genvar gqs;
	generate
		for (gqs = 0; gqs < 8; gqs = gqs + 1) begin : g_qins_sl
			(* dont_touch = "true" *) reg [1:0] fp_sl;
			(* dont_touch = "true" *) reg [1:0] rp_sl;
			wire fill0_sl = ic_rvalid && (fp_sl == 2'd0);
			wire fill1_sl = ic_rvalid && (fp_sl == 2'd1);
			wire fill2_sl = ic_rvalid && (fp_sl == 2'd2);
			wire fill3_sl = ic_rvalid && (fp_sl == 2'd3);
			(* shreg_extract = "no" *) reg [7:0] q_ins0_r, q_ins1_r, q_ins2_r, q_ins3_r;
			always @(posedge clk) begin
				if (fill0_sl)
					q_ins0_r <= ic_rdata[gqs*8 +: 8];
				if (fill1_sl)
					q_ins1_r <= ic_rdata[gqs*8 +: 8];
				if (fill2_sl)
					q_ins2_r <= ic_rdata[gqs*8 +: 8];
				if (fill3_sl)
					q_ins3_r <= ic_rdata[gqs*8 +: 8];
			end
			always @(posedge clk or posedge rst_p) begin
				if (rst_p) begin
					fp_sl <= 2'd0;
					rp_sl <= 2'd0;
				end else begin
					if (ic_rvalid)
						fp_sl <= fp_next[1:0];
					if (pop)
						rp_sl <= rp_next[1:0];
				end
			end
			assign d_instr[gqs*8 +: 8] = (rp_sl == 2'd3) ? q_ins3_r :
			                             (rp_sl == 2'd2) ? q_ins2_r :
			                             (rp_sl == 2'd1) ? q_ins1_r : q_ins0_r;
		end
	endgenerate

	always @(posedge clk) begin
		if (push_0) begin
			q_warp[0] <= f_warp;
			q_pc[0]   <= f_pc;
			q_addr[0] <= f_addr;
		end
		if (push_1) begin
			q_warp[1] <= f_warp;
			q_pc[1]   <= f_pc;
			q_addr[1] <= f_addr;
		end
		if (push_2) begin
			q_warp[2] <= f_warp;
			q_pc[2]   <= f_pc;
			q_addr[2] <= f_addr;
		end
		if (push_3) begin
			q_warp[3] <= f_warp;
			q_pc[3]   <= f_pc;
			q_addr[3] <= f_addr;
		end
	end

	always @(posedge clk or posedge rst_p) begin
		if (rst_p) begin
			wp <= 3'd0;
			ip <= 3'd0;
			hip_addr_lo <= 2'd0;
			hip_addr_hi <= 2'd0;
			rp <= 3'd0;
			fp <= 3'd0;
			q_have <= 4'b0000;
		end else begin
			if (push_w)
				wp <= wp_next;
			if (ip_advance) begin
				ip <= ip_next;
				hip_addr_lo <= ip_next[1:0];
				hip_addr_hi <= ip_next[1:0];
			end
			if (fill_0)
				q_have[0] <= 1'b1;
			else if (push_0)
				q_have[0] <= 1'b0;
			if (fill_1)
				q_have[1] <= 1'b1;
			else if (push_1)
				q_have[1] <= 1'b0;
			if (fill_2)
				q_have[2] <= 1'b1;
			else if (push_2)
				q_have[2] <= 1'b0;
			if (fill_3)
				q_have[3] <= 1'b1;
			else if (push_3)
				q_have[3] <= 1'b0;
			if (ic_rvalid)
				fp <= fp_next;
			if (pop)
				rp <= rp_next;
		end
	end
endmodule

`default_nettype wire
