/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_idtrack: the AXI transactions of one direction in flight per ID
 * (am_axi_split; spec/common/am_axi_split.md): for each of the 2^ID_W IDs
 * a count and the destination (2 bits) of the transactions taken (take,
 * with take_id and take_dst) and not yet answered (done, with done_id).
 * ok: a transaction of q_id to q_dst may be taken now (none of that ID in
 * flight, or all at q_dst, and fewer than 2^CNT_W - 1).  A take and a done
 * of the same ID in one cycle leave the count as it is.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_idtrack #(
	parameter ID_W = 1,
	parameter CNT_W = 3
) (
	input wire clk,
	input wire rst_n,
	input wire take,
	input wire [ID_W-1:0] take_id,
	input wire [1:0] take_dst,
	input wire done,
	input wire [ID_W-1:0] done_id,
	input wire [ID_W-1:0] q_id,
	input wire [1:0] q_dst,
	output wire ok
);
	localparam NI = 1 << ID_W;

	wire [NI*CNT_W-1:0] cnt_v;
	wire [NI*2-1:0] dst_v;

	genvar gi;
	generate
		for (gi = 0; gi < NI; gi = gi + 1) begin : ids
			localparam [ID_W-1:0] GID = gi;
			reg [CNT_W-1:0] c;
			reg [1:0] d;
			wire up = take && take_id == GID;
			wire dn = done && done_id == GID;
			wire [CNT_W-1:0] c_n;
			wire co;

			am_addsub #(.W(CNT_W)) cs (.a(c), .b({{(CNT_W-1){1'b0}}, 1'b1}), .sub(dn), .s(c_n), .co(co));

			always @(posedge clk) begin
				if (!rst_n) begin
					c <= {CNT_W{1'b0}};
					d <= 2'd0;
				end else begin
					if (up != dn)
						c <= c_n;
					if (up)
						d <= take_dst;
				end
			end

			assign cnt_v[gi*CNT_W +: CNT_W] = c;
			assign dst_v[gi*2 +: 2] = d;

			wire unused_co = &{1'b0, co};
		end
	endgenerate

	wire [CNT_W-1:0] q_cnt = cnt_v[q_id*CNT_W +: CNT_W];

	assign ok = (q_cnt == {CNT_W{1'b0}} || dst_v[q_id*2 +: 2] == q_dst) &&
		q_cnt != {CNT_W{1'b1}};
endmodule

`default_nettype wire
