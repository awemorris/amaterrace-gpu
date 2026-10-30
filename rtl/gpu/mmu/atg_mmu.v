/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mmu: Memory Management Unit.
 * Translates GPU virtual addresses (VA) to physical addresses (PA).
 * Multi-level TLB architecture with hardware page table walker.
 * Supports multiple client pipelines concurrently (SU, TU, ROP, CP, VDEC).
 * See spec/gpu/mmu/atg_mmu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mmu #(
	parameter NUM_CLIENTS = 5,
	parameter MAX_SESSIONS = 16,
	parameter VA_BITS = 32,
	parameter PA_BITS = 32,
	parameter VPN_BITS = VA_BITS - 12,
	parameter PPN_BITS = PA_BITS - 12,
`ifdef SYNTH_KINTEX7
	parameter REG_CLIENT_OUT = 1
`else
	parameter REG_CLIENT_OUT = 0
`endif
) (
	input wire clk,
	input wire rst_n,

	/* Translation Client Interfaces (per-client request/ack) */
	input  wire [NUM_CLIENTS-1:0]         client_req_valid,
	input  wire [NUM_CLIENTS*4-1:0]       client_req_session,
	input  wire [NUM_CLIENTS*VA_BITS-1:0] client_req_va,
	input  wire [NUM_CLIENTS*2-1:0]       client_req_type,
	output reg  [NUM_CLIENTS-1:0]         client_ack,
	output reg  [NUM_CLIENTS*PA_BITS-1:0] client_pa,
	output reg  [NUM_CLIENTS*6-1:0]       client_flags,
	output reg  [NUM_CLIENTS-1:0]         client_fault,

	/* In-flight transaction counter monitoring (for cache/barrier flush) */
	input  wire        mem_req_fire,
	input  wire        mem_rsp_fire,
	output wire [15:0] inflight_count,

	/* Host / Control Processor Management Interface */
	input wire        cp_pt_root_we,
	input wire [3:0]  cp_pt_root_session,
	input wire [PPN_BITS-1:0] cp_pt_root_base,

	input wire        cp_flush_trigger,
	input wire        cp_flush_all,
	input wire [3:0]  cp_flush_session,

	/* Fault reporting to CP / Host */
	(* max_fanout = 16 *) output reg                fault_valid,
	(* max_fanout = 16 *) output reg [3:0]          fault_kind,
	(* max_fanout = 16 *) output reg [3:0]          fault_session,
	(* max_fanout = 16 *) output reg [2:0]          fault_client,
	(* max_fanout = 16 *) output reg [VA_BITS-1:0]  fault_addr,

	/* Walker Memory Read Master interface (to MC) */
	output wire               walker_mem_req_valid,
	output wire [PA_BITS-1:0] walker_mem_req_addr,
	input  wire               walker_mem_req_ready,
	input  wire               walker_mem_rsp_valid,
	input  wire [63:0]        walker_mem_rsp_data
);
	/* Clock buffer under Kintex-7 to mark clock tree as GLOBAL_CLOCK */
`ifdef SYNTH_KINTEX7
	wire clk_bufg;
	BUFG u_clk_bufg (.I(clk), .O(clk_bufg));
	(* keep = "true" *) wire clk_mmu = clk_bufg;
`else
	(* keep = "true" *) wire clk_mmu = clk;
`endif
`ifdef SYNTH_KINTEX7
	wire rst_inv;
	LUT1 #(.INIT(2'h1)) u_rst_inv (.I0(rst_n), .O(rst_inv));
	wire rst_global = rst_inv;
	wire rst_mmu_int = rst_inv;
`else
	wire rst_global = ~rst_n;
	wire rst_mmu_int = rst_global;
`endif
	wire rst_active = rst_mmu_int;

	/* Buffered input client valid signals to control input port fanout */
	(* keep = "true", max_fanout = 16 *) wire [NUM_CLIENTS-1:0] req_valid_buf = client_req_valid;

	/* Session Root Page Directory Base Table [PA_BITS-1:12] */
	reg [PPN_BITS-1:0] session_root_pt [0:MAX_SESSIONS-1];

	integer s;
	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			for (s = 0; s < MAX_SESSIONS; s = s + 1)
				session_root_pt[s] <= {PPN_BITS{1'b0}};
		end else if (cp_pt_root_we) begin
			session_root_pt[cp_pt_root_session] <= cp_pt_root_base;
		end
	end

	/* In-flight transaction counter (clean single CARRY4 addsub, <= 1 LUT pre/post) */
	(* max_fanout = 16 *) reg [15:0] r_inflight;
	wire if_en  = mem_req_fire ^ mem_rsp_fire;
	wire if_sub = mem_rsp_fire;
	wire [15:0] next_inflight;
	wire if_co_unused;

	am_addsub #(.W(16), .USE_DSP(0)) u_if_addsub (
		.a(r_inflight),
		.b(16'd1),
		.sub(if_sub),
		.s(next_inflight),
		.co(if_co_unused)
	);

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			r_inflight <= 16'd0;
		end else if (if_en) begin
			r_inflight <= next_inflight;
		end
	end
	assign inflight_count = r_inflight;

	/* Active client registers */
	reg [2:0]          active_client;
	reg [3:0]          active_session;
	reg [VPN_BITS-1:0] active_vpn;
	reg [11:0]         active_offset;
	reg [1:0]          active_type;

	/* Destination-specific session and VPN registers to decouple fanout */
	(* dont_touch = "true" *) reg [3:0]          l1_ref_sess_c0, l1_ref_sess_c1, l1_ref_sess_c2, l1_ref_sess_c3, l1_ref_sess_c4;
	(* dont_touch = "true" *) reg [3:0]          l2_ref_sess;
	(* dont_touch = "true" *) reg [3:0]          wlk_session;
	(* dont_touch = "true" *) reg [3:0]          l2_lk_session;

	(* dont_touch = "true" *) reg [VPN_BITS-1:0] l1_ref_vpn_c0, l1_ref_vpn_c1, l1_ref_vpn_c2, l1_ref_vpn_c3, l1_ref_vpn_c4;
	(* dont_touch = "true" *) reg [VPN_BITS-1:0] l2_ref_vpn;
	(* dont_touch = "true" *) reg [VPN_BITS-1:0] wlk_vpn;
	(* dont_touch = "true" *) reg [VPN_BITS-1:0] flt_vpn;

	/* Registered flush signals to break high input port fanout */
	(* max_fanout = 16 *) reg [3:0] r_flush_sess;
	(* max_fanout = 16 *) reg       r_flush_trig;
	(* max_fanout = 16 *) reg       r_flush_all;

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			r_flush_sess <= 4'd0;
			r_flush_trig <= 1'b0;
			r_flush_all  <= 1'b0;
		end else begin
			r_flush_sess <= cp_flush_session;
			r_flush_trig <= cp_flush_trigger;
			r_flush_all  <= cp_flush_all;
		end
	end

	/* Replicated state decode registers per client to isolate state fanout */
	(* dont_touch = "true" *) reg st_is_refill_c0, st_is_refill_c1, st_is_refill_c2, st_is_refill_c3, st_is_refill_c4;
	(* dont_touch = "true" *) reg st_is_idle_c0,   st_is_idle_c1,   st_is_idle_c2,   st_is_idle_c3,   st_is_idle_c4;
	wire [NUM_CLIENTS-1:0] st_is_refill_c = {st_is_refill_c4, st_is_refill_c3, st_is_refill_c2, st_is_refill_c1, st_is_refill_c0};
	wire [NUM_CLIENTS-1:0] st_is_idle_c   = {st_is_idle_c4,   st_is_idle_c3,   st_is_idle_c2,   st_is_idle_c1,   st_is_idle_c0};

	/* Per-client L1 TLBs */
	wire [NUM_CLIENTS-1:0]          l1_hit;
	wire [NUM_CLIENTS-1:0]          l1_miss;
	wire [NUM_CLIENTS-1:0]          l1_hit_w1;
	wire [NUM_CLIENTS*PPN_BITS-1:0] l1_hit_pfn;
	wire [NUM_CLIENTS*6-1:0]        l1_hit_flags;
	wire [NUM_CLIENTS*PPN_BITS-1:0] l1_pfn_w0;
	wire [NUM_CLIENTS*PPN_BITS-1:0] l1_pfn_w1;
	wire [NUM_CLIENTS*6-1:0]        l1_flags_w0;
	wire [NUM_CLIENTS*6-1:0]        l1_flags_w1;
	(* max_fanout = 16 *) reg [NUM_CLIENTS-1:0] l1_refill_we;
	wire [PPN_BITS-1:0]    l1_refill_pfn;
	wire [5:0]             l1_refill_flags;

	genvar gc;
	generate
	for (gc = 0; gc < NUM_CLIENTS; gc = gc + 1) begin : g_l1
		wire [3:0]          c_sess = client_req_session[gc*4 +: 4];
		wire [VPN_BITS-1:0] c_vpn  = client_req_va[gc*VA_BITS + 12 +: VPN_BITS];
		wire                cl_req_val = req_valid_buf[gc] & st_is_idle_c[gc];

`ifdef SYNTH_KINTEX7
		wire [2:0] c_set_pfn_lo;
		wire [2:0] c_set_pfn_hi;
		wire [2:0] c_set_flg;
		wire [2:0] c_set_hit;
		LUT1 #(.INIT(2'h2)) u_b_pfn_lo_0 (.I0(client_req_va[gc*VA_BITS+12]), .O(c_set_pfn_lo[0]));
		LUT1 #(.INIT(2'h2)) u_b_pfn_lo_1 (.I0(client_req_va[gc*VA_BITS+13]), .O(c_set_pfn_lo[1]));
		LUT1 #(.INIT(2'h2)) u_b_pfn_lo_2 (.I0(client_req_va[gc*VA_BITS+14]), .O(c_set_pfn_lo[2]));
		LUT1 #(.INIT(2'h2)) u_b_pfn_hi_0 (.I0(client_req_va[gc*VA_BITS+12]), .O(c_set_pfn_hi[0]));
		LUT1 #(.INIT(2'h2)) u_b_pfn_hi_1 (.I0(client_req_va[gc*VA_BITS+13]), .O(c_set_pfn_hi[1]));
		LUT1 #(.INIT(2'h2)) u_b_pfn_hi_2 (.I0(client_req_va[gc*VA_BITS+14]), .O(c_set_pfn_hi[2]));
		LUT1 #(.INIT(2'h2)) u_b_flg_0    (.I0(client_req_va[gc*VA_BITS+12]), .O(c_set_flg[0]));
		LUT1 #(.INIT(2'h2)) u_b_flg_1    (.I0(client_req_va[gc*VA_BITS+13]), .O(c_set_flg[1]));
		LUT1 #(.INIT(2'h2)) u_b_flg_2    (.I0(client_req_va[gc*VA_BITS+14]), .O(c_set_flg[2]));
		LUT1 #(.INIT(2'h2)) u_b_hit_0    (.I0(client_req_va[gc*VA_BITS+12]), .O(c_set_hit[0]));
		LUT1 #(.INIT(2'h2)) u_b_hit_1    (.I0(client_req_va[gc*VA_BITS+13]), .O(c_set_hit[1]));
		LUT1 #(.INIT(2'h2)) u_b_hit_2    (.I0(client_req_va[gc*VA_BITS+14]), .O(c_set_hit[2]));
