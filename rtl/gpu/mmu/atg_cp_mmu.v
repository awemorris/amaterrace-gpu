/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_mmu: Control-processor sub-bus & fault adapter for atg_mmu.
 *
 * Decodes the CP firmware window sub-bus addresses 0x36..0x3F:
 *   0x36  HW_BOOT_CAPS       (R)   BOOT_CAPS (VA/PA widths, HW_WALKER/PROT bits)
 *   0x37  HW_MMU_FAULT_VA_HI (R)   Faulting GPU VA [VA_BITS-1:32] (0 if <=32)
 *   0x38  HW_MMU_SESSION     (RW)  [3:0] target session for ROOT_PT update
 *   0x39  HW_MMU_ROOT_PT     (W)   [31:0] root PT PPN low (commits root write)
 *   0x3A  HW_MMU_FLUSH       (W)   [0] trigger, [1] all, [7:4] session
 *   0x3B  HW_MMU_INFLIGHT    (R)   [15:0] exact total in-flight bridge count
 *   0x3C  HW_MMU_STATUS      (RW1C) [0] valid, [4:1] kind, [8:5] sess, [12:9] client
 *   0x3D  HW_MMU_FAULT_VA    (R)   Faulting GPU VA [31:0]
 *   0x3E  HW_DEVICE_CAPS     (R)   DEVICE_CAPS
 *   0x3F  HW_MMU_ROOT_PT_HI  (RW)  Upper PPN bits [PPN_BITS-33:0] when PA > 44
 *
 * Also sums the NUM_CLIENTS 8-bit bridge inflight counters via a registered
 * binary am_add tree (Rule 1 <= 1 LUT pre/post) and captures faults from
 * either atg_mmu (walker page/perm fault) or am_mmu_bridge (L1/L2 cached hit
 * perm violation), emitting a registered 1-cycle fault pulse to atg_cp_ctl.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_mmu #(
	parameter VA_BITS = 32,
	parameter PA_BITS = 40,
	parameter PPN_BITS = PA_BITS - 12,
	parameter NUM_CLIENTS = 5,
	parameter FC_W = (NUM_CLIENTS > 8) ? 4 : 3,
	parameter USE_MAP_PORT = 0,
	parameter [NUM_CLIENTS*8-1:0] CLIENT_MC_MAP = {NUM_CLIENTS{8'd0}}
) (
	input wire clk,
	input wire rst_n,

	/* CP firmware window sub-bus */
	input wire sb_we,
	input wire sb_re,
	input wire [5:0] sb_idx,
	input wire [31:0] sb_wdata,
	output reg [31:0] sb_rdata,

	/* Static capabilities exposed to CP firmware */
	input wire [31:0] boot_caps,
	input wire [31:0] device_caps,

	/* Control & flush to atg_mmu */
	output reg cp_pt_root_we,
	output reg [3:0] cp_pt_root_session,
	output reg [PPN_BITS-1:0] cp_pt_root_base,
	output reg cp_flush_trigger,
	output reg cp_flush_all,
	output reg [3:0] cp_flush_session,

	/* Exact per-bridge in-flight counts [7:0] per client */
	input wire [NUM_CLIENTS*8-1:0] bridge_inflight,
	input wire [NUM_CLIENTS*8-1:0] client_mc_map,

	/* Fault from atg_mmu (walker trap) */
	input wire mmu_fault_valid,
	input wire [3:0] mmu_fault_kind,
	input wire [3:0] mmu_fault_session,
	input wire [FC_W-1:0] mmu_fault_client,
	input wire [VA_BITS-1:0] mmu_fault_addr,

	/* Cached-TLB permission fault from am_mmu_bridge instances */
	input wire [NUM_CLIENTS-1:0] brg_fault_valid,
	input wire [NUM_CLIENTS*4-1:0] brg_fault_session,
	input wire [NUM_CLIENTS*VA_BITS-1:0] brg_fault_addr,

	/* Registered fault event to atg_cp_ctl */
	output reg ctl_fault_valid,
	output reg [3:0] ctl_fault_kind,
	output reg [3:0] ctl_fault_session,
	output reg [7:0] ctl_fault_mc_client,
	output reg [VA_BITS-1:0] ctl_fault_addr,

	/* Session active HCR readback when HAS_PROT=0 & HAS_HW_WALKER=1 */
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	input wire fault_session_clear,
	input wire [7:0] fault_session_tag
);
	`include "ghci_regs.vh"
	localparam [5:0] W_BOOT_CAPS       = 6'h36;
	localparam [5:0] W_MMU_FAULT_VA_HI = 6'h37;
	localparam [5:0] W_MMU_SESSION     = 6'h38;
	localparam [5:0] W_MMU_ROOT_PT     = 6'h39;
	localparam [5:0] W_MMU_FLUSH       = 6'h3A;
	localparam [5:0] W_MMU_INFLIGHT    = 6'h3B;
	localparam [5:0] W_MMU_STATUS      = 6'h3C;
	localparam [5:0] W_MMU_FAULT_VA    = 6'h3D;
	localparam [5:0] W_DEVICE_CAPS     = 6'h3E;
	localparam [5:0] W_MMU_ROOT_PT_HI  = 6'h3F;

	localparam [3:0] FAULT_PERM_VIOLATION = 4'd10;

	reg [3:0]  r_session;
	reg [31:0] r_root_hi;
	reg [15:1] r_session_active;

	reg        r_fault_valid;
	reg [3:0]  r_fault_kind;
	reg [3:0]  r_fault_sess;
	reg [3:0]  r_fault_client;
	reg [VA_BITS-1:0] r_fault_addr;

	/* Registered 16-entry binary adder tree for exact inflight_total[15:0] */
	reg [15:0] sum_s0 [0:7];
	reg [15:0] sum_s1 [0:3];
	reg [15:0] sum_s2 [0:1];
	reg [15:0] r_inflight_total;

	wire [15:0] in16 [0:15];
	wire [15:0] add_s0 [0:7];
	wire [15:0] add_s1 [0:3];
	wire [15:0] add_s2 [0:1];
	wire [15:0] add_s3;
	wire [7:0]  co_s0;
	wire [3:0]  co_s1;
	wire [1:0]  co_s2;
	wire        co_s3;

	genvar g;
	generate
		for (g = 0; g < 16; g = g + 1) begin : g_in
			if (g < NUM_CLIENTS) begin : g_live
				assign in16[g] = {8'd0, bridge_inflight[g*8 +: 8]};
			end else begin : g_zero
				assign in16[g] = 16'd0;
			end
		end
		for (g = 0; g < 8; g = g + 1) begin : g_s0
			am_add #(.W(16)) u_a0 (.a(in16[2*g]), .b(in16[2*g+1]), .ci(1'b0), .s(add_s0[g]), .co(co_s0[g]));
		end
		for (g = 0; g < 4; g = g + 1) begin : g_s1
			am_add #(.W(16)) u_a1 (.a(sum_s0[2*g]), .b(sum_s0[2*g+1]), .ci(1'b0), .s(add_s1[g]), .co(co_s1[g]));
		end
		for (g = 0; g < 2; g = g + 1) begin : g_s2
			am_add #(.W(16)) u_a2 (.a(sum_s1[2*g]), .b(sum_s1[2*g+1]), .ci(1'b0), .s(add_s2[g]), .co(co_s2[g]));
		end
	endgenerate
	am_add #(.W(16)) u_a3 (.a(sum_s2[0]), .b(sum_s2[1]), .ci(1'b0), .s(add_s3), .co(co_s3));

	integer k;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			for (k = 0; k < 8; k = k + 1) sum_s0[k] <= 16'd0;
			for (k = 0; k < 4; k = k + 1) sum_s1[k] <= 16'd0;
			for (k = 0; k < 2; k = k + 1) sum_s2[k] <= 16'd0;
			r_inflight_total <= 16'd0;
		end else begin
			for (k = 0; k < 8; k = k + 1) sum_s0[k] <= add_s0[k];
			for (k = 0; k < 4; k = k + 1) sum_s1[k] <= add_s1[k];
			for (k = 0; k < 2; k = k + 1) sum_s2[k] <= add_s2[k];
			r_inflight_total <= add_s3;
		end
	end

	/* Priority select among bridge permission faults (lowest client wins) */
	reg brg_any;
	reg [FC_W-1:0] brg_cid;
	reg [3:0] brg_sess;
	reg [VA_BITS-1:0] brg_addr;
	integer bc;
	always @(*) begin
		brg_any  = 1'b0;
		brg_cid  = {FC_W{1'b0}};
		brg_sess = 4'd0;
		brg_addr = {VA_BITS{1'b0}};
		for (bc = NUM_CLIENTS - 1; bc >= 0; bc = bc - 1) begin
			if (brg_fault_valid[bc]) begin
				brg_any  = 1'b1;
				brg_cid  = bc[FC_W-1:0];
				brg_sess = brg_fault_session[bc*4 +: 4];
				brg_addr = brg_fault_addr[bc*VA_BITS +: VA_BITS];
			end
		end
	end

	wire any_fault = mmu_fault_valid || brg_any;
	wire [3:0]  f_kind   = mmu_fault_valid ? mmu_fault_kind    : FAULT_PERM_VIOLATION;
	wire [3:0]  f_sess   = mmu_fault_valid ? mmu_fault_session : brg_sess;
	wire [FC_W-1:0] f_cl = mmu_fault_valid ? mmu_fault_client  : brg_cid;
	wire [VA_BITS-1:0] f_va = mmu_fault_valid ? mmu_fault_addr : brg_addr;

	reg [7:0] f_mc_client;
	integer mc_i;
	always @(*) begin
		f_mc_client = 8'd0;
		for (mc_i = 0; mc_i < NUM_CLIENTS; mc_i = mc_i + 1) begin
			if (f_cl == mc_i[FC_W-1:0])
				f_mc_client = (USE_MAP_PORT != 0) ? client_mc_map[mc_i*8 +: 8] : CLIENT_MC_MAP[mc_i*8 +: 8];
		end
	end

	wire [7:0] f_cl8 = {{(8-FC_W){1'b0}}, f_cl};
	wire [3:0] f_cl4 = f_cl8[3:0];
	wire [63:0] root_comb64 = {r_root_hi, sb_wdata};

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			r_session           <= 4'd0;
			r_root_hi           <= 32'd0;
			r_session_active    <= 15'd0;
			cp_pt_root_we       <= 1'b0;
			cp_pt_root_session  <= 4'd0;
			cp_pt_root_base     <= {PPN_BITS{1'b0}};
			cp_flush_trigger    <= 1'b0;
			cp_flush_all        <= 1'b0;
			cp_flush_session    <= 4'd0;
			r_fault_valid       <= 1'b0;
			r_fault_kind        <= 4'd0;
			r_fault_sess        <= 4'd0;
			r_fault_client      <= 4'd0;
			r_fault_addr        <= {VA_BITS{1'b0}};
			ctl_fault_valid     <= 1'b0;
			ctl_fault_kind      <= 4'd0;
			ctl_fault_session   <= 4'd0;
			ctl_fault_mc_client <= 8'd0;
			ctl_fault_addr      <= {VA_BITS{1'b0}};
		end else begin
			cp_pt_root_we    <= 1'b0;
			cp_flush_trigger <= 1'b0;
			ctl_fault_valid  <= any_fault;

			if (any_fault) begin
				ctl_fault_kind      <= f_kind;
				ctl_fault_session   <= f_sess;
				ctl_fault_mc_client <= f_mc_client;
				ctl_fault_addr      <= f_va;

				r_fault_valid  <= 1'b1;
				r_fault_kind   <= f_kind;
				r_fault_sess   <= f_sess;
				r_fault_client <= f_cl4;
				r_fault_addr   <= f_va;
			end

			if (fault_session_clear && fault_session_tag[7:4] == 4'd0 && fault_session_tag[3:0] != 4'd0)
				r_session_active[fault_session_tag[3:0]] <= 1'b0;

			if (sb_we) begin
				case (sb_idx)
				W_MMU_SESSION: begin
					if (!sb_wdata[8] && !sb_wdata[9])
						r_session <= sb_wdata[3:0];
					if (sb_wdata[8] && sb_wdata[3:0] != 4'd0)
						r_session_active[sb_wdata[3:0]] <= 1'b1;
					if (sb_wdata[9] && sb_wdata[3:0] != 4'd0)
						r_session_active[sb_wdata[3:0]] <= 1'b0;
				end
				W_MMU_ROOT_PT_HI: r_root_hi <= sb_wdata;
				W_MMU_ROOT_PT: begin
					cp_pt_root_we      <= 1'b1;
					cp_pt_root_session <= r_session;
					cp_pt_root_base    <= root_comb64[PPN_BITS-1:0];
				end
				W_MMU_FLUSH: begin
					cp_flush_trigger <= sb_wdata[0];
					cp_flush_all     <= sb_wdata[1];
					cp_flush_session <= sb_wdata[7:4];
				end
				W_MMU_STATUS: begin
					if (sb_wdata[0] && !any_fault)
						r_fault_valid <= 1'b0;
				end
				default: ;
				endcase
			end
		end
	end

	wire [63:0] fault_va64 = {{(64-VA_BITS){1'b0}}, r_fault_addr};

	always @(*) begin
		sb_rdata = 32'd0;
		if (sb_re) begin
			case (sb_idx)
			W_BOOT_CAPS:       sb_rdata = boot_caps;
			W_MMU_FAULT_VA_HI: sb_rdata = fault_va64[63:32];
			W_MMU_SESSION:     sb_rdata = {28'd0, r_session};
			W_MMU_INFLIGHT:    sb_rdata = {16'd0, r_inflight_total};
			W_MMU_STATUS:      sb_rdata = {19'd0, r_fault_client, r_fault_sess, r_fault_kind, r_fault_valid};
			W_MMU_FAULT_VA:    sb_rdata = fault_va64[31:0];
			W_DEVICE_CAPS:     sb_rdata = device_caps;
			W_MMU_ROOT_PT_HI:  sb_rdata = r_root_hi;
			default:           sb_rdata = 32'd0;
			endcase
		end
	end

	assign hcr_rdata = (hcr_ridx == HCR_IDX_SESSION_ACTIVE) ? {16'd0, r_session_active, 1'b0} : 32'd0;

	wire unused_ok = &{1'b0, co_s0, co_s1, co_s2, co_s3, root_comb64};
endmodule

`default_nettype wire
