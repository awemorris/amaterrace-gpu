/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_mmu_bridge: Flop-to-flop virtual-to-physical AMB translation bridge.
 *
 * Sits on the request/response path between one GPU execution unit (UNIT_ADDR_W
 * virtual line space) and atg_mc / Fat-Tree NoC (MC_ADDR_W physical line space).
 * All upstream/downstream request and response ports are registered at the module
 * boundary (Rule 3: zero combinational feedthrough, <= 4 LUT levels per stage).
 *
 * Operation:
 *   1. Accepts an upstream AMB request when idle (u_req_ready = 1) and latches it.
 *   2. Submits {session, va, req_type} to one client port of atg_mmu (mmu_req_*).
 *      - On mmu_ack: checks W/X permissions against mmu_flags when CHECK_PERM=1.
 *        If permitted, forwards the translated physical line address (m_req_valid)
 *        to atg_mc; once m_req_ready accepts it, returns to idle for the next request.
 *        If permission fails, raises perm_fault_valid for 1 cycle, suppresses MC
 *        access completely, and returns a synthetic u_rsp_error=1 response.
 *      - On mmu_fault: suppresses MC access completely and returns u_rsp_error=1.
 *   3. Downstream MC responses take strict priority over synthetic error responses
 *      on u_rsp_* so responses are never dropped or stalled (AMB has no rsp_ready).
 *   4. Maintains an exact 8-bit in-flight transaction count (accepted u_req to
 *      delivered u_rsp) without multi-client simultaneous-fire drift.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_mmu_bridge #(
	parameter UNIT_ADDR_W = 32,
	parameter MC_ADDR_W = 40,
	parameter VA_BITS = 32,
	parameter PA_BITS = 40,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter CHECK_PERM = 1
) (
	input wire clk,
	input wire rst_n,

	/* Upstream AMB unit port (VA space) */
	input wire u_req_valid,
	output reg u_req_ready,
	input wire u_req_write,
	input wire u_req_exec,
	input wire [UNIT_ADDR_W-LINE_SHIFT-1:0] u_req_line,
	input wire [LINE_BYTES-1:0] u_req_be,
	input wire [LINE_BYTES*8-1:0] u_req_wdata,
	input wire [7:0] u_req_tag,
	input wire [3:0] u_req_session,
	input wire u_req_chk,
	input wire u_req_tbl,
	input wire [5:0] u_req_slot,
	output reg u_rsp_valid,
	output reg u_rsp_write,
	output reg [7:0] u_rsp_tag,
	output reg [LINE_BYTES*8-1:0] u_rsp_rdata,
	output reg u_rsp_error,

	/* To/from one client slice of atg_mmu */
	output reg mmu_req_valid,
	output wire [3:0] mmu_req_session,
	output wire [VA_BITS-1:0] mmu_req_va,
	output wire [1:0] mmu_req_type,
	input wire mmu_ack,
	input wire [PA_BITS-1:0] mmu_pa,
	input wire [5:0] mmu_flags,
	input wire mmu_fault,

	/* Downstream AMB port (PA space -> MC / NoC) */
	output reg m_req_valid,
	input wire m_req_ready,
	output wire m_req_write,
	output wire [MC_ADDR_W-LINE_SHIFT-1:0] m_req_line,
	output wire [LINE_BYTES-1:0] m_req_be,
	output wire [LINE_BYTES*8-1:0] m_req_wdata,
	output wire [7:0] m_req_tag,
	output wire m_req_chk,
	output wire m_req_tbl,
	output wire [5:0] m_req_slot,
	output wire [3:0] m_req_session,
	output wire [1:0] m_req_exec_type,
	input wire m_rsp_valid,
	input wire m_rsp_write,
	input wire [7:0] m_rsp_tag,
	input wire [LINE_BYTES*8-1:0] m_rsp_rdata,
	input wire m_rsp_error,

	/* L1/L2 cached hit permission fault reporting & exact in-flight counter */
	output reg perm_fault_valid,
	output reg [3:0] perm_fault_session,
	output reg [VA_BITS-1:0] perm_fault_addr,
	output wire [7:0] inflight_cnt
);
	localparam UNIT_LA_W = UNIT_ADDR_W - LINE_SHIFT;
	localparam MC_LA_W   = MC_ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;

	localparam [1:0] ST_IDLE    = 2'd0;
	localparam [1:0] ST_XLAT    = 2'd1;
	localparam [1:0] ST_MC_REQ  = 2'd2;
	localparam [1:0] ST_ERR_RSP = 2'd3;

	reg [1:0] st;

	/* Latched upstream request */
	reg q_write;
	reg q_exec;
	reg [VA_BITS-1:0] q_va;
	reg [LINE_BYTES-1:0] q_be;
	reg [LINE_BITS-1:0] q_wdata;
	reg [7:0] q_tag;
	reg [3:0] q_sess;
	reg q_chk;
	reg q_tbl;
	reg [5:0] q_slot;
	reg [MC_LA_W-1:0] q_pa_line;

	wire [63:0] u_line64 = {{(64-UNIT_LA_W){1'b0}}, u_req_line};
	wire [63:0] mmu_pa64 = {{(64-PA_BITS){1'b0}}, mmu_pa};
	wire [VA_BITS-1:0] next_va = {u_line64[VA_BITS-LINE_SHIFT-1:0], {LINE_SHIFT{1'b0}}};

	wire [1:0] q_exec_type = q_exec ? 2'd2 : (q_write ? 2'd1 : 2'd0);
	/* flags: [0]=V, [1]=LOCAL, [2]=W, [3]=X */
	wire perm_ok = (CHECK_PERM == 0) ||
		((!q_write || mmu_flags[2]) && (!q_exec || mmu_flags[3]));

	assign mmu_req_session = q_sess;
	assign mmu_req_va      = q_va;
	assign mmu_req_type    = q_exec_type;

	assign m_req_write     = q_write;
	assign m_req_line      = q_pa_line;
	assign m_req_be        = q_be;
	assign m_req_wdata     = q_wdata;
	assign m_req_tag       = q_tag;
	assign m_req_chk       = q_chk;
	assign m_req_tbl       = q_tbl;
	assign m_req_slot      = q_slot;
	assign m_req_session   = q_sess;
	assign m_req_exec_type = q_exec_type;

	/* Exact single-port in-flight counter (accepted u_req to delivered u_rsp) */
	reg [7:0] r_inflight;
	wire u_take = u_req_valid && u_req_ready;
	wire send_err = (st == ST_ERR_RSP) && !m_rsp_valid;
	wire u_rsp_next_v = m_rsp_valid || send_err;
	wire cnt_en  = u_take ^ u_rsp_valid;
	wire cnt_sub = u_rsp_valid;
	wire [7:0] next_inflight;
	wire unused_cnt_co;

	am_addsub #(.W(8), .USE_DSP(0)) u_cnt_addsub (
		.a(r_inflight),
		.b(8'd1),
		.sub(cnt_sub),
		.s(next_inflight),
		.co(unused_cnt_co)
	);
	assign inflight_cnt = r_inflight;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			st                 <= ST_IDLE;
			u_req_ready        <= 1'b1;
			mmu_req_valid      <= 1'b0;
			m_req_valid        <= 1'b0;
			perm_fault_valid   <= 1'b0;
			perm_fault_session <= 4'd0;
			perm_fault_addr    <= {VA_BITS{1'b0}};
			q_write            <= 1'b0;
			q_exec             <= 1'b0;
			q_va               <= {VA_BITS{1'b0}};
			q_be               <= {LINE_BYTES{1'b0}};
			q_wdata            <= {LINE_BITS{1'b0}};
			q_tag              <= 8'd0;
			q_sess             <= 4'd0;
			q_chk              <= 1'b0;
			q_tbl              <= 1'b0;
			q_slot             <= 6'd0;
			q_pa_line          <= {MC_LA_W{1'b0}};
			u_rsp_valid        <= 1'b0;
			u_rsp_write        <= 1'b0;
			u_rsp_tag          <= 8'd0;
			u_rsp_rdata        <= {LINE_BITS{1'b0}};
			u_rsp_error        <= 1'b0;
			r_inflight         <= 8'd0;
		end else begin
			perm_fault_valid <= 1'b0;

			if (cnt_en)
				r_inflight <= next_inflight;

			/* Response path: real MC response beats synthetic error response */
			u_rsp_valid <= u_rsp_next_v;
			if (m_rsp_valid) begin
				u_rsp_write <= m_rsp_write;
				u_rsp_tag   <= m_rsp_tag;
				u_rsp_rdata <= m_rsp_rdata;
				u_rsp_error <= m_rsp_error;
			end else if (send_err) begin
				u_rsp_write <= q_write;
				u_rsp_tag   <= q_tag;
				u_rsp_rdata <= {LINE_BITS{1'b0}};
				u_rsp_error <= 1'b1;
			end

			case (st)
			ST_IDLE: begin
				if (u_take) begin
					u_req_ready   <= 1'b0;
					mmu_req_valid <= 1'b1;
					q_write       <= u_req_write;
					q_exec        <= u_req_exec;
					q_va          <= next_va;
					q_be          <= u_req_be;
					q_wdata       <= u_req_wdata;
					q_tag         <= u_req_tag;
					q_sess        <= u_req_session;
					q_chk         <= u_req_chk;
					q_tbl         <= u_req_tbl;
					q_slot        <= u_req_slot;
					st            <= ST_XLAT;
				end
			end

			ST_XLAT: begin
				if (mmu_fault) begin
					mmu_req_valid <= 1'b0;
					st            <= ST_ERR_RSP;
				end else if (mmu_ack) begin
					mmu_req_valid <= 1'b0;
					if (!perm_ok) begin
						perm_fault_valid   <= 1'b1;
						perm_fault_session <= q_sess;
						perm_fault_addr    <= q_va;
						st                 <= ST_ERR_RSP;
					end else begin
						q_pa_line   <= mmu_pa64[LINE_SHIFT +: MC_LA_W];
						m_req_valid <= 1'b1;
						st          <= ST_MC_REQ;
					end
				end
			end

			ST_MC_REQ: begin
				if (m_req_valid && m_req_ready) begin
					m_req_valid <= 1'b0;
					u_req_ready <= 1'b1;
					st          <= ST_IDLE;
				end
			end

			ST_ERR_RSP: begin
				if (!m_rsp_valid) begin
					u_req_ready <= 1'b1;
					st          <= ST_IDLE;
				end
			end

			default: st <= ST_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, unused_cnt_co, mmu_flags[5:4], mmu_flags[1:0], u_line64, mmu_pa64};
endmodule

`default_nettype wire
