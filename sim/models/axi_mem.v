/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * axi_mem: simulation only.  An AXI slave memory of MEM_BYTES bytes at
 * address 0 for the master side of the GPU, with a protocol checker:
 *
 *   - AW/AR/W payloads stay stable while valid and not ready, and valid
 *     does not fall before its handshake;
 *   - INCR bursts only, AxSIZE equal to the bus width, the address aligned
 *     to the burst (len + 1) * DATA_W / 8, no 4 KiB crossing;
 *   - WLAST exactly on the burst's last beat;
 *   - responses in order (the GPU uses one ID).
 *
 * The ready signals and the response latency are random (seeded by SEED)
 * when RANDOM is 1.  Addresses at or above ERR_BASE answer SLVERR (the
 * write is not done).  errors counts the protocol violations; each is
 * also printed with "axi_mem: ERROR".  Memory starts at zero.
 *
 * READ_EARLY = 1 takes a read's data when its AR is accepted (bursts of up
 * to 64 bytes), so a read may pass a write whose data is still on its way,
 * as a memory controller that reorders may do: a master that reads what it
 * wrote without waiting for the write's response gets the old data.  The
 * write data then comes slowly (WREADY 20% of the cycles) to widen that
 * window.
 */

`timescale 1ns / 1ps
`default_nettype none

