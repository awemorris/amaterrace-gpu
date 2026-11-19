/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_msb: the index n of the highest set bit of a W-bit a (a priority
 * encoder; combinational, LUTs: SW levels of a half select), 0 when a is
 * 0; nz: a is not 0.  W <= 2^SW.  Written without a loop: a loop in an
 * always @(*) runs again on every change of its input while the logic in
 * front of it settles, which made the simulation of the fp datapaths six
 * times slower than the former functions.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_msb #(
	parameter W = 32,
	parameter SW = 5	/* index bits */
) (
	input wire [W-1:0] a,
	output wire [SW-1:0] n,
	output wire nz
);
	localparam P = 1 << SW;
	wire [P-1:0] v0;	/* a zero-extended */
	generate
		if (P > W) begin : g_ext
			assign v0 = {{(P - W){1'b0}}, a};
		end else begin : g_eq
			assign v0 = a;
		end
	endgenerate

	/*
	 * Parallel radix-4 LZD (O(log4 P) gate depth instead of O(SW) serial halving):
	 *   Stage 0: 4-bit leaves -> (nz, 2b idx)
	 *   Stage 1: 4-to-1 combine (16-bit groups) -> (nz, 4b idx)
	 *   Stage 2: 4-to-1 combine (64-bit groups) -> (nz, 6b idx)
	 *   Top:     if 2 groups remain (odd SW >= 3), 2-to-1 select.
	 */
	localparam integer N0 = (P >= 4) ? (P / 4) : 1;
	localparam integer N1 = (N0 >= 4) ? (N0 / 4) : 1;
	localparam integer N2 = (N1 >= 4) ? (N1 / 4) : 1;
	genvar k;
	generate
		if (SW == 1) begin : g_sw1
			assign n[0] = v0[1];
		end else begin : g_tree
			wire [N0-1:0]   s0_nz;
			wire [N0*2-1:0] s0_id;
			for (k = 0; k < N0; k = k + 1) begin : g_s0
				wire [3:0] b4 = v0[k*4 +: 4];
				assign s0_nz[k] = |b4;
				assign s0_id[k*2 +: 2] = {b4[3] | b4[2], b4[3] | (~b4[2] & b4[1])};
			end

			if (SW == 2) begin : g_sw2
				assign n = s0_id;
			end else if (SW == 3) begin : g_sw3
				assign n = s0_nz[1] ? {1'b1, s0_id[3:2]} : {1'b0, s0_id[1:0]};
			end else begin : g_ge4
				wire [N1-1:0]   s1_nz;
				wire [N1*4-1:0] s1_id;
				for (k = 0; k < N1; k = k + 1) begin : g_s1
					wire [3:0] z4 = s0_nz[k*4 +: 4];
					wire [1:0] h2 = {z4[3] | z4[2], z4[3] | (~z4[2] & z4[1])};
					wire [3:0] oh = {z4[3], ~z4[3] & z4[2], ~z4[3] & ~z4[2] & z4[1], ~z4[3] & ~z4[2] & ~z4[1]};
					wire [1:0] l2 = ({2{oh[3]}} & s0_id[(k*4 + 3)*2 +: 2]) |
					                ({2{oh[2]}} & s0_id[(k*4 + 2)*2 +: 2]) |
					                ({2{oh[1]}} & s0_id[(k*4 + 1)*2 +: 2]) |
					                ({2{oh[0]}} & s0_id[(k*4 + 0)*2 +: 2]);
					assign s1_nz[k] = |z4;
					assign s1_id[k*4 +: 4] = {h2, l2};
				end

				if (SW == 4) begin : g_sw4
					assign n = s1_id;
				end else if (SW == 5) begin : g_sw5
					assign n = s1_nz[1] ? {1'b1, s1_id[7:4]} : {1'b0, s1_id[3:0]};
				end else begin : g_ge6
					wire [N2-1:0]   s2_nz;
					wire [N2*6-1:0] s2_id;
					for (k = 0; k < N2; k = k + 1) begin : g_s2
						wire [3:0] z4 = s1_nz[k*4 +: 4];
						wire [1:0] h2 = {z4[3] | z4[2], z4[3] | (~z4[2] & z4[1])};
						wire [3:0] oh = {z4[3], ~z4[3] & z4[2], ~z4[3] & ~z4[2] & z4[1], ~z4[3] & ~z4[2] & ~z4[1]};
						wire [3:0] l4 = ({4{oh[3]}} & s1_id[(k*4 + 3)*4 +: 4]) |
						                ({4{oh[2]}} & s1_id[(k*4 + 2)*4 +: 4]) |
						                ({4{oh[1]}} & s1_id[(k*4 + 1)*4 +: 4]) |
						                ({4{oh[0]}} & s1_id[(k*4 + 0)*4 +: 4]);
						assign s2_nz[k] = |z4;
						assign s2_id[k*6 +: 6] = {h2, l4};
					end

					if (SW == 6) begin : g_sw6
						assign n = s2_id;
					end else begin : g_sw7
						assign n = s2_nz[1] ? {1'b1, s2_id[11:6]} : {1'b0, s2_id[5:0]};
					end
				end
			end
		end
	endgenerate
	assign nz = |a;
endmodule

`default_nettype wire
