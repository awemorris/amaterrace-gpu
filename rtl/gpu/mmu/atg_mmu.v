/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mmu: Autonomous GPU Memory Management Unit.
 * Integrates per-client L1 TLBs, a shared L2 TLB, a 2-level hardware page
 * table walker, an in-flight memory transaction counter, and internal CP registers.
 * Traps unmapped or illegal accesses internally to protect host IOMMU.
 * See spec/gpu/mmu/atg_mmu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mmu #(
	parameter NUM_CLIENTS = 5,		/* 0:VF, 1:SU, 2:TU, 3:ROP, 4:BLT */
	parameter MAX_SESSIONS = 16,
	parameter VA_BITS = 32,
	parameter PA_BITS = 32,
	parameter VPN_BITS = VA_BITS - 12,
	parameter PPN_BITS = PA_BITS - 12
) (
	input wire clk,
	input wire rst_n,

	/* Client translation requests */
	input  wire [NUM_CLIENTS-1:0]           client_req_valid,
	input  wire [NUM_CLIENTS*4-1:0]         client_req_session,
	input  wire [NUM_CLIENTS*VA_BITS-1:0]   client_req_va,
	input  wire [NUM_CLIENTS*2-1:0]         client_req_type,	/* 0=Read, 1=Write, 2=Exec */
	output reg  [NUM_CLIENTS-1:0]           client_ack,
	output reg  [NUM_CLIENTS*PA_BITS-1:0]   client_pa,
	output reg  [NUM_CLIENTS*6-1:0]         client_flags,
	output reg  [NUM_CLIENTS-1:0]           client_fault,

	/* In-flight transaction tracking */
	input wire mem_req_fire,
	input wire mem_rsp_fire,
	output wire [15:0] inflight_count,

	/* CP Register Interface */
	input wire                       cp_pt_root_we,
	input wire [3:0]                 cp_pt_root_session,
	input wire [PPN_BITS-1:0]        cp_pt_root_base,	/* [PA_BITS-1:12] */
	input wire                       cp_flush_trigger,
	input wire                       cp_flush_all,
	input wire [3:0]                 cp_flush_session,

	/* Fault reporting to CP / Host */
	output reg                fault_valid,
	output reg [3:0]          fault_kind,
	output reg [3:0]          fault_session,
	output reg [2:0]          fault_client,
	output reg [VA_BITS-1:0]  fault_addr,

	/* Walker Memory Read Master interface (to MC) */
	output wire               walker_mem_req_valid,
	output wire [PA_BITS-1:0] walker_mem_req_addr,
	input  wire               walker_mem_req_ready,
	input  wire               walker_mem_rsp_valid,
	input  wire [63:0]        walker_mem_rsp_data
);
	/* Session Root Page Directory Base Table [PA_BITS-1:12] */
	reg [PPN_BITS-1:0] session_root_pt [0:MAX_SESSIONS-1];

	integer s;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (s = 0; s < MAX_SESSIONS; s = s + 1)
				session_root_pt[s] <= {PPN_BITS{1'b0}};
		end else if (cp_pt_root_we) begin
			session_root_pt[cp_pt_root_session] <= cp_pt_root_base;
		end
	end

	/* In-flight transaction counter */
	reg [15:0] r_inflight;
	wire [15:0] inflight_inc, inflight_dec;
	wire inc_co_unused, dec_bo_unused;
	am_add #(.W(16)) u_if_inc (.a(r_inflight), .b(16'd1), .ci(1'b0), .s(inflight_inc), .co(inc_co_unused));
	am_sub #(.W(16)) u_if_dec (.a(r_inflight), .b(16'd1), .bi(1'b0), .d(inflight_dec), .bo(dec_bo_unused));

	always @(posedge clk) begin
		if (!rst_n) begin
			r_inflight <= 16'd0;
		end else begin
			if (mem_req_fire && !mem_rsp_fire)
				r_inflight <= inflight_inc;
			else if (!mem_req_fire && mem_rsp_fire && r_inflight != 16'd0)
				r_inflight <= inflight_dec;
		end
	end
	assign inflight_count = r_inflight;

	/* Active client registers */
	reg [2:0]          active_client;
	reg [3:0]          active_session;
	reg [VPN_BITS-1:0] active_vpn;
	reg [11:0]         active_offset;
	reg [1:0]          active_type;

	/* Per-client L1 TLBs */
	wire [NUM_CLIENTS-1:0]          l1_hit;
	wire [NUM_CLIENTS*PPN_BITS-1:0] l1_hit_pfn;
	wire [NUM_CLIENTS*6-1:0]        l1_hit_flags;
	reg  [NUM_CLIENTS-1:0]          l1_refill_we;
	reg  [PPN_BITS-1:0]             l1_refill_pfn;
	reg  [5:0]                      l1_refill_flags;

	genvar gc;
	generate
	for (gc = 0; gc < NUM_CLIENTS; gc = gc + 1) begin : g_l1
		wire [3:0]          c_sess = client_req_session[gc*4 +: 4];
		wire [VPN_BITS-1:0] c_vpn  = client_req_va[gc*VA_BITS + 12 +: VPN_BITS];
		atg_tlb_l1 #(
			.ENTRIES(16),
			.VA_BITS(VA_BITS),
			.PA_BITS(PA_BITS)
		) u_l1 (
			.clk(clk),
			.rst_n(rst_n),
			.flush_trigger(cp_flush_trigger),
			.flush_all(cp_flush_all),
			.flush_session(cp_flush_session),
			.req_session(c_sess),
			.req_vpn(c_vpn),
			.hit(l1_hit[gc]),
			.hit_pfn(l1_hit_pfn[gc*PPN_BITS +: PPN_BITS]),
			.hit_flags(l1_hit_flags[gc*6 +: 6]),
			.refill_we(l1_refill_we[gc]),
			.refill_session(active_session),
			.refill_vpn(active_vpn),
			.refill_pfn(l1_refill_pfn),
			.refill_flags(l1_refill_flags)
		);
	end
	endgenerate

	/* Shared L2 TLB */
	reg                l2_lookup_valid;
	reg  [3:0]         l2_lookup_session;
	reg [VPN_BITS-1:0] l2_lookup_vpn;
	wire               l2_hit;
	wire [PPN_BITS-1:0] l2_hit_pfn;
	wire [5:0]         l2_hit_flags;

	reg                l2_refill_we;

	atg_tlb_l2 #(
		.SETS(64),
		.VA_BITS(VA_BITS),
		.PA_BITS(PA_BITS)
	) u_l2 (
		.clk(clk),
		.rst_n(rst_n),
		.flush_trigger(cp_flush_trigger),
		.flush_all(cp_flush_all),
		.flush_session(cp_flush_session),
		.lookup_valid(l2_lookup_valid),
		.lookup_session(l2_lookup_session),
		.lookup_vpn(l2_lookup_vpn),
		.hit(l2_hit),
		.hit_pfn(l2_hit_pfn),
		.hit_flags(l2_hit_flags),
		.refill_we(l2_refill_we),
		.refill_session(active_session),
		.refill_vpn(active_vpn),
		.refill_pfn(l1_refill_pfn),
		.refill_flags(l1_refill_flags)
	);

	/* Hardware Page Table Walker */
	reg                walker_start;
	wire               walker_busy;
	wire               walker_done;
	wire               walker_fault;
	wire [3:0]         walker_fault_kind;
	wire [PPN_BITS-1:0] walker_out_pfn;
	wire [5:0]         walker_out_flags;

	wire [PPN_BITS-1:0] walker_root_pt = session_root_pt[active_session];

	atg_mmu_walker #(
		.VA_BITS(VA_BITS),
		.PA_BITS(PA_BITS)
	) u_walker (
		.clk(clk),
		.rst_n(rst_n),
		.start(walker_start),
		.session_id(active_session),
		.vpn(active_vpn),
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
	localparam [2:0] S_WALK     = 3'd2;
	localparam [2:0] S_REFILL   = 3'd3;

	reg [2:0]          state;
	reg                r_refill_fault;
	reg [PPN_BITS-1:0] r_refill_pfn;
	reg [5:0]          r_refill_flags;

	integer c;
	always @(*) begin
		for (c = 0; c < NUM_CLIENTS; c = c + 1) begin
			client_ack[c] = 1'b0;
			client_fault[c] = 1'b0;
			client_pa[c*PA_BITS +: PA_BITS] = {PA_BITS{1'b0}};
			client_flags[c*6 +: 6] = 6'd0;

			if (client_req_valid[c]) begin
				if (l1_hit[c]) begin
					/* Fast 1-cycle L1 Hit */
					client_ack[c] = 1'b1;
					client_pa[c*PA_BITS +: PA_BITS] = {l1_hit_pfn[c*PPN_BITS +: PPN_BITS], client_req_va[c*VA_BITS +: 12]};
					client_flags[c*6 +: 6] = l1_hit_flags[c*6 +: 6];
				end
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

	always @(posedge clk) begin
		walker_start    <= 1'b0;
		l1_refill_we    <= {NUM_CLIENTS{1'b0}};
		l2_refill_we    <= 1'b0;
		l2_lookup_valid <= 1'b0;
		fault_valid     <= 1'b0;

		if (!rst_n) begin
			state          <= S_IDLE;
			active_client  <= 3'd0;
			active_session <= 4'd0;
			active_vpn     <= {VPN_BITS{1'b0}};
			active_offset  <= 12'd0;
			active_type    <= 2'd0;
			r_refill_fault <= 1'b0;
			r_refill_pfn   <= {PPN_BITS{1'b0}};
			r_refill_flags <= 6'd0;
			l1_refill_pfn  <= {PPN_BITS{1'b0}};
			l1_refill_flags<= 6'd0;
			fault_kind     <= 4'd0;
			fault_session  <= 4'd0;
			fault_client   <= 3'd0;
			fault_addr     <= {VA_BITS{1'b0}};
		end else begin
			case (state)
			S_IDLE: begin
				/* Select first client with an L1 miss */
				for (c = NUM_CLIENTS - 1; c >= 0; c = c - 1) begin
					if (client_req_valid[c] && !l1_hit[c]) begin
						active_client   <= c[2:0];
						active_session  <= client_req_session[c*4 +: 4];
						active_vpn      <= client_req_va[c*VA_BITS + 12 +: VPN_BITS];
						active_offset   <= client_req_va[c*VA_BITS +: 12];
						active_type     <= client_req_type[c*2 +: 2];

						l2_lookup_valid   <= 1'b1;
						l2_lookup_session <= client_req_session[c*4 +: 4];
						l2_lookup_vpn     <= client_req_va[c*VA_BITS + 12 +: VPN_BITS];
						state             <= S_L2_LOOKUP;
					end
				end
			end

			S_L2_LOOKUP: begin
				if (l2_hit) begin
					/* L2 hit: refill L1 */
					l1_refill_we[active_client] <= 1'b1;
					l1_refill_pfn               <= l2_hit_pfn;
					l1_refill_flags             <= l2_hit_flags;
					r_refill_fault              <= 1'b0;
					r_refill_pfn                <= l2_hit_pfn;
					r_refill_flags              <= l2_hit_flags;
					state                       <= S_REFILL;
				end else begin
					/* L2 miss: kick Hardware Walker */
					walker_start <= 1'b1;
					state        <= S_WALK;
				end
			end

			S_WALK: begin
				if (walker_done) begin
					/* Successful walk: refill L2 and L1 */
					l2_refill_we                <= 1'b1;
					l1_refill_we[active_client] <= 1'b1;
					l1_refill_pfn               <= walker_out_pfn;
					l1_refill_flags             <= walker_out_flags;
					r_refill_fault              <= 1'b0;
					r_refill_pfn                <= walker_out_pfn;
					r_refill_flags              <= walker_out_flags;
					state                       <= S_REFILL;
				end else if (walker_fault) begin
					/* Trap fault internally: prevent bus access */
					r_refill_fault <= 1'b1;
					fault_valid    <= 1'b1;
					fault_kind     <= walker_fault_kind;
					fault_session  <= active_session;
					fault_client   <= active_client;
					fault_addr     <= {active_vpn, active_offset};
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

	wire unused_ok = &{1'b0, inc_co_unused, dec_bo_unused, walker_busy};
endmodule

`default_nettype wire