module axi_mem #(
	parameter DATA_W = 64,
	parameter MEM_BYTES = 1 << 20,
	parameter [31:0] ERR_BASE = 32'hF0000000,
	parameter RANDOM = 1,
	parameter READ_EARLY = 0,
	parameter SEED = 1
) (
	input wire clk,
	input wire rst_n,

	input wire [31:0] awaddr,
	input wire [7:0] awlen,
	input wire [2:0] awsize,
	input wire [1:0] awburst,
	input wire awvalid,
	output reg awready,
	input wire [DATA_W-1:0] wdata,
	input wire [DATA_W/8-1:0] wstrb,
	input wire wlast,
	input wire wvalid,
	output reg wready,
	output reg [1:0] bresp,
	output reg bvalid,
	input wire bready,
	input wire [31:0] araddr,
	input wire [7:0] arlen,
	input wire [2:0] arsize,
	input wire [1:0] arburst,
	input wire arvalid,
	output reg arready,
	output reg [DATA_W-1:0] rdata,
	output reg [1:0] rresp,
	output reg rlast,
	output reg rvalid,
	input wire rready
);
	localparam NB = DATA_W / 8;
	localparam QN = 16;

	reg [7:0] mem [0:MEM_BYTES-1];
	integer errors;
	integer seed;
	integer i;

	/* Accepted bursts. */
	reg [31:0] awq_addr [0:QN-1];
	reg [7:0] awq_len [0:QN-1];
	integer awq_h, awq_t;
	reg [31:0] arq_addr [0:QN-1];
	reg [7:0] arq_len [0:QN-1];
	reg [511:0] arq_snap [0:QN-1];
	integer arq_h, arq_t;
	integer bq_n;		/* write responses owed */
	reg [1:0] bq_resp [0:QN-1];
	integer bq_h, bq_t;

	integer w_beat;
	reg w_err;
	integer r_beat;
	integer r_delay;
	integer b_delay;

	/* The previous cycle, for the stability checks. */
	reg p_awvalid, p_awready, p_arvalid, p_arready, p_wvalid, p_wready;
	reg [31:0] p_awaddr, p_araddr;
	reg [7:0] p_awlen, p_arlen;
	reg [DATA_W-1:0] p_wdata;
	reg [NB-1:0] p_wstrb;
	reg p_wlast;

	function rnd;
		input integer pct;
		begin
			if (RANDOM)
				rnd = ($unsigned($random(seed)) % 100) < pct;
			else
				rnd = 1'b1;
		end
	endfunction

	task fail;
		input [8*64-1:0] what;
		begin
			errors = errors + 1;
			$display("axi_mem: ERROR %0s at %0t", what, $time);
		end
	endtask

	task check_burst;
		input [31:0] addr;
		input [7:0] len;
		input [2:0] size;
		input [1:0] burst;
		integer bytes;
		begin
			bytes = (len + 1) * NB;
			if (burst != 2'b01)
				fail("burst type not INCR");
			if ((1 << size) != NB)
				fail("AxSIZE not the bus width");
			if (addr % bytes != 0)
				fail("burst address not aligned to the burst");
			if ((addr % 4096) + bytes > 4096)
				fail("burst crosses 4 KiB");
		end
	endtask

	initial begin
		errors = 0;
		seed = SEED;
		for (i = 0; i < MEM_BYTES; i = i + 1)
			mem[i] = 8'd0;
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			awready <= 1'b0;
			wready <= 1'b0;
			arready <= 1'b0;
			bvalid <= 1'b0;
			bresp <= 2'b00;
			rvalid <= 1'b0;
			rlast <= 1'b0;
			rresp <= 2'b00;
			rdata <= {DATA_W{1'b0}};
			awq_h = 0; awq_t = 0;
			arq_h = 0; arq_t = 0;
			bq_h = 0; bq_t = 0; bq_n = 0;
			w_beat = 0; w_err = 1'b0;
			r_beat = 0; r_delay = 0; b_delay = 0;
			p_awvalid <= 1'b0; p_arvalid <= 1'b0; p_wvalid <= 1'b0;
			p_awready <= 1'b0; p_arready <= 1'b0; p_wready <= 1'b0;
		end else begin
			/* Stability. */
			if (p_awvalid && !p_awready) begin
				if (!awvalid)
					fail("AWVALID fell before AWREADY");
				else if (awaddr != p_awaddr || awlen != p_awlen)
					fail("AW changed while waiting");
			end
			if (p_arvalid && !p_arready) begin
				if (!arvalid)
					fail("ARVALID fell before ARREADY");
				else if (araddr != p_araddr || arlen != p_arlen)
					fail("AR changed while waiting");
			end
			if (p_wvalid && !p_wready) begin
				if (!wvalid)
					fail("WVALID fell before WREADY");
				else if (wdata != p_wdata || wstrb != p_wstrb || wlast != p_wlast)
					fail("W changed while waiting");
			end
			p_awvalid <= awvalid; p_awready <= awready; p_awaddr <= awaddr; p_awlen <= awlen;
			p_arvalid <= arvalid; p_arready <= arready; p_araddr <= araddr; p_arlen <= arlen;
			p_wvalid <= wvalid; p_wready <= wready; p_wdata <= wdata; p_wstrb <= wstrb;
			p_wlast <= wlast;

			/* AW. */
			if (awvalid && awready) begin
				check_burst(awaddr, awlen, awsize, awburst);
				awq_addr[awq_t % QN] = awaddr;
				awq_len[awq_t % QN] = awlen;
				awq_t = awq_t + 1;
			end
			awready <= (awq_t - awq_h) < QN - 1 && rnd(70);

			/* W: beats of the oldest burst whose address came. */
			if (wvalid && wready) begin
				if (awq_h == awq_t) begin
					fail("W beat before its AW (model takes W after AW)");
				end else begin
					if (awq_addr[awq_h % QN] >= ERR_BASE) begin
						w_err = 1'b1;
					end else begin
						for (i = 0; i < NB; i = i + 1)
							if (wstrb[i])
								mem[(awq_addr[awq_h % QN] + w_beat * NB + i) % MEM_BYTES] =
									wdata[i*8 +: 8];
					end
					if (wlast != (w_beat == awq_len[awq_h % QN]))
						fail("WLAST not on the last beat");
					if (w_beat == awq_len[awq_h % QN]) begin
						bq_resp[bq_t % QN] = w_err ? 2'b10 : 2'b00;
						bq_t = bq_t + 1;
						awq_h = awq_h + 1;
						w_beat = 0;
						w_err = 1'b0;
					end else begin
						w_beat = w_beat + 1;
					end
				end
			end
			wready <= awq_h != awq_t && rnd(READ_EARLY ? 20 : 70);

			/* B. */
			if (bvalid && bready)
				bvalid <= 1'b0;
			if ((!bvalid || bready) && bq_h != bq_t) begin
				if (b_delay > 0) begin
					b_delay = b_delay - 1;
				end else begin
					bvalid <= 1'b1;
					bresp <= bq_resp[bq_h % QN];
					bq_h = bq_h + 1;
					b_delay = RANDOM ? $unsigned($random(seed)) % 4 : 0;
				end
			end

			/* AR. */
			if (arvalid && arready) begin
				check_burst(araddr, arlen, arsize, arburst);
				arq_addr[arq_t % QN] = araddr;
				arq_len[arq_t % QN] = arlen;
				if (READ_EARLY) begin
					if ((arlen + 1) * NB > 64)
						fail("READ_EARLY burst longer than 64 bytes");
					for (i = 0; i < 64; i = i + 1)
						arq_snap[arq_t % QN][i*8 +: 8] = mem[(araddr + i) % MEM_BYTES];
				end
				arq_t = arq_t + 1;
			end
			arready <= (arq_t - arq_h) < QN - 1 && rnd(70);

			/* R: beats of the oldest read, after a delay. */
			if (rvalid && rready) begin
				rvalid <= 1'b0;
				if (rlast) begin
					arq_h = arq_h + 1;
					r_beat = 0;
					r_delay = RANDOM ? $unsigned($random(seed)) % 6 : 0;
				end else begin
					r_beat = r_beat + 1;
				end
			end
			if ((!rvalid || rready) && arq_h != arq_t) begin
				if (r_delay > 0) begin
					r_delay = r_delay - 1;
				end else if (rnd(80)) begin
					rvalid <= 1'b1;
					rlast <= r_beat == arq_len[arq_h % QN];
					if (arq_addr[arq_h % QN] >= ERR_BASE) begin
						rresp <= 2'b10;
						rdata <= {DATA_W{1'b0}};
					end else begin
						rresp <= 2'b00;
						for (i = 0; i < NB; i = i + 1)
							rdata[i*8 +: 8] <= READ_EARLY ?
								arq_snap[arq_h % QN][(r_beat * NB + i) * 8 +: 8] :
								mem[(arq_addr[arq_h % QN] + r_beat * NB + i) % MEM_BYTES];
					end
				end
			end
		end
	end

	/* Helpers for the testbenches. */
	function [31:0] peek32;
		input [31:0] addr;
		peek32 = {mem[addr + 3], mem[addr + 2], mem[addr + 1], mem[addr]};
	endfunction

	task poke32;
		input [31:0] addr;
		input [31:0] value;
		begin
			mem[addr] = value[7:0];
			mem[addr + 1] = value[15:8];
			mem[addr + 2] = value[23:16];
			mem[addr + 3] = value[31:24];
		end
	endtask
endmodule

`default_nettype wire
