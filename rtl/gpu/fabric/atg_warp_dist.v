/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_warp_dist: K-way pipelined warp distributor for VF (vl_*) and RX (fl_*).
 *
 * Aggregates K child availability signals (c_vl_avail / c_fl_avail) upward
 * through a register stage and routes allocation requests + subsequent setup
 * strobes (vl_we..vl_go / fl_we..fl_go) down to the granted child with strict
 * flop-to-flop boundaries.
 *
 * Once a child subtree asserts c_*_gnt in response to c_*_req, this node locks
 * onto that child until the registered *_go pulse finishes passing downstream.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_warp_dist #(
	parameter K = 4
) (
	input wire clk,
	input wire rst_n,

	/* Upstream VF vertex warp port (from Spine / parent distributor) */
	input wire p_vl_req,
	output reg p_vl_gnt,
	output reg [7:0] p_vl_ptbase,
	output reg p_vl_avail,
	input wire p_vl_we,
	input wire [5:0] p_vl_reg,
	input wire [4:0] p_vl_lane,
	input wire [31:0] p_vl_data,
	input wire p_vl_go,
	input wire [31:0] p_vl_mask,
	input wire [7:0] p_vl_go_ptbase,

	/* Downstream K child VF ports */
	output reg [K-1:0] c_vl_req,
	input wire [K-1:0] c_vl_gnt,
	input wire [K*8-1:0] c_vl_ptbase,
	input wire [K-1:0] c_vl_avail,
	output reg [K-1:0] c_vl_we,
	output reg [5:0] c_vl_reg,
	output reg [4:0] c_vl_lane,
	output reg [31:0] c_vl_data,
	output reg [K-1:0] c_vl_go,
	output reg [31:0] c_vl_mask,
	output reg [7:0] c_vl_go_ptbase,

	/* Upstream RX fragment warp port */
	input wire p_fl_req,
	output reg p_fl_gnt,
	output reg p_fl_avail,
	input wire p_fl_we,
	input wire [5:0] p_fl_reg,
	input wire [4:0] p_fl_lane,
	input wire [31:0] p_fl_data,
	input wire p_fl_pw_we,
	input wire [11:0] p_fl_pw_addr,
	input wire [31:0] p_fl_pw_data,
	input wire p_fl_go,
	input wire [31:0] p_fl_mask,
	input wire [63:0] p_fl_info,

	/* Downstream K child RX ports */
	output reg [K-1:0] c_fl_req,
	input wire [K-1:0] c_fl_gnt,
	input wire [K-1:0] c_fl_avail,
	output reg [K-1:0] c_fl_we,
	output reg [5:0] c_fl_reg,
	output reg [4:0] c_fl_lane,
	output reg [31:0] c_fl_data,
	output reg [K-1:0] c_fl_pw_we,
	output reg [11:0] c_fl_pw_addr,
	output reg [31:0] c_fl_pw_data,
	output reg [K-1:0] c_fl_go,
	output reg [31:0] c_fl_mask,
	output reg [63:0] c_fl_info
);
	localparam KW = (K > 2) ? 2 : 1;

	/* ---- Vertex warp distributor (VF -> SU) ---- */
	localparam [1:0] V_IDLE = 2'd0, V_WAIT_GNT = 2'd1, V_LOCKED = 2'd2;
	reg [1:0]    vl_st;
	reg [KW-1:0] vl_owner, vl_rr;

	reg [KW-1:0] vl_pick;
	reg          vl_any;
	integer      vs, vi;
	always @(*) begin
		vl_pick = {KW{1'b0}};
		vl_any  = 1'b0;
		for (vs = K - 1; vs >= 0; vs = vs - 1) begin
			for (vi = 0; vi < K; vi = vi + 1) begin
				if (vl_rr == vi[KW-1:0] && c_vl_avail[(vi + 1 + vs) % K]) begin
					vl_pick = ((vi + 1 + vs) % K);
					vl_any  = 1'b1;
				end
			end
		end
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			vl_st          <= V_IDLE;
			vl_owner       <= {KW{1'b0}};
			vl_rr          <= {KW{1'b0}};
			p_vl_avail     <= 1'b0;
			p_vl_gnt       <= 1'b0;
			p_vl_ptbase    <= 8'd0;
			c_vl_req       <= {K{1'b0}};
			c_vl_we        <= {K{1'b0}};
			c_vl_reg       <= 6'd0;
			c_vl_lane      <= 5'd0;
			c_vl_data      <= 32'd0;
			c_vl_go        <= {K{1'b0}};
			c_vl_mask      <= 32'd0;
			c_vl_go_ptbase <= 8'd0;
		end else begin
			p_vl_avail <= |c_vl_avail;
			p_vl_gnt   <= 1'b0;
			c_vl_we    <= {K{1'b0}};
			c_vl_go    <= {K{1'b0}};

			/* Pipeline register slice for setup payload */
			c_vl_reg       <= p_vl_reg;
			c_vl_lane      <= p_vl_lane;
			c_vl_data      <= p_vl_data;
			c_vl_mask      <= p_vl_mask;
			c_vl_go_ptbase <= p_vl_go_ptbase;

			case (vl_st)
			V_IDLE: begin
				c_vl_req <= {K{1'b0}};
				if (p_vl_req && vl_any) begin
					vl_owner          <= vl_pick;
					vl_rr             <= vl_pick;
					c_vl_req[vl_pick] <= 1'b1;
					vl_st             <= V_WAIT_GNT;
				end
			end

			V_WAIT_GNT: begin
				if (c_vl_gnt[vl_owner]) begin
					c_vl_req[vl_owner] <= 1'b0;
					p_vl_gnt           <= 1'b1;
					p_vl_ptbase        <= c_vl_ptbase[vl_owner*8 +: 8];
					vl_st              <= V_LOCKED;
				end else if (!p_vl_req) begin
					c_vl_req <= {K{1'b0}};
					vl_st    <= V_IDLE;
				end
			end

			V_LOCKED: begin
				c_vl_we[vl_owner] <= p_vl_we;
				c_vl_go[vl_owner] <= p_vl_go;
				if (p_vl_go)
					vl_st <= V_IDLE;
			end

			default: vl_st <= V_IDLE;
			endcase
		end
	end

	/* ---- Fragment warp distributor (RX -> SU) ---- */
	localparam [1:0] F_IDLE = 2'd0, F_WAIT_GNT = 2'd1, F_LOCKED = 2'd2;
	reg [1:0]    fl_st;
	reg [KW-1:0] fl_owner, fl_rr;

	reg [KW-1:0] fl_pick;
	reg          fl_any;
	integer      fs, fi;
	always @(*) begin
		fl_pick = {KW{1'b0}};
		fl_any  = 1'b0;
		for (fs = K - 1; fs >= 0; fs = fs - 1) begin
			for (fi = 0; fi < K; fi = fi + 1) begin
				if (fl_rr == fi[KW-1:0] && c_fl_avail[(fi + 1 + fs) % K]) begin
					fl_pick = ((fi + 1 + fs) % K);
					fl_any  = 1'b1;
				end
			end
		end
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			fl_st        <= F_IDLE;
			fl_owner     <= {KW{1'b0}};
			fl_rr        <= {KW{1'b0}};
			p_fl_avail   <= 1'b0;
			p_fl_gnt     <= 1'b0;
			c_fl_req     <= {K{1'b0}};
			c_fl_we      <= {K{1'b0}};
			c_fl_reg     <= 6'd0;
			c_fl_lane    <= 5'd0;
			c_fl_data    <= 32'd0;
			c_fl_pw_we   <= {K{1'b0}};
			c_fl_pw_addr <= 12'd0;
			c_fl_pw_data <= 32'd0;
			c_fl_go      <= {K{1'b0}};
			c_fl_mask    <= 32'd0;
			c_fl_info    <= 64'd0;
		end else begin
			p_fl_avail <= |c_fl_avail;
			p_fl_gnt   <= 1'b0;
			c_fl_we    <= {K{1'b0}};
			c_fl_pw_we <= {K{1'b0}};
			c_fl_go    <= {K{1'b0}};

			c_fl_reg     <= p_fl_reg;
			c_fl_lane    <= p_fl_lane;
			c_fl_data    <= p_fl_data;
			c_fl_pw_addr <= p_fl_pw_addr;
			c_fl_pw_data <= p_fl_pw_data;
			c_fl_mask    <= p_fl_mask;
			c_fl_info    <= p_fl_info;

			case (fl_st)
			F_IDLE: begin
				c_fl_req <= {K{1'b0}};
				if (p_fl_req && fl_any) begin
					fl_owner          <= fl_pick;
					fl_rr             <= fl_pick;
					c_fl_req[fl_pick] <= 1'b1;
					fl_st             <= F_WAIT_GNT;
				end
			end

			F_WAIT_GNT: begin
				if (c_fl_gnt[fl_owner]) begin
					c_fl_req[fl_owner] <= 1'b0;
					p_fl_gnt           <= 1'b1;
					fl_st              <= F_LOCKED;
				end else if (!p_fl_req) begin
					c_fl_req <= {K{1'b0}};
					fl_st    <= F_IDLE;
				end
			end

			F_LOCKED: begin
				c_fl_we[fl_owner]    <= p_fl_we;
				c_fl_pw_we[fl_owner] <= p_fl_pw_we;
				c_fl_go[fl_owner]    <= p_fl_go;
				if (p_fl_go)
					fl_st <= F_IDLE;
			end

			default: fl_st <= F_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
