/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_acc: a row address of the blitter's engines (atg_blt_2d,
 * atg_blt_rsv): go loads r = b and starts r += y x s by shift and add, one
 * bit of y a cycle (idle when the bits are used up: at most 17 cycles);
 * add (when idle) adds d to r (the next row).  32-bit wrap.
 * See spec/gpu/blt/atg_blt_acc.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_blt_acc #(
	parameter W = 32
) (
	input wire clk,
	input wire rst_n,
	input wire go,
	input wire [16:0] y,
	input wire [W-1:0] s,
	input wire [W-1:0] b,
	input wire add,
	input wire [W-1:0] d,
	output wire [W-1:0] r,
	output wire idle
);
	(* keep = "true", dont_touch = "true" *) wire rst_acc_high = !rst_n;
	wire go_my, go_idle, go_ms0, go_ms1, go_ms_ce, go_hi, go_r0, go_r1, go_ce0, go_ce1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gmy (.I0(go), .O(go_my));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gidl (.I0(go), .O(go_idle));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gms0 (.I0(go), .O(go_ms0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gms1 (.I0(go), .O(go_ms1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gmsce (.I0(go), .O(go_ms_ce));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_ghi (.I0(go), .O(go_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gr0 (.I0(go), .O(go_r0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gr1 (.I0(go), .O(go_r1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gce0 (.I0(go), .O(go_ce0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_gce1 (.I0(go), .O(go_ce1));
`else
	assign go_my = go;
	assign go_idle = go;
	assign go_ms0 = go;
	assign go_ms1 = go;
	assign go_ms_ce = go;
	assign go_hi = go;
	assign go_r0 = go;
	assign go_r1 = go;
	assign go_ce0 = go;
	assign go_ce1 = go;
`endif

	reg [15:0] my_lo;
	reg my_hi;
	(* max_fanout = 16 *) reg idle_q;
	assign idle = idle_q;

	(* equivalent_register_removal = "no" *) reg [15:0] ms_lo, ms_hi;
	wire [W-1:0] ms = {ms_hi, ms_lo};

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] r_lo;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] r_hi;
	assign r = {r_hi, r_lo};

	wire step = !idle_q;
	(* keep = "true" *) wire ce_my = go_my || step;
	(* keep = "true" *) wire ce_ms0 = go_ms0 || step;
	(* keep = "true" *) wire ce_ms1 = go_ms_ce || step;
	(* keep = "true" *) wire ce_hi = go_hi || step;
	(* keep = "true" *) wire ce_r0 = go_ce0 || (step && my_lo[0]) || add;
	(* keep = "true" *) wire ce_r1 = go_ce1 || (step && my_lo[0]) || add;
	wire idle_lo, idle_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_ilo (.I0(idle_q), .O(idle_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_ihi (.I0(idle_q), .O(idle_hi));
`else
	assign idle_lo = idle_q;
	assign idle_hi = idle_q;
`endif

	/* One adder for both sums (a step of the multiply, or the final add: never in one cycle). */
	wire [W-1:0] sum;
	wire sum_co_unused;
	wire [W-1:0] b_mux = {idle_hi ? d[31:16] : ms[31:16], idle_lo ? d[15:0] : ms[15:0]};

	am_add #(.W(W)) a_sum (.a(r), .b(b_mux), .ci(1'b0), .s(sum), .co(sum_co_unused));

	always @(posedge clk) begin
		if (rst_acc_high) begin
			my_lo <= 16'd0;
			my_hi <= 1'b0;
			idle_q <= 1'b1;
		end else begin
			if (ce_my) begin
				my_lo[14:0] <= go_my ? y[14:0] : my_lo[15:1];
				my_hi <= go_my ? y[16] : 1'b0;
			end
			if (ce_ms0) begin
				my_lo[15] <= go_ms0 ? y[15] : my_hi;
			end
			if (go_idle)
				idle_q <= 1'b0;
			else if (step)
				idle_q <= !my_hi && (my_lo[15:1] == 15'd0);
		end
	end

	always @(posedge clk) begin
		if (ce_ms1)
			ms_lo[15:1] <= go_ms1 ? s[15:1] : ms_lo[14:0];
		ms_lo[0] <= go_ms1 ? s[0] : (step ? 1'b0 : ms_lo[0]);

		if (ce_hi)
			ms_hi <= go_hi ? s[31:16] : {ms_hi[14:0], ms_lo[15]};

		if (ce_r0)
			r_lo <= go_r0 ? b[15:0] : sum[15:0];

		if (ce_r1)
			r_hi <= go_r1 ? b[31:16] : sum[31:16];
	end

	wire unused_ok = &{1'b0, sum_co_unused};
endmodule

`default_nettype wire
