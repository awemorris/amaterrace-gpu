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
	localparam S_IDLE        = 4'd0;
	localparam S_LOOKUP      = 4'd1;
	localparam S_EVICT_REQ   = 4'd2;
	localparam S_EVICT_WAIT  = 4'd3;
	localparam S_REFILL_REQ  = 4'd4;
	localparam S_REFILL_WAIT = 4'd5;
	localparam S_BYPASS_REQ  = 4'd6;
	localparam S_BYPASS_WAIT = 4'd7;
	localparam S_FLUSH_STEP  = 4'd8;
	localparam S_FLUSH_EVICT = 4'd9;
	localparam S_FLUSH_WAIT  = 4'd10;

	reg [3:0] state;
	reg [3:0] saved_state;
	assign fsm = state;

	/* Tag array and metadata: 16 ways x 256 sets */
	reg [TAG_W-1:0] tag_mem [0:WAYS-1][0:NSETS-1];
	reg valid_mem [0:WAYS-1][0:NSETS-1];
	reg dirty_mem [0:WAYS-1][0:NSETS-1];

	/* Tree-PLRU replacement metadata: 15 bits per set */
	reg [14:0] plru_mem [0:NSETS-1];

	/* Data Block RAM: 16 ways x 256 sets x LINE_BITS */
	reg [LINE_BITS-1:0] data_mem [0:WAYS-1][0:NSETS-1];

	/* Registered incoming request */
	reg req_write;
	reg [LA_W-1:0] req_line;
	reg [LINE_BYTES-1:0] req_be;
	reg [LINE_BITS-1:0] req_wdata;
	reg [UW-1:0] req_user;
	reg req_id;
	reg req_nc;
	reg req_high;

	wire [SET_W-1:0] req_set = req_line[SET_W-1:0];
	wire [TAG_W-1:0] req_tag = req_line[LA_W-1:SET_W];

	/* Synchronous read data from BRAM for each way */
	reg [LINE_BITS-1:0] way_rdata [0:WAYS-1];

	/* Invalidation / flush control registers */
	reg inv_clean_r;
	reg inv_range_r;
	reg [LA_W-1:0] inv_base_r;
	reg [LA_W-1:0] inv_limit_r;
	reg [SET_W-1:0] flush_set;

	/* Arithmetic for flush counters */
	wire [SET_W-1:0] next_flush_set;
	wire flush_set_co;

	am_add #(.W(SET_W)) set_add (
		.a(flush_set), .b({SET_W{1'b0}}), .ci(1'b1),
		.s(next_flush_set), .co(flush_set_co)
	);

	/* Hit detection */
	wire [WAYS-1:0] way_hit;
	wire [WAYS-1:0] way_valid;
	wire [TAG_W-1:0] way_tag [0:WAYS-1];

	genvar w;
	generate
		for (w = 0; w < WAYS; w = w + 1) begin : g_hit
			assign way_valid[w] = valid_mem[w][req_set];
			assign way_tag[w]   = tag_mem[w][req_set];
			assign way_hit[w]   = way_valid[w] && (way_tag[w] == req_tag);
		end
	endgenerate

	wire hit = |way_hit;

	/* Priority encoder for hit way */
	reg [3:0] hit_way_idx;
	integer hit_i;
	always @(*) begin
		hit_way_idx = 4'd0;
		for (hit_i = 0; hit_i < WAYS; hit_i = hit_i + 1) begin
			if (way_hit[hit_i])
				hit_way_idx = hit_i[3:0];
		end
	end

	/* Tree-PLRU victim selection for 16 ways */
	wire [14:0] cur_plru = plru_mem[req_set];
	reg [3:0] victim_way_idx;
	always @(*) begin
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

	/* Active victim information */
	reg [3:0] active_victim_way;

	/* Combinational Tree-PLRU update */
	wire [3:0] plru_access_way = (state == S_LOOKUP) ? hit_way_idx : active_victim_way;
	wire [14:0] plru_in_tree = plru_mem[req_set];
	reg [14:0] plru_out_tree;

	always @(*) begin
		plru_out_tree = plru_in_tree;
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

	/* Combinational line merge */
	wire [LINE_BITS-1:0] merge_orig_line = (state == S_LOOKUP) ? way_rdata[hit_way_idx] : m_rsp_rdata;
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

	/* BRAM Read memory read registers */
	wire [SET_W-1:0] read_set = (s_req_valid && s_req_ready) ? s_req_line[SET_W-1:0] : req_set;

	generate
		for (w = 0; w < WAYS; w = w + 1) begin : g_bram_rd
			always @(posedge clk) begin
				way_rdata[w] <= data_mem[w][read_set];
			end
		end
	endgenerate

	/* Set status for fast set-parallel flush */
	wire [WAYS-1:0] set_dirty;
	generate
		for (w = 0; w < WAYS; w = w + 1) begin : g_set_dirty
			assign set_dirty[w] = dirty_mem[w][flush_set] && valid_mem[w][flush_set];
		end
	endgenerate

	wire set_has_dirty = |set_dirty;

	reg [3:0] first_dirty_way;
	integer fdw_i;
	always @(*) begin
		first_dirty_way = 4'd0;
		for (fdw_i = WAYS - 1; fdw_i >= 0; fdw_i = fdw_i - 1) begin
			if (set_dirty[fdw_i])
				first_dirty_way = fdw_i[3:0];
		end
	end

	wire [TAG_W-1:0] flush_line_tag = tag_mem[first_dirty_way][flush_set];
	wire [LA_W-1:0] flush_line_addr = {flush_line_tag, flush_set};

	/* Range check for Range Invalidation */
	wire in_range = !inv_range_r || (flush_line_addr >= inv_base_r && flush_line_addr < inv_limit_r);

	assign s_req_ready = (state == S_IDLE && (!ctrl_inv_valid || s_req_high)) ||
	                     (state == S_FLUSH_STEP && s_req_high);
	assign idle = (state == S_IDLE);

	/* Main state machine */
	integer init_s, init_w;
	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			saved_state <= S_IDLE;
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
			flush_set <= {SET_W{1'b0}};
			inv_clean_r <= 1'b0;
			inv_range_r <= 1'b0;
			inv_base_r <= {LA_W{1'b0}};
			inv_limit_r <= {LA_W{1'b0}};
			active_victim_way <= 4'd0;
			req_write <= 1'b0;
			req_line <= {LA_W{1'b0}};
			req_be <= {LINE_BYTES{1'b0}};
			req_wdata <= {LINE_BITS{1'b0}};
			req_user <= {UW{1'b0}};
			req_id <= 1'b0;
			req_nc <= 1'b0;
			req_high <= 1'b0;
			for (init_w = 0; init_w < WAYS; init_w = init_w + 1) begin
				for (init_s = 0; init_s < NSETS; init_s = init_s + 1) begin
					valid_mem[init_w][init_s] <= 1'b0;
					dirty_mem[init_w][init_s] <= 1'b0;
					tag_mem[init_w][init_s] <= {TAG_W{1'b0}};
					data_mem[init_w][init_s] <= {LINE_BITS{1'b0}};
				end
			end
			for (init_s = 0; init_s < NSETS; init_s = init_s + 1) begin
				plru_mem[init_s] <= 15'd0;
			end
		end else begin
			s_rsp_valid <= 1'b0;
			ctrl_inv_done <= 1'b0;

			case (state)
				S_IDLE: begin
					if (s_req_valid && s_req_high) begin
						req_write <= s_req_write;
						req_line  <= s_req_line;
						req_be    <= s_req_be;
						req_wdata <= s_req_wdata;
						req_user  <= s_req_user;
						req_id    <= s_req_id;
						req_nc    <= s_req_nc;
						req_high  <= s_req_high;
						state     <= S_LOOKUP;
					end else if (ctrl_inv_valid) begin
						inv_clean_r <= ctrl_inv_clean;
						inv_range_r <= ctrl_inv_range;
						inv_base_r  <= ctrl_inv_base;
						inv_limit_r <= ctrl_inv_limit;
						flush_set   <= {SET_W{1'b0}};
						state       <= S_FLUSH_STEP;
					end else if (s_req_valid) begin
						req_write <= s_req_write;
						req_line  <= s_req_line;
						req_be    <= s_req_be;
						req_wdata <= s_req_wdata;
						req_user  <= s_req_user;
						req_id    <= s_req_id;
						req_nc    <= s_req_nc;
						req_high  <= s_req_high;
						state     <= S_LOOKUP;
					end
				end

				S_LOOKUP: begin
					if (req_nc) begin
						/* Non-cacheable bypass */
						m_req_valid <= 1'b1;
						m_req_write <= req_write;
						m_req_line  <= req_line;
						m_req_be    <= req_be;
						m_req_wdata <= req_wdata;
						m_req_user  <= req_user;
						m_req_id    <= req_id;
						m_req_key   <= req_user[15:8];
						state       <= S_BYPASS_REQ;
					end else if (hit) begin
						/* Cache hit */
						plru_mem[req_set] <= plru_out_tree;
						if (!req_write) begin
							/* Read hit */
							s_rsp_valid <= 1'b1;
							s_rsp_write <= 1'b0;
							s_rsp_user  <= req_user;
							s_rsp_rdata <= way_rdata[hit_way_idx];
							s_rsp_error <= 1'b0;
							state       <= (saved_state != S_IDLE) ? saved_state : S_IDLE;
							saved_state <= S_IDLE;
						end else begin
							/* Write hit */
							data_mem[hit_way_idx][req_set] <= merged_line_out;
							dirty_mem[hit_way_idx][req_set] <= 1'b1;
							s_rsp_valid <= 1'b1;
							s_rsp_write <= 1'b1;
							s_rsp_user  <= req_user;
							s_rsp_rdata <= {LINE_BITS{1'b0}};
							s_rsp_error <= 1'b0;
							state       <= (saved_state != S_IDLE) ? saved_state : S_IDLE;
							saved_state <= S_IDLE;
						end
					end else begin
						/* Cache miss */
						active_victim_way <= victim_way_idx;
						if (valid_mem[victim_way_idx][req_set] && dirty_mem[victim_way_idx][req_set]) begin
							/* Victim is dirty: evict to AXI master */
							m_req_valid <= 1'b1;
							m_req_write <= 1'b1;
							m_req_line  <= {tag_mem[victim_way_idx][req_set], req_set};
							m_req_be    <= {LINE_BYTES{1'b1}};
							m_req_wdata <= way_rdata[victim_way_idx];
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
							m_req_wdata <= {LINE_BITS{1'b0}};
							m_req_user  <= req_user;
							m_req_id    <= req_id;
							m_req_key   <= req_user[15:8];
							state       <= S_REFILL_REQ;
						end
					end
				end

				S_EVICT_REQ: begin
					if (m_req_ready) begin
						m_req_valid <= 1'b0;
						state <= S_EVICT_WAIT;
					end
				end

				S_EVICT_WAIT: begin
					if (m_rsp_valid && m_rsp_write) begin
						dirty_mem[active_victim_way][req_set] <= 1'b0;
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
						plru_mem[req_set] <= plru_out_tree;
						tag_mem[active_victim_way][req_set] <= req_tag;
						valid_mem[active_victim_way][req_set] <= 1'b1;

						if (!req_write) begin
							/* Read miss complete */
							data_mem[active_victim_way][req_set] <= m_rsp_rdata;
							dirty_mem[active_victim_way][req_set] <= 1'b0;
							s_rsp_valid <= 1'b1;
							s_rsp_write <= 1'b0;
							s_rsp_user  <= req_user;
							s_rsp_rdata <= m_rsp_rdata;
							s_rsp_error <= m_rsp_error;
							state       <= (saved_state != S_IDLE) ? saved_state : S_IDLE;
							saved_state <= S_IDLE;
						end else begin
							/* Write-allocate complete */
							data_mem[active_victim_way][req_set] <= merged_line_out;
							dirty_mem[active_victim_way][req_set] <= 1'b1;
							s_rsp_valid <= 1'b1;
							s_rsp_write <= 1'b1;
							s_rsp_user  <= req_user;
							s_rsp_rdata <= {LINE_BITS{1'b0}};
							s_rsp_error <= m_rsp_error;
							state       <= (saved_state != S_IDLE) ? saved_state : S_IDLE;
							saved_state <= S_IDLE;
						end
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
						req_line  <= s_req_line;
						req_be    <= s_req_be;
						req_wdata <= s_req_wdata;
						req_user  <= s_req_user;
						req_id    <= s_req_id;
						req_nc    <= s_req_nc;
						req_high  <= s_req_high;
						saved_state <= S_FLUSH_STEP;
						state     <= S_LOOKUP;
					end else if (in_range && set_has_dirty && inv_clean_r) begin
						m_req_valid <= 1'b1;
						m_req_write <= 1'b1;
						m_req_line  <= flush_line_addr;
						m_req_be    <= {LINE_BYTES{1'b1}};
						m_req_wdata <= data_mem[first_dirty_way][flush_set];
						m_req_user  <= {UW{1'b0}};
						m_req_id    <= 1'b0; /* Local VRAM */
						m_req_key   <= 8'hFE;
						active_victim_way <= first_dirty_way;
						state       <= S_FLUSH_EVICT;
					end else begin
						if (in_range) begin
							for (init_w = 0; init_w < WAYS; init_w = init_w + 1) begin
								valid_mem[init_w][flush_set] <= 1'b0;
								dirty_mem[init_w][flush_set] <= 1'b0;
							end
						end
						if (flush_set == MAX_SET) begin
							ctrl_inv_done <= 1'b1;
							state <= S_IDLE;
						end else begin
							flush_set <= next_flush_set;
						end
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
						dirty_mem[active_victim_way][flush_set] <= 1'b0;
						valid_mem[active_victim_way][flush_set] <= 1'b0;
						state <= S_FLUSH_STEP;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_co = &{1'b0, flush_set_co, quiesce, req_high, flush};
endmodule

`default_nettype wire
