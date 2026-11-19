/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_l2: 256 KiB 16-way set-associative write-back / write-allocate Last
 * Level Cache (LLC) for the memory controller (atg_mc).
 *
 * Sits on the root AMB request path between atg_mc_prot (grant) and
 * am_axi_master.
 *
 * Cache geometry (default 64-byte line):
 *   Capacity: 256 KiB
 *   Line size: LINE_BYTES = 64 bytes (LINE_BITS = 512)
 *   Total lines: 4096
 *   Associativity: 16 ways
 *   Sets: 256 sets (SET_W = 8)
 *   Tag width: TAG_W = LA_W - SET_W
 *
 * Storage:
 *   Data: 16 ways of synchronous dual-port Block RAM (RAMB36E1 inferable).
 *   Tag: 16 ways of tag + valid + dirty bits.
 *   Replacement: 15-bit Tree-PLRU per set.
 *
 * Policies:
 *   Hit: Read in 1-2 cycles; Write updates cache and marks dirty.
 *   Miss: Write-allocate; evicts dirty victim line to AXI master before refill.
 *   Bypass / NC: Passes directly to AXI master without allocating.
 *   DC Priority: Requests with s_req_high or ROOT_CLIENT get prioritized access.
 *   Invalidate / Clean: Line, range, or full cache flush with set-parallel scanning.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_l2 #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 64,
	parameter LINE_SHIFT = 6,
	parameter UW = 21,
	parameter LA_W = ADDR_W - LINE_SHIFT,
	parameter LINE_BITS = LINE_BYTES * 8,
	parameter WAYS = 16,
	parameter SET_W = 8,
	parameter NSETS = 1 << SET_W,
	parameter TAG_W = LA_W - SET_W
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire quiesce,

	/* Upstream request (from atg_mc_prot grant) */
	input wire s_req_valid,
	output wire s_req_ready,
	input wire s_req_write,
	input wire [LA_W-1:0] s_req_line,
	input wire [LINE_BYTES-1:0] s_req_be,
	input wire [LINE_BITS-1:0] s_req_wdata,
	input wire [UW-1:0] s_req_user,
	input wire s_req_id,
	input wire s_req_nc,
	input wire s_req_high,

	/* Upstream response (to atg_mc response router) */
	output reg s_rsp_valid,
	output reg s_rsp_write,
	output reg [UW-1:0] s_rsp_user,
	output reg [LINE_BITS-1:0] s_rsp_rdata,
	output reg s_rsp_error,

	/* Downstream AXI master request (to am_axi_master) */
	output reg m_req_valid,
	input wire m_req_ready,
	output reg m_req_write,
	output reg [LA_W-1:0] m_req_line,
	output reg [LINE_BYTES-1:0] m_req_be,
	output reg [LINE_BITS-1:0] m_req_wdata,
	output reg [UW-1:0] m_req_user,
	output reg m_req_id,
	output reg [7:0] m_req_key,

	/* Downstream AXI master response (from am_axi_master) */
	input wire m_rsp_valid,
	input wire m_rsp_write,
	input wire [UW-1:0] m_rsp_user,
	input wire [LINE_BITS-1:0] m_rsp_rdata,
	input wire m_rsp_error,

	/* Range Invalidate / Clean control */
	input wire ctrl_inv_valid,
	input wire ctrl_inv_clean,
	input wire ctrl_inv_range,
	input wire [LA_W-1:0] ctrl_inv_base,
	input wire [LA_W-1:0] ctrl_inv_limit,
	output reg ctrl_inv_done,

	/* Diagnostics and status */
	output wire idle,
	output wire [3:0] fsm
);

	localparam [SET_W-1:0] MAX_SET = {SET_W{1'b1}};

	/* FSM states */
	localparam S_IDLE         = 4'd0;
	localparam S_LOOKUP       = 4'd1;
	localparam S_EVICT_REQ    = 4'd2;
	localparam S_EVICT_WAIT   = 4'd3;
	localparam S_REFILL_REQ   = 4'd4;
	localparam S_REFILL_WAIT  = 4'd5;
	localparam S_BYPASS_REQ   = 4'd6;
	localparam S_BYPASS_WAIT  = 4'd7;
	localparam S_FLUSH_STEP   = 4'd8;
	localparam S_FLUSH_EVICT  = 4'd9;
	localparam S_FLUSH_WAIT   = 4'd10;
	localparam S_FLUSH_READ   = 4'd11;
	localparam S_READ_WAIT    = 4'd12;
	localparam S_FLUSH_RWAIT  = 4'd13;
	localparam S_WRITE_COMMIT = 4'd14;

	reg [3:0] state;
	reg [3:0] saved_state;
	reg wait_phase;
	assign fsm = state;

	localparam WAY_W = WAYS > 8 ? 4 : (WAYS > 4 ? 3 : (WAYS > 2 ? 2 : 1));

	/* Tag array and metadata: 16 ways x NSETS */
	reg [TAG_W-1:0] way_tag_r [0:WAYS-1];
	reg tag_we;
	reg [SET_W-1:0] tag_waddr;
	reg [TAG_W-1:0] tag_wdata;
	reg [WAY_W-1:0] tag_way;
	wire [SET_W-1:0] tag_raddr = (state == S_FLUSH_STEP || state == S_FLUSH_RWAIT) ? flush_set : req_set;

	genvar gw;
	generate
		for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_tag
			(* ram_style = "distributed" *) reg [TAG_W-1:0] tag_ram [0:NSETS-1];
			always @(posedge clk) begin
				if (tag_we && tag_way == gw[WAY_W-1:0])
					tag_ram[tag_waddr] <= tag_wdata;
			end
			always @(posedge clk) begin
				way_tag_r[gw] <= tag_ram[tag_raddr];
			end
		end
	endgenerate

	/* Registered incoming request */
	reg req_write;
	reg [LA_W-1:0] req_line;
	reg [LINE_BYTES-1:0] req_be;
	reg [LINE_BITS-1:0] req_wdata;
	reg [UW-1:0] req_user;
	reg req_id;
	localparam NSL = LINE_BYTES / 4;
	localparam HALF_BITS = LINE_BITS / 2;

	reg req_nc;
	(* keep = "true", dont_touch = "true" *) reg [NSL-1:0] req_nc_s;
	(* keep = "true", dont_touch = "true" *) reg [NSL-1:0] req_write_s;
	(* keep = "true", dont_touch = "true" *) reg [NSL-1:0] st_lookup_s;
	(* keep = "true", dont_touch = "true" *) reg [NSL-1:0] hit_s;
	(* keep = "true", dont_touch = "true" *) reg [NSL-1:0] victim_dirty_s;
	(* keep = "true", dont_touch = "true" *) reg [WAYS-1:0] meta_lk_dirty;
	(* keep = "true", dont_touch = "true" *) reg [WAYS-1:0] meta_vic_match;
	(* keep = "true", dont_touch = "true" *) reg [WAYS-1:0] meta_req_write;
	(* keep = "true", dont_touch = "true" *) reg [14:0] plru_lk_hit_s;
	reg req_high;

	wire [SET_W-1:0] req_set = req_line[SET_W-1:0];
	wire [TAG_W-1:0] req_tag = req_line[LA_W-1:SET_W];

	/* Synchronous read data from BRAM for each way, plus clean Rule 4 pipeline regs */
	reg [LINE_BITS-1:0] way_rdata [0:WAYS-1];
	(* dont_touch = "true" *) reg [LINE_BITS-1:0] way_rdata_r [0:WAYS-1];
	(* max_fanout = 16 *) reg [SET_W-1:0] bram_raddr [0:WAYS-1];
	(* max_fanout = 16 *) reg [SET_W-1:0] bram_waddr [0:WAYS-1];
	(* keep = "true", dont_touch = "true" *) reg [WAYS-1:0] bram_we_lo_r;
	(* keep = "true", dont_touch = "true" *) reg [WAYS-1:0] bram_we_hi_r;
	reg [LINE_BITS-1:0] bram_wdata_r;
	reg pending_rsp_write;
	reg [UW-1:0] pending_rsp_user;
	reg [LINE_BITS-1:0] pending_rsp_rdata;
	reg pending_rsp_error;

	/* Invalidation / flush control registers */
	reg inv_clean_r;
	reg inv_range_r;
	reg [LA_W-1:0] inv_base_r;
	reg [LA_W-1:0] inv_limit_r;
	reg [SET_W-1:0] flush_set;
	reg inv_active_r;

	/* Arithmetic for flush counters */
	wire [SET_W-1:0] next_flush_set;
	wire flush_set_co;

	am_add #(.W(SET_W)) set_add (
		.a(flush_set), .b({SET_W{1'b0}}), .ci(1'b1),
		.s(next_flush_set), .co(flush_set_co)
	);

	/* Forward declarations for per-way metadata / PLRU outputs */
	wire [WAYS-1:0] way_hit;
	wire [WAYS-1:0] set_dirty;
	reg [WAYS-1:0] way_valid_r;
	reg [WAYS-1:0] way_dirty_r;
	reg [14:0] cur_plru_r;
	reg [WAYS-1:0] set_dirty_r;
	wire set_has_dirty;
	reg [WAY_W-1:0] active_victim_way;
	reg [14:0] plru_out_tree;

	wire meta_flush_clr_all = (state == S_FLUSH_STEP) && !(s_req_valid && s_req_high) && wait_phase && !set_has_dirty;
	wire meta_evict_clr     = (state == S_EVICT_WAIT) && m_rsp_valid && m_rsp_write;
	wire meta_refill_set    = (state == S_REFILL_WAIT) && m_rsp_valid && !m_rsp_write;
	wire meta_fwait_clr     = (state == S_FLUSH_WAIT) && m_rsp_valid && m_rsp_write;
	wire meta_fread_clr     = (state == S_FLUSH_READ) && !(in_range && inv_clean_r) && in_range;
	wire meta_lk_set        = (state == S_LOOKUP);

	/* Per-way isolated valid/dirty arrays to bound control fanout <= NSETS */
	integer mi;
	generate
		for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_meta
			(* ram_style = "registers" *) reg valid_ram [0:NSETS-1];
			(* ram_style = "registers" *) reg dirty_ram [0:NSETS-1];

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n) begin
					for (mi = 0; mi < NSETS; mi = mi + 1) begin
						valid_ram[mi] <= 1'b0;
						dirty_ram[mi] <= 1'b0;
					end
				end else begin
					if (meta_lk_set && meta_lk_dirty[gw])
						dirty_ram[req_set] <= 1'b1;
					if (meta_evict_clr && meta_vic_match[gw])
						dirty_ram[req_set] <= 1'b0;
					if (meta_refill_set && meta_vic_match[gw]) begin
						valid_ram[req_set] <= 1'b1;
						dirty_ram[req_set] <= meta_req_write[gw];
					end
					if (meta_flush_clr_all) begin
						valid_ram[flush_set] <= 1'b0;
						dirty_ram[flush_set] <= 1'b0;
					end
					if (meta_fwait_clr && meta_vic_match[gw]) begin
						dirty_ram[flush_set] <= 1'b0;
						valid_ram[flush_set] <= 1'b0;
					end
					if (meta_fread_clr && meta_vic_match[gw]) begin
						valid_ram[flush_set] <= 1'b0;
						dirty_ram[flush_set] <= 1'b0;
					end
				end
			end

			always @(posedge clk) begin
				way_valid_r[gw] <= valid_ram[req_set];
				way_dirty_r[gw] <= dirty_ram[req_set];
			end

			assign way_hit[gw] = way_valid_r[gw] && (way_tag_r[gw] == req_tag);
			assign set_dirty[gw] = dirty_ram[flush_set] && valid_ram[flush_set];
		end
	endgenerate

	/* Per-bit sliced Tree-PLRU replacement metadata: 15 bits x NSETS */
	genvar gb;
	integer pi;
	generate
		for (gb = 0; gb < 15; gb = gb + 1) begin : g_plru
			(* ram_style = "registers" *) reg plru_bit_ram [0:NSETS-1];
			always @(posedge clk or negedge rst_n) begin
				if (!rst_n) begin
					for (pi = 0; pi < NSETS; pi = pi + 1)
						plru_bit_ram[pi] <= 1'b0;
				end else if ((meta_lk_set && plru_lk_hit_s[gb]) || meta_refill_set) begin
					plru_bit_ram[req_set] <= plru_out_tree[gb];
				end
			end
			always @(posedge clk) begin
				cur_plru_r[gb] <= plru_bit_ram[req_set];
			end
		end
	endgenerate

	wire hit = |way_hit;

	/* Priority encoder for hit way (balanced 2-level tree for <= 10 cmos3 at 16 ways) */
	wire [WAY_W-1:0] hit_way_idx;
	wire hit_msb_nz;
	generate
		if (WAYS == 16) begin : g_hm16
			wire [3:0] g_nz;
			wire [1:0] g_hi [0:3];
			genvar gh;
			for (gh = 0; gh < 4; gh = gh + 1) begin : g_grp
				wire [3:0] wv = way_hit[gh*4 +: 4];
				assign g_nz[gh] = |wv;
				assign g_hi[gh] = wv[3] ? 2'd3 : wv[2] ? 2'd2 : wv[1] ? 2'd1 : 2'd0;
			end
			wire [1:0] top_g = g_nz[3] ? 2'd3 : g_nz[2] ? 2'd2 : g_nz[1] ? 2'd1 : 2'd0;
			assign hit_way_idx = {top_g, g_hi[top_g]};
			assign hit_msb_nz  = |g_nz;
		end else begin : g_hm_gen
			am_msb #(.W(WAYS), .SW(WAY_W)) u_hit_msb (
				.a(way_hit), .n(hit_way_idx), .nz(hit_msb_nz)
			);
		end
	endgenerate
	wire unused_hit_nz = hit_msb_nz;

	/* Registered lookup results captured at end of S_READ_WAIT (wait_phase == 1) */
	reg hit_r;
	reg [WAY_W-1:0] hit_way_r;
	reg [WAY_W-1:0] victim_way_r;
	reg victim_dirty_r;
	reg [TAG_W-1:0] victim_tag_r;
	(* keep = "true", dont_touch = "true" *) reg [NSL*WAY_W-1:0] hit_way_s;
	(* keep = "true", dont_touch = "true" *) reg [NSL*WAY_W-1:0] evict_way_s;

	/* Tree-PLRU victim selection for 16 or 4 ways */
	wire [14:0] cur_plru = cur_plru_r;
	reg [WAY_W-1:0] victim_way_idx;
	/* verilator lint_off WIDTHTRUNC */
	/* verilator lint_off WIDTHEXPAND */
	always @(*) begin
		if (WAYS == 4) begin
			if (!cur_plru[0])
				victim_way_idx = cur_plru[1] ? 2'd0 : 2'd1;
			else
				victim_way_idx = cur_plru[2] ? 2'd2 : 2'd3;
		end else begin
			if (!cur_plru[0]) begin
				/* Go left (0..7) */
				if (!cur_plru[1]) begin
					/* Go left-left (0..3) */
					if (!cur_plru[3])
						victim_way_idx = cur_plru[7] ? 4'd0 : 4'd1;
					else
						victim_way_idx = cur_plru[8] ? 4'd2 : 4'd3;
				end else begin
					/* Go left-right (4..7) */
					if (!cur_plru[4])
						victim_way_idx = cur_plru[9] ? 4'd4 : 4'd5;
					else
						victim_way_idx = cur_plru[10] ? 4'd6 : 4'd7;
				end
			end else begin
				/* Go right (8..15) */
				if (!cur_plru[2]) begin
					/* Go right-left (8..11) */
					if (!cur_plru[5])
						victim_way_idx = cur_plru[11] ? 4'd8 : 4'd9;
					else
						victim_way_idx = cur_plru[12] ? 4'd10 : 4'd11;
				end else begin
					/* Go right-right (12..15) */
					if (!cur_plru[6])
						victim_way_idx = cur_plru[13] ? 4'd12 : 4'd13;
					else
						victim_way_idx = cur_plru[14] ? 4'd14 : 4'd15;
				end
			end
		end
	end
	/* verilator lint_on WIDTHTRUNC */
	/* verilator lint_on WIDTHEXPAND */

	/* Active victim information declared above for g_meta */
	genvar w;

	/* Combinational Tree-PLRU update */
	wire [WAY_W-1:0] cur_access_way = (state == S_LOOKUP) ? hit_way_r : active_victim_way;
	wire [3:0] plru_access_way = {{ (4-WAY_W){1'b0} }, cur_access_way};
	wire [14:0] plru_in_tree = cur_plru_r;

	always @(*) begin
		plru_out_tree = plru_in_tree;
		if (WAYS == 4) begin
			plru_out_tree[0] = !plru_access_way[1];
			if (!plru_access_way[1])
				plru_out_tree[1] = !plru_access_way[0];
			else
				plru_out_tree[2] = !plru_access_way[0];
		end else begin
			plru_out_tree[0] = !plru_access_way[3];
			if (!plru_access_way[3]) begin
				plru_out_tree[1] = !plru_access_way[2];
				if (!plru_access_way[2]) begin
					plru_out_tree[3] = !plru_access_way[1];
					if (!plru_access_way[1])
						plru_out_tree[7] = !plru_access_way[0];
					else
						plru_out_tree[8] = !plru_access_way[0];
				end else begin
					plru_out_tree[4] = !plru_access_way[1];
					if (!plru_access_way[1])
						plru_out_tree[9] = !plru_access_way[0];
					else
						plru_out_tree[10] = !plru_access_way[0];
				end
			end else begin
				plru_out_tree[2] = !plru_access_way[2];
				if (!plru_access_way[2]) begin
					plru_out_tree[5] = !plru_access_way[1];
					if (!plru_access_way[1])
						plru_out_tree[11] = !plru_access_way[0];
					else
						plru_out_tree[12] = !plru_access_way[0];
				end else begin
					plru_out_tree[6] = !plru_access_way[1];
					if (!plru_access_way[1])
						plru_out_tree[13] = !plru_access_way[0];
					else
						plru_out_tree[14] = !plru_access_way[0];
				end
			end
		end
	end

	/* Sliced 32-bit way data muxes driven by per-slice replicated select registers */
	wire [LINE_BITS-1:0] hit_rdata;
	wire [LINE_BITS-1:0] evict_rdata;
	wire [LINE_BITS-1:0] merge_orig_line;
	wire [LINE_BITS-1:0] bram_wdata;
	genvar gs, gw_m;
	generate
		for (gs = 0; gs < NSL; gs = gs + 1) begin : g_rdata_slice
			wire [WAY_W-1:0] hw = hit_way_s[gs*WAY_W +: WAY_W];
			wire [WAY_W-1:0] ew = evict_way_s[gs*WAY_W +: WAY_W];
			wire [31:0] hw_vec [0:WAYS-1];
			wire [31:0] ew_vec [0:WAYS-1];
			for (gw_m = 0; gw_m < WAYS; gw_m = gw_m + 1) begin : g_wvec
				assign hw_vec[gw_m] = way_rdata_r[gw_m][gs*32 +: 32];
				assign ew_vec[gw_m] = way_rdata_r[gw_m][gs*32 +: 32];
			end
			assign hit_rdata[gs*32 +: 32] = hw_vec[hw];
			assign evict_rdata[gs*32 +: 32] = ew_vec[ew];
			assign merge_orig_line[gs*32 +: 32] = st_lookup_s[gs] ? hit_rdata[gs*32 +: 32] : m_rsp_rdata[gs*32 +: 32];
		end
	endgenerate

	/* Combinational line merge */
	wire [LINE_BITS-1:0] merge_new_line = req_wdata;
	wire [LINE_BYTES-1:0] merge_be = req_be;
	reg [LINE_BITS-1:0] merged_line_out;
	integer mb;

	always @(*) begin
		merged_line_out = merge_orig_line;
		for (mb = 0; mb < LINE_BYTES; mb = mb + 1) begin
			if (merge_be[mb])
				merged_line_out[mb*8 +: 8] = merge_new_line[mb*8 +: 8];
		end
	end

	/* Data Block RAMs inferred per way (Rule 4: 0 LUT on ADDR/WE/DI and 0 LUT on DOUT) */
	wire [LINE_BITS-1:0] lookup_mwdata;
	generate
		for (gs = 0; gs < NSL; gs = gs + 1) begin : g_bwdata_slice
			assign bram_wdata[gs*32 +: 32] = st_lookup_s[gs] ? merged_line_out[gs*32 +: 32] :
			                                  ((!req_write_s[gs]) ? m_rsp_rdata[gs*32 +: 32] : merged_line_out[gs*32 +: 32]);
			assign lookup_mwdata[gs*32 +: 32] = req_nc_s[gs] ? req_wdata[gs*32 +: 32] :
			                                     ((!hit_s[gs] && victim_dirty_s[gs]) ? evict_rdata[gs*32 +: 32] : 32'd0);

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n) begin
					pending_rsp_rdata[gs*32 +: 32] <= 32'd0;
				end else if (meta_lk_set && !req_nc_s[gs] && hit_s[gs] && req_write_s[gs]) begin
					pending_rsp_rdata[gs*32 +: 32] <= 32'd0;
				end else if (meta_refill_set) begin
					pending_rsp_rdata[gs*32 +: 32] <= req_write_s[gs] ? 32'd0 : m_rsp_rdata[gs*32 +: 32];
				end
			end
		end
	endgenerate

	generate
		for (w = 0; w < WAYS; w = w + 1) begin : g_bram
			(* ram_style = "block" *) reg [HALF_BITS-1:0] data_mem_lo [0:NSETS-1];
			(* ram_style = "block" *) reg [HALF_BITS-1:0] data_mem_hi [0:NSETS-1];

			always @(posedge clk) begin
				if (bram_we_lo_r[w])
					data_mem_lo[bram_waddr[w]] <= bram_wdata_r[HALF_BITS-1:0];
				if (bram_we_hi_r[w])
					data_mem_hi[bram_waddr[w]] <= bram_wdata_r[LINE_BITS-1:HALF_BITS];
			end

			always @(posedge clk) begin
				way_rdata[w] <= {data_mem_hi[bram_raddr[w]], data_mem_lo[bram_raddr[w]]};
				way_rdata_r[w] <= way_rdata[w];
			end
		end
	endgenerate

	/* Set status computed inside g_meta */
	wire [WAYS-1:0] set_dirty_rev;
	generate
		for (w = 0; w < WAYS; w = w + 1) begin : g_dirty_rev
			assign set_dirty_rev[w] = set_dirty_r[WAYS - 1 - w];
		end
	endgenerate
	wire [WAY_W-1:0] first_dirty_rev_idx;
	am_msb #(.W(WAYS), .SW(WAY_W)) u_dirty_msb (
		.a(set_dirty_rev), .n(first_dirty_rev_idx), .nz(set_has_dirty)
	);
	wire [WAY_W-1:0] first_dirty_way = set_has_dirty ? ~first_dirty_rev_idx : {WAY_W{1'b0}};

	wire [TAG_W-1:0] flush_line_tag = way_tag_r[active_victim_way];
	wire [LA_W-1:0] flush_line_addr = {flush_line_tag, flush_set};

	/* Range check for Range Invalidation (pre-registered in S_FLUSH_RWAIT) */
	wire in_range = !inv_range_r || (flush_line_addr >= inv_base_r && flush_line_addr < inv_limit_r);
	reg [LA_W-1:0] flush_line_addr_r;
	reg            flush_in_range_r;

	assign s_req_ready = (state == S_IDLE && ((!ctrl_inv_valid && !flush) || s_req_high)) ||
	                     (state == S_FLUSH_STEP && s_req_high);
	assign idle = (state == S_IDLE);

	/* Main state machine */
	integer init_w;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state <= S_IDLE;
			saved_state <= S_IDLE;
			wait_phase <= 1'b0;
			s_rsp_valid <= 1'b0;
			s_rsp_write <= 1'b0;
			s_rsp_user <= {UW{1'b0}};
			s_rsp_rdata <= {LINE_BITS{1'b0}};
			s_rsp_error <= 1'b0;
			m_req_valid <= 1'b0;
			m_req_write <= 1'b0;
			m_req_line <= {LA_W{1'b0}};
			m_req_be <= {LINE_BYTES{1'b0}};
			m_req_wdata <= {LINE_BITS{1'b0}};
			m_req_user <= {UW{1'b0}};
			m_req_id <= 1'b0;
			m_req_key <= 8'd0;
			ctrl_inv_done <= 1'b0;
			set_dirty_r <= {WAYS{1'b0}};
			flush_set <= {SET_W{1'b0}};
			inv_active_r <= 1'b0;
			inv_clean_r <= 1'b0;
			inv_range_r <= 1'b0;
			inv_base_r <= {LA_W{1'b0}};
			inv_limit_r <= {LA_W{1'b0}};
			active_victim_way <= {WAY_W{1'b0}};
			flush_line_addr_r <= {LA_W{1'b0}};
			flush_in_range_r <= 1'b0;
			req_write <= 1'b0;
			req_line <= {LA_W{1'b0}};
			req_be <= {LINE_BYTES{1'b0}};
			req_wdata <= {LINE_BITS{1'b0}};
			req_user <= {UW{1'b0}};
			req_id <= 1'b0;
			req_nc <= 1'b0;
			req_nc_s <= {NSL{1'b0}};
			req_write_s <= {NSL{1'b0}};
			st_lookup_s <= {NSL{1'b0}};
			hit_r <= 1'b0;
			hit_s <= {NSL{1'b0}};
			hit_way_r <= {WAY_W{1'b0}};
			hit_way_s <= {(NSL*WAY_W){1'b0}};
			victim_way_r <= {WAY_W{1'b0}};
			evict_way_s <= {(NSL*WAY_W){1'b0}};
			victim_dirty_r <= 1'b0;
			victim_dirty_s <= {NSL{1'b0}};
			victim_tag_r <= {TAG_W{1'b0}};
			meta_lk_dirty <= {WAYS{1'b0}};
			meta_vic_match <= {WAYS{1'b0}};
			meta_req_write <= {WAYS{1'b0}};
			plru_lk_hit_s <= 15'd0;
			req_high <= 1'b0;
			bram_we_lo_r <= {WAYS{1'b0}};
			bram_we_hi_r <= {WAYS{1'b0}};
			bram_wdata_r <= {LINE_BITS{1'b0}};
			pending_rsp_write <= 1'b0;
			pending_rsp_user <= {UW{1'b0}};
			pending_rsp_error <= 1'b0;
			tag_we <= 1'b0;
			tag_way <= {WAY_W{1'b0}};
			tag_waddr <= {SET_W{1'b0}};
			tag_wdata <= {TAG_W{1'b0}};
			for (init_w = 0; init_w < WAYS; init_w = init_w + 1) begin
				bram_raddr[init_w] <= {SET_W{1'b0}};
				bram_waddr[init_w] <= {SET_W{1'b0}};
			end
		end else begin
			s_rsp_valid <= 1'b0;
			ctrl_inv_done <= 1'b0;
			bram_we_lo_r <= {WAYS{1'b0}};
			bram_we_hi_r <= {WAYS{1'b0}};
			tag_we <= 1'b0;
			if (!ctrl_inv_valid)
				inv_active_r <= 1'b0;

			case (state)
				S_IDLE: begin
					if (s_req_valid && s_req_high) begin
						req_write <= s_req_write;
						req_write_s <= {NSL{s_req_write}};
						meta_req_write <= {WAYS{s_req_write}};
						req_line  <= s_req_line;
						req_be    <= s_req_be;
						req_wdata <= s_req_wdata;
						req_user  <= s_req_user;
						req_id    <= s_req_id;
						req_nc    <= s_req_nc;
						req_nc_s  <= {NSL{s_req_nc}};
						req_high  <= s_req_high;
						for (init_w = 0; init_w < WAYS; init_w = init_w + 1)
							bram_raddr[init_w] <= s_req_line[SET_W-1:0];
						wait_phase <= 1'b0;
						state     <= S_READ_WAIT;
					end else if (((ctrl_inv_valid && !inv_active_r) || flush)) begin
						inv_clean_r <= ctrl_inv_valid ? ctrl_inv_clean : 1'b1;
						inv_range_r <= ctrl_inv_valid ? ctrl_inv_range : 1'b0;
						inv_base_r  <= ctrl_inv_base;
						inv_limit_r <= ctrl_inv_limit;
						flush_set   <= {SET_W{1'b0}};
						inv_active_r <= 1'b1;
						state       <= S_FLUSH_STEP;
					end else if (s_req_valid && s_req_ready) begin
						req_write <= s_req_write;
						req_write_s <= {NSL{s_req_write}};
						meta_req_write <= {WAYS{s_req_write}};
						req_line  <= s_req_line;
						req_be    <= s_req_be;
						req_wdata <= s_req_wdata;
						req_user  <= s_req_user;
						req_id    <= s_req_id;
						req_nc    <= s_req_nc;
						req_nc_s  <= {NSL{s_req_nc}};
						req_high  <= s_req_high;
						for (init_w = 0; init_w < WAYS; init_w = init_w + 1)
							bram_raddr[init_w] <= s_req_line[SET_W-1:0];
						wait_phase <= 1'b0;
						state     <= S_READ_WAIT;
					end
				end

				S_READ_WAIT: begin
					if (!wait_phase) begin
						wait_phase <= 1'b1;
					end else begin
						wait_phase     <= 1'b0;
						hit_r          <= hit;
						hit_s          <= {NSL{hit}};
						hit_way_r      <= hit_way_idx;
						hit_way_s      <= {NSL{hit_way_idx}};
						victim_way_r   <= victim_way_idx;
						evict_way_s    <= {NSL{victim_way_idx}};
						victim_dirty_r <= way_valid_r[victim_way_idx] && way_dirty_r[victim_way_idx];
						victim_dirty_s <= {NSL{way_valid_r[victim_way_idx] && way_dirty_r[victim_way_idx]}};
						victim_tag_r   <= way_tag_r[victim_way_idx];
						plru_lk_hit_s  <= {15{!req_nc && hit}};
						for (init_w = 0; init_w < WAYS; init_w = init_w + 1) begin
							meta_lk_dirty[init_w]  <= !req_nc && req_write && way_hit[init_w];
							meta_vic_match[init_w] <= (victim_way_idx == init_w[WAY_W-1:0]);
						end
						st_lookup_s    <= {NSL{1'b1}};
						state          <= S_LOOKUP;
					end
				end

				S_LOOKUP: begin
					st_lookup_s  <= {NSL{1'b0}};
					bram_wdata_r <= bram_wdata;
					s_rsp_rdata  <= hit_rdata;
					m_req_wdata  <= lookup_mwdata;
					if (req_nc) begin
						/* Non-cacheable bypass */
						m_req_valid <= 1'b1;
						m_req_write <= req_write;
						m_req_line  <= req_line;
						m_req_be    <= req_be;
						m_req_user  <= req_user;
						m_req_id    <= req_id;
						m_req_key   <= req_user[15:8];
						state       <= S_BYPASS_REQ;
					end else if (hit_r) begin
						/* Cache hit (plru_bit_ram updated via g_plru) */
						if (!req_write) begin
							/* Read hit */
							s_rsp_valid <= 1'b1;
							s_rsp_write <= 1'b0;
							s_rsp_user  <= req_user;
							s_rsp_error <= 1'b0;
							state       <= (saved_state != S_IDLE) ? saved_state : S_IDLE;
							saved_state <= S_IDLE;
						end else begin
							/* Write hit: pipeline BRAM write (dirty_ram updated via g_meta) */
							for (init_w = 0; init_w < WAYS; init_w = init_w + 1) begin
								bram_we_lo_r[init_w] <= (hit_way_r == init_w[WAY_W-1:0]);
								bram_we_hi_r[init_w] <= (hit_way_r == init_w[WAY_W-1:0]);
								bram_waddr[init_w] <= req_set;
							end
							pending_rsp_write <= 1'b1;
							pending_rsp_user  <= req_user;
							pending_rsp_error <= 1'b0;
							state <= S_WRITE_COMMIT;
						end
					end else begin
						/* Cache miss */
						active_victim_way <= victim_way_r;
						if (victim_dirty_r) begin
							/* Victim is dirty: evict to AXI master */
							m_req_valid <= 1'b1;
							m_req_write <= 1'b1;
							m_req_line  <= {victim_tag_r, req_set};
							m_req_be    <= {LINE_BYTES{1'b1}};
							m_req_user  <= {UW{1'b0}};
							m_req_id    <= req_id;
							m_req_key   <= 8'hFE;
							state       <= S_EVICT_REQ;
						end else begin
							/* Clean/invalid victim: refill directly */
							m_req_valid <= 1'b1;
							m_req_write <= 1'b0;
							m_req_line  <= req_line;
							m_req_be    <= {LINE_BYTES{1'b0}};
							m_req_user  <= req_user;
							m_req_id    <= req_id;
							m_req_key   <= req_user[15:8];
							state       <= S_REFILL_REQ;
						end
					end
				end

				S_WRITE_COMMIT: begin
					s_rsp_valid <= 1'b1;
					s_rsp_write <= pending_rsp_write;
					s_rsp_user  <= pending_rsp_user;
					s_rsp_rdata <= pending_rsp_rdata;
					s_rsp_error <= pending_rsp_error;
					state       <= (saved_state != S_IDLE) ? saved_state : S_IDLE;
					saved_state <= S_IDLE;
				end

				S_EVICT_REQ: begin
					if (m_req_ready) begin
						m_req_valid <= 1'b0;
						state <= S_EVICT_WAIT;
					end
				end

				S_EVICT_WAIT: begin
					if (m_rsp_valid && m_rsp_write) begin
						/* dirty_ram cleared via g_meta */
						m_req_valid <= 1'b1;
						m_req_write <= 1'b0;
						m_req_line  <= req_line;
						m_req_be    <= {LINE_BYTES{1'b0}};
						m_req_wdata <= {LINE_BITS{1'b0}};
						m_req_user  <= req_user;
						m_req_id    <= req_id;
						m_req_key   <= req_user[15:8];
						state <= S_REFILL_REQ;
					end
				end

				S_REFILL_REQ: begin
					if (m_req_ready) begin
						m_req_valid <= 1'b0;
						state <= S_REFILL_WAIT;
					end
				end

				S_REFILL_WAIT: begin
					if (m_rsp_valid && !m_rsp_write) begin
						/* plru_bit_ram and valid_ram/dirty_ram updated via g_plru/g_meta */
						tag_we <= 1'b1;
						tag_way <= active_victim_way;
						tag_waddr <= req_set;
						tag_wdata <= req_tag;
						for (init_w = 0; init_w < WAYS; init_w = init_w + 1) begin
							bram_we_lo_r[init_w] <= (active_victim_way == init_w[WAY_W-1:0]);
							bram_we_hi_r[init_w] <= (active_victim_way == init_w[WAY_W-1:0]);
							bram_waddr[init_w] <= req_set;
						end
						bram_wdata_r <= bram_wdata;

						/* pending_rsp_rdata updated via g_bwdata_slice */
						pending_rsp_write <= req_write;
						pending_rsp_user  <= req_user;
						pending_rsp_error <= m_rsp_error;
						state             <= S_WRITE_COMMIT;
					end
				end

				S_BYPASS_REQ: begin
					if (m_req_ready) begin
						m_req_valid <= 1'b0;
						state <= S_BYPASS_WAIT;
					end
				end

				S_BYPASS_WAIT: begin
					if (m_rsp_valid && (m_rsp_write == req_write)) begin
						s_rsp_valid <= 1'b1;
						s_rsp_write <= m_rsp_write;
						s_rsp_user  <= m_rsp_user;
						s_rsp_rdata <= m_rsp_rdata;
						s_rsp_error <= m_rsp_error;
						state       <= (saved_state != S_IDLE) ? saved_state : S_IDLE;
						saved_state <= S_IDLE;
					end
				end

				S_FLUSH_STEP: begin
					if (s_req_valid && s_req_high) begin
						/* Priority service for DC request */
						req_write <= s_req_write;
						req_write_s <= {NSL{s_req_write}};
						meta_req_write <= {WAYS{s_req_write}};
						req_line  <= s_req_line;
						req_be    <= s_req_be;
						req_wdata <= s_req_wdata;
						req_user  <= s_req_user;
						req_id    <= s_req_id;
						req_nc    <= s_req_nc;
						req_nc_s  <= {NSL{s_req_nc}};
						req_high  <= s_req_high;
						for (init_w = 0; init_w < WAYS; init_w = init_w + 1)
							bram_raddr[init_w] <= s_req_line[SET_W-1:0];
						wait_phase  <= 1'b0;
						saved_state <= S_FLUSH_STEP;
						state       <= S_READ_WAIT;
					end else if (!wait_phase) begin
						wait_phase  <= 1'b1;
						set_dirty_r <= set_dirty;
					end else begin
						wait_phase <= 1'b0;
						if (set_has_dirty) begin
							active_victim_way <= first_dirty_way;
							evict_way_s <= {NSL{first_dirty_way}};
							for (init_w = 0; init_w < WAYS; init_w = init_w + 1) begin
								meta_vic_match[init_w] <= (first_dirty_way == init_w[WAY_W-1:0]);
								bram_raddr[init_w] <= flush_set;
							end
							state <= S_FLUSH_RWAIT;
						end else begin
							/* valid_ram/dirty_ram cleared via g_meta */
							if (flush_set == MAX_SET) begin
								ctrl_inv_done <= 1'b1;
								state <= S_IDLE;
							end else begin
								flush_set <= next_flush_set;
							end
						end
					end
				end

				S_FLUSH_RWAIT: begin
					if (!wait_phase) begin
						wait_phase <= 1'b1;
					end else begin
						wait_phase <= 1'b0;
						flush_line_addr_r <= flush_line_addr;
						flush_in_range_r  <= in_range;
						state <= S_FLUSH_READ;
					end
				end

				S_FLUSH_EVICT: begin
					if (m_req_ready) begin
						m_req_valid <= 1'b0;
						state <= S_FLUSH_WAIT;
					end
				end

				S_FLUSH_WAIT: begin
					if (m_rsp_valid && m_rsp_write) begin
						/* valid_ram/dirty_ram cleared via g_meta */
						wait_phase <= 1'b0;
						state <= S_FLUSH_STEP;
					end
				end

				S_FLUSH_READ: begin
					if (flush_in_range_r && inv_clean_r) begin
						m_req_valid <= 1'b1;
						m_req_write <= 1'b1;
						m_req_line  <= flush_line_addr_r;
						m_req_be    <= {LINE_BYTES{1'b1}};
						m_req_wdata <= evict_rdata;
						m_req_user  <= {UW{1'b0}};
						m_req_id    <= 1'b0; /* Local VRAM */
						m_req_key   <= 8'hFE;
						state       <= S_FLUSH_EVICT;
					end else begin
						/* valid_ram/dirty_ram cleared via g_meta */
						wait_phase <= 1'b0;
						state <= S_FLUSH_STEP;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_co = &{1'b0, flush_set_co, quiesce, req_high, unused_hit_nz};
endmodule

`default_nettype wire
