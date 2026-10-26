/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_coalesce: Memory Controller AXI Burst Coalescer (ws001-p027).
 *
 * Monitors incoming single-line requests (from clients or LLC) and
 * merges consecutive line accesses into multi-beat AXI bursts (up to
 * MAX_BURST beats, e.g. ARLEN=3 for 128B or ARLEN=7 for 256B).
 *
 * Coalescing rules:
 *   1. Requests must be sequential: next_line == active_line + len + 1.
 *   2. Requests must share the same direction (read vs write).
 *   3. Requests must reside within the same 4 KiB address boundary.
 *   4. Bursts are issued when:
 *      - Maximum burst length (MAX_BURST) is reached.
 *      - A non-consecutive or opposite-direction request arrives.
 *      - Idle timeout (TIMEOUT_CYCLES) elapses.
 *
 * Response Demultiplexing:
 *   - Read burst data beats are demuxed to original client tags in order.
 *   - Write completion acknowledgements are distributed to all merged tags.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_coalesce #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter MAX_BURST = 8,	/* Maximum 8 beats: ARLEN/AWLEN 0 to 7 */
	parameter TIMEOUT_CYCLES = 8
) (
	input wire clk,
	input wire rst_n,

	/* Upstream (Client/Single-line) Interface */
	input wire in_req_valid,
	output wire in_req_ready,
	input wire in_req_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] in_req_line,
	input wire [LINE_BYTES*8-1:0] in_req_wdata,
	input wire [7:0] in_req_tag,

	output reg in_rsp_valid,
	output reg in_rsp_write,
	output reg [LINE_BYTES*8-1:0] in_rsp_rdata,
	output reg [7:0] in_rsp_tag,
	output reg in_rsp_error,

	/* Downstream (AXI/Burst) Interface */
	output reg out_req_valid,
	input wire out_req_ready,
	output reg out_req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] out_req_line,
	output reg [7:0] out_req_len,
	output reg [LINE_BYTES*8-1:0] out_req_wdata,
	output reg [7:0] out_req_tag,

	input wire out_rsp_valid,
	input wire out_rsp_write,
	input wire [LINE_BYTES*8-1:0] out_rsp_rdata,
	input wire [7:0] out_rsp_tag,
	input wire out_rsp_last,
	input wire out_rsp_error,

	output wire idle
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam [3:0] TIMEOUT_LIMIT = (TIMEOUT_CYCLES > 0) ? (TIMEOUT_CYCLES[3:0] - 4'd1) : 4'd7;

	localparam [2:0] S_IDLE         = 3'd0;
	localparam [2:0] S_COALESCE     = 3'd1;
	localparam [2:0] S_ISSUE_REQ    = 3'd2;
	localparam [2:0] S_WRITE_BEATS  = 3'd3;
	localparam [2:0] S_WAIT_RSP     = 3'd4;
	localparam [2:0] S_DELIVER_WRSP = 3'd5;

	reg [2:0] state;

	/* Active Coalescing Buffer */
	reg [LA_W-1:0] active_line;
	reg active_write;
	reg [2:0] active_len;
	reg [7:0] active_tags [0:MAX_BURST-1];
	reg [LINE_BITS-1:0] active_wdata [0:MAX_BURST-1];
	reg [3:0] idle_cnt;

	/* Staged Request Buffer (when non-consecutive request arrives) */
	reg staged_v;
	reg staged_write;
	reg [LA_W-1:0] staged_line;
	reg [LINE_BITS-1:0] staged_wdata;
	reg [7:0] staged_tag;

	/* In-flight Burst Tracking */
	reg [2:0] inflight_len;
	reg inflight_write;
	reg [7:0] inflight_tags [0:MAX_BURST-1];
	reg [2:0] wbeat_cnt;
	reg [2:0] rbeat_cnt;
	reg [2:0] wrsp_cnt;

	/* Arithmetic: Length increment using am_add */
	wire [2:0] next_len_w;
	wire len_co;
	am_add #(.W(3)) len_add (
		.a(active_len), .b(3'd0), .ci(1'b1),
		.s(next_len_w), .co(len_co)
	);
	wire [3:0] next_len = {len_co, next_len_w};

	/* Arithmetic: Sequential line calculation using am_add */
	wire [LA_W-1:0] expected_line;
	wire exp_co;
	am_add #(.W(LA_W)) line_add (
		.a(active_line), .b({{(LA_W-3){1'b0}}, next_len[2:0]}), .ci(1'b0),
		.s(expected_line), .co(exp_co)
	);

	/* Arithmetic: Timeout counter using am_add */
	wire [3:0] next_idle_cnt;
	wire idle_co;
	am_add #(.W(4)) idle_add (
		.a(idle_cnt), .b(4'd0), .ci(1'b1),
		.s(next_idle_cnt), .co(idle_co)
	);

	/* Arithmetic: Write beat counter using am_add */
	wire [2:0] next_wbeat;
	wire wbeat_co;
	am_add #(.W(3)) wbeat_add (
		.a(wbeat_cnt), .b(3'd0), .ci(1'b1),
		.s(next_wbeat), .co(wbeat_co)
	);

	/* Arithmetic: Read response beat counter using am_add */
	wire [2:0] next_rbeat;
	wire rbeat_co;
	am_add #(.W(3)) rbeat_add (
		.a(rbeat_cnt), .b(3'd0), .ci(1'b1),
		.s(next_rbeat), .co(rbeat_co)
	);

	/* Arithmetic: Write response delivery counter using am_add */
	wire [2:0] next_wrsp_idx;
	wire wrsp_co;
	am_add #(.W(3)) wrsp_add (
		.a(wrsp_cnt), .b(3'd0), .ci(1'b1),
		.s(next_wrsp_idx), .co(wrsp_co)
	);

	/* Page boundary check (AXI4 forbids bursts crossing 4 KiB boundaries) */
	/* For 32-byte lines, 128 lines per 4 KiB page: bits [6:0] are in-page offset */
	wire is_consec = (in_req_line == expected_line);
	wire is_same_dir = (in_req_write == active_write);
	wire is_same_page = (expected_line[LA_W-1:7] == active_line[LA_W-1:7]);
	wire can_merge = in_req_valid && is_consec && is_same_dir && is_same_page && (active_len < 3'd7);

	assign in_req_ready = (state == S_IDLE) || (state == S_COALESCE && !staged_v);
	assign idle = (state == S_IDLE) && !staged_v && !in_rsp_valid;

	integer i;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			active_line <= {LA_W{1'b0}};
			active_write <= 1'b0;
			active_len <= 3'd0;
			idle_cnt <= 4'd0;
			staged_v <= 1'b0;
			staged_write <= 1'b0;
			staged_line <= {LA_W{1'b0}};
			staged_wdata <= {LINE_BITS{1'b0}};
			staged_tag <= 8'd0;
			inflight_len <= 3'd0;
			inflight_write <= 1'b0;
			wbeat_cnt <= 3'd0;
			rbeat_cnt <= 3'd0;
			wrsp_cnt <= 3'd0;
			out_req_valid <= 1'b0;
			out_req_write <= 1'b0;
			out_req_line <= {LA_W{1'b0}};
			out_req_len <= 8'd0;
			out_req_wdata <= {LINE_BITS{1'b0}};
			out_req_tag <= 8'd0;
			in_rsp_valid <= 1'b0;
			in_rsp_write <= 1'b0;
			in_rsp_rdata <= {LINE_BITS{1'b0}};
			in_rsp_tag <= 8'd0;
			in_rsp_error <= 1'b0;
			for (i = 0; i < MAX_BURST; i = i + 1) begin
				active_tags[i] <= 8'd0;
				active_wdata[i] <= {LINE_BITS{1'b0}};
				inflight_tags[i] <= 8'd0;
			end
		end else begin
			in_rsp_valid <= 1'b0;

			case (state)
				S_IDLE: begin
					if (staged_v) begin
						active_line <= staged_line;
						active_write <= staged_write;
						active_len <= 3'd0;
						active_tags[0] <= staged_tag;
						active_wdata[0] <= staged_wdata;
						idle_cnt <= 4'd0;
						staged_v <= 1'b0;
						state <= S_COALESCE;
					end else if (in_req_valid) begin
						active_line <= in_req_line;
						active_write <= in_req_write;
						active_len <= 3'd0;
						active_tags[0] <= in_req_tag;
						active_wdata[0] <= in_req_wdata;
						idle_cnt <= 4'd0;
						state <= S_COALESCE;
					end
				end

				S_COALESCE: begin
					if (can_merge) begin
						active_len <= next_len[2:0];
						active_tags[next_len[2:0]] <= in_req_tag;
						active_wdata[next_len[2:0]] <= in_req_wdata;
						idle_cnt <= 4'd0;
						if (next_len[2:0] == 3'd7) begin
							/* Reached MAX_BURST (8 beats) */
							state <= S_ISSUE_REQ;
						end
					end else if (in_req_valid) begin
						/* Non-consecutive or different direction: buffer and flush current burst */
						staged_v <= 1'b1;
						staged_write <= in_req_write;
						staged_line <= in_req_line;
						staged_wdata <= in_req_wdata;
						staged_tag <= in_req_tag;
						state <= S_ISSUE_REQ;
					end else begin
						/* Idle timeout */
						if (idle_cnt == TIMEOUT_LIMIT) begin
							state <= S_ISSUE_REQ;
						end else begin
							idle_cnt <= next_idle_cnt;
						end
					end
				end

				S_ISSUE_REQ: begin
					inflight_len <= active_len;
					inflight_write <= active_write;
					for (i = 0; i < MAX_BURST; i = i + 1) begin
						inflight_tags[i] <= active_tags[i];
					end

					out_req_valid <= 1'b1;
					out_req_write <= active_write;
					out_req_line  <= active_line;
					out_req_len   <= {5'd0, active_len};
					out_req_tag   <= active_tags[0];
					out_req_wdata <= active_wdata[0];
					wbeat_cnt     <= 3'd0;

					if (out_req_valid && out_req_ready) begin
						out_req_valid <= 1'b0;
						if (active_write) begin
							if (active_len == 3'd0) begin
								state <= S_WAIT_RSP;
							end else begin
								wbeat_cnt <= 3'd1;
								state <= S_WRITE_BEATS;
							end
						end else begin
							rbeat_cnt <= 3'd0;
							state <= S_WAIT_RSP;
						end
					end
				end

				S_WRITE_BEATS: begin
					out_req_valid <= 1'b1;
					out_req_write <= 1'b1;
					out_req_line  <= active_line;
					out_req_len   <= {5'd0, inflight_len};
					out_req_tag   <= inflight_tags[wbeat_cnt];
					out_req_wdata <= active_wdata[wbeat_cnt];

					if (out_req_ready) begin
						if (wbeat_cnt == inflight_len) begin
							out_req_valid <= 1'b0;
							state <= S_WAIT_RSP;
						end else begin
							wbeat_cnt <= next_wbeat;
						end
					end
				end

				S_WAIT_RSP: begin
					if (!inflight_write) begin
						/* Read response path */
						if (out_rsp_valid && !out_rsp_write) begin
							in_rsp_valid <= 1'b1;
							in_rsp_write <= 1'b0;
							in_rsp_rdata <= out_rsp_rdata;
							in_rsp_tag   <= inflight_tags[rbeat_cnt];
							in_rsp_error <= out_rsp_error;

							if (rbeat_cnt == inflight_len || out_rsp_last) begin
								if (staged_v) begin
									active_line <= staged_line;
									active_write <= staged_write;
									active_len <= 3'd0;
									active_tags[0] <= staged_tag;
									active_wdata[0] <= staged_wdata;
									idle_cnt <= 4'd0;
									staged_v <= 1'b0;
									state <= S_COALESCE;
								end else begin
									state <= S_IDLE;
								end
							end else begin
								rbeat_cnt <= next_rbeat;
							end
						end
					end else begin
						/* Write response path */
						if (out_rsp_valid && out_rsp_write) begin
							in_rsp_valid <= 1'b1;
							in_rsp_write <= 1'b1;
							in_rsp_rdata <= {LINE_BITS{1'b0}};
							in_rsp_tag   <= inflight_tags[0];
							in_rsp_error <= out_rsp_error;

							if (inflight_len == 3'd0) begin
								if (staged_v) begin
									active_line <= staged_line;
									active_write <= staged_write;
									active_len <= 3'd0;
									active_tags[0] <= staged_tag;
									active_wdata[0] <= staged_wdata;
									idle_cnt <= 4'd0;
									staged_v <= 1'b0;
									state <= S_COALESCE;
								end else begin
									state <= S_IDLE;
								end
							end else begin
								wrsp_cnt <= 3'd1;
								state <= S_DELIVER_WRSP;
							end
						end
					end
				end

				S_DELIVER_WRSP: begin
					in_rsp_valid <= 1'b1;
					in_rsp_write <= 1'b1;
					in_rsp_rdata <= {LINE_BITS{1'b0}};
					in_rsp_tag   <= inflight_tags[wrsp_cnt];
					in_rsp_error <= 1'b0;

					if (wrsp_cnt == inflight_len) begin
						if (staged_v) begin
							active_line <= staged_line;
							active_write <= staged_write;
							active_len <= 3'd0;
							active_tags[0] <= staged_tag;
							active_wdata[0] <= staged_wdata;
							idle_cnt <= 4'd0;
							staged_v <= 1'b0;
							state <= S_COALESCE;
						end else begin
							state <= S_IDLE;
						end
					end else begin
						wrsp_cnt <= next_wrsp_idx;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_co = &{1'b0, exp_co, idle_co, wbeat_co, rbeat_co, wrsp_co, out_rsp_tag, next_len[3]};
endmodule

`default_nettype wire
