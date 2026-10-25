/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * axi_id_slave: simulation only.  An AXI4 slave with IDs that keeps no
 * memory: it answers in order (B with the AW's ID after the burst's last
 * beat; R beats with the AR's ID), a read beat's data is
 * axi_id_data(K, address, beat) and a write beat must carry
 * axi_id_data(0, address, beat) with all strobes (the testbench writes
 * that).  Ready signals and response gaps are random (PCT: the percentage
 * of cycles with a handshake offered; SEED).  WAIT_W = 1: AWREADY only
 * while WVALID is also shown (a slave that waits for the data first,
 * allowed by AXI).  Checks: AW/AR/W stable while valid and not ready,
 * WLAST on the burst's last beat, the write data.  errors counts the
 * violations ("axi_id_slave: ERROR").  bursts counts the bursts answered.
 */

`timescale 1ns / 1ps
`default_nettype none

module axi_id_slave #(
	parameter ID_W = 2,
	parameter D_W = 64,
	parameter K = 1,
	parameter PCT = 50,
	parameter WAIT_W = 0,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,
	input wire [ID_W-1:0] awid,
	input wire [31:0] awaddr,
	input wire [7:0] awlen,
	input wire awvalid,
	output reg awready,
	input wire [D_W-1:0] wdata,
	input wire [D_W/8-1:0] wstrb,
	input wire wlast,
	input wire wvalid,
	output reg wready,
	output reg [ID_W-1:0] bid,
	output wire [1:0] bresp,
	output reg bvalid,
	input wire bready,
	input wire [ID_W-1:0] arid,
	input wire [31:0] araddr,
	input wire [7:0] arlen,
	input wire arvalid,
	output reg arready,
	output reg [ID_W-1:0] rid,
	output reg [D_W-1:0] rdata,
	output wire [1:0] rresp,
	output reg rlast,
	output reg rvalid,
	input wire rready
);
	localparam QN = 64;

	`include "axi_id_data.vh"

	integer errors = 0, bursts = 0, seed = SEED;
	reg [ID_W-1:0] awq_id [0:QN-1];
	reg [31:0] awq_addr [0:QN-1];
	reg [7:0] awq_len [0:QN-1];
	integer awq_h = 0, awq_t = 0, w_beat = 0;
	reg [ID_W-1:0] bq_id [0:QN-1];
	integer bq_h = 0, bq_t = 0;
	reg [ID_W-1:0] arq_id [0:QN-1];
	reg [31:0] arq_addr [0:QN-1];
	reg [7:0] arq_len [0:QN-1];
	integer arq_h = 0, arq_t = 0, r_beat = 0;

	reg p_awv = 1'b0, p_awr = 1'b0, p_arv = 1'b0, p_arr = 1'b0, p_wv = 1'b0, p_wr = 1'b0;
	reg [31:0] p_awa = 0, p_ara = 0;
	reg [D_W-1:0] p_wd = 0;

	assign bresp = 2'b00;
	assign rresp = 2'b00;

	function rnd;
		input integer pct;
		rnd = ($unsigned($random(seed)) % 100) < pct;
	endfunction

	task fail;
		input [8*48-1:0] what;
		begin
			errors = errors + 1;
			$display("axi_id_slave %0d: ERROR %0s at %0t", K, what, $time);
		end
	endtask

	initial begin
		awready = 1'b0;
		wready = 1'b0;
		bvalid = 1'b0;
		bid = 0;
		arready = 1'b0;
		rvalid = 1'b0;
		rlast = 1'b0;
		rid = 0;
		rdata = 0;
	end

	always @(posedge clk) begin
		if (rst_n) begin
			/* stability */
			if (p_awv && !p_awr && (!awvalid || awaddr != p_awa))
				fail("AW changed before ready");
			if (p_arv && !p_arr && (!arvalid || araddr != p_ara))
				fail("AR changed before ready");
			if (p_wv && !p_wr && (!wvalid || wdata != p_wd))
				fail("W changed before ready");
			/* AW */
			if (awvalid && awready) begin
				awq_id[awq_t % QN] = awid;
				awq_addr[awq_t % QN] = awaddr;
				awq_len[awq_t % QN] = awlen;
				awq_t = awq_t + 1;
			end
			/* W */
			if (wvalid && wready) begin
				if (awq_h == awq_t) begin
					fail("W without AW");
				end else begin
					if (wdata != axi_id_data(0, awq_addr[awq_h % QN], w_beat) ||
						wstrb != {(D_W/8){1'b1}})
						fail("write data");
					if (wlast != (w_beat == awq_len[awq_h % QN]))
						fail("WLAST");
					if (wlast) begin
						bq_id[bq_t % QN] = awq_id[awq_h % QN];
						bq_t = bq_t + 1;
						awq_h = awq_h + 1;
						w_beat = 0;
					end else begin
						w_beat = w_beat + 1;
					end
				end
			end
			/* B */
			if (bvalid && bready) begin
				bvalid <= 1'b0;
				bursts = bursts + 1;
			end else if (!bvalid && bq_h != bq_t && rnd(PCT)) begin
				bvalid <= 1'b1;
				bid <= bq_id[bq_h % QN];
				bq_h = bq_h + 1;
			end
			/* AR */
			if (arvalid && arready) begin
				arq_id[arq_t % QN] = arid;
				arq_addr[arq_t % QN] = araddr;
				arq_len[arq_t % QN] = arlen;
				arq_t = arq_t + 1;
			end
			/* R */
			if (rvalid && rready) begin
				rvalid <= 1'b0;
				if (rlast) begin
					arq_h = arq_h + 1;
					r_beat = 0;
					bursts = bursts + 1;
				end else begin
					r_beat = r_beat + 1;
				end
			end
			if ((!rvalid || rready) && arq_h != arq_t && rnd(PCT) &&
				!(rvalid && rready && rlast && arq_h == arq_t)) begin
				rvalid <= 1'b1;
				rid <= arq_id[arq_h % QN];
				rdata <= axi_id_data(K, arq_addr[arq_h % QN], r_beat);
				rlast <= r_beat == arq_len[arq_h % QN];
			end
			awready <= rnd(PCT) && (WAIT_W == 0 || wvalid) && awq_t - awq_h < QN - 1;
			wready <= rnd(PCT) && awq_h != awq_t;
			arready <= rnd(PCT) && arq_t - arq_h < QN - 1;
		end
		p_awv <= awvalid;
		p_awr <= awready;
		p_awa <= awaddr;
		p_arv <= arvalid;
		p_arr <= arready;
		p_ara <= araddr;
		p_wv <= wvalid;
		p_wr <= wready;
		p_wd <= wdata;
	end
endmodule

`default_nettype wire