`else
		wire [2:0] c_set_pfn_lo = client_req_va[gc*VA_BITS+12 +: 3];
		wire [2:0] c_set_pfn_hi = client_req_va[gc*VA_BITS+12 +: 3];
		wire [2:0] c_set_flg    = client_req_va[gc*VA_BITS+12 +: 3];
		wire [2:0] c_set_hit    = client_req_va[gc*VA_BITS+12 +: 3];
`endif

		wire [VPN_BITS-1:0] c_ref_vpn = (gc == 0) ? l1_ref_vpn_c0 :
		                                (gc == 1) ? l1_ref_vpn_c1 :
		                                (gc == 2) ? l1_ref_vpn_c2 :
		                                (gc == 3) ? l1_ref_vpn_c3 : l1_ref_vpn_c4;
		wire [3:0] c_ref_sess = (gc == 0) ? l1_ref_sess_c0 :
		                        (gc == 1) ? l1_ref_sess_c1 :
		                        (gc == 2) ? l1_ref_sess_c2 :
		                        (gc == 3) ? l1_ref_sess_c3 : l1_ref_sess_c4;
		wire [PPN_BITS-1:0] c_ref_pfn = (gc == 0) ? r_refill_pfn_c0 :
		                                (gc == 1) ? r_refill_pfn_c1 :
		                                (gc == 2) ? r_refill_pfn_c2 :
		                                (gc == 3) ? r_refill_pfn_c3 : r_refill_pfn_c4;
		wire [5:0] c_ref_flg = (gc == 0) ? r_refill_flags_c0 :
		                       (gc == 1) ? r_refill_flags_c1 :
		                       (gc == 2) ? r_refill_flags_c2 :
		                       (gc == 3) ? r_refill_flags_c3 : r_refill_flags_c4;

		atg_tlb_l1 #(
			.ENTRIES(16),
			.VA_BITS(VA_BITS),
			.PA_BITS(PA_BITS)
		) u_l1 (
			.clk(clk_mmu),
			.rst_active(rst_global),
			.flush_trigger(r_flush_trig),
			.flush_all(r_flush_all),
			.flush_session(r_flush_sess),
			.req_valid(cl_req_val),
			.req_session(c_sess),
			.req_vpn(c_vpn),
			.req_set_pfn_lo(c_set_pfn_lo),
			.req_set_pfn_hi(c_set_pfn_hi),
			.req_set_flg(c_set_flg),
			.req_set_hit(c_set_hit),
			.hit(l1_hit[gc]),
			.miss(l1_miss[gc]),
			.hit_pfn(l1_hit_pfn[gc*PPN_BITS +: PPN_BITS]),
			.hit_flags(l1_hit_flags[gc*6 +: 6]),
			.hit_w1(l1_hit_w1[gc]),
			.pfn_w0(l1_pfn_w0[gc*PPN_BITS +: PPN_BITS]),
			.pfn_w1(l1_pfn_w1[gc*PPN_BITS +: PPN_BITS]),
			.flags_w0(l1_flags_w0[gc*6 +: 6]),
			.flags_w1(l1_flags_w1[gc*6 +: 6]),
			.refill_we(l1_refill_we[gc]),
			.refill_session(c_ref_sess),
			.refill_vpn(c_ref_vpn),
			.refill_pfn(c_ref_pfn),
			.refill_flags(c_ref_flg)
		);
	end
	endgenerate

	/* Dedicated L2 write address registers per slice (fanout <= 15 per net) */
	(* dont_touch = "true" *) reg [5:0] l2_ref_w0_vpn_a, l2_ref_w0_vpn_b, l2_ref_w0_vpn_c;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w0_pfn_a, l2_ref_w0_pfn_b, l2_ref_w0_pfn_c, l2_ref_w0_pfn_d;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w0_flg_a, l2_ref_w0_flg_b;

	(* dont_touch = "true" *) reg [5:0] l2_ref_w1_vpn_a, l2_ref_w1_vpn_b, l2_ref_w1_vpn_c;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w1_pfn_a, l2_ref_w1_pfn_b, l2_ref_w1_pfn_c, l2_ref_w1_pfn_d;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w1_flg_a, l2_ref_w1_flg_b;

	(* dont_touch = "true" *) reg [5:0] l2_ref_w2_vpn_a, l2_ref_w2_vpn_b, l2_ref_w2_vpn_c;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w2_pfn_a, l2_ref_w2_pfn_b, l2_ref_w2_pfn_c, l2_ref_w2_pfn_d;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w2_flg_a, l2_ref_w2_flg_b;

	(* dont_touch = "true" *) reg [5:0] l2_ref_w3_vpn_a, l2_ref_w3_vpn_b, l2_ref_w3_vpn_c;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w3_pfn_a, l2_ref_w3_pfn_b, l2_ref_w3_pfn_c, l2_ref_w3_pfn_d;
	(* dont_touch = "true" *) reg [5:0] l2_ref_w3_flg_a, l2_ref_w3_flg_b;

	/* Dedicated L2 lookup set registers (fanout <= 14 per net) */
	(* dont_touch = "true" *) reg [5:0] l2_lookup_set_w0_vpn, l2_lookup_set_w0_pfn_lo, l2_lookup_set_w0_pfn_hi, l2_lookup_set_w0_flg, l2_lookup_set_w0_sl;
	(* dont_touch = "true" *) reg [5:0] l2_lookup_set_w1_vpn, l2_lookup_set_w1_pfn_lo, l2_lookup_set_w1_pfn_hi, l2_lookup_set_w1_flg, l2_lookup_set_w1_sl;
	(* dont_touch = "true" *) reg [5:0] l2_lookup_set_w2_vpn, l2_lookup_set_w2_pfn_lo, l2_lookup_set_w2_pfn_hi, l2_lookup_set_w2_flg, l2_lookup_set_w2_sl;
	(* dont_touch = "true" *) reg [5:0] l2_lookup_set_w3_vpn, l2_lookup_set_w3_pfn_lo, l2_lookup_set_w3_pfn_hi, l2_lookup_set_w3_flg, l2_lookup_set_w3_sl;

	/* Replicated L1 refill signals per client to strictly limit fanout <= 16 */
	(* dont_touch = "true" *) reg [PPN_BITS-1:0] r_refill_pfn_c0, r_refill_pfn_c1, r_refill_pfn_c2, r_refill_pfn_c3, r_refill_pfn_c4;
	(* dont_touch = "true" *) reg [5:0]          r_refill_flags_c0, r_refill_flags_c1, r_refill_flags_c2, r_refill_flags_c3, r_refill_flags_c4;

	/* Dedicated L2 refill signals */
	(* dont_touch = "true" *) reg [PPN_BITS-1:0] r_refill_pfn_l2;
	(* dont_touch = "true" *) reg [5:0]          r_refill_flags_l2;

	/* Shared L2 TLB (Hit latency: 2 clock cycles) */
	reg                l2_lookup_valid;
	reg  [3:0]         l2_lookup_session;
	reg [VPN_BITS-1:0] l2_lookup_vpn;
	wire               l2_hit;
	wire [PPN_BITS-1:0] l2_hit_pfn;
	wire [5:0]         l2_hit_flags;

	(* dont_touch = "true" *) reg l2_refill_we_w0, l2_refill_we_w1, l2_refill_we_w2, l2_refill_we_w3;
	(* dont_touch = "true" *) reg l2_refill_we_sl0, l2_refill_we_sl1, l2_refill_we_sl2, l2_refill_we_sl3;

	atg_tlb_l2 #(
		.SETS(64),
		.VA_BITS(VA_BITS),
		.PA_BITS(PA_BITS)
	) u_l2 (
		.clk(clk_mmu),
		.rst_active(rst_global),
		.flush_trigger(r_flush_trig),
		.flush_all(r_flush_all),
		.flush_session(r_flush_sess),
		.lookup_valid(l2_lookup_valid),
		.lookup_session(l2_lk_session),
		.lookup_vpn(l2_lookup_vpn),
		.lookup_set_w0_vpn(l2_lookup_set_w0_vpn),
		.lookup_set_w0_pfn_lo(l2_lookup_set_w0_pfn_lo),
		.lookup_set_w0_pfn_hi(l2_lookup_set_w0_pfn_hi),
		.lookup_set_w0_flg(l2_lookup_set_w0_flg),
		.lookup_set_w0_sl(l2_lookup_set_w0_sl),
		.lookup_set_w1_vpn(l2_lookup_set_w1_vpn),
		.lookup_set_w1_pfn_lo(l2_lookup_set_w1_pfn_lo),
		.lookup_set_w1_pfn_hi(l2_lookup_set_w1_pfn_hi),
		.lookup_set_w1_flg(l2_lookup_set_w1_flg),
		.lookup_set_w1_sl(l2_lookup_set_w1_sl),
		.lookup_set_w2_vpn(l2_lookup_set_w2_vpn),
		.lookup_set_w2_pfn_lo(l2_lookup_set_w2_pfn_lo),
		.lookup_set_w2_pfn_hi(l2_lookup_set_w2_pfn_hi),
		.lookup_set_w2_flg(l2_lookup_set_w2_flg),
		.lookup_set_w2_sl(l2_lookup_set_w2_sl),
		.lookup_set_w3_vpn(l2_lookup_set_w3_vpn),
		.lookup_set_w3_pfn_lo(l2_lookup_set_w3_pfn_lo),
		.lookup_set_w3_pfn_hi(l2_lookup_set_w3_pfn_hi),
		.lookup_set_w3_flg(l2_lookup_set_w3_flg),
		.lookup_set_w3_sl(l2_lookup_set_w3_sl),
		.hit(l2_hit),
		.hit_pfn(l2_hit_pfn),
		.hit_flags(l2_hit_flags),
		.refill_we_w0(l2_refill_we_w0),
		.refill_we_w1(l2_refill_we_w1),
		.refill_we_w2(l2_refill_we_w2),
		.refill_we_w3(l2_refill_we_w3),
		.refill_we_sl0(l2_refill_we_sl0),
		.refill_we_sl1(l2_refill_we_sl1),
		.refill_we_sl2(l2_refill_we_sl2),
		.refill_we_sl3(l2_refill_we_sl3),
		.refill_session(l2_ref_sess),
		.refill_vpn(l2_ref_vpn),
		.refill_set_w0_vpn_a(l2_ref_w0_vpn_a),
		.refill_set_w0_vpn_b(l2_ref_w0_vpn_b),
		.refill_set_w0_vpn_c(l2_ref_w0_vpn_c),
		.refill_set_w0_pfn_a(l2_ref_w0_pfn_a),
		.refill_set_w0_pfn_b(l2_ref_w0_pfn_b),
		.refill_set_w0_pfn_c(l2_ref_w0_pfn_c),
		.refill_set_w0_pfn_d(l2_ref_w0_pfn_d),
		.refill_set_w0_flg_a(l2_ref_w0_flg_a),
		.refill_set_w0_flg_b(l2_ref_w0_flg_b),
		.refill_set_w1_vpn_a(l2_ref_w1_vpn_a),
		.refill_set_w1_vpn_b(l2_ref_w1_vpn_b),
		.refill_set_w1_vpn_c(l2_ref_w1_vpn_c),
		.refill_set_w1_pfn_a(l2_ref_w1_pfn_a),
		.refill_set_w1_pfn_b(l2_ref_w1_pfn_b),
		.refill_set_w1_pfn_c(l2_ref_w1_pfn_c),
		.refill_set_w1_pfn_d(l2_ref_w1_pfn_d),
		.refill_set_w1_flg_a(l2_ref_w1_flg_a),
		.refill_set_w1_flg_b(l2_ref_w1_flg_b),
		.refill_set_w2_vpn_a(l2_ref_w2_vpn_a),
		.refill_set_w2_vpn_b(l2_ref_w2_vpn_b),
		.refill_set_w2_vpn_c(l2_ref_w2_vpn_c),
		.refill_set_w2_pfn_a(l2_ref_w2_pfn_a),
		.refill_set_w2_pfn_b(l2_ref_w2_pfn_b),
		.refill_set_w2_pfn_c(l2_ref_w2_pfn_c),
		.refill_set_w2_pfn_d(l2_ref_w2_pfn_d),
		.refill_set_w2_flg_a(l2_ref_w2_flg_a),
		.refill_set_w2_flg_b(l2_ref_w2_flg_b),
		.refill_set_w3_vpn_a(l2_ref_w3_vpn_a),
		.refill_set_w3_vpn_b(l2_ref_w3_vpn_b),
		.refill_set_w3_vpn_c(l2_ref_w3_vpn_c),
		.refill_set_w3_pfn_a(l2_ref_w3_pfn_a),
		.refill_set_w3_pfn_b(l2_ref_w3_pfn_b),
		.refill_set_w3_pfn_c(l2_ref_w3_pfn_c),
		.refill_set_w3_pfn_d(l2_ref_w3_pfn_d),
		.refill_set_w3_flg_a(l2_ref_w3_flg_a),
		.refill_set_w3_flg_b(l2_ref_w3_flg_b),
		.refill_pfn(r_refill_pfn_l2),
		.refill_flags(r_refill_flags_l2)
	);

	/* Hardware Page Table Walker */
	(* max_fanout = 16 *) reg walker_start_fsm;
	(* max_fanout = 16 *) reg walker_start_meta;
	wire               walker_busy;
	wire               walker_done;
	wire               walker_fault;
	wire [3:0]         walker_fault_kind;
	wire [PPN_BITS-1:0] walker_out_pfn;
	wire [5:0]         walker_out_flags;

	/* Decoupled session root table read multiplexers (<= 20 fanout per select bit) */
	wire [3:0] wlk_sess_g0, wlk_sess_g1, wlk_sess_g2, wlk_sess_g3;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'h2)) u_b_ws0_0 (.I0(wlk_session[0]), .O(wlk_sess_g0[0]));
	LUT1 #(.INIT(2'h2)) u_b_ws0_1 (.I0(wlk_session[1]), .O(wlk_sess_g0[1]));
	LUT1 #(.INIT(2'h2)) u_b_ws0_2 (.I0(wlk_session[2]), .O(wlk_sess_g0[2]));
	LUT1 #(.INIT(2'h2)) u_b_ws0_3 (.I0(wlk_session[3]), .O(wlk_sess_g0[3]));

	LUT1 #(.INIT(2'h2)) u_b_ws1_0 (.I0(wlk_session[0]), .O(wlk_sess_g1[0]));
	LUT1 #(.INIT(2'h2)) u_b_ws1_1 (.I0(wlk_session[1]), .O(wlk_sess_g1[1]));
	LUT1 #(.INIT(2'h2)) u_b_ws1_2 (.I0(wlk_session[2]), .O(wlk_sess_g1[2]));
	LUT1 #(.INIT(2'h2)) u_b_ws1_3 (.I0(wlk_session[3]), .O(wlk_sess_g1[3]));

	LUT1 #(.INIT(2'h2)) u_b_ws2_0 (.I0(wlk_session[0]), .O(wlk_sess_g2[0]));
	LUT1 #(.INIT(2'h2)) u_b_ws2_1 (.I0(wlk_session[1]), .O(wlk_sess_g2[1]));
	LUT1 #(.INIT(2'h2)) u_b_ws2_2 (.I0(wlk_session[2]), .O(wlk_sess_g2[2]));
	LUT1 #(.INIT(2'h2)) u_b_ws2_3 (.I0(wlk_session[3]), .O(wlk_sess_g2[3]));

	LUT1 #(.INIT(2'h2)) u_b_ws3_0 (.I0(wlk_session[0]), .O(wlk_sess_g3[0]));
	LUT1 #(.INIT(2'h2)) u_b_ws3_1 (.I0(wlk_session[1]), .O(wlk_sess_g3[1]));
	LUT1 #(.INIT(2'h2)) u_b_ws3_2 (.I0(wlk_session[2]), .O(wlk_sess_g3[2]));
	LUT1 #(.INIT(2'h2)) u_b_ws3_3 (.I0(wlk_session[3]), .O(wlk_sess_g3[3]));
