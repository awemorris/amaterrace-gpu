/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_regs: an AXI slave (AXI3 or AXI4, 64-bit data) that turns host
 * accesses into a simple 32-bit register bus.
 *
 * The register bus:
 *   reg_wr     one cycle per written 32-bit beat; reg_waddr is the byte
 *              offset, reg_wdata and reg_wstrb the beat.
 *   reg_rd     one cycle per read 32-bit beat with reg_raddr; the target drives
 *              reg_rdata in the next cycle (registered, never waits).
 *
 * Write behaviour (64-bit AXI):
 *   - Lower 32-bit only (wstrb[3:0] != 0, wstrb[7:4] == 0): 1 cycle write
 *     to address {aw_addr[ADDR_BITS-1:3], 3'b000}.
 *   - Upper 32-bit only (wstrb[3:0] == 0, wstrb[7:4] != 0): 1 cycle write
 *     to address {aw_addr[ADDR_BITS-1:3], 3'b100}.
 *   - Both halves (wstrb[3:0] != 0, wstrb[7:4] != 0): 2 cycle write.
 *     Cycle 0 writes lower 32-bit with s_wready = 0.
 *     Cycle 1 writes upper 32-bit with s_wready = 1.
 *   - No strobe (wstrb == 8'h00): 1 cycle completion without reg_wr.
 *
 * Read behaviour:
 *   - Read with araddr[2] == 1: 1 cycle fetch from {araddr[ADDR_BITS-1:3], 3'b100},
 *     duplicated on both lanes {reg_rdata, reg_rdata}.
 *   - Read with araddr[2] == 0: 2 cycle fetch:
 *     Cycle 0 fetches {araddr[ADDR_BITS-1:3], 3'b000} (lower word).
 *     Cycle 1 fetches {araddr[ADDR_BITS-1:3], 3'b100} (upper word).
 *     Result presented as {upper_word, lower_word}.
 *
 * A burst does not stall the bus: every beat reads or writes the burst's
 * first address. Every access is answered OKAY. One write and one read
 * are in progress at a time.
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
	input wire [63:0] s_wdata,
	input wire [7:0] s_wstrb,
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
	output wire [63:0] s_rdata,
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
	localparam W_IDLE = 1'b0;
	localparam W_UPPER = 1'b1;

	reg w_state;
	reg aw_full;
	reg [ADDR_BITS-1:0] aw_addr;
	reg [ID_W-1:0] aw_id;
	reg b_valid;
	reg [ID_W-1:0] b_id;
	reg [31:0] w_data_hi;
	reg [3:0] w_strb_hi;

	wire w_both = (s_wstrb[3:0] != 4'b0000) && (s_wstrb[7:4] != 4'b0000);
	wire w_hi_only = (s_wstrb[3:0] == 4'b0000) && (s_wstrb[7:4] != 4'b0000);
	wire w_has_strb = (s_wstrb != 8'h00);

	assign s_awready = rst_n && !aw_full && !b_valid && (w_state == W_IDLE);
	assign s_wready = (w_state == W_UPPER) || (aw_full && !w_both);
	assign s_bvalid = b_valid;
	assign s_bid = b_id;
	assign s_bresp = 2'b00;

	reg r_reg_wr;
	reg [ADDR_BITS-1:0] r_reg_waddr;
	reg [31:0] r_reg_wdata;
	reg [3:0] r_reg_wstrb;

	assign reg_wr = r_reg_wr;
	assign reg_waddr = r_reg_waddr;
	assign reg_wdata = r_reg_wdata;
	assign reg_wstrb = r_reg_wstrb;

	always @(*) begin
		if (w_state == W_UPPER) begin
			r_reg_wr = 1'b1;
			r_reg_waddr = {aw_addr[ADDR_BITS-1:3], 3'b100};
			r_reg_wdata = w_data_hi;
			r_reg_wstrb = w_strb_hi;
		end else if (aw_full && s_wvalid) begin
			r_reg_wr = w_has_strb;
			if (w_hi_only) begin
				r_reg_waddr = {aw_addr[ADDR_BITS-1:3], 3'b100};
				r_reg_wdata = s_wdata[63:32];
				r_reg_wstrb = s_wstrb[7:4];
			end else begin
				r_reg_waddr = {aw_addr[ADDR_BITS-1:3], 3'b000};
				r_reg_wdata = s_wdata[31:0];
				r_reg_wstrb = s_wstrb[3:0];
			end
		end else begin
			r_reg_wr = 1'b0;
			r_reg_waddr = {ADDR_BITS{1'b0}};
			r_reg_wdata = 32'd0;
			r_reg_wstrb = 4'd0;
		end
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			aw_full <= 1'b0;
			aw_addr <= {ADDR_BITS{1'b0}};
			aw_id <= {ID_W{1'b0}};
			b_valid <= 1'b0;
			b_id <= {ID_W{1'b0}};
			w_state <= W_IDLE;
			w_data_hi <= 32'd0;
			w_strb_hi <= 4'd0;
		end else begin
			if (s_awvalid && s_awready) begin
				aw_full <= 1'b1;
				aw_addr <= s_awaddr;
				aw_id <= s_awid;
			end
			case (w_state)
			W_IDLE: begin
				if (aw_full && s_wvalid) begin
					if (w_both) begin
						w_state <= W_UPPER;
						w_data_hi <= s_wdata[63:32];
						w_strb_hi <= s_wstrb[7:4];
					end else if (s_wlast) begin
						aw_full <= 1'b0;
						b_valid <= 1'b1;
						b_id <= aw_id;
					end
				end
			end
			W_UPPER: begin
				w_state <= W_IDLE;
				if (s_wlast) begin
					aw_full <= 1'b0;
					b_valid <= 1'b1;
					b_id <= aw_id;
				end
			end
			endcase
			if (b_valid && s_bready)
				b_valid <= 1'b0;
		end
	end

	/* Read channel:
	 *   - araddr[2] == 1: R_FETCH_HI fetches {araddr[ADDR_BITS-1:3], 3'b100}.
	 *   - araddr[2] == 0: R_FETCH_LO fetches lower word 3'b000,
	 *     then R_FETCH_LO_HI fetches upper word 3'b100.
	 */
	localparam [1:0] R_IDLE = 2'd0;
	localparam [1:0] R_FETCH_HI = 2'd1;
	localparam [1:0] R_FETCH_LO = 2'd2;
	localparam [1:0] R_FETCH_LO_HI = 2'd3;

	reg [1:0] r_state;
	reg r_valid;
	reg [ADDR_BITS-1:0] r_addr;
	reg [ID_W-1:0] r_id;
	reg [LEN_W-1:0] r_left;
	reg [63:0] r_data;
	reg [31:0] r_data_lo;

	wire ar_fire = s_arvalid && s_arready;
	wire r_next = r_valid && s_rready && (r_left != {LEN_W{1'b0}});

	assign s_arready = rst_n && (r_state == R_IDLE) && !r_valid;
	assign s_rvalid = r_valid;
	assign s_rdata = r_data;
	assign s_rid = r_id;
	assign s_rresp = 2'b00;
	assign s_rlast = r_left == {LEN_W{1'b0}};

	wire [LEN_W-1:0] r_left_n;
	wire unused_rl_bo;
	am_sub #(.W(LEN_W)) u_r_left (
		.a(r_left), .b({LEN_W{1'b0}}), .bi(1'b1), .d(r_left_n), .bo(unused_rl_bo)
	);

	assign reg_rd = ar_fire || (r_state == R_FETCH_LO) || r_next;
	assign reg_raddr = (r_state == R_FETCH_LO) ? {r_addr[ADDR_BITS-1:3], 3'b100} :
	                   ar_fire ? (s_araddr[2] ? {s_araddr[ADDR_BITS-1:3], 3'b100} : {s_araddr[ADDR_BITS-1:3], 3'b000}) :
	                   (r_addr[2] ? {r_addr[ADDR_BITS-1:3], 3'b100} : {r_addr[ADDR_BITS-1:3], 3'b000});

	always @(posedge clk) begin
		if (!rst_n) begin
			r_state <= R_IDLE;
			r_valid <= 1'b0;
			r_addr <= {ADDR_BITS{1'b0}};
			r_id <= {ID_W{1'b0}};
			r_left <= {LEN_W{1'b0}};
			r_data <= 64'd0;
			r_data_lo <= 32'd0;
		end else begin
			case (r_state)
			R_IDLE: begin
				if (ar_fire) begin
					r_addr <= s_araddr;
					r_id <= s_arid;
					r_left <= s_arlen;
					if (s_araddr[2]) begin
						r_state <= R_FETCH_HI;
					end else begin
						r_state <= R_FETCH_LO;
					end
				end
			end
			R_FETCH_HI: begin
				r_state <= R_IDLE;
				r_valid <= 1'b1;
				r_data <= {reg_rdata, reg_rdata};
			end
			R_FETCH_LO: begin
				r_state <= R_FETCH_LO_HI;
				r_data_lo <= reg_rdata;
			end
			R_FETCH_LO_HI: begin
				r_state <= R_IDLE;
				r_valid <= 1'b1;
				r_data <= {reg_rdata, r_data_lo};
			end
			endcase

			if (r_valid && s_rready) begin
				if (r_left == {LEN_W{1'b0}}) begin
					r_valid <= 1'b0;
				end else begin
					r_left <= r_left_n;
					r_valid <= 1'b0;
					if (r_addr[2]) begin
						r_state <= R_FETCH_HI;
					end else begin
						r_state <= R_FETCH_LO;
					end
				end
			end
		end
	end

	wire unused_ok = &{1'b0, aw_addr[2:0], r_addr[1:0]};
endmodule

`default_nettype wire
