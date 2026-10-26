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

module atg_mmu_walker (
	input wire clk,
	input wire rst_n,

	/* Start request from MMU / L2 TLB miss */
	input wire start,
	input wire [3:0] session_id,
	input wire [19:0] vpn,
	input wire [1:0] access_type,		/* 0=Read, 1=Write, 2=Exec */
	input wire [19:0] root_pt,		/* Root Page Directory base [31:12] */

	/* Status & Results */
	output wire busy,
	output reg done,
	output reg fault,
	output reg [3:0] fault_kind,		/* 9=Page Fault, 10=Perm Violation */
	output reg [19:0] out_pfn,
	output reg [5:0] out_flags,

	/* Memory Read Master interface */
	output reg req_valid,
	output reg [31:0] req_addr,
	input wire req_ready,
	input wire rsp_valid,
	input wire [31:0] rsp_data
);
	localparam [3:0] FAULT_NONE           = 4'd0;
	localparam [3:0] FAULT_PAGE_FAULT     = 4'd9;
	localparam [3:0] FAULT_PERM_VIOLATION = 4'd10;

	localparam [2:0] ST_IDLE     = 3'd0;
	localparam [2:0] ST_READ_PDE = 3'd1;
	localparam [2:0] ST_WAIT_PDE = 3'd2;
	localparam [2:0] ST_READ_PTE = 3'd3;
	localparam [2:0] ST_WAIT_PTE = 3'd4;
	localparam [2:0] ST_DONE     = 3'd5;
	localparam [2:0] ST_FAULT    = 3'd6;

	reg [2:0] st;
	reg [1:0] r_access_type;
	reg [9:0] r_pti;
	reg [19:0] r_l2_base;

	assign busy = (st != ST_IDLE);

	/* Address calculations (4 KiB page aligned base + 10-bit index * 4) */
	wire [31:0] pde_addr = {root_pt, vpn[19:10], 2'b00};
	wire [31:0] pte_addr = {r_l2_base, r_pti, 2'b00};

	always @(posedge clk) begin
		done <= 1'b0;
		fault <= 1'b0;
		if (!rst_n) begin
			st            <= ST_IDLE;
			req_valid     <= 1'b0;
			req_addr      <= 32'd0;
			fault_kind    <= FAULT_NONE;
			out_pfn       <= 20'd0;
			out_flags     <= 6'd0;
			r_access_type <= 2'd0;
			r_pti         <= 10'd0;
			r_l2_base     <= 20'd0;
		end else begin
			case (st)
			ST_IDLE: begin
				if (start) begin
					r_access_type <= access_type;
					r_pti         <= vpn[9:0];
					req_valid     <= 1'b1;
					req_addr      <= pde_addr;
					st            <= ST_READ_PDE;
				end
			end

			ST_READ_PDE: begin
				if (req_valid && req_ready) begin
					req_valid <= 1'b0;
					st        <= ST_WAIT_PDE;
				end
			end

			ST_WAIT_PDE: begin
				if (rsp_valid) begin
					if (!rsp_data[0]) begin
						/* Page Directory entry invalid */
						fault_kind <= FAULT_PAGE_FAULT;
						st         <= ST_FAULT;
					end else begin
						/* Valid PDE: fetch PTE */
						r_l2_base <= rsp_data[31:12];
						req_valid <= 1'b1;
						req_addr  <= {rsp_data[31:12], r_pti, 2'b00};
						st        <= ST_READ_PTE;
					end
				end
			end

			ST_READ_PTE: begin
				if (req_valid && req_ready) begin
					req_valid <= 1'b0;
					st        <= ST_WAIT_PTE;
				end
			end

			ST_WAIT_PTE: begin
				if (rsp_valid) begin
					if (!rsp_data[0]) begin
						/* Page Table entry invalid */
						fault_kind <= FAULT_PAGE_FAULT;
						st         <= ST_FAULT;
					end else begin
						/* Check access permissions: [1]=R, [2]=W, [3]=X */
						if ((r_access_type == 2'd0 && !rsp_data[1]) ||
						    (r_access_type == 2'd1 && !rsp_data[2]) ||
						    (r_access_type == 2'd2 && !rsp_data[3])) begin
							fault_kind <= FAULT_PERM_VIOLATION;
							st         <= ST_FAULT;
						end else begin
							out_pfn   <= rsp_data[31:12];
							out_flags <= rsp_data[5:0];
							st        <= ST_DONE;
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

	wire unused_ok = &{1'b0, session_id, pte_addr, rsp_data[11:6]};
endmodule

`default_nettype wire
