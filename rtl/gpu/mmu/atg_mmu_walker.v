/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mmu_walker: 2-level hardware page table walker for 4 KiB paging.
 * Resolves a GPU virtual address (VPN) to a Physical Frame Number (PFN)
 * and permission flags by walking Page Directory (PDE) and Page Table (PTE)
 * entries directly from memory.
 * See spec/gpu/mmu/atg_mmu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mmu_walker #(
	parameter VA_BITS = 32,
	parameter PA_BITS = 32,
	parameter VPN_BITS = VA_BITS - 12,
	parameter PPN_BITS = PA_BITS - 12,
	parameter ENTRY_SHIFT = (PA_BITS > 32) ? 3 : 2
) (
	input wire clk,
	input wire rst_active,

	/* Start request from MMU / L2 TLB miss */
	input wire start_fsm,
	input wire start_meta,
	input wire [3:0] session_id,
	input wire [VPN_BITS-1:0] vpn,
	input wire [1:0] access_type,		/* 0=Read, 1=Write, 2=Exec */
	input wire [PPN_BITS-1:0] root_pt,	/* Root Page Directory base [PA_BITS-1:12] */

	/* Status & Results */
	output wire busy,
	(* max_fanout = 16 *) output reg done,
	(* max_fanout = 16 *) output reg fault,
	(* max_fanout = 16 *) output reg [3:0] fault_kind,		/* 9=Page Fault, 10=Perm Violation */
	(* max_fanout = 16 *) output reg [PPN_BITS-1:0] out_pfn,
	(* max_fanout = 16 *) output reg [5:0] out_flags,

	/* Memory Read Master interface */
	(* max_fanout = 16 *) output reg req_valid,
	(* max_fanout = 16 *) output reg [PA_BITS-1:0] req_addr,
	input wire req_ready,
	input wire rsp_valid,
	input wire [63:0] rsp_data
);
	(* keep = "true" *) wire clk_wlk = clk;
	(* keep = "true" *) wire rst_wlk_int = rst_active;
	localparam [3:0] FAULT_NONE           = 4'd0;
	localparam [3:0] FAULT_PAGE_FAULT     = 4'd9;
	localparam [3:0] FAULT_PERM_VIOLATION = 4'd10;

	localparam [2:0] ST_IDLE     = 3'd0;
	localparam [2:0] ST_READ     = 3'd1;
	localparam [2:0] ST_WAIT     = 3'd2;
	localparam [2:0] ST_DONE     = 3'd5;
	localparam [2:0] ST_FAULT    = 3'd6;

	/* Number of page table walk levels (strictly <= 4 KiB per table):
	 * - PA_BITS <= 32 (4B entries): 2 levels (10 + 10 bits)
	 * - PA_BITS >  32 (8B entries, 9 bits/page): 2 (VA<=30), 3 (VA 31..39), 4 (VA 40) */
	localparam LEVELS = (ENTRY_SHIFT == 2) ? 2 : ((VPN_BITS <= 18) ? 2 : ((VPN_BITS <= 27) ? 3 : 4));
	localparam [1:0] LAST_LVL = (LEVELS == 2) ? 2'd1 : ((LEVELS == 3) ? 2'd2 : 2'd3);

	(* max_fanout = 16 *) reg [2:0] st;
	(* max_fanout = 16 *) reg [1:0] r_lvl;
	(* max_fanout = 16 *) reg [1:0] r_access_type;
	(* max_fanout = 16 *) reg [VPN_BITS-1:0] r_vpn;
	(* max_fanout = 16 *) reg [PPN_BITS-11:0] r_base_hi;
	(* max_fanout = 16 *) reg [9:0]           r_base_lo;
	wire [PPN_BITS-1:0] r_base = {r_base_hi, r_base_lo};

	assign busy = (st != ST_IDLE);

	/* Input register stage for memory response to decouple bus fanout */
	(* max_fanout = 16 *) reg        r_rsp_valid;
	(* max_fanout = 16 *) reg [63:0] r_rsp_data;

	always @(posedge clk_wlk or posedge rst_wlk_int) begin
		if (rst_wlk_int) begin
			r_rsp_valid <= 1'b0;
			r_rsp_data  <= 64'd0;
		end else begin
			r_rsp_valid <= rsp_valid;
			r_rsp_data  <= rsp_data;
		end
	end

	/* 64-bit PTE / 32-bit legacy parsing */
	wire pte_data_is_64 = (PA_BITS > 32);
	wire [63:0] pte_data = pte_data_is_64 ? r_rsp_data : {32'd0, r_rsp_data[31:0]};
	wire pte_v     = pte_data[0];
	wire pte_local = pte_data[1];
	wire pte_w     = pte_data[2];
	wire pte_x     = pte_data[3];
	wire [PPN_BITS-1:0] pte_ppn = pte_data[PPN_BITS+11:12];

	/* PDE parsing */
	wire pde_v = r_rsp_data[0];
	wire [PPN_BITS-1:0] pde_ppn = r_rsp_data[PPN_BITS+11:12];

	/* Zero-padded VPN for uniform slice selection across VA_BITS = 30..40 */
	wire [35:0] vpn_pad   = {{(36-VPN_BITS){1'b0}}, vpn};
	wire [35:0] r_vpn_pad = {{(36-VPN_BITS){1'b0}}, r_vpn};

	/* Level index extraction */
	reg [9:0] top_idx32;
	reg [8:0] cur_idx64;
	always @(*) begin
		top_idx32 = 10'd0;
		cur_idx64 = 9'd0;
		if (ENTRY_SHIFT == 2) begin
			top_idx32 = (st == ST_IDLE) ? vpn_pad[19:10] : r_vpn_pad[9:0];
		end else begin
			if (st == ST_IDLE) begin
				if (LEVELS == 2)
					cur_idx64 = vpn_pad[17:9];
				else if (LEVELS == 3)
					cur_idx64 = vpn_pad[26:18];
				else
					cur_idx64 = vpn_pad[35:27];
			end else begin
				if (LEVELS == 2)
					cur_idx64 = r_vpn_pad[8:0];
				else if (LEVELS == 3)
					cur_idx64 = (r_lvl == 2'd0) ? r_vpn_pad[17:9] : r_vpn_pad[8:0];
				else
					cur_idx64 = (r_lvl == 2'd0) ? r_vpn_pad[26:18] : ((r_lvl == 2'd1) ? r_vpn_pad[17:9] : r_vpn_pad[8:0]);
			end
		end
	end

	wire [PPN_BITS-1:0] addr_base = (st == ST_IDLE) ? root_pt : pde_ppn;
	wire [PA_BITS-1:0] next_req_addr = (ENTRY_SHIFT == 3) ?
		{addr_base, cur_idx64, 3'b000} :
		{addr_base, top_idx32, 2'b00};
	wire is_last_lvl = (r_lvl == LAST_LVL);

	/* Dedicated address register stage with decoupled byte enables (<= 16 fanout) */
	wire ce_req_raw = (st == ST_IDLE && start_fsm) || (st == ST_WAIT && r_rsp_valid && pde_v && !is_last_lvl);
	wire ce_req_hi, ce_req_lo;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'h2)) u_b_ce_hi (.I0(ce_req_raw), .O(ce_req_hi));
	LUT1 #(.INIT(2'h2)) u_b_ce_lo (.I0(ce_req_raw), .O(ce_req_lo));
`else
	assign ce_req_hi = ce_req_raw;
	assign ce_req_lo = ce_req_raw;
`endif

	always @(posedge clk_wlk or posedge rst_wlk_int) begin
		if (rst_wlk_int) begin
			req_addr[PA_BITS-1:16] <= {(PA_BITS-16){1'b0}};
			req_addr[15:0]         <= 16'd0;
		end else begin
			if (ce_req_hi) req_addr[PA_BITS-1:16] <= next_req_addr[PA_BITS-1:16];
			if (ce_req_lo) req_addr[15:0]         <= next_req_addr[15:0];
		end
	end

	/* Dedicated output register stage (<= 20 fanout) */
	(* keep = "true", max_fanout = 16 *) wire ce_out = (st == ST_WAIT && is_last_lvl && r_rsp_valid && pte_v &&
	             !((r_access_type == 2'd1 && !pte_w) || (r_access_type == 2'd2 && !pte_x)));

	always @(posedge clk_wlk or posedge rst_wlk_int) begin
		if (rst_wlk_int) begin
			out_pfn   <= {PPN_BITS{1'b0}};
			out_flags <= 6'd0;
		end else if (ce_out) begin
			out_pfn   <= pte_ppn;
			out_flags <= r_rsp_data[5:0];
		end
	end

	wire [1:0] next_lvl = (r_lvl == 2'd0) ? 2'd1 : ((r_lvl == 2'd1) ? 2'd2 : 2'd3);

	always @(posedge clk_wlk or posedge rst_wlk_int) begin
		if (rst_wlk_int) begin
			done          <= 1'b0;
			fault         <= 1'b0;
			st            <= ST_IDLE;
			r_lvl         <= 2'd0;
			req_valid     <= 1'b0;
			fault_kind    <= FAULT_NONE;
			r_access_type <= 2'd0;
			r_vpn         <= {VPN_BITS{1'b0}};
			r_base_hi     <= {(PPN_BITS-10){1'b0}};
			r_base_lo     <= 10'd0;
		end else begin
			done  <= 1'b0;
			fault <= 1'b0;
			case (st)
			ST_IDLE: begin
				if (start_fsm) begin
					req_valid <= 1'b1;
					r_lvl     <= 2'd0;
					st        <= ST_READ;
				end
				if (start_meta) begin
					r_access_type <= access_type;
					r_vpn         <= vpn;
				end
			end

			ST_READ: begin
				if (req_valid && req_ready) begin
					req_valid <= 1'b0;
					st        <= ST_WAIT;
				end
			end

			ST_WAIT: begin
				if (r_rsp_valid) begin
					if (!is_last_lvl) begin
						if (!pde_v) begin
							fault_kind <= FAULT_PAGE_FAULT;
							st         <= ST_FAULT;
						end else begin
							r_base_hi <= pde_ppn[PPN_BITS-1:10];
							r_base_lo <= pde_ppn[9:0];
							r_lvl     <= next_lvl;
							req_valid <= 1'b1;
							st        <= ST_READ;
						end
					end else begin
						if (!pte_v) begin
							fault_kind <= FAULT_PAGE_FAULT;
							st         <= ST_FAULT;
						end else if ((r_access_type == 2'd1 && !pte_w) ||
						             (r_access_type == 2'd2 && !pte_x)) begin
							fault_kind <= FAULT_PERM_VIOLATION;
							st         <= ST_FAULT;
						end else begin
							st <= ST_DONE;
						end
					end
				end
			end

			ST_DONE: begin
				done <= 1'b1;
				st   <= ST_IDLE;
			end

			ST_FAULT: begin
				fault <= 1'b1;
				st    <= ST_IDLE;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, session_id, pte_local, rsp_data, pte_data, r_base, vpn_pad, r_vpn_pad};
endmodule

`default_nettype wire