`else
	assign wlk_sess_g0 = wlk_session;
	assign wlk_sess_g1 = wlk_session;
	assign wlk_sess_g2 = wlk_session;
	assign wlk_sess_g3 = wlk_session;
`endif

	wire [PPN_BITS-1:0] root_pt_g0 = session_root_pt[wlk_sess_g0];
	wire [PPN_BITS-1:0] root_pt_g1 = session_root_pt[wlk_sess_g1];
	wire [PPN_BITS-1:0] root_pt_g2 = session_root_pt[wlk_sess_g2];
	wire [PPN_BITS-1:0] root_pt_g3 = session_root_pt[wlk_sess_g3];
	wire [PPN_BITS-1:0] walker_root_pt = {root_pt_g3[19:15], root_pt_g2[14:10], root_pt_g1[9:5], root_pt_g0[4:0]};

	atg_mmu_walker #(
		.VA_BITS(VA_BITS),
		.PA_BITS(PA_BITS)
	) u_walker (
		.clk(clk_mmu),
		.rst_active(rst_global),
		.start_fsm(walker_start_fsm),
		.start_meta(walker_start_meta),
		.session_id(wlk_session),
		.vpn(wlk_vpn),
		.access_type(active_type),
		.root_pt(walker_root_pt),
		.busy(walker_busy),
		.done(walker_done),
		.fault(walker_fault),
		.fault_kind(walker_fault_kind),
		.out_pfn(walker_out_pfn),
		.out_flags(walker_out_flags),
		.req_valid(walker_mem_req_valid),
		.req_addr(walker_mem_req_addr),
		.req_ready(walker_mem_req_ready),
		.rsp_valid(walker_mem_rsp_valid),
		.rsp_data(walker_mem_rsp_data)
	);

	/* MMU State Machine */
	localparam [2:0] S_IDLE     = 3'd0;
	localparam [2:0] S_L2_LOOKUP= 3'd1;
	localparam [2:0] S_L2_WAIT  = 3'd4;
	localparam [2:0] S_L2_WAIT2 = 3'd6;
	localparam [2:0] S_L2_CHECK = 3'd5;
	localparam [2:0] S_WALK     = 3'd2;
	localparam [2:0] S_REFILL   = 3'd3;

	(* max_fanout = 16 *) reg [2:0]          state;
	(* max_fanout = 16 *) reg                r_refill_fault;
	(* max_fanout = 16 *) reg [PPN_BITS-1:0] r_refill_pfn;
	(* max_fanout = 16 *) reg [5:0]          r_refill_flags;
	assign l1_refill_pfn   = r_refill_pfn;
	assign l1_refill_flags = r_refill_flags;

	/* Registered output registers (used in ASIC synthesis for zero feedthrough) */
	(* max_fanout = 16 *) reg [NUM_CLIENTS-1:0]         r_client_ack;
	(* max_fanout = 16 *) reg [NUM_CLIENTS-1:0]         r_client_fault;
	(* max_fanout = 16 *) reg [NUM_CLIENTS*PA_BITS-1:0] r_client_pa;
	(* max_fanout = 16 *) reg [NUM_CLIENTS*6-1:0]       r_client_flags;

	genvar gout;
	generate
	for (gout = 0; gout < NUM_CLIENTS; gout = gout + 1) begin : g_client_out
		(* dont_touch = "true" *) wire refill_now_hi  = st_is_refill_c[gout] & (active_client == gout[2:0]);
		(* dont_touch = "true" *) wire refill_now_lo  = st_is_refill_c[gout] & (active_client == gout[2:0]);
		(* dont_touch = "true" *) wire refill_now_flg = st_is_refill_c[gout] & (active_client == gout[2:0]);
		(* dont_touch = "true" *) wire refill_now_ctl = st_is_refill_c[gout] & (active_client == gout[2:0]);

		reg [PA_BITS-1:16] r_l1_pa_w0_hi;
		reg [15:0]         r_l1_pa_w0_lo;
		reg [5:0]          r_l1_flg_w0;
		reg [PA_BITS-1:16] r_l1_pa_w1_hi;
		reg [15:0]         r_l1_pa_w1_lo;
		reg [5:0]          r_l1_flg_w1;
		(* dont_touch = "true" *) reg r_l1_hit_w1_pa;
		(* dont_touch = "true" *) reg r_l1_hit_w1_flg;
		reg [PA_BITS-1:16] r_ref_pa_hi;
		reg [15:0]         r_ref_pa_lo;
		reg [5:0]          r_ref_flg;

		(* dont_touch = "true" *) reg r_is_refill_hi;
		(* dont_touch = "true" *) reg r_is_refill_lo;
		(* dont_touch = "true" *) reg r_is_refill_flg;

		(* dont_touch = "true" *) reg r_client_ack_l1;
		(* dont_touch = "true" *) reg r_client_ack_ref;

		always @(posedge clk_mmu) begin
			r_l1_pa_w0_hi   <= l1_pfn_w0[gout*PPN_BITS + 4 +: 16];
			r_l1_pa_w0_lo   <= {l1_pfn_w0[gout*PPN_BITS +: 4], client_req_va[gout*VA_BITS +: 12]};
			r_l1_flg_w0     <= l1_flags_w0[gout*6 +: 6];

			r_l1_pa_w1_hi   <= l1_pfn_w1[gout*PPN_BITS + 4 +: 16];
			r_l1_pa_w1_lo   <= {l1_pfn_w1[gout*PPN_BITS +: 4], client_req_va[gout*VA_BITS +: 12]};
			r_l1_flg_w1     <= l1_flags_w1[gout*6 +: 6];

			r_l1_hit_w1_pa  <= l1_hit_w1[gout];
			r_l1_hit_w1_flg <= l1_hit_w1[gout];

			if (refill_now_hi)  r_ref_pa_hi <= r_refill_pfn[19:4];
			if (refill_now_lo)  r_ref_pa_lo <= {r_refill_pfn[3:0], active_offset};
			if (refill_now_flg) r_ref_flg   <= r_refill_flags;
		end

		always @(posedge clk_mmu) begin
			if (rst_mmu_int) begin
				r_client_ack_l1      <= 1'b0;
				r_client_ack_ref     <= 1'b0;
				r_client_fault[gout] <= 1'b0;
				r_is_refill_hi       <= 1'b0;
				r_is_refill_lo       <= 1'b0;
				r_is_refill_flg      <= 1'b0;
			end else if (st_is_refill_c[gout]) begin
				r_client_ack_l1      <= 1'b0;
				r_client_ack_ref     <= refill_now_ctl & !r_refill_fault;
				r_client_fault[gout] <= refill_now_ctl & r_refill_fault;
				r_is_refill_hi       <= refill_now_ctl;
				r_is_refill_lo       <= refill_now_ctl;
				r_is_refill_flg      <= refill_now_ctl;
			end else begin
				r_client_ack_l1      <= l1_hit[gout];
				r_client_ack_ref     <= 1'b0;
				r_client_fault[gout] <= 1'b0;
				r_is_refill_hi       <= 1'b0;
				r_is_refill_lo       <= 1'b0;
				r_is_refill_flg      <= 1'b0;
			end
		end

		wire [PA_BITS-1:16] l1_pa_hi_mux = r_l1_hit_w1_pa  ? r_l1_pa_w1_hi : r_l1_pa_w0_hi;
		wire [15:0]         l1_pa_lo_mux = r_l1_hit_w1_pa  ? r_l1_pa_w1_lo : r_l1_pa_w0_lo;
		wire [5:0]          l1_flg_mux   = r_l1_hit_w1_flg ? r_l1_flg_w1   : r_l1_flg_w0;

		always @(*) begin
			r_client_ack[gout]                   = r_client_ack_l1 | r_client_ack_ref;
			r_client_pa[gout*PA_BITS + 16 +: 16] = r_is_refill_hi  ? r_ref_pa_hi : l1_pa_hi_mux;
			r_client_pa[gout*PA_BITS + 0  +: 16] = r_is_refill_lo  ? r_ref_pa_lo : l1_pa_lo_mux;
			r_client_flags[gout*6 +: 6]          = r_is_refill_flg ? r_ref_flg   : l1_flg_mux;
		end
	end
	endgenerate

	generate
	if (REG_CLIENT_OUT != 0) begin : g_reg_out
		always @(*) begin
			client_ack   = r_client_ack;
			client_fault = r_client_fault;
			client_pa    = r_client_pa;
			client_flags = r_client_flags;
		end
	end else begin : g_comb_out
		integer c;
		always @(*) begin
			for (c = 0; c < NUM_CLIENTS; c = c + 1) begin
				client_ack[c] = 1'b0;
				client_fault[c] = 1'b0;
				client_pa[c*PA_BITS +: PA_BITS] = {PA_BITS{1'b0}};
				client_flags[c*6 +: 6] = 6'd0;

				if (l1_hit[c]) begin
					/* Fast 1-cycle L1 Hit */
					client_ack[c] = 1'b1;
					client_pa[c*PA_BITS +: PA_BITS] = {l1_hit_pfn[c*PPN_BITS +: PPN_BITS], client_req_va[c*VA_BITS +: 12]};
					client_flags[c*6 +: 6] = l1_hit_flags[c*6 +: 6];
				end
			end

			/* Served after L2 hit or Walker completion */
			if (state == S_REFILL) begin
				client_ack[active_client] = !r_refill_fault;
				client_fault[active_client] = r_refill_fault;
				case (active_client)
				3'd0: begin client_pa[0*PA_BITS +: PA_BITS] = {r_refill_pfn, active_offset}; client_flags[0*6 +: 6] = r_refill_flags; end
				3'd1: begin client_pa[1*PA_BITS +: PA_BITS] = {r_refill_pfn, active_offset}; client_flags[1*6 +: 6] = r_refill_flags; end
				3'd2: begin client_pa[2*PA_BITS +: PA_BITS] = {r_refill_pfn, active_offset}; client_flags[2*6 +: 6] = r_refill_flags; end
				3'd3: begin client_pa[3*PA_BITS +: PA_BITS] = {r_refill_pfn, active_offset}; client_flags[3*6 +: 6] = r_refill_flags; end
				3'd4: begin client_pa[4*PA_BITS +: PA_BITS] = {r_refill_pfn, active_offset}; client_flags[4*6 +: 6] = r_refill_flags; end
				default: ;
				endcase
			end
		end
	end
	endgenerate

	/* Client miss priority grant logic (<= 2 LUT levels, zero CARRY4) */
	(* max_fanout = 16 *) reg [NUM_CLIENTS-1:0] r_client_miss;
	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			r_client_miss <= {NUM_CLIENTS{1'b0}};
		end else begin
			r_client_miss <= l1_miss;
		end
	end



	wire any_miss = |r_client_miss;
	reg [2:0] next_client;
	always @(*) begin
		if (r_client_miss[0])      next_client = 3'd0;
		else if (r_client_miss[1]) next_client = 3'd1;
		else if (r_client_miss[2]) next_client = 3'd2;
		else if (r_client_miss[3]) next_client = 3'd3;
		else                       next_client = 3'd4;
	end

	/* Active client context registers with replicated client select to avoid high fanout */
	(* dont_touch = "true" *) reg [2:0] act_client_vpn_lo;
	(* dont_touch = "true" *) reg [2:0] act_client_vpn_hi;
	(* dont_touch = "true" *) reg [2:0] act_client_off;
	(* dont_touch = "true" *) reg [2:0] act_client_meta;

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			active_client     <= 3'd0;
			act_client_vpn_lo <= 3'd0;
			act_client_vpn_hi <= 3'd0;
			act_client_off    <= 3'd0;
			act_client_meta   <= 3'd0;
		end else if (state == S_IDLE && any_miss) begin
			active_client     <= next_client;
			act_client_vpn_lo <= next_client;
			act_client_vpn_hi <= next_client;
			act_client_off    <= next_client;
			act_client_meta   <= next_client;
		end
	end

	(* keep = "true", max_fanout = 16 *) wire ce_l2_vpn_hi  = (state == S_L2_LOOKUP);
	(* keep = "true", max_fanout = 16 *) wire ce_l2_vpn_lo  = (state == S_L2_LOOKUP);
	(* keep = "true", max_fanout = 16 *) wire ce_act_vpn_hi = (state == S_L2_LOOKUP);
	(* keep = "true", max_fanout = 16 *) wire ce_act_vpn_lo = (state == S_L2_LOOKUP);
	(* keep = "true", max_fanout = 16 *) wire ce_act_offset = (state == S_L2_LOOKUP);
	(* keep = "true", max_fanout = 16 *) wire ce_act_meta   = (state == S_L2_LOOKUP);

	(* dont_touch = "true" *) reg ce_w0_vpn, ce_w0_pfn, ce_w0_flg;
	(* dont_touch = "true" *) reg ce_w1_vpn, ce_w1_pfn, ce_w1_flg;
	(* dont_touch = "true" *) reg ce_w2_vpn, ce_w2_pfn, ce_w2_flg;
	(* dont_touch = "true" *) reg ce_w3_vpn, ce_w3_pfn, ce_w3_flg;

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			ce_w0_vpn <= 1'b0; ce_w0_pfn <= 1'b0; ce_w0_flg <= 1'b0;
			ce_w1_vpn <= 1'b0; ce_w1_pfn <= 1'b0; ce_w1_flg <= 1'b0;
			ce_w2_vpn <= 1'b0; ce_w2_pfn <= 1'b0; ce_w2_flg <= 1'b0;
			ce_w3_vpn <= 1'b0; ce_w3_pfn <= 1'b0; ce_w3_flg <= 1'b0;
		end else begin
			ce_w0_vpn <= (state == S_IDLE && any_miss);
			ce_w0_pfn <= (state == S_IDLE && any_miss);
			ce_w0_flg <= (state == S_IDLE && any_miss);
			ce_w1_vpn <= (state == S_IDLE && any_miss);
			ce_w1_pfn <= (state == S_IDLE && any_miss);
			ce_w1_flg <= (state == S_IDLE && any_miss);
			ce_w2_vpn <= (state == S_IDLE && any_miss);
			ce_w2_pfn <= (state == S_IDLE && any_miss);
			ce_w2_flg <= (state == S_IDLE && any_miss);
			ce_w3_vpn <= (state == S_IDLE && any_miss);
			ce_w3_pfn <= (state == S_IDLE && any_miss);
			ce_w3_flg <= (state == S_IDLE && any_miss);
		end
	end

	reg [3:0]  sel_session;
	reg [9:0]  sel_vpn_lo;
	reg [5:0]  raw_lo_lk;
	reg [5:0]  raw_lo_ref_a;
	reg [5:0]  raw_lo_ref_b;
	reg [9:0]  sel_vpn_hi;
	reg [11:0] sel_offset;
	reg [1:0]  sel_type;

	always @(*) begin
		case (act_client_vpn_lo)
		3'd0: begin
			sel_vpn_lo   = client_req_va[0*VA_BITS + 12 +: 10];
			raw_lo_lk    = client_req_va[0*VA_BITS + 12 +: 6];
			raw_lo_ref_a = client_req_va[0*VA_BITS + 12 +: 6];
			raw_lo_ref_b = client_req_va[0*VA_BITS + 12 +: 6];
		end
		3'd1: begin
			sel_vpn_lo   = client_req_va[1*VA_BITS + 12 +: 10];
			raw_lo_lk    = client_req_va[1*VA_BITS + 12 +: 6];
			raw_lo_ref_a = client_req_va[1*VA_BITS + 12 +: 6];
			raw_lo_ref_b = client_req_va[1*VA_BITS + 12 +: 6];
		end
		3'd2: begin
			sel_vpn_lo   = client_req_va[2*VA_BITS + 12 +: 10];
			raw_lo_lk    = client_req_va[2*VA_BITS + 12 +: 6];
			raw_lo_ref_a = client_req_va[2*VA_BITS + 12 +: 6];
			raw_lo_ref_b = client_req_va[2*VA_BITS + 12 +: 6];
		end
		3'd3: begin
			sel_vpn_lo   = client_req_va[3*VA_BITS + 12 +: 10];
			raw_lo_lk    = client_req_va[3*VA_BITS + 12 +: 6];
			raw_lo_ref_a = client_req_va[3*VA_BITS + 12 +: 6];
			raw_lo_ref_b = client_req_va[3*VA_BITS + 12 +: 6];
		end
		default: begin
			sel_vpn_lo   = client_req_va[4*VA_BITS + 12 +: 10];
			raw_lo_lk    = client_req_va[4*VA_BITS + 12 +: 6];
			raw_lo_ref_a = client_req_va[4*VA_BITS + 12 +: 6];
			raw_lo_ref_b = client_req_va[4*VA_BITS + 12 +: 6];
		end
		endcase

		case (act_client_vpn_hi)
		3'd0: sel_vpn_hi = client_req_va[0*VA_BITS + 22 +: 10];
		3'd1: sel_vpn_hi = client_req_va[1*VA_BITS + 22 +: 10];
		3'd2: sel_vpn_hi = client_req_va[2*VA_BITS + 22 +: 10];
		3'd3: sel_vpn_hi = client_req_va[3*VA_BITS + 22 +: 10];
		default: sel_vpn_hi = client_req_va[4*VA_BITS + 22 +: 10];
		endcase

		case (act_client_off)
		3'd0: sel_offset = client_req_va[0*VA_BITS +: 12];
		3'd1: sel_offset = client_req_va[1*VA_BITS +: 12];
		3'd2: sel_offset = client_req_va[2*VA_BITS +: 12];
		3'd3: sel_offset = client_req_va[3*VA_BITS +: 12];
		default: sel_offset = client_req_va[4*VA_BITS +: 12];
		endcase

		case (act_client_meta)
		3'd0: begin sel_session = client_req_session[0*4 +: 4]; sel_type = client_req_type[0*2 +: 2]; end
		3'd1: begin sel_session = client_req_session[1*4 +: 4]; sel_type = client_req_type[1*2 +: 2]; end
		3'd2: begin sel_session = client_req_session[2*4 +: 4]; sel_type = client_req_type[2*2 +: 2]; end
		3'd3: begin sel_session = client_req_session[3*4 +: 4]; sel_type = client_req_type[3*2 +: 2]; end
		default: begin sel_session = client_req_session[4*4 +: 4]; sel_type = client_req_type[4*2 +: 2]; end
		endcase
	end

	wire [5:0] sel_vpn_lk_w0_a, sel_vpn_lk_w0_b;
	wire [5:0] sel_vpn_lk_w1_a, sel_vpn_lk_w1_b;
	wire [5:0] sel_vpn_lk_w2_a, sel_vpn_lk_w2_b;
	wire [5:0] sel_vpn_lk_w3_a, sel_vpn_lk_w3_b;
	wire [5:0] sel_vpn_ref_w0_vpn, sel_vpn_ref_w0_pfn, sel_vpn_ref_w0_flg;
	wire [5:0] sel_vpn_ref_w1_vpn, sel_vpn_ref_w1_pfn, sel_vpn_ref_w1_flg;
	wire [5:0] sel_vpn_ref_w2_vpn, sel_vpn_ref_w2_pfn, sel_vpn_ref_w2_flg;
	wire [5:0] sel_vpn_ref_w3_vpn, sel_vpn_ref_w3_pfn, sel_vpn_ref_w3_flg;

`ifdef SYNTH_KINTEX7
	genvar gbit;
	generate
	for (gbit = 0; gbit < 6; gbit = gbit + 1) begin : g_lk_buf
		LUT1 #(.INIT(2'h2)) u_b_lk0_a (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w0_a[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_lk0_b (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w0_b[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_lk1_a (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w1_a[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_lk1_b (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w1_b[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_lk2_a (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w2_a[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_lk2_b (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w2_b[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_lk3_a (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w3_a[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_lk3_b (.I0(raw_lo_lk[gbit]), .O(sel_vpn_lk_w3_b[gbit]));

		LUT1 #(.INIT(2'h2)) u_b_rf0_v (.I0(raw_lo_ref_a[gbit]), .O(sel_vpn_ref_w0_vpn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf0_p (.I0(raw_lo_ref_a[gbit]), .O(sel_vpn_ref_w0_pfn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf0_f (.I0(raw_lo_ref_a[gbit]), .O(sel_vpn_ref_w0_flg[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf1_v (.I0(raw_lo_ref_a[gbit]), .O(sel_vpn_ref_w1_vpn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf1_p (.I0(raw_lo_ref_a[gbit]), .O(sel_vpn_ref_w1_pfn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf1_f (.I0(raw_lo_ref_a[gbit]), .O(sel_vpn_ref_w1_flg[gbit]));

		LUT1 #(.INIT(2'h2)) u_b_rf2_v (.I0(raw_lo_ref_b[gbit]), .O(sel_vpn_ref_w2_vpn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf2_p (.I0(raw_lo_ref_b[gbit]), .O(sel_vpn_ref_w2_pfn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf2_f (.I0(raw_lo_ref_b[gbit]), .O(sel_vpn_ref_w2_flg[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf3_v (.I0(raw_lo_ref_b[gbit]), .O(sel_vpn_ref_w3_vpn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf3_p (.I0(raw_lo_ref_b[gbit]), .O(sel_vpn_ref_w3_pfn[gbit]));
		LUT1 #(.INIT(2'h2)) u_b_rf3_f (.I0(raw_lo_ref_b[gbit]), .O(sel_vpn_ref_w3_flg[gbit]));
	end
	endgenerate
`else
	assign sel_vpn_lk_w0_a = raw_lo_lk;
	assign sel_vpn_lk_w0_b = raw_lo_lk;
	assign sel_vpn_lk_w1_a = raw_lo_lk;
	assign sel_vpn_lk_w1_b = raw_lo_lk;
	assign sel_vpn_lk_w2_a = raw_lo_lk;
	assign sel_vpn_lk_w2_b = raw_lo_lk;
	assign sel_vpn_lk_w3_a = raw_lo_lk;
	assign sel_vpn_lk_w3_b = raw_lo_lk;

	assign sel_vpn_ref_w0_vpn = raw_lo_ref_a;
	assign sel_vpn_ref_w0_pfn = raw_lo_ref_a;
	assign sel_vpn_ref_w0_flg = raw_lo_ref_a;
	assign sel_vpn_ref_w1_vpn = raw_lo_ref_a;
	assign sel_vpn_ref_w1_pfn = raw_lo_ref_a;
	assign sel_vpn_ref_w1_flg = raw_lo_ref_a;

	assign sel_vpn_ref_w2_vpn = raw_lo_ref_b;
	assign sel_vpn_ref_w2_pfn = raw_lo_ref_b;
	assign sel_vpn_ref_w2_flg = raw_lo_ref_b;
	assign sel_vpn_ref_w3_vpn = raw_lo_ref_b;
	assign sel_vpn_ref_w3_pfn = raw_lo_ref_b;
	assign sel_vpn_ref_w3_flg = raw_lo_ref_b;
`endif

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			active_session    <= 4'd0;
			active_type       <= 2'd0;
			l1_ref_sess_c0    <= 4'd0;
			l1_ref_sess_c1    <= 4'd0;
			l1_ref_sess_c2    <= 4'd0;
			l1_ref_sess_c3    <= 4'd0;
			l1_ref_sess_c4    <= 4'd0;
			l2_ref_sess       <= 4'd0;
			wlk_session       <= 4'd0;
			l2_lk_session     <= 4'd0;
			l2_lookup_session <= 4'd0;
		end else if (ce_act_meta) begin
			active_session    <= sel_session;
			active_type       <= sel_type;
			l1_ref_sess_c0    <= sel_session;
			l1_ref_sess_c1    <= sel_session;
			l1_ref_sess_c2    <= sel_session;
			l1_ref_sess_c3    <= sel_session;
			l1_ref_sess_c4    <= sel_session;
			l2_ref_sess       <= sel_session;
			wlk_session       <= sel_session;
			l2_lk_session     <= sel_session;
			l2_lookup_session <= sel_session;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			active_offset <= 12'd0;
		end else if (ce_act_offset) begin
			active_offset <= sel_offset;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			active_vpn[19:10]    <= 10'd0;
			active_vpn[9:0]      <= 10'd0;
			l1_ref_vpn_c0        <= {VPN_BITS{1'b0}};
			l1_ref_vpn_c1        <= {VPN_BITS{1'b0}};
			l1_ref_vpn_c2        <= {VPN_BITS{1'b0}};
			l1_ref_vpn_c3        <= {VPN_BITS{1'b0}};
			l1_ref_vpn_c4        <= {VPN_BITS{1'b0}};
			l2_ref_vpn           <= {VPN_BITS{1'b0}};
			wlk_vpn              <= {VPN_BITS{1'b0}};
			flt_vpn              <= {VPN_BITS{1'b0}};
		end else begin
			if (ce_act_vpn_hi) begin
				active_vpn[19:10]    <= sel_vpn_hi;
				l1_ref_vpn_c0[19:10] <= sel_vpn_hi;
				l1_ref_vpn_c1[19:10] <= sel_vpn_hi;
				l1_ref_vpn_c2[19:10] <= sel_vpn_hi;
				l1_ref_vpn_c3[19:10] <= sel_vpn_hi;
				l1_ref_vpn_c4[19:10] <= sel_vpn_hi;
				l2_ref_vpn[19:10]    <= sel_vpn_hi;
				wlk_vpn[19:10]       <= sel_vpn_hi;
				flt_vpn[19:10]       <= sel_vpn_hi;
			end
			if (ce_act_vpn_lo) begin
				active_vpn[9:0]      <= sel_vpn_lo;
				l1_ref_vpn_c0[9:0]   <= sel_vpn_lo;
				l1_ref_vpn_c1[9:0]   <= sel_vpn_lo;
				l1_ref_vpn_c2[9:0]   <= sel_vpn_lo;
				l1_ref_vpn_c3[9:0]   <= sel_vpn_lo;
				l1_ref_vpn_c4[9:0]   <= sel_vpn_lo;
				l2_ref_vpn[9:0]      <= sel_vpn_lo;
				wlk_vpn[9:0]         <= sel_vpn_lo;
				flt_vpn[9:0]         <= sel_vpn_lo;
			end
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w0_vpn_a <= 6'h00; l2_ref_w0_vpn_b <= 6'h00; l2_ref_w0_vpn_c <= 6'h00;
		end else if (ce_w0_vpn) begin
			l2_ref_w0_vpn_a <= sel_vpn_ref_w0_vpn; l2_ref_w0_vpn_b <= sel_vpn_ref_w0_vpn; l2_ref_w0_vpn_c <= sel_vpn_ref_w0_vpn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w0_pfn_a <= 6'h00; l2_ref_w0_pfn_b <= 6'h00; l2_ref_w0_pfn_c <= 6'h00; l2_ref_w0_pfn_d <= 6'h00;
		end else if (ce_w0_pfn) begin
			l2_ref_w0_pfn_a <= sel_vpn_ref_w0_pfn; l2_ref_w0_pfn_b <= sel_vpn_ref_w0_pfn; l2_ref_w0_pfn_c <= sel_vpn_ref_w0_pfn; l2_ref_w0_pfn_d <= sel_vpn_ref_w0_pfn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w0_flg_a <= 6'h00; l2_ref_w0_flg_b <= 6'h00;
		end else if (ce_w0_flg) begin
			l2_ref_w0_flg_a <= sel_vpn_ref_w0_flg; l2_ref_w0_flg_b <= sel_vpn_ref_w0_flg;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w1_vpn_a <= 6'h01; l2_ref_w1_vpn_b <= 6'h01; l2_ref_w1_vpn_c <= 6'h01;
		end else if (ce_w1_vpn) begin
			l2_ref_w1_vpn_a <= sel_vpn_ref_w1_vpn; l2_ref_w1_vpn_b <= sel_vpn_ref_w1_vpn; l2_ref_w1_vpn_c <= sel_vpn_ref_w1_vpn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w1_pfn_a <= 6'h01; l2_ref_w1_pfn_b <= 6'h01; l2_ref_w1_pfn_c <= 6'h01; l2_ref_w1_pfn_d <= 6'h01;
		end else if (ce_w1_pfn) begin
			l2_ref_w1_pfn_a <= sel_vpn_ref_w1_pfn; l2_ref_w1_pfn_b <= sel_vpn_ref_w1_pfn; l2_ref_w1_pfn_c <= sel_vpn_ref_w1_pfn; l2_ref_w1_pfn_d <= sel_vpn_ref_w1_pfn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w1_flg_a <= 6'h01; l2_ref_w1_flg_b <= 6'h01;
		end else if (ce_w1_flg) begin
			l2_ref_w1_flg_a <= sel_vpn_ref_w1_flg; l2_ref_w1_flg_b <= sel_vpn_ref_w1_flg;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w2_vpn_a <= 6'h02; l2_ref_w2_vpn_b <= 6'h02; l2_ref_w2_vpn_c <= 6'h02;
		end else if (ce_w2_vpn) begin
			l2_ref_w2_vpn_a <= sel_vpn_ref_w2_vpn; l2_ref_w2_vpn_b <= sel_vpn_ref_w2_vpn; l2_ref_w2_vpn_c <= sel_vpn_ref_w2_vpn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w2_pfn_a <= 6'h02; l2_ref_w2_pfn_b <= 6'h02; l2_ref_w2_pfn_c <= 6'h02; l2_ref_w2_pfn_d <= 6'h02;
		end else if (ce_w2_pfn) begin
			l2_ref_w2_pfn_a <= sel_vpn_ref_w2_pfn; l2_ref_w2_pfn_b <= sel_vpn_ref_w2_pfn; l2_ref_w2_pfn_c <= sel_vpn_ref_w2_pfn; l2_ref_w2_pfn_d <= sel_vpn_ref_w2_pfn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w2_flg_a <= 6'h02; l2_ref_w2_flg_b <= 6'h02;
		end else if (ce_w2_flg) begin
			l2_ref_w2_flg_a <= sel_vpn_ref_w2_flg; l2_ref_w2_flg_b <= sel_vpn_ref_w2_flg;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w3_vpn_a <= 6'h03; l2_ref_w3_vpn_b <= 6'h03; l2_ref_w3_vpn_c <= 6'h03;
		end else if (ce_w3_vpn) begin
			l2_ref_w3_vpn_a <= sel_vpn_ref_w3_vpn; l2_ref_w3_vpn_b <= sel_vpn_ref_w3_vpn; l2_ref_w3_vpn_c <= sel_vpn_ref_w3_vpn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w3_pfn_a <= 6'h03; l2_ref_w3_pfn_b <= 6'h03; l2_ref_w3_pfn_c <= 6'h03; l2_ref_w3_pfn_d <= 6'h03;
		end else if (ce_w3_pfn) begin
			l2_ref_w3_pfn_a <= sel_vpn_ref_w3_pfn; l2_ref_w3_pfn_b <= sel_vpn_ref_w3_pfn; l2_ref_w3_pfn_c <= sel_vpn_ref_w3_pfn; l2_ref_w3_pfn_d <= sel_vpn_ref_w3_pfn;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_ref_w3_flg_a <= 6'h03; l2_ref_w3_flg_b <= 6'h03;
		end else if (ce_w3_flg) begin
			l2_ref_w3_flg_a <= sel_vpn_ref_w3_flg; l2_ref_w3_flg_b <= sel_vpn_ref_w3_flg;
		end
	end

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			l2_lookup_vpn[19:10]      <= 10'd0;
			l2_lookup_vpn[9:0]        <= 10'd0;
			l2_lookup_set_w0_vpn      <= 6'h00;
			l2_lookup_set_w0_pfn_lo   <= 6'h00;
			l2_lookup_set_w0_pfn_hi   <= 6'h00;
			l2_lookup_set_w0_flg      <= 6'h00;
			l2_lookup_set_w0_sl       <= 6'h00;
			l2_lookup_set_w1_vpn      <= 6'h01;
			l2_lookup_set_w1_pfn_lo   <= 6'h01;
			l2_lookup_set_w1_pfn_hi   <= 6'h01;
			l2_lookup_set_w1_flg      <= 6'h01;
			l2_lookup_set_w1_sl       <= 6'h01;
			l2_lookup_set_w2_vpn      <= 6'h02;
			l2_lookup_set_w2_pfn_lo   <= 6'h02;
			l2_lookup_set_w2_pfn_hi   <= 6'h02;
			l2_lookup_set_w2_flg      <= 6'h02;
			l2_lookup_set_w2_sl       <= 6'h02;
			l2_lookup_set_w3_vpn      <= 6'h03;
			l2_lookup_set_w3_pfn_lo   <= 6'h03;
			l2_lookup_set_w3_pfn_hi   <= 6'h03;
			l2_lookup_set_w3_flg      <= 6'h03;
			l2_lookup_set_w3_sl       <= 6'h03;
		end else begin
			if (ce_l2_vpn_hi) l2_lookup_vpn[19:10] <= sel_vpn_hi;
			if (ce_l2_vpn_lo) begin
				l2_lookup_vpn[9:0]        <= sel_vpn_lo;
				l2_lookup_set_w0_vpn      <= sel_vpn_lk_w0_a;
				l2_lookup_set_w0_pfn_lo   <= sel_vpn_lk_w0_a;
				l2_lookup_set_w0_pfn_hi   <= sel_vpn_lk_w0_a;
				l2_lookup_set_w0_flg      <= sel_vpn_lk_w0_b;
				l2_lookup_set_w0_sl       <= sel_vpn_lk_w0_b;
				l2_lookup_set_w1_vpn      <= sel_vpn_lk_w1_a;
				l2_lookup_set_w1_pfn_lo   <= sel_vpn_lk_w1_a;
				l2_lookup_set_w1_pfn_hi   <= sel_vpn_lk_w1_a;
				l2_lookup_set_w1_flg      <= sel_vpn_lk_w1_b;
				l2_lookup_set_w1_sl       <= sel_vpn_lk_w1_b;
				l2_lookup_set_w2_vpn      <= sel_vpn_lk_w2_a;
				l2_lookup_set_w2_pfn_lo   <= sel_vpn_lk_w2_a;
				l2_lookup_set_w2_pfn_hi   <= sel_vpn_lk_w2_a;
				l2_lookup_set_w2_flg      <= sel_vpn_lk_w2_b;
				l2_lookup_set_w2_sl       <= sel_vpn_lk_w2_b;
				l2_lookup_set_w3_vpn      <= sel_vpn_lk_w3_a;
				l2_lookup_set_w3_pfn_lo   <= sel_vpn_lk_w3_a;
				l2_lookup_set_w3_pfn_hi   <= sel_vpn_lk_w3_a;
				l2_lookup_set_w3_flg      <= sel_vpn_lk_w3_b;
				l2_lookup_set_w3_sl       <= sel_vpn_lk_w3_b;
			end
		end
	end

	/* Refill payload data registers with decoupled byte enables (<= 10 fanout per block) */
	wire l2_hit_p, l2_hit_f, l2_hit_c;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'h2)) u_b_hit_p (.I0(l2_hit), .O(l2_hit_p));
	LUT1 #(.INIT(2'h2)) u_b_hit_f (.I0(l2_hit), .O(l2_hit_f));
	LUT1 #(.INIT(2'h2)) u_b_hit_c (.I0(l2_hit), .O(l2_hit_c));
`else
	assign l2_hit_p = l2_hit;
	assign l2_hit_f = l2_hit;
	assign l2_hit_c = l2_hit;
`endif

	(* keep = "true", max_fanout = 16 *) wire ce_l2_hit = (state == S_L2_CHECK) & l2_hit_c;
	(* keep = "true", max_fanout = 16 *) wire ce_walk_done = (state == S_WALK) & walker_done;
	(* keep = "true", max_fanout = 16 *) wire ce_refill_hi  = ce_l2_hit | ce_walk_done;
	(* keep = "true", max_fanout = 16 *) wire ce_refill_lo  = ce_l2_hit | ce_walk_done;
	(* keep = "true", max_fanout = 16 *) wire ce_refill_flg = ce_l2_hit | ce_walk_done;

	wire [PPN_BITS-1:0] next_refill_pfn = l2_hit_p ? l2_hit_pfn : walker_out_pfn;
	wire [5:0]          next_refill_flags = l2_hit_f ? l2_hit_flags : walker_out_flags;

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			r_refill_pfn      <= {PPN_BITS{1'b0}};
			r_refill_flags    <= 6'd0;
			r_refill_pfn_c0   <= {PPN_BITS{1'b0}};
			r_refill_pfn_c1   <= {PPN_BITS{1'b0}};
			r_refill_pfn_c2   <= {PPN_BITS{1'b0}};
			r_refill_pfn_c3   <= {PPN_BITS{1'b0}};
			r_refill_pfn_c4   <= {PPN_BITS{1'b0}};
			r_refill_flags_c0 <= 6'd0;
			r_refill_flags_c1 <= 6'd0;
			r_refill_flags_c2 <= 6'd0;
			r_refill_flags_c3 <= 6'd0;
			r_refill_flags_c4 <= 6'd0;
			r_refill_pfn_l2   <= {PPN_BITS{1'b0}};
			r_refill_flags_l2 <= 6'd0;
		end else begin
			if (ce_refill_hi) begin
				r_refill_pfn[19:10]    <= next_refill_pfn[19:10];
				r_refill_pfn_c0[19:10] <= next_refill_pfn[19:10];
				r_refill_pfn_c1[19:10] <= next_refill_pfn[19:10];
				r_refill_pfn_c2[19:10] <= next_refill_pfn[19:10];
				r_refill_pfn_c3[19:10] <= next_refill_pfn[19:10];
				r_refill_pfn_c4[19:10] <= next_refill_pfn[19:10];
				r_refill_pfn_l2[19:10] <= next_refill_pfn[19:10];
			end
			if (ce_refill_lo) begin
				r_refill_pfn[9:0]    <= next_refill_pfn[9:0];
				r_refill_pfn_c0[9:0] <= next_refill_pfn[9:0];
				r_refill_pfn_c1[9:0] <= next_refill_pfn[9:0];
				r_refill_pfn_c2[9:0] <= next_refill_pfn[9:0];
				r_refill_pfn_c3[9:0] <= next_refill_pfn[9:0];
				r_refill_pfn_c4[9:0] <= next_refill_pfn[9:0];
				r_refill_pfn_l2[9:0] <= next_refill_pfn[9:0];
			end
			if (ce_refill_flg) begin
				r_refill_flags    <= next_refill_flags;
				r_refill_flags_c0 <= next_refill_flags;
				r_refill_flags_c1 <= next_refill_flags;
				r_refill_flags_c2 <= next_refill_flags;
				r_refill_flags_c3 <= next_refill_flags;
				r_refill_flags_c4 <= next_refill_flags;
				r_refill_flags_l2 <= next_refill_flags;
			end
		end
	end

	/* Fault reporting data registers */
	(* keep = "true", max_fanout = 16 *) wire ce_fault_data = (state == S_WALK) & walker_fault;
	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			fault_kind    <= 4'd0;
			fault_session <= 4'd0;
			fault_client  <= 3'd0;
			fault_addr    <= {VA_BITS{1'b0}};
		end else if (ce_fault_data) begin
			fault_kind    <= walker_fault_kind;
			fault_session <= active_session;
			fault_client  <= active_client;
			fault_addr    <= {flt_vpn, active_offset};
		end
	end

	wire next_is_refill = (state == S_L2_CHECK && l2_hit) || (state == S_WALK && (walker_done || walker_fault));
	wire next_is_idle   = (state == S_REFILL) || (state == S_IDLE && !any_miss);

	always @(posedge clk_mmu) begin
		if (rst_mmu_int) begin
			st_is_refill_c0 <= 1'b0;
			st_is_refill_c1 <= 1'b0;
			st_is_refill_c2 <= 1'b0;
			st_is_refill_c3 <= 1'b0;
			st_is_refill_c4 <= 1'b0;
			st_is_idle_c0   <= 1'b1;
			st_is_idle_c1   <= 1'b1;
			st_is_idle_c2   <= 1'b1;
			st_is_idle_c3   <= 1'b1;
			st_is_idle_c4   <= 1'b1;
		end else begin
			st_is_refill_c0 <= next_is_refill;
			st_is_refill_c1 <= next_is_refill;
			st_is_refill_c2 <= next_is_refill;
			st_is_refill_c3 <= next_is_refill;
			st_is_refill_c4 <= next_is_refill;
			st_is_idle_c0   <= next_is_idle;
			st_is_idle_c1   <= next_is_idle;
			st_is_idle_c2   <= next_is_idle;
			st_is_idle_c3   <= next_is_idle;
			st_is_idle_c4   <= next_is_idle;
		end
	end

	/* MMU State Machine Control (clean low-fanout control registers) */
	always @(posedge clk_mmu) begin
		walker_start_fsm  <= 1'b0;
		walker_start_meta <= 1'b0;
		l1_refill_we      <= {NUM_CLIENTS{1'b0}};
		l2_refill_we_w0   <= 1'b0;
		l2_refill_we_w1   <= 1'b0;
		l2_refill_we_w2   <= 1'b0;
		l2_refill_we_w3   <= 1'b0;
		l2_refill_we_sl0  <= 1'b0;
		l2_refill_we_sl1  <= 1'b0;
		l2_refill_we_sl2  <= 1'b0;
		l2_refill_we_sl3  <= 1'b0;
		l2_lookup_valid   <= 1'b0;
		fault_valid       <= 1'b0;

		if (rst_mmu_int) begin
			state          <= S_IDLE;
			r_refill_fault <= 1'b0;
		end else begin
			case (state)
			S_IDLE: begin
				if (any_miss) begin
					state <= S_L2_LOOKUP;
				end
			end

			S_L2_LOOKUP: begin
				l2_lookup_valid <= 1'b1;
				state           <= S_L2_WAIT;
			end

			S_L2_WAIT: begin
				/* Allow 1 clock cycle for L2 TLB set-read stage register to settle */
				state <= S_L2_WAIT2;
			end

			S_L2_WAIT2: begin
				/* Allow 1 clock cycle for L2 TLB hit stage register to settle */
				state <= S_L2_CHECK;
			end

			S_L2_CHECK: begin
				if (l2_hit) begin
					/* L2 hit: refill L1 */
					l1_refill_we[active_client] <= 1'b1;
					r_refill_fault              <= 1'b0;
					state                       <= S_REFILL;
				end else begin
					/* L2 miss: kick Hardware Walker */
					walker_start_fsm  <= 1'b1;
					walker_start_meta <= 1'b1;
					state             <= S_WALK;
				end
			end

			S_WALK: begin
				if (walker_done) begin
					/* Successful walk: refill L2 and L1 */
					l2_refill_we_w0             <= 1'b1;
					l2_refill_we_w1             <= 1'b1;
					l2_refill_we_w2             <= 1'b1;
					l2_refill_we_w3             <= 1'b1;
					l2_refill_we_sl0            <= 1'b1;
					l2_refill_we_sl1            <= 1'b1;
					l2_refill_we_sl2            <= 1'b1;
					l2_refill_we_sl3            <= 1'b1;
					l1_refill_we[active_client] <= 1'b1;
					r_refill_fault              <= 1'b0;
					state                       <= S_REFILL;
				end else if (walker_fault) begin
					/* Trap fault internally: prevent bus access */
					r_refill_fault <= 1'b1;
					fault_valid    <= 1'b1;
					state          <= S_REFILL;
				end
			end

			S_REFILL: begin
				state <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, if_co_unused, walker_busy};
endmodule

`default_nettype wire
