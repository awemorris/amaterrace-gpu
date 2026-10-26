/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_cache: 4-Way Set-Associative L1 Tile Cache for ROP.
 *
 * Parameters:
 *   LINE_BYTES: 64 bytes (1 AMB burst line).
 *   WAYS: 4 ways.
 *   SETS_LOG2: 5 (32 sets -> 32 * 4 * 64B = 8 KiB capacity).
 *
 * Features:
 *   - RAMB36E1 block RAM inference for 64B data lines with per-byte write enable.
 *   - Parallel 4-way tag comparison and 1-cycle hit latency.
 *   - Tree-PLRU pseudo-LRU replacement policy.
 *   - Write-back policy with dirty bit tracking.
 *   - Line eviction and memory refill via AMB client interface.
 *   - Flush control to drain all dirty lines to memory.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_cache #(
	parameter LINE_BYTES = 64,
	parameter WAYS       = 4,
	parameter SETS_LOG2  = 5    /* 32 sets * 4 ways * 64B = 8 KiB */
) (
	input  wire        clk,
	input  wire        rst_n,

	/* ROP pipeline read/write port */
	input  wire        req_valid,
	output wire        req_ready,
	input  wire        req_write,
	input  wire [31:0] req_addr,
	input  wire [LINE_BYTES-1:0]   req_be,
	input  wire [LINE_BYTES*8-1:0] req_wdata,
	output reg         rsp_valid,
	output reg  [LINE_BYTES*8-1:0] rsp_rdata,

	/* External AMB / L2 bus port */
	output reg         mem_req_valid,
	input  wire        mem_req_ready,
	output reg         mem_req_write,
	output reg  [32-((LINE_BYTES==64)?6:5)-1:0] mem_req_line,
	output reg  [LINE_BYTES*8-1:0] mem_req_wdata,
	input  wire        mem_rsp_valid,
	input  wire [LINE_BYTES*8-1:0] mem_rsp_rdata,

	/* Optional Flush & Status */
	input  wire        flush,
	output wire        busy
);
	localparam LINE_SHIFT = (LINE_BYTES == 64) ? 6 : 5;
	localparam NUM_SETS   = 1 << SETS_LOG2;
	localparam TAG_W      = 32 - SETS_LOG2 - LINE_SHIFT;
	localparam LA_W       = 32 - LINE_SHIFT;
	localparam TOTAL_LINES = WAYS * NUM_SETS;

	/* Address decomposition */
	wire [LINE_SHIFT-1:0] byte_off = req_addr[LINE_SHIFT-1:0];
	wire [SETS_LOG2-1:0] set_idx  = req_addr[LINE_SHIFT+SETS_LOG2-1 : LINE_SHIFT];
	wire [TAG_W-1:0]     addr_tag = req_addr[31 : LINE_SHIFT+SETS_LOG2];

	/* Tag, Valid, Dirty, and Tree-PLRU storage */
	reg [WAYS-1:0]  valid [0:NUM_SETS-1];
	reg [WAYS-1:0]  dirty [0:NUM_SETS-1];
	reg [TAG_W-1:0] tag   [0:NUM_SETS-1][0:WAYS-1];
	reg [2:0]       plru  [0:NUM_SETS-1];

	/* Block RAM Data Storage (8 KiB total = 128 lines * 64 bytes) */
	(* ram_style = "block" *)
	reg [LINE_BYTES*8-1:0] data_mem [0:TOTAL_LINES-1];

	/* Hit Detection */
	wire [WAYS-1:0] way_match;
	genvar gw;
	generate
	for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_match
		assign way_match[gw] = valid[set_idx][gw] && (tag[set_idx][gw] == addr_tag);
	end
	endgenerate

	wire hit = |way_match;
	reg [1:0] hit_way;
	always @(*) begin
		if (way_match[0])      hit_way = 2'd0;
		else if (way_match[1]) hit_way = 2'd1;
		else if (way_match[2]) hit_way = 2'd2;
		else                   hit_way = 2'd3;
	end

	/* Tree-PLRU victim selection */
	function [1:0] get_victim;
		input [WAYS-1:0] v_val;
		input [2:0] p;
		begin
			if (!v_val[0])      get_victim = 2'd0;
			else if (!v_val[1]) get_victim = 2'd1;
			else if (!v_val[2]) get_victim = 2'd2;
			else if (!v_val[3]) get_victim = 2'd3;
			else if (!p[0]) begin
				get_victim = (!p[1]) ? 2'd0 : 2'd1;
			end else begin
				get_victim = (!p[2]) ? 2'd2 : 2'd3;
			end
		end
	endfunction

	/* Tree-PLRU state update */
	function [2:0] update_plru;
		input [2:0] p;
		input [1:0] acc_way;
		begin
			case (acc_way)
			2'd0: update_plru = {p[2], 1'b1, 1'b1};
			2'd1: update_plru = {p[2], 1'b0, 1'b1};
			2'd2: update_plru = {1'b1, p[1], 1'b0};
			2'd3: update_plru = {1'b0, p[1], 1'b0};
			default: update_plru = p;
			endcase
		end
	endfunction

	/* FSM States */
	localparam [2:0]
		S_IDLE        = 3'd0,
		S_EVICT       = 3'd1,
		S_REFILL_REQ  = 3'd2,
		S_REFILL_WAIT = 3'd3,
		S_FLUSH_CHECK = 3'd4,
		S_FLUSH_WRITE = 3'd5;

	reg [2:0] st;

	/* Registered Request Buffers for Miss/Refill */
	reg        cur_req_write;
	reg [31:0] cur_req_addr;
	reg [LINE_BYTES-1:0] cur_req_be;
	reg [LINE_BYTES*8-1:0] cur_req_wdata;
	reg [1:0]  cur_victim_way;

	wire [SETS_LOG2-1:0] cur_set = cur_req_addr[LINE_SHIFT+SETS_LOG2-1 : LINE_SHIFT];
	wire [TAG_W-1:0]     cur_tag = cur_req_addr[31 : LINE_SHIFT+SETS_LOG2];

	/* Flush scan state */
	reg [SETS_LOG2-1:0] flush_set;
	reg [1:0]           flush_way;
	wire [SETS_LOG2-1:0] next_flush_set;
	wire [1:0]           next_flush_way;
	wire flush_set_co, flush_way_co;

	am_add #(.W(SETS_LOG2)) u_fset (.a(flush_set), .b({{(SETS_LOG2-1){1'b0}}, 1'b1}), .ci(1'b0),
		.s(next_flush_set), .co(flush_set_co));
	am_add #(.W(2)) u_fway (.a(flush_way), .b(2'd1), .ci(1'b0),
		.s(next_flush_way), .co(flush_way_co));

	/* Handshake */
	assign req_ready = (st == S_IDLE) && (!flush) && (hit || !req_valid);
	assign busy = (st != S_IDLE) || flush;

	/* Helper for byte-masked write */
	/* verilator lint_off BLKSEQ */
	function [LINE_BYTES*8-1:0] apply_be;
		input [LINE_BYTES*8-1:0] orig_line;
		input [LINE_BYTES*8-1:0] new_data;
		input [LINE_BYTES-1:0]   be;
		integer b;
		reg [LINE_BYTES*8-1:0] res;
		begin
			res = orig_line;
			for (b = 0; b < LINE_BYTES; b = b + 1) begin
				if (be[b])
					res[8*b +: 8] = new_data[8*b +: 8];
			end
			apply_be = res;
		end
	endfunction
	/* verilator lint_on BLKSEQ */

	integer i, j;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			rsp_valid <= 1'b0;
			rsp_rdata <= {(LINE_BYTES*8){1'b0}};
			mem_req_valid <= 1'b0;
			mem_req_write <= 1'b0;
			mem_req_line <= {LA_W{1'b0}};
			mem_req_wdata <= {(LINE_BYTES*8){1'b0}};
			flush_set <= {SETS_LOG2{1'b0}};
			flush_way <= 2'd0;
			cur_req_write <= 1'b0;
			cur_req_addr <= 32'd0;
			cur_req_be <= {LINE_BYTES{1'b0}};
			cur_req_wdata <= {(LINE_BYTES*8){1'b0}};
			cur_victim_way <= 2'd0;
			for (i = 0; i < NUM_SETS; i = i + 1) begin
				valid[i] <= {WAYS{1'b0}};
				dirty[i] <= {WAYS{1'b0}};
				plru[i]  <= 3'd0;
				for (j = 0; j < WAYS; j = j + 1)
					tag[i][j] <= {TAG_W{1'b0}};
			end
		end else begin
			rsp_valid <= 1'b0;

			case (st)
			S_IDLE: begin
				if (flush) begin
					flush_set <= {SETS_LOG2{1'b0}};
					flush_way <= 2'd0;
					st <= S_FLUSH_CHECK;
				end else if (req_valid) begin
					if (hit) begin
						/* 1-cycle Cache Hit */
						plru[set_idx] <= update_plru(plru[set_idx], hit_way);
						if (req_write) begin
							data_mem[{set_idx, hit_way}] <= apply_be(data_mem[{set_idx, hit_way}], req_wdata, req_be);
							dirty[set_idx][hit_way] <= 1'b1;
							rsp_valid <= 1'b1;
						end else begin
							rsp_valid <= 1'b1;
							rsp_rdata <= data_mem[{set_idx, hit_way}];
						end
					end else begin
						/* Cache Miss: initiate eviction / refill */
						cur_req_write <= req_write;
						cur_req_addr  <= req_addr;
						cur_req_be    <= req_be;
						cur_req_wdata <= req_wdata;
						cur_victim_way <= get_victim(valid[set_idx], plru[set_idx]);

						if (valid[set_idx][get_victim(valid[set_idx], plru[set_idx])] &&
						    dirty[set_idx][get_victim(valid[set_idx], plru[set_idx])]) begin
							st <= S_EVICT;
						end else begin
							st <= S_REFILL_REQ;
						end
					end
				end
			end

			S_EVICT: begin
				/* Write back victim line to memory */
				mem_req_valid <= 1'b1;
				mem_req_write <= 1'b1;
				mem_req_line  <= {tag[cur_set][cur_victim_way], cur_set};
				mem_req_wdata <= data_mem[{cur_set, cur_victim_way}];

				if (mem_req_valid && mem_req_ready) begin
					mem_req_valid <= 1'b0;
					st <= S_REFILL_REQ;
				end
			end

			S_REFILL_REQ: begin
				/* Request new line from memory */
				mem_req_valid <= 1'b1;
				mem_req_write <= 1'b0;
				mem_req_line  <= cur_req_addr[31:LINE_SHIFT];

				if (mem_req_valid && mem_req_ready) begin
					mem_req_valid <= 1'b0;
					st <= S_REFILL_WAIT;
				end
			end

			S_REFILL_WAIT: begin
				if (mem_rsp_valid) begin
					/* Refill complete: install line into cache */
					valid[cur_set][cur_victim_way] <= 1'b1;
					tag[cur_set][cur_victim_way]   <= cur_tag;
					plru[cur_set] <= update_plru(plru[cur_set], cur_victim_way);

					if (cur_req_write) begin
						data_mem[{cur_set, cur_victim_way}] <= apply_be(mem_rsp_rdata, cur_req_wdata, cur_req_be);
						dirty[cur_set][cur_victim_way] <= 1'b1;
						rsp_valid <= 1'b1;
					end else begin
						data_mem[{cur_set, cur_victim_way}] <= mem_rsp_rdata;
						dirty[cur_set][cur_victim_way] <= 1'b0;
						rsp_valid <= 1'b1;
						rsp_rdata <= mem_rsp_rdata;
					end
					st <= S_IDLE;
				end
			end

			S_FLUSH_CHECK: begin
				if (valid[flush_set][flush_way] && dirty[flush_set][flush_way]) begin
					st <= S_FLUSH_WRITE;
				end else begin
					/* Advance flush pointer */
					flush_way <= next_flush_way;
					if (next_flush_way == 2'd0) begin
						flush_set <= next_flush_set;
						if (next_flush_set == {SETS_LOG2{1'b0}}) begin
							st <= S_IDLE;
						end
					end
				end
			end

			S_FLUSH_WRITE: begin
				mem_req_valid <= 1'b1;
				mem_req_write <= 1'b1;
				mem_req_line  <= {tag[flush_set][flush_way], flush_set};
				mem_req_wdata <= data_mem[{flush_set, flush_way}];

				if (mem_req_valid && mem_req_ready) begin
					mem_req_valid <= 1'b0;
					dirty[flush_set][flush_way] <= 1'b0;
					/* Advance */
					flush_way <= next_flush_way;
					if (next_flush_way == 2'd0) begin
						flush_set <= next_flush_set;
						if (next_flush_set == {SETS_LOG2{1'b0}}) begin
							st <= S_IDLE;
						end else begin
							st <= S_FLUSH_CHECK;
						end
					end else begin
						st <= S_FLUSH_CHECK;
					end
				end
			end

			default: st <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, flush_set_co, flush_way_co, byte_off, cur_req_addr[LINE_SHIFT-1:0]};
endmodule

`default_nettype wire
