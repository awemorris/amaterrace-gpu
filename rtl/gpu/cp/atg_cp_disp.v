/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_disp: the command processor's side of a DISP2 display controller
 * (spec/gpu/cp/atg_cp_disp.md, docs/ghci.md section 13.2, design §18.4):
 * DISP_SET and FLIP of atg_cp_seq, the host's gate to the controller's
 * registers, the plane slots and the flip records.  It reaches the DC
 * (atg_dc, a child of atg_top) through its register bus (d_*) and flips
 * (flip_*, taken).  rst_n is the board reset: CTRL.RESET of the GPU does
 * not clear the slots or the records still to write.
 *
 *   active      cp_state RUNNING or HALTING: only then do the sequencer's
 *               writes and kicks take effect; outside, disp_wait is 0.
 *   DISP_SET    a payload write 0x3C0 + k goes to the DC's word k in its
 *               cycle; K_DISP_IDLE (kick_idle) waits for dc_idle.
 *   FLIP        0x3B8-0x3BB stage plane, base, record, value; kick_flip
 *               checks them (fault 3, combinational in the kick's cycle so
 *               that the CP is FAULTED before the next header) or makes
 *               base the plane's pending image with its slot {record,
 *               value}.
 *   take        taken[p] with a slot: TAKENp = value (bit 31: cancelled),
 *               the record {TAKENp, frame_count} is due (record 0: none,
 *               ev_flip at once).
 *   records     one FSM, IDLE → REQ → RSP: a due record (plane 0 first) is
 *               written in IDLE, RUNNING or HALTING only, 8 bytes in one
 *               beat; ev_flip after the response, dc_err[0] on its error.
 *   host gate   a host write of the window by its kind: S (CTRL, FB_NEXT,
 *               FB_STRIDE, FB_SIZE, the timing, SYNC_POL, PCLK_SEL) only in
 *               IDLE, HALTED and FAULTED, else dropped with dc_err[1]; C,
 *               L, I and W always; R dropped.  A passed write goes to the
 *               DC in its cycle, or through a one-entry buffer when the
 *               sequencer writes in that cycle (the sequencer's next write
 *               waits while the buffer is full: disp_wait).
 *   reads       hcr_rdata in the window: the DC's word, STATUS[31] (a
 *               record due) and TAKEN0/1.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_disp #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter NPLANES = 1,	/* 1, or 2 with the cursor plane */
	parameter [31:0] LOCAL_BASE = 32'd0,	/* the MEM capability's local memory */
	parameter [31:0] LOCAL_BYTES = 32'd0,	/* 0: no local memory check */
	parameter [9:0] BASE_IDX = 10'h080	/* HCR word index of the window (64-word aligned) */
) (
	input wire clk,
	input wire rst_n,
	/* HCR snoop port (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	input wire [3:0] cp_state,
	/* From atg_cp_seq */
	input wire uop_we,
	input wire [9:0] uop_idx,
	input wire [31:0] uop_wdata,
	input wire kick_flip,
	input wire kick_idle,
	input wire [7:0] seq_tag,
	output wire disp_wait,
	input wire [ADDR_W-1:0] aperture_base,
	input wire [ADDR_W-1:0] aperture_limit,
	output wire fault,
	output wire [3:0] fault_kind,
	output wire [31:0] fault_addr,
	output wire [7:0] fault_tag,
	/* The DC (atg_dc) */
	output wire d_we,
	output wire [5:0] d_idx,
	output wire [31:0] d_wdata,
	output wire [31:0] d_wmask,
	output wire [5:0] d_ridx,
	input wire [31:0] d_rdata,
	output wire flip_valid,
	output wire flip_plane,
	output wire [31:0] flip_base,
	input wire [1:0] taken,
	input wire [1:0] taken_cancel,
	input wire [1:0] dc_pending,
	input wire dc_idle,
	input wire [31:0] frame_count,
	output wire [1:0] dc_err,
	/* AMB client port: the record writer (a leaf of the CP's am_amb_mux) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error,
	output wire ev_flip
);
	`include "ghci_regs.vh"

	localparam [32:0] LOCAL_END = {1'b0, LOCAL_BASE} + {1'b0, LOCAL_BYTES};
	localparam NW = LINE_BYTES / 8;	/* 8-byte words in a line */
	localparam WSEL = LINE_SHIFT - 3;

	/* The CP's state. */
	wire active = cp_state == GHCI_ST_RUNNING || cp_state == GHCI_ST_HALTING;
	wire host_s = cp_state == GHCI_ST_IDLE || cp_state == GHCI_ST_HALTED ||
		cp_state == GHCI_ST_FAULTED;
	wire rec_ok = cp_state == GHCI_ST_IDLE || active;

	/* ------------------------------------------------ the host's gate */

	wire h_in = hcr_we && hcr_widx[9:6] == BASE_IDX[9:6];
	wire [5:0] h_k = hcr_widx[5:0];
	/* S: CTRL 4, FB_NEXT 9, FB_STRIDE 10, FB_SIZE 11, timing and SYNC_POL 12-20, PCLK_SEL 22. */
	wire h_s = h_k == 6'd4 || (h_k >= 6'd9 && h_k <= 6'd20) || h_k == 6'd22;
	/* C 41-42, L 24, 25, 27, I 32, W (STATUS) 5. */
	wire h_any = h_k == 6'd41 || h_k == 6'd42 || h_k == 6'd24 || h_k == 6'd25 ||
		h_k == 6'd27 || h_k == 6'd32 || h_k == 6'd5;
`ifdef MUT_DISP_NOGATE
	wire h_pass = h_in && (h_s || h_any);
	wire h_bad = 1'b0;
`else
	wire h_pass = h_in && (h_s && host_s || h_any);
	wire h_bad = h_in && h_s && !host_s;
`endif

	/* ------------------------------------------- the sequencer's writes */

`ifdef MUT_DISP_NOEXCL
	wire s_we = uop_we && uop_idx[9:6] == 4'hF;
`else
	wire s_we = active && uop_we && uop_idx[9:6] == 4'hF;
`endif
	wire s_stage = active && uop_we && uop_idx[9:2] == 8'hEE;	/* 0x3B8-0x3BB */

	reg hb_v;
	reg [5:0] hb_k;
	reg [31:0] hb_data, hb_mask;

	assign d_we = s_we || hb_v || h_pass;
	assign d_idx = s_we ? uop_idx[5:0] : hb_v ? hb_k : h_k;
	assign d_wdata = s_we ? uop_wdata : hb_v ? hb_data : hcr_wdata;
	assign d_wmask = s_we ? 32'hFFFFFFFF : hb_v ? hb_mask : hcr_wmask;

	always @(posedge clk) begin
		if (!rst_n) begin
			hb_v <= 1'b0;
		end else begin
			/* A passed write waits when the sequencer or the buffer has the bus. */
			hb_v <= h_pass && (s_we || hb_v);
			if (h_pass) begin
				hb_k <= h_k;
				hb_data <= hcr_wdata;
				hb_mask <= hcr_wmask;
			end
		end
	end

	/* ---------------------------------------------------------- FLIP */

	reg st_v;
	reg [31:0] st_plane, st_base, st_record, st_value;
	reg [1:0] slot_v, due;
	reg [31:0] slot_rec0, slot_rec1, slot_val0, slot_val1;
	reg [31:0] taken0, taken1;
	reg [31:0] fc0, fc1;
	reg idle_req;

	wire sp = st_plane[0];
	wire plane_ok = st_plane < NPLANES;
	wire busy_p = sp ? dc_pending[1] || slot_v[1] || due[1] : dc_pending[0] || slot_v[0] || due[0];

	wire base_bad = st_base < aperture_base || st_base >= aperture_limit ||
		(LOCAL_BYTES != 32'd0 && ({1'b0, st_base} < {1'b0, LOCAL_BASE} ||
		{1'b0, st_base} >= LOCAL_END)) ||
		(sp ? st_base[5:0] != 6'd0 : st_base[LINE_SHIFT-1:0] != {LINE_SHIFT{1'b0}});
	wire rec_bad = st_record != 32'd0 && (st_record[2:0] != 3'd0 ||
		st_record < aperture_base || st_record >= aperture_limit);
	wire k_flip = active && kick_flip;
	wire f_bad = k_flip && (!plane_ok || base_bad || rec_bad);
	wire f_go = k_flip && !f_bad;

	assign fault = f_bad;
	assign fault_kind = GHCI_FAULT_RING;
	assign fault_addr = !plane_ok ? st_plane : base_bad ? st_base : st_record;
	assign fault_tag = seq_tag;

	assign flip_valid = f_go;
	assign flip_plane = sp;
	assign flip_base = st_base;

	assign disp_wait = active && (st_v && plane_ok && busy_p || idle_req && !dc_idle || hb_v);

	/* The record writer. */
	localparam [1:0] R_IDLE = 2'd0;
	localparam [1:0] R_REQ = 2'd1;
	localparam [1:0] R_RSP = 2'd2;

	reg [1:0] rs;
	reg rp;	/* the plane of the record being written */
	reg ev_q, err_q;

	wire [1:0] take = taken & slot_v;
	/* A take with record 0: FLIP at once. */
	wire take_nr = take[0] && slot_rec0 == 32'd0 || take[1] && slot_rec1 == 32'd0;
	wire rec_done = rs == R_RSP && rsp_valid;

	always @(posedge clk) begin
		if (!rst_n) begin
			st_v <= 1'b0;
			slot_v <= 2'b00;
			due <= 2'b00;
			taken0 <= 32'd0;
			taken1 <= 32'd0;
			idle_req <= 1'b0;
			rs <= R_IDLE;
			rp <= 1'b0;
			ev_q <= 1'b0;
			err_q <= 1'b0;
		end else begin
			ev_q <= take_nr || rec_done;
			err_q <= rec_done && rsp_error;
			if (s_stage) begin
				case (uop_idx[1:0])
				2'd0: st_plane <= uop_wdata;
				2'd1: st_base <= uop_wdata;
				2'd2: st_record <= uop_wdata;
				default: st_value <= uop_wdata;
				endcase
				if (uop_idx[1:0] == 2'd0)
					st_v <= 1'b1;
			end
			if (k_flip || !active)
				st_v <= 1'b0;
			if (f_go) begin
				slot_v[sp] <= 1'b1;
				if (sp) begin
					slot_rec1 <= st_record;
					slot_val1 <= st_value;
				end else begin
					slot_rec0 <= st_record;
					slot_val0 <= st_value;
				end
			end
			/* kick_idle: wait for the controller's idle. */
			if (!active || dc_idle)
				idle_req <= 1'b0;
			if (active && kick_idle)
				idle_req <= 1'b1;
`ifdef MUT_DISP_NOTAKE
			if (1'b0) begin
`else
			if (take[0]) begin
`endif
				slot_v[0] <= 1'b0;
				taken0 <= {taken_cancel[0], slot_val0[30:0]};
				fc0 <= frame_count;
				due[0] <= slot_rec0 != 32'd0;
			end
			if (take[1]) begin
				slot_v[1] <= 1'b0;
				taken1 <= {taken_cancel[1], slot_val1[30:0]};
				fc1 <= frame_count;
				due[1] <= slot_rec1 != 32'd0;
			end
			case (rs)
			R_IDLE:
`ifdef MUT_DISP_HALTSEND
				if (due != 2'b00) begin
`else
				if (rec_ok && due != 2'b00) begin
`endif
					rp <= !due[0];
					rs <= R_REQ;
				end
			R_REQ:
				if (req_ready)
					rs <= R_RSP;
			R_RSP:
				if (rsp_valid) begin
					due[rp] <= 1'b0;
					rs <= R_IDLE;
				end
			default:
				rs <= R_IDLE;
			endcase
		end
	end

	/* The record's beat: {value, frame_count}, value first, at record. */
	wire [31:0] r_addr = rp ? slot_rec1 : slot_rec0;
	wire [63:0] r_word = rp ? {fc1, taken1} : {fc0, taken0};
	genvar w;
	generate
		for (w = 0; w < NW; w = w + 1) begin : g_be
			if (NW > 1) begin : g_sel
				localparam [WSEL-1:0] WI = w;
				assign req_be[w*8 +: 8] = {8{r_addr[LINE_SHIFT-1:3] == WI}};
			end else begin : g_one
				assign req_be[w*8 +: 8] = 8'hFF;
			end
			assign req_wdata[w*64 +: 64] = r_word;
		end
	endgenerate

	assign req_valid = rs == R_REQ;
	assign req_write = 1'b1;
	assign req_line = r_addr[ADDR_W-1:LINE_SHIFT];
	assign req_tag = 8'd0;

`ifdef MUT_DISP_EARLYIRQ
	assign ev_flip = take_nr || (rs == R_REQ && req_ready);
`else
	assign ev_flip = ev_q;
`endif
	assign dc_err = {h_bad, err_q};

	/* ----------------------------------------------------------- reads */

	assign d_ridx = hcr_ridx[5:0];
	wire r_in = hcr_ridx[9:6] == BASE_IDX[9:6];
	reg [31:0] own;

	always @(*) begin
		own = 32'd0;
		case (hcr_ridx[5:0])
		6'd5: own = {due != 2'b00, 31'd0};	/* STATUS[31] */
		6'd44: own = taken0;	/* TAKEN0 0xB0 */
		6'd45: own = taken1;	/* TAKEN1 0xB4 */
		default: ;
		endcase
	end

	assign hcr_rdata = r_in ? d_rdata | own : 32'd0;

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_rdata, slot_val0[31], slot_val1[31],
		r_addr[2:0]};
endmodule

`default_nettype wire
