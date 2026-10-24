/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_regs: an AXI slave (AXI3 or AXI4, 32-bit data) that turns host
 * accesses into a simple register bus.
 *
 * The register bus:
 *   reg_wr     one cycle per written beat; reg_waddr is the byte offset
 *              (the low ADDR_BITS bits of AWADDR), reg_wdata and reg_wstrb
 *              the beat.
 *   reg_rd     one cycle per read beat with reg_raddr; the target drives
 *              reg_rdata in the next cycle (registered, never waits).
 *
 * The host is expected to make single 32-bit accesses.  A burst does not
 * stall the bus: every beat of it reads or writes the burst's first
 * address (reads are repeated, so a burst read of a register sees it
 * several times).  Every access is answered OKAY.  One write and one read
 * are in progress at a time; the write takes its data after its address.
 * An AXI4-Lite master is connected with s_wlast = 1 and s_arlen = 0.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_regs #(
	parameter ADDR_BITS = 17,
	parameter ID_W = 12,
	parameter LEN_W = 4
) (
	input wire clk,
	input wire rst_n,

	input wire [ADDR_BITS-1:0] s_awaddr,
	input wire [ID_W-1:0] s_awid,
	input wire s_awvalid,
	output wire s_awready,
	input wire [31:0] s_wdata,
	input wire [3:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [ID_W-1:0] s_bid,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [ADDR_BITS-1:0] s_araddr,
	input wire [ID_W-1:0] s_arid,
	input wire [LEN_W-1:0] s_arlen,
	input wire s_arvalid,
	output wire s_arready,
	output wire [31:0] s_rdata,
	output wire [ID_W-1:0] s_rid,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,

	output wire reg_wr,
	output wire [ADDR_BITS-1:0] reg_waddr,
	output wire [31:0] reg_wdata,
	output wire [3:0] reg_wstrb,
	output wire reg_rd,
	output wire [ADDR_BITS-1:0] reg_raddr,
	input wire [31:0] reg_rdata
);
	/* Write channel: one burst at a time, the data after its address. */
	reg aw_full;
	reg [ADDR_BITS-1:0] aw_addr;
	reg [ID_W-1:0] aw_id;
	reg b_valid;
	reg [ID_W-1:0] b_id;
	wire w_fire = s_wvalid && s_wready;

	assign s_awready = rst_n && !aw_full && !b_valid;
	assign s_wready = aw_full;
	assign s_bvalid = b_valid;
	assign s_bid = b_id;
	assign s_bresp = 2'b00;

	assign reg_wr = w_fire;
	assign reg_waddr = aw_addr;
	assign reg_wdata = s_wdata;
	assign reg_wstrb = s_wstrb;

	always @(posedge clk) begin
		if (!rst_n) begin
			aw_full <= 1'b0;
			aw_addr <= {ADDR_BITS{1'b0}};
			aw_id <= {ID_W{1'b0}};
			b_valid <= 1'b0;
			b_id <= {ID_W{1'b0}};
		end else begin
			if (s_awvalid && s_awready) begin
				aw_full <= 1'b1;
				aw_addr <= s_awaddr;
				aw_id <= s_awid;
			end
			if (w_fire && s_wlast) begin
				aw_full <= 1'b0;
				b_valid <= 1'b1;
				b_id <= aw_id;
			end
			if (b_valid && s_bready)
				b_valid <= 1'b0;
		end
	end

	/* Read channel: R_FETCH is the cycle in which the target answers
	 * reg_rd; the beat is then held in R_VALID until it is taken. */
	localparam [1:0] R_IDLE = 2'd0;
	localparam [1:0] R_FETCH = 2'd1;
	localparam [1:0] R_VALID = 2'd2;

	reg [1:0] r_state;
	reg [ADDR_BITS-1:0] r_addr;
	reg [ID_W-1:0] r_id;
	reg [LEN_W-1:0] r_left;
	reg [31:0] r_data;
	wire ar_fire = s_arvalid && s_arready;
	wire r_next = r_state == R_VALID && s_rready && r_left != {LEN_W{1'b0}};

	assign s_arready = rst_n && r_state == R_IDLE;
	assign s_rvalid = r_state == R_VALID;
	assign s_rdata = r_data;
	assign s_rid = r_id;
	assign s_rresp = 2'b00;
	assign s_rlast = r_left == {LEN_W{1'b0}};

	assign reg_rd = ar_fire || r_next;
	assign reg_raddr = ar_fire ? s_araddr : r_addr;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_state <= R_IDLE;
			r_addr <= {ADDR_BITS{1'b0}};
			r_id <= {ID_W{1'b0}};
			r_left <= {LEN_W{1'b0}};
			r_data <= 32'd0;
		end else begin
			case (r_state)
			R_IDLE:
				if (ar_fire) begin
					r_state <= R_FETCH;
					r_addr <= s_araddr;
					r_id <= s_arid;
					r_left <= s_arlen;
				end
			R_FETCH: begin
				r_state <= R_VALID;
				r_data <= reg_rdata;
			end
			R_VALID:
				if (s_rready) begin
					if (r_left == {LEN_W{1'b0}}) begin
						r_state <= R_IDLE;
					end else begin
						r_state <= R_FETCH;
						r_left <= r_left - 1'b1;
					end
				end
			default:
				r_state <= R_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
