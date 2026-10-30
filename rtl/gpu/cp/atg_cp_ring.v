/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ring: the multi-engine command ring:
 *   - 3 independent hardware queues (0: Graphics, 1: Compute, 2: Copy/DMA)
 *   - Independent BASE/SIZE/WPTR/RPTR per queue
 *   - Dynamic fetch arbiter (priority + round-robin)
 *   - Hardware preemption (CP_PREEMPT) and context switch
 *   - Inter-queue lightweight semaphore synchronization (CP_SEMA)
 *   - 8-entry circular line prefetch cache for zero-bubble packet delivery
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_ring #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter CLASS_V = 1	/* 1: class V packets go to the CPU; 0: fault kind 2 */
) (
	input wire clk,
	input wire rst_n,
	input wire core_rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	/* Control (from atg_cp_ctl) */
	input wire run,
	input wire halt,
	input wire step,
	input wire open,
	/* Class N packets (to atg_cp_seq) */
	output wire n_valid,
	input wire n_ready,
	output wire [31:0] n_data,
	output wire n_last,
	/* Class V packets (to atg_cpu) */
	output wire v_valid,
	output wire [31:0] v_addr,
	output wire [15:0] v_dwords,
	output wire [7:0] v_tag,
	input wire v_done,
	/* Dedicated DMA transfer queue (RING_DMA to atg_blt_3d) */
	output wire dma_req_valid,
	input  wire dma_req_ready,
	output wire [31:0] dma_src_base,
	output wire [31:0] dma_dst_base,
	output wire [31:0] dma_src_row_stride,
	output wire [31:0] dma_dst_row_stride,
	output wire [31:0] dma_src_slice_stride,
	output wire [31:0] dma_dst_slice_stride,
	output wire [15:0] dma_copy_w,
	output wire [15:0] dma_copy_h,
	output wire [15:0] dma_copy_d,
	input  wire dma_done,
	output wire dma_empty,
	output wire dma_busy,
	/* Status */
	output wire empty,
	output wire retire,
	output wire busy,
	/* Multi-queue & Preemption status */
	output wire [1:0] queue_id,
	output wire preempt_ev,
	/* Fault report to atg_cp_ctl (one source of its `src_*` vectors) */
	output wire fault,
	output wire [3:0] fault_kind,
	output wire [31:0] fault_addr,
	output wire [7:0] fault_tag,
	/* AMB client port (design §4.1) */
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
	input wire rsp_error
);
	`include "ghci_regs.vh"

	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam WS = LINE_SHIFT - 2;

	localparam [9:0] I_BASE0_LO = GHCI_REG_RING_BASE_LO[11:2];
	localparam [9:0] I_BASE0_HI = GHCI_REG_RING_BASE_HI[11:2];
	localparam [9:0] I_BASE0    = GHCI_RING_BASE[11:2];
	localparam [9:0] I_SIZE0    = GHCI_RING_SIZE[11:2];
	localparam [9:0] I_WPTR0 = GHCI_RING_WPTR[11:2];
	localparam [9:0] I_RPTR0 = GHCI_RING_RPTR[11:2];

	localparam [9:0] I_BASE1 = GHCI_RING1_BASE[11:2];
	localparam [9:0] I_SIZE1 = GHCI_RING1_SIZE[11:2];
	localparam [9:0] I_WPTR1 = GHCI_RING1_WPTR[11:2];
	localparam [9:0] I_RPTR1 = GHCI_RING1_RPTR[11:2];

	localparam [9:0] I_BASE2 = GHCI_RING2_BASE[11:2];
	localparam [9:0] I_SIZE2 = GHCI_RING2_SIZE[11:2];
	localparam [9:0] I_WPTR2 = GHCI_RING2_WPTR[11:2];
	localparam [9:0] I_RPTR2 = GHCI_RING2_RPTR[11:2];

	localparam [9:0] I_PREEMPT        = GHCI_CP_PREEMPT[11:2];
	localparam [9:0] I_PREEMPT_STATUS = GHCI_CP_PREEMPT_STATUS[11:2];
	localparam [9:0] I_CTX_BASE       = GHCI_CP_CTX_BASE[11:2];
	localparam [9:0] I_SEMA           = GHCI_CP_SEMA[11:2];
	localparam [9:0] I_DMA_BASE         = GHCI_RING_DMA_BASE[11:2];
	localparam [9:0] I_DMA_SIZE         = GHCI_RING_DMA_SIZE[11:2];
	localparam [9:0] I_DMA_WPTR         = GHCI_RING_DMA_WPTR[11:2];
	localparam [9:0] I_DMA_RPTR         = GHCI_RING_DMA_RPTR[11:2];
	localparam [9:0] I_DMA_SEM          = GHCI_DMA_SEMAPHORE[11:2];
	localparam [9:0] I_DMA_DST_BASE     = GHCI_DMA_DST_BASE[11:2];
	localparam [9:0] I_DMA_ROW_STRIDE   = GHCI_DMA_ROW_STRIDE[11:2];
	localparam [9:0] I_DMA_SLICE_STRIDE = GHCI_DMA_SLICE_STRIDE[11:2];
	localparam [9:0] I_DMA_EXTENT       = GHCI_DMA_EXTENT[11:2];

	localparam [3:0] R_IDLE         = 4'd0;
	localparam [3:0] R_HDR          = 4'd1;	/* fetch the header at cur */
	localparam [3:0] R_DEC          = 4'd12;	/* decode the header */
	localparam [3:0] R_DEC2         = 4'd13;
	localparam [3:0] R_N            = 4'd2;	/* stream a class N packet */
	localparam [3:0] R_V            = 4'd3;	/* a class V packet waits for v_done */
	localparam [3:0] R_ADV          = 4'd4;	/* move RPTR past the packet */
	localparam [3:0] R_REQ          = 4'd5;	/* on-demand line read request */
	localparam [3:0] R_RSP          = 4'd6;	/* on-demand line read response */
	localparam [3:0] R_FAULT        = 4'd7;
	localparam [3:0] R_CTX_SAVE_REQ = 4'd8;	/* preemption context save AMB write req */
	localparam [3:0] R_CTX_SAVE_RSP = 4'd9;	/* preemption context save AMB write rsp */
	localparam [3:0] R_CTX_REST_REQ = 4'd10;	/* preemption context restore AMB read req */
	localparam [3:0] R_CTX_REST_RSP = 4'd11;	/* preemption context restore AMB read rsp */

	localparam [1:0] PF_IDLE = 2'd0;
	localparam [1:0] PF_REQ  = 2'd1;
	localparam [1:0] PF_RSP  = 2'd2;

	/*
	 * 3 Independent Hardware Queues
	 */
	reg [63:0] base [0:2];
`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg [4:0] size [0:2];
	(* keep = "true" *) wire core_rst_sync = ~core_rst_n;
	(* keep = "true" *) wire rst_sync = ~rst_n;
`else
	reg [4:0] size [0:2];
`endif
	reg [17:0] wptr [0:2];
	reg [17:0] rptr [0:2];

`ifdef SYNTH_KINTEX7
	wire rptr_adv_q0 = (st == R_ADV) && (active_qid == 2'd0);
	wire rptr_adv_q1 = (st == R_ADV) && (active_qid == 2'd1);
	wire rptr_adv_q2 = (st == R_ADV) && (active_qid == 2'd2);
	wire rptr_rst_q0 = (st == R_CTX_REST_RSP) && rsp_valid && (rsp_tag == 8'd3) && (interrupted_qid == 2'd0);
	wire rptr_rst_q1 = (st == R_CTX_REST_RSP) && rsp_valid && (rsp_tag == 8'd3) && (interrupted_qid == 2'd1);
	wire rptr_rst_q2 = (st == R_CTX_REST_RSP) && rsp_valid && (rsp_tag == 8'd3) && (interrupted_qid == 2'd2);
	wire rptr_imm_q0 = (st == R_IDLE) && preempt_active && q_empty[0] && (ctx_base == 32'd0) && (interrupted_qid == 2'd0);
	wire rptr_imm_q1 = (st == R_IDLE) && preempt_active && q_empty[0] && (ctx_base == 32'd0) && (interrupted_qid == 2'd1);
	wire rptr_imm_q2 = (st == R_IDLE) && preempt_active && q_empty[0] && (ctx_base == 32'd0) && (interrupted_qid == 2'd2);

	always @(posedge clk) begin
		if (!core_rst_n) begin
			rptr[0] <= 18'd0;
			rptr[1] <= 18'd0;
			rptr[2] <= 18'd0;
		end else begin
			if (rptr_adv_q0) rptr[0] <= p_end;
			else if (rptr_rst_q0 || rptr_imm_q0) rptr[0] <= saved_rptr;

			if (rptr_adv_q1) rptr[1] <= p_end;
			else if (rptr_rst_q1 || rptr_imm_q1) rptr[1] <= saved_rptr;

			if (rptr_adv_q2) rptr[2] <= p_end;
			else if (rptr_rst_q2 || rptr_imm_q2) rptr[2] <= saved_rptr;
		end
	end
`endif

	/* Dedicated DMA Transfer Queue registers */
	reg [31:0] dma_base;
	(* max_fanout = 16 *) reg [4:0]  dma_size;
	reg [17:0] dma_wptr;
	reg [17:0] dma_rptr;
	(* max_fanout = 16 *) reg [31:0] dma_sem;
	reg [31:0] dma_dst_base_r;
	reg [31:0] dma_src_row_stride_r, dma_dst_row_stride_r;
	reg [31:0] dma_src_slice_stride_r, dma_dst_slice_stride_r;
	reg [15:0] dma_copy_w_r, dma_copy_h_r, dma_copy_d_r;
	reg dma_active;
	reg dma_req_v;

	wire [17:0] dma_rptr_next;
	wire unused_dr_co;
	am_add #(.W(18)) u_dma_rptr_add (.a(dma_rptr), .b(18'd1), .ci(1'b0), .s(dma_rptr_next), .co(unused_dr_co));

	wire [31:0] dma_sem_next;
	wire unused_ds_co;
	am_add #(.W(32)) u_dma_sem_add (.a(dma_sem), .b(32'd1), .ci(1'b0), .s(dma_sem_next), .co(unused_ds_co));

	assign dma_req_valid        = dma_req_v;
	assign dma_src_base         = dma_base;
	assign dma_dst_base         = dma_dst_base_r;
	assign dma_src_row_stride   = dma_src_row_stride_r;
	assign dma_dst_row_stride   = dma_dst_row_stride_r;
	assign dma_src_slice_stride = dma_src_slice_stride_r;
	assign dma_dst_slice_stride = dma_dst_slice_stride_r;
	assign dma_copy_w           = dma_copy_w_r;
	assign dma_copy_h           = dma_copy_h_r;
	assign dma_copy_d           = dma_copy_d_r;
	assign dma_empty            = (dma_wptr == dma_rptr);
	assign dma_busy             = dma_active || (dma_wptr != dma_rptr);

	wire [4:0] size0 = size[0];
	wire [4:0] size1 = size[1];
	wire [4:0] size2 = size[2];

	reg [17:0] mask0, mask1, mask2;
	reg [18:0] nwords0, nwords1, nwords2;

	integer mi;
	always @(*) begin
		for (mi = 0; mi < 18; mi = mi + 1) begin
			mask0[mi] = {27'd0, size0} > mi + 2;
			mask1[mi] = {27'd0, size1} > mi + 2;
			mask2[mi] = {27'd0, size2} > mi + 2;
		end
		for (mi = 0; mi < 19; mi = mi + 1) begin
			nwords0[mi] = {27'd0, size0} == mi + 2;
			nwords1[mi] = {27'd0, size1} == mi + 2;
			nwords2[mi] = {27'd0, size2} == mi + 2;
		end
	end

	wire [17:0] mask [0:2];
	assign mask[0] = mask0;
	assign mask[1] = mask1;
	assign mask[2] = mask2;

	wire [18:0] nwords [0:2];
	assign nwords[0] = nwords0;
	assign nwords[1] = nwords1;
	assign nwords[2] = nwords2;

	(* max_fanout = 16 *) reg [1:0] active_qid;
	reg [1:0] interrupted_qid;
	reg [17:0] saved_rptr;
	reg [31:0] ctx_base;
	reg preempt_pending;
	reg preempt_active;
	reg preempt_saved;
	reg preempt_auto;
	reg [3:0] prio_mode;
	reg preempt_pulse;
	reg [1:0] last_non_q0;

	/*
	 * Lightweight Semaphores (8 entries)
	 */
	reg [7:0] sema [0:7];
	reg [2:0] queue_sema_id [0:2];
	reg [2:0] queue_sema_wait;

	wire [1:0] sema_cmd = hcr_wdata[1:0];
	wire [2:0] sema_w_id = hcr_wdata[4:2];
	wire [1:0] sema_w_qid = hcr_wdata[6:5];
	wire sema_set_q_wait = hcr_wdata[7];
	wire sema_clr_q_wait = hcr_wdata[8];

	wire [7:0] sema_cur = sema[sema_w_id];
	wire [7:0] sema_op_val = (hcr_wdata[23:16] == 8'd0) ? 8'd1 : hcr_wdata[23:16];
	wire [7:0] sema_next;
	wire sema_co;

	am_addsub #(.W(8)) u_sema_addsub (
		.a(sema_cur),
		.b(sema_op_val),
		.sub(sema_cmd == 2'd2),
		.s(sema_next),
		.co(sema_co)
	);

	/*
	 * Active Queue Signals & Status
	 */
	wire [2:0] q_empty;
	assign q_empty[0] = (wptr[0] == rptr[0]);
	assign q_empty[1] = (wptr[1] == rptr[1]);
	assign q_empty[2] = (wptr[2] == rptr[2]);

	wire [2:0] has_work;
	assign has_work[0] = !q_empty[0] && !(queue_sema_wait[0] && (sema[queue_sema_id[0]] == 8'd0));
	assign has_work[1] = !q_empty[1] && !(queue_sema_wait[1] && (sema[queue_sema_id[1]] == 8'd0));
	assign has_work[2] = !q_empty[2] && !(queue_sema_wait[2] && (sema[queue_sema_id[2]] == 8'd0));

	wire [17:0] wptr_act   = wptr[active_qid];
	wire [17:0] rptr_act   = rptr[active_qid];
	wire [63:0] base_act   = base[active_qid];
	wire [17:0] mask_act   = mask[active_qid];
	wire [18:0] nwords_act = nwords[active_qid];

	/*
	 * Arbiter Selection
	 */
	wire [1:0] rr_next1 = (active_qid == 2'd0) ? 2'd1 : ((active_qid == 2'd1) ? 2'd2 : 2'd0);
	wire [1:0] rr_next2 = (active_qid == 2'd0) ? 2'd2 : ((active_qid == 2'd1) ? 2'd0 : 2'd1);

	reg [1:0] next_qid;
`ifdef SYNTH_KINTEX7
	reg [2:0] has_work_r;
	always @(posedge clk) begin
		if (!core_rst_n)
			has_work_r <= 3'd0;
		else
			has_work_r <= has_work;
	end
	wire [2:0] hw_sel = has_work_r;
`else
	wire [2:0] hw_sel = has_work;
`endif
	always @(*) begin
		if (preempt_active) begin
			next_qid = 2'd0;
		end else case (prio_mode)
		4'd1: begin
			/* Strict Priority: Q0 > Q1 > Q2 */
			next_qid = hw_sel[0] ? 2'd0 :
				hw_sel[1] ? 2'd1 :
				hw_sel[2] ? 2'd2 : active_qid;
		end
		4'd2: begin
			/* Pure Round Robin */
			next_qid = hw_sel[rr_next1] ? rr_next1 :
				hw_sel[rr_next2] ? rr_next2 :
				hw_sel[active_qid] ? active_qid : active_qid;
		end
		default: begin
			/* Balanced: Graphics prioritized, Compute & Copy interleaved */
			next_qid = hw_sel[0] ? 2'd0 :
				(last_non_q0 == 2'd1) ? (hw_sel[2] ? 2'd2 : (hw_sel[1] ? 2'd1 : 2'd0)) :
				(hw_sel[1] ? 2'd1 : (hw_sel[2] ? 2'd2 : 2'd0));
		end
		endcase
	end

	(* max_fanout = 16 *) reg [3:0] st;
	reg ret_n;	/* the read is for R_N (else R_HDR) */
	reg [17:0] cur;	/* the header's dword index */
	reg [15:0] n;	/* dwords after the header */
	(* max_fanout = 16 *) reg [15:0] k;	/* R_N: dword of the packet on n_data (0 = header) */
	reg [7:0] tag;
	(* max_fanout = 16, extract_enable = "no" *) reg [31:0] hdr_data;
	(* max_fanout = 16 *) reg step_pend;
	(* max_fanout = 16 *) reg stale;
	reg h_bad_r, h_novf_r;
	reg h_bad_words_r, h_bad_avail_r;
	reg [1:0] h_class_r;

	/*
	 * 8-entry circular prefetch line buffer (256 bytes = 64 words for 32B lines)
	 */
	reg [7:0] buf_valid;
	(* max_fanout = 16 *) reg [LA_W-1:0] buf_tag [0:7];
	reg [LINE_BYTES*8-1:0] buf_data [0:7];

`ifdef SYNTH_KINTEX7
	wire pf_wr = (pf_st == PF_RSP) && rsp_valid && (rsp_tag == 8'd1) && !rsp_error;
	wire dm_wr = (st == R_RSP) && rsp_valid && (rsp_tag == 8'd0) && !rsp_error;
	wire [7:0] buf_wr_en;
	wire [15:0] buf_slice_we [0:7];
	genvar g_bi, g_sl;
	generate
		for (g_bi = 0; g_bi < 8; g_bi = g_bi + 1) begin : g_buf_wr
			assign buf_wr_en[g_bi] = (pf_wr && pf_idx == g_bi[2:0]) || (dm_wr && want_idx == g_bi[2:0]);
			for (g_sl = 0; g_sl < 16; g_sl = g_sl + 1) begin : g_sl_gen
				(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sl_we (
					.I0(buf_wr_en[g_bi]),
					.O(buf_slice_we[g_bi][g_sl])
				);
				always @(posedge clk) begin
					if (buf_slice_we[g_bi][g_sl])
						buf_data[g_bi][g_sl*16 +: 16] <= rsp_rdata[g_sl*16 +: 16];
				end
			end
		end
	endgenerate
`endif

	/*
	 * The dword wanted as byte address in memory
	 */
	(* max_fanout = 16 *) reg [ADDR_W-1:0] pa;
	wire [ADDR_W-1:0] want_addr = pa;
	wire [LA_W-1:0] want_line = want_addr[ADDR_W-1:LINE_SHIFT];
	wire [WS-1:0] want_word = want_addr[LINE_SHIFT-1:2];
	wire [2:0] want_idx = want_line[2:0];

`ifdef SYNTH_KINTEX7
	wire [LA_W-1:0] cur_tag = buf_tag[want_idx];
	wire m0 = (cur_tag[4:0]   == want_line[4:0]);
	wire m1 = (cur_tag[9:5]   == want_line[9:5]);
	wire m2 = (cur_tag[14:10] == want_line[14:10]);
	wire m3 = (cur_tag[19:15] == want_line[19:15]);
	wire m4 = (cur_tag[24:20] == want_line[24:20]);
	wire m5 = (cur_tag[LA_W-1:25] == want_line[LA_W-1:25]);
	wire tag_match = m0 && m1 && m2 && m3 && m4 && m5;
	wire hit_comb = buf_valid[want_idx] && tag_match;

	(* max_fanout = 16 *) reg tag_match_r;
	reg hdr_wait;
	wire hit_n = buf_valid[want_idx] && tag_match_r;
	wire hit = (st == R_N) ? hit_n : hit_comb;
`else
	wire hit_comb = buf_valid[want_idx] && (buf_tag[want_idx] == want_line);
	wire hit_n    = hit_comb;
	wire hit      = hit_comb;
`endif
	wire [31:0] want_data = buf_data[want_idx][{want_word, 5'd0} +: 32];

	wire go = (run && !halt) || step_pend;

`ifdef SYNTH_KINTEX7
	wire hcr_we_cfg, hcr_we_db, hcr_we_dma, hcr_we_sync;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_cfg  (.I0(hcr_we), .O(hcr_we_cfg));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_db   (.I0(hcr_we), .O(hcr_we_db));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_dma  (.I0(hcr_we), .O(hcr_we_dma));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_sync (.I0(hcr_we), .O(hcr_we_sync));
`else
	wire hcr_we_cfg  = hcr_we;
	wire hcr_we_db   = hcr_we;
	wire hcr_we_dma  = hcr_we;
	wire hcr_we_sync = hcr_we;
`endif

	/* Doorbells for the 3 queues */
	wire [2:0] doorbell;
	assign doorbell[0] = hcr_we_db && (hcr_widx == I_WPTR0);
	assign doorbell[1] = hcr_we_db && (hcr_widx == I_WPTR1);
	assign doorbell[2] = hcr_we_db && (hcr_widx == I_WPTR2);

	wire [17:0] wptr_new0 = ((wptr[0] & ~hcr_wmask[17:0]) | (hcr_wdata[17:0] & hcr_wmask[17:0])) & mask[0];
	wire [17:0] wptr_new1 = ((wptr[1] & ~hcr_wmask[17:0]) | (hcr_wdata[17:0] & hcr_wmask[17:0])) & mask[1];
	wire [17:0] wptr_new2 = ((wptr[2] & ~hcr_wmask[17:0]) | (hcr_wdata[17:0] & hcr_wmask[17:0])) & mask[2];

	/* Header decode (from registered hdr_data) */
	wire is_ghci = (
		(hdr_data[7:0] >= 8'h10 && hdr_data[7:0] <= 8'h14) ||
		(hdr_data[7:0] >= 8'h20 && hdr_data[7:0] <= 8'h37) ||
		(hdr_data[7:0] >= 8'h40 && hdr_data[7:0] <= 8'h46) ||
		(hdr_data[7:0] >= 8'h50 && hdr_data[7:0] <= 8'h51)
	) && (hdr_data[15:8] >= 8'd1);
	wire [7:0] ghci_n;
	wire ghci_n_bo;
	am_sub #(.W(8)) u_ghci_n (
		.a(hdr_data[15:8]), .b(8'd1), .bi(1'b0), .d(ghci_n), .bo(ghci_n_bo)
	);
`ifdef SYNTH_KINTEX7
	wire [1:0] is_ghci_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_igh0 (.I0(is_ghci), .O(is_ghci_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_igh1 (.I0(is_ghci), .O(is_ghci_b[1]));
	wire [1:0] h_class = is_ghci_b[0] ? 2'd0 : hdr_data[31:30];
	wire [15:0] h_n = is_ghci_b[1] ? {8'd0, ghci_n} : (h_class[1] ? hdr_data[15:0] : {8'd0, hdr_data[7:0]});
`else
	wire [1:0] h_class = is_ghci ? 2'd0 : hdr_data[31:30];
	wire [15:0] h_n = is_ghci ? {8'd0, ghci_n} : (h_class[1] ? hdr_data[15:0] : {8'd0, hdr_data[7:0]});
`endif

	wire [17:0] avail_d, avail;
	wire avail_bo;

	am_sub #(.W(18)) avail_sub (.a(wptr_act), .b(cur), .bi(1'b0), .d(avail_d), .bo(avail_bo));
	assign avail = avail_d & mask_act;

	(* max_fanout = 16 *) reg [17:0] avail_r;
	always @(posedge clk) begin
		if (!rst_n)
			avail_r <= 18'd0;
		else
			avail_r <= avail;
	end

`ifdef SYNTH_KINTEX7
	wire [17:0] avail_check = avail_r;
`else
	wire [17:0] avail_check = avail;
`endif

	wire [18:0] rem_words_s;
	wire rem_words_bo;
	am_sub #(.W(19)) u_rem_sub (
		.a(nwords_act), .b({1'b0, cur}), .bi(1'b1), .d(rem_words_s), .bo(rem_words_bo)
	);

	(* max_fanout = 16 *) reg [18:0] rem_words_r;
	(* max_fanout = 16 *) reg rem_words_bo_r;
	always @(posedge clk) begin
		if (!rst_n) begin
			rem_words_r    <= 19'd0;
			rem_words_bo_r <= 1'b0;
		end else begin
			rem_words_r    <= rem_words_s;
			rem_words_bo_r <= rem_words_bo;
		end
	end

	wire [18:0] h_end_s, p_end_s;
	wire h_end_co, p_end_co;
	am_add #(.W(19)) u_h_end_add (
		.a({1'b0, cur}), .b({3'd0, h_n}), .ci(1'b1), .s(h_end_s), .co(h_end_co)
	);
	am_add #(.W(19)) u_p_end_add (
		.a({1'b0, cur}), .b({3'd0, n}), .ci(1'b1), .s(p_end_s), .co(p_end_co)
	);
	wire [18:0] h_end = h_end_s;
`ifdef SYNTH_KINTEX7
	wire h_novf_words = rem_words_bo_r || ({3'd0, h_n} > rem_words_r);
	wire h_bad_words = h_novf_words;
	wire h_bad_avail = ({3'd0, h_n} >= {1'b0, avail_check});
	wire h_bad = h_bad_words || h_bad_avail;
`else
	wire h_novf_words = h_end > nwords_act;
	wire h_bad = h_novf_words || ({3'd0, h_n} >= {1'b0, avail_check});
`endif
	wire h_novf = (h_class == 2'd2) && (CLASS_V == 0);
	wire [17:0] p_end = p_end_s[17:0] & mask_act;

	wire [ADDR_W-1:0] pa_4, pa_hdr;
	wire [15:0] k_n;
	wire pa_4_co, pa_hdr_co, k_co;

	am_add #(.W(ADDR_W)) pa_4_add (.a(pa), .b({{(ADDR_W-3){1'b0}}, 3'd4}), .ci(1'b0), .s(pa_4), .co(pa_4_co));
	am_add #(.W(ADDR_W)) pa_hdr_add (
		.a(base_act[ADDR_W-1:0]), .b({{(ADDR_W-20){1'b0}}, rptr_act, 2'b00}), .ci(1'b0), .s(pa_hdr), .co(pa_hdr_co)
	);
`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire [15:0] k_add_in = k;
	am_add #(.W(16)) k_add (.a(k_add_in), .b(16'd0), .ci(1'b1), .s(k_n), .co(k_co));
`else
	am_add #(.W(16)) k_add (.a(k), .b(16'd0), .ci(1'b1), .s(k_n), .co(k_co));
`endif

	/*
	 * Background Prefetch Engine
	 */
	wire [LA_W-1:0] next_line;
	wire unused_nl_co;
	am_add #(.W(LA_W)) u_next_line (
		.a(want_line), .b({{(LA_W-1){1'b0}}, 1'b1}), .ci(1'b0), .s(next_line), .co(unused_nl_co)
	);
`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg [LA_W-1:0] next_line_r;
	always @(posedge clk) begin
		if (!core_rst_n)
			next_line_r <= {LA_W{1'b0}};
		else
			next_line_r <= next_line;
	end

	wire [2:0] next_idx = next_line_r[2:0];
	wire [LA_W-1:0] nxt_tag = buf_tag[next_idx];
	wire ntm0 = (nxt_tag[4:0]   == next_line_r[4:0]);
	wire ntm1 = (nxt_tag[9:5]   == next_line_r[9:5]);
	wire ntm2 = (nxt_tag[14:10] == next_line_r[14:10]);
	wire ntm3 = (nxt_tag[19:15] == next_line_r[19:15]);
	wire ntm4 = (nxt_tag[24:20] == next_line_r[24:20]);
	wire ntm5 = (nxt_tag[LA_W-1:25] == next_line_r[LA_W-1:25]);
	wire next_tag_match = ntm0 && ntm1 && ntm2 && ntm3 && ntm4 && ntm5;
	wire next_hit = buf_valid[next_idx] && next_tag_match;
`else
	wire [2:0] next_idx = next_line[2:0];
	wire next_hit = buf_valid[next_idx] && (buf_tag[next_idx] == next_line);
`endif

	reg [1:0] pf_st;
	(* max_fanout = 16, extract_enable = "no" *) reg [LA_W-1:0] pf_line;
	wire [2:0] pf_idx = pf_line[2:0];

	wire ctx_save_req = (st == R_CTX_SAVE_REQ);
	wire ctx_rest_req = (st == R_CTX_REST_REQ);
	wire ctx_req = ctx_save_req || ctx_rest_req;

	// Prefetch next line while executing Class N packet before boundary hit
	wire pf_trigger = (st == R_N) && (k != n) && !next_hit && (pf_st == PF_IDLE) &&
		(st != R_REQ) && (st != R_RSP) && !ctx_req && go;
`ifdef SYNTH_KINTEX7
	reg pf_trigger_r;
	always @(posedge clk) begin
		if (!core_rst_n)
			pf_trigger_r <= 1'b0;
		else
			pf_trigger_r <= pf_trigger;
	end
	wire pf_start = pf_trigger_r;
	wire [1:0] pf_line_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pfl0 (.I0(pf_st == PF_IDLE && pf_start), .O(pf_line_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pfl1 (.I0(pf_st == PF_IDLE && pf_start), .O(pf_line_we_b[1]));
`else
	wire pf_start = pf_trigger;
`endif

	reg f_pulse;
	reg [3:0] f_kind;
	reg [31:0] f_addr;
	reg ret_pulse;

	wire k_eq_n = (k[15:8] == n[15:8]) && (k[7:0] == n[7:0]);

`ifdef SYNTH_KINTEX7
	wire pa_we_hdr = (st == R_IDLE) && go && hw_sel[active_qid];
	wire pa_we_adv = (st == R_N) && hit_n && n_ready && !k_eq_n;
	wire [1:0] pa_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pawe0 (.I0(pa_we_hdr), .I1(pa_we_adv), .O(pa_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pawe1 (.I0(pa_we_hdr), .I1(pa_we_adv), .O(pa_we_b[1]));

	wire f_addr_we_bad = (st == R_DEC);
	wire f_addr_we_rsp = (st == R_RSP) && rsp_valid && (rsp_tag == 8'd0) && rsp_error;
	wire [1:0] fa_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_fawe0 (.I0(f_addr_we_bad), .I1(f_addr_we_rsp), .O(fa_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_fawe1 (.I0(f_addr_we_bad), .I1(f_addr_we_rsp), .O(fa_we_b[1]));
`endif

	assign fault = f_pulse;
	assign fault_kind = f_kind;
	assign fault_addr = f_addr;
	assign fault_tag = tag;
	assign retire = ret_pulse;
	assign empty = q_empty[0] && q_empty[1] && q_empty[2];
	assign busy = (st != R_IDLE && st != R_FAULT) || (pf_st != PF_IDLE) ||
		preempt_pending || preempt_active;
	assign queue_id = active_qid;
	assign preempt_ev = preempt_pulse;

	assign n_valid = (st == R_N) && hit_n;
	assign n_data = want_data;
	assign n_last = (k == n);

	assign v_valid = (st == R_V);
	assign v_addr = pa_4[31:0];
	assign v_dwords = n;
	assign v_tag = tag;

	// AMB port multiplexing
	wire demand_req = (st == R_REQ);
	wire [LA_W-1:0] ctx_line = ctx_base[31:LINE_SHIFT];
	wire [LINE_BYTES*8-1:0] ctx_save_wdata =
		{{(LINE_BYTES*8 > 80 ? LINE_BYTES*8 - 80 : 1){1'b0}}, 14'd0, saved_rptr, 14'd0, interrupted_qid, 32'h43545853};

	assign req_valid = ctx_req || demand_req || (pf_st == PF_REQ);
	assign req_write = ctx_save_req;
	assign req_line = ctx_req ? ctx_line : (demand_req ? want_line : pf_line);
	assign req_be = ctx_save_req ? {LINE_BYTES{1'b1}} : {LINE_BYTES{1'b0}};
`ifdef SYNTH_KINTEX7
	assign req_wdata = ctx_save_wdata;
`else
	assign req_wdata = ctx_save_req ? ctx_save_wdata : {(LINE_BYTES * 8){1'b0}};
`endif
	assign req_tag = ctx_save_req ? 8'd2 : (ctx_rest_req ? 8'd3 : (demand_req ? 8'd0 : 8'd1));

	/* Registers surviving CTRL.RESET */
	integer bi;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (bi = 0; bi < 3; bi = bi + 1) begin
				base[bi] <= 64'd0;
				size[bi] <= 5'd12;
			end
			dma_base <= 32'd0;
			dma_size <= 5'd12;
			dma_dst_base_r <= 32'd0;
			dma_src_row_stride_r <= 32'd512;
			dma_dst_row_stride_r <= 32'd512;
			dma_src_slice_stride_r <= 32'd65536;
			dma_dst_slice_stride_r <= 32'd65536;
			dma_copy_w_r <= 16'd512;
			dma_copy_h_r <= 16'd128;
			dma_copy_d_r <= 16'd64;
			ctx_base <= 32'd0;
			prio_mode <= 4'd0;
			preempt_auto <= 1'b0;
		end else if (hcr_we_cfg) begin
			if (open) begin
				if (hcr_widx == I_BASE0_LO || hcr_widx == I_BASE0)
					base[0][31:0] <= ((base[0][31:0] & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & 32'hFFFFFFE0;
				if (hcr_widx == I_BASE0_HI)
					base[0][63:32] <= (base[0][63:32] & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
				if (hcr_widx == I_SIZE0 && hcr_wmask[0])
					size[0] <= hcr_wdata[4:0] < 5'd10 ? 5'd10 :
						hcr_wdata[4:0] > 5'd20 ? 5'd20 : hcr_wdata[4:0];

				if (hcr_widx == I_BASE1)
					base[1][31:0] <= ((base[1][31:0] & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & 32'hFFFFFFE0;
				if (hcr_widx == I_SIZE1 && hcr_wmask[0])
					size[1] <= hcr_wdata[4:0] < 5'd10 ? 5'd10 :
						hcr_wdata[4:0] > 5'd20 ? 5'd20 : hcr_wdata[4:0];

				if (hcr_widx == I_BASE2)
					base[2][31:0] <= ((base[2][31:0] & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & 32'hFFFFFFE0;
				if (hcr_widx == I_SIZE2 && hcr_wmask[0])
					size[2] <= hcr_wdata[4:0] < 5'd10 ? 5'd10 :
						hcr_wdata[4:0] > 5'd20 ? 5'd20 : hcr_wdata[4:0];

				if (hcr_widx == I_DMA_BASE)
					dma_base <= ((dma_base & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & 32'hFFFFFFE0;
				if (hcr_widx == I_DMA_SIZE && hcr_wmask[0])
					dma_size <= hcr_wdata[4:0] < 5'd10 ? 5'd10 :
						hcr_wdata[4:0] > 5'd20 ? 5'd20 : hcr_wdata[4:0];
				if (hcr_widx == I_DMA_DST_BASE)
					dma_dst_base_r <= (dma_dst_base_r & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
				if (hcr_widx == I_DMA_ROW_STRIDE) begin
					dma_src_row_stride_r <= (dma_src_row_stride_r & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
					dma_dst_row_stride_r <= (dma_dst_row_stride_r & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
				end
				if (hcr_widx == I_DMA_SLICE_STRIDE) begin
					dma_src_slice_stride_r <= (dma_src_slice_stride_r & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
					dma_dst_slice_stride_r <= (dma_dst_slice_stride_r & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
				end
				if (hcr_widx == I_DMA_EXTENT) begin
					dma_copy_w_r <= hcr_wdata[15:0];
					dma_copy_h_r <= hcr_wdata[23:16] != 8'd0 ? {8'd0, hcr_wdata[23:16]} : 16'd128;
					dma_copy_d_r <= hcr_wdata[31:24] != 8'd0 ? {8'd0, hcr_wdata[31:24]} : 16'd64;
				end

				if (hcr_widx == I_CTX_BASE)
					ctx_base <= ((ctx_base & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) & 32'hFFFFFFE0;
			end
			if (hcr_widx == I_PREEMPT && hcr_wmask[0]) begin
				prio_mode <= hcr_wdata[7:4];
				preempt_auto <= hcr_wdata[4];
			end
		end
	end

	/* Main sequential logic */
	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (core_rst_sync) begin
`else
		if (!core_rst_n) begin
`endif
			for (bi = 0; bi < 3; bi = bi + 1) begin
				wptr[bi] <= 18'd0;
`ifndef SYNTH_KINTEX7
				rptr[bi] <= 18'd0;
`endif
				queue_sema_id[bi] <= 3'd0;
			end
			queue_sema_wait <= 3'd0;
			for (bi = 0; bi < 8; bi = bi + 1)
				sema[bi] <= 8'd0;

			dma_wptr   <= 18'd0;
			dma_rptr   <= 18'd0;
			dma_sem    <= 32'd0;
			dma_active <= 1'b0;
			dma_req_v  <= 1'b0;

			active_qid      <= 2'd0;
			interrupted_qid <= 2'd0;
			saved_rptr      <= 18'd0;
			preempt_pending <= 1'b0;
			preempt_active  <= 1'b0;
			preempt_saved   <= 1'b0;
			preempt_pulse   <= 1'b0;
			last_non_q0     <= 2'd1;

			st        <= R_IDLE;
			ret_n     <= 1'b0;
			pa        <= {ADDR_W{1'b0}};
			cur       <= 18'd0;
			n         <= 16'd0;
			k         <= 16'd0;
			tag       <= 8'd0;
			hdr_data  <= 32'd0;
			step_pend <= 1'b0;
			stale     <= 1'b0;
			h_bad_r   <= 1'b0;
			h_bad_words_r <= 1'b0;
			h_bad_avail_r <= 1'b0;
			h_novf_r  <= 1'b0;
			h_class_r <= 2'd0;
			buf_valid <= 8'd0;
`ifndef SYNTH_KINTEX7
			for (bi = 0; bi < 8; bi = bi + 1) begin
				buf_tag[bi]  <= {LA_W{1'b0}};
				buf_data[bi] <= {(LINE_BYTES * 8){1'b0}};
			end
`endif
			pf_st     <= PF_IDLE;
			pf_line   <= {LA_W{1'b0}};
			f_pulse   <= 1'b0;
			f_kind    <= 4'd0;
			f_addr    <= 32'd0;
			ret_pulse <= 1'b0;
`ifdef SYNTH_KINTEX7
			tag_match_r <= 1'b0;
			hdr_wait    <= 1'b1;
`endif
		end else begin
			f_pulse       <= 1'b0;
			ret_pulse     <= 1'b0;
			preempt_pulse <= 1'b0;

			/* Doorbells */
			if (doorbell[0]) begin
				wptr[0] <= wptr_new0;
				if (active_qid == 2'd0) begin
					stale     <= 1'b1;
					buf_valid <= 8'd0;
				end
			end
			if (doorbell[1]) begin
				wptr[1] <= wptr_new1;
				if (active_qid == 2'd1) begin
					stale     <= 1'b1;
					buf_valid <= 8'd0;
				end
			end
			if (doorbell[2]) begin
				wptr[2] <= wptr_new2;
				if (active_qid == 2'd2) begin
					stale     <= 1'b1;
					buf_valid <= 8'd0;
				end
			end

			if (hcr_we_dma && hcr_widx == I_DMA_WPTR)
				dma_wptr <= (dma_wptr & ~hcr_wmask[17:0]) | (hcr_wdata[17:0] & hcr_wmask[17:0]);
			if (hcr_we_dma && hcr_widx == I_DMA_SEM)
				dma_sem <= (dma_sem & ~hcr_wmask) | (hcr_wdata & hcr_wmask);

			if (!dma_active && (dma_wptr != dma_rptr) && go) begin
				dma_active <= 1'b1;
				dma_req_v  <= 1'b1;
			end else if (dma_req_v && dma_req_ready) begin
				dma_req_v  <= 1'b0;
			end

			if (dma_active && dma_done) begin
				dma_active <= 1'b0;
				dma_rptr   <= dma_rptr_next;
				dma_sem    <= dma_sem_next;
			end

			/* Preemption request from host */
			if (hcr_we_sync && (hcr_widx == I_PREEMPT)) begin
				if (hcr_wdata[0] && !preempt_active)
					preempt_pending <= 1'b1;
			end

			/* Auto-preempt when Queue 0 receives work during Queue 1/2 execution */
			if (preempt_auto && has_work[0] && (active_qid != 2'd0) && !preempt_active)
				preempt_pending <= 1'b1;

			/* Semaphore update from host or ring */
			if (hcr_we_sync && (hcr_widx == I_SEMA)) begin
				if (sema_set_q_wait && (sema_w_qid < 2'd3)) begin
					queue_sema_wait[sema_w_qid] <= 1'b1;
					queue_sema_id[sema_w_qid]   <= sema_w_id;
				end
				if (sema_clr_q_wait && (sema_w_qid < 2'd3)) begin
					queue_sema_wait[sema_w_qid] <= 1'b0;
				end
				if (sema_cmd == 2'd1 || sema_cmd == 2'd2) begin
					sema[sema_w_id] <= sema_next;
				end else if (sema_cmd == 2'd3) begin
					sema[sema_w_id] <= hcr_wdata[23:16];
				end
			end

			if (step)
				step_pend <= 1'b1;
			else if (run && !halt)
				step_pend <= 1'b0;

			// ---------------------------------------------------------
			// Background Prefetcher FSM
			// ---------------------------------------------------------
			case (pf_st)
			PF_IDLE: begin
				if (pf_trigger) begin
`ifndef SYNTH_KINTEX7
					pf_line <= next_line;
`endif
					pf_st   <= PF_REQ;
				end
			end
			PF_REQ: begin
				if (req_ready && !demand_req && !ctx_req)
					pf_st <= PF_RSP;
			end
			PF_RSP: begin
				if (rsp_valid && (rsp_tag == 8'd1)) begin
					if (!rsp_error) begin
`ifndef SYNTH_KINTEX7
						buf_data[pf_idx]  <= rsp_rdata;
`endif
						buf_tag[pf_idx]   <= pf_line;
						buf_valid[pf_idx] <= 1'b1;
					end
					pf_st <= PF_IDLE;
				end
			end
			default: pf_st <= PF_IDLE;
			endcase

			// ---------------------------------------------------------
			// Main Command Execution FSM
			// ---------------------------------------------------------
			case (st)
			R_IDLE: begin
				if (preempt_pending && (active_qid != 2'd0)) begin
					interrupted_qid <= active_qid;
					saved_rptr      <= rptr[active_qid];
					if (ctx_base == 32'd0) begin
						/* Instant shadow context switch */
						preempt_saved   <= 1'b1;
						preempt_pending <= 1'b0;
						preempt_active  <= 1'b1;
						preempt_pulse   <= 1'b1;
						active_qid      <= 2'd0;
						buf_valid       <= 8'd0;
					end else begin
						st <= R_CTX_SAVE_REQ;
					end
				end else if (preempt_active && q_empty[0]) begin
					/* High-priority Queue 0 finished: restore interrupted queue */
					if (ctx_base == 32'd0) begin
						preempt_active  <= 1'b0;
						preempt_saved   <= 1'b0;
						preempt_pulse   <= 1'b1;
						active_qid      <= interrupted_qid;
`ifndef SYNTH_KINTEX7
						rptr[interrupted_qid] <= saved_rptr;
`endif
						buf_valid       <= 8'd0;
					end else begin
						st <= R_CTX_REST_REQ;
					end
				end else if (go) begin
`ifdef SYNTH_KINTEX7
					if (hw_sel[active_qid]) begin
						cur       <= rptr_act;
						step_pend <= 1'b0;
						hdr_wait  <= 1'b1;
						st        <= R_HDR;
					end else if (|hw_sel) begin
						/* Arbiter switches to next active queue */
						active_qid <= next_qid;
						if (next_qid != 2'd0)
							last_non_q0 <= next_qid;
						buf_valid  <= 8'd0;
					end
`else
					if (has_work[active_qid]) begin
						cur       <= rptr_act;
						pa        <= pa_hdr;
						step_pend <= 1'b0;
						st        <= R_HDR;
					end else if (|has_work) begin
						/* Arbiter switches to next active queue */
						active_qid <= next_qid;
						if (next_qid != 2'd0)
							last_non_q0 <= next_qid;
						buf_valid  <= 8'd0;
					end
`endif
				end
			end

			R_HDR: begin
`ifdef SYNTH_KINTEX7
				hdr_data <= want_data;
				k        <= 16'd0;
				if (hdr_wait) begin
					hdr_wait <= 1'b0;
				end else begin
					hdr_wait <= 1'b1;
					if (!hit_n || stale) begin
						ret_n <= 1'b0;
						stale <= doorbell[active_qid];
						st    <= R_REQ;
					end else begin
						st    <= R_DEC;
					end
				end
`else
				if (!hit_comb || stale) begin
					ret_n <= 1'b0;
					stale <= doorbell[active_qid];
					st    <= R_REQ;
				end else begin
					hdr_data <= want_data;
					k        <= 16'd0;
					st       <= R_DEC;
				end
`endif
			end

			R_DEC: begin
				tag <= hdr_data[23:16];
				n   <= h_n;
`ifdef SYNTH_KINTEX7
				if (fa_we_b[0]) f_addr[15:0] <= want_addr[15:0];
				if (fa_we_b[1]) f_addr[31:16] <= want_addr[31:16];
`else
				f_addr  <= want_addr[31:0];
				h_bad_r <= h_bad;
`endif
				h_novf_r  <= h_novf;
				h_class_r <= h_class;
				st        <= R_DEC2;
			end

			R_DEC2: begin
`ifdef SYNTH_KINTEX7
				if (rem_words_bo_r || ({3'd0, n} > rem_words_r) || ({3'd0, n} >= {1'b0, avail_check}) || h_novf_r) begin
					f_pulse <= 1'b1;
					f_kind  <= (h_novf_r) ? GHCI_FAULT_OPCODE : GHCI_FAULT_RING;
					st      <= R_FAULT;
				end else begin
`else
				if (h_bad_r || h_novf_r) begin
					f_pulse <= 1'b1;
					f_kind  <= h_bad_r ? GHCI_FAULT_RING : GHCI_FAULT_OPCODE;
					st      <= R_FAULT;
				end else begin
`endif
					case (h_class_r)
					2'd2:    st <= R_V;
					2'd3:    st <= R_ADV;
					default: st <= R_N;
					endcase
				end
			end

			R_N: begin
				if (!hit_n) begin
					ret_n <= 1'b1;
					st    <= R_REQ;
				end else if (n_ready) begin
					if (k_eq_n) begin
						st <= R_ADV;
					end else begin
						k  <= k_n;
`ifndef SYNTH_KINTEX7
						pa <= pa_4;
`endif
					end
				end
			end

			R_V: begin
				if (v_done)
					st <= R_ADV;
			end

			R_ADV: begin
`ifndef SYNTH_KINTEX7
				rptr[active_qid] <= p_end;
`endif
				ret_pulse        <= 1'b1;
				if (queue_sema_wait[active_qid])
					queue_sema_wait[active_qid] <= 1'b0;
				if (preempt_pending && (active_qid != 2'd0)) begin
					interrupted_qid <= active_qid;
					saved_rptr      <= p_end;
					if (ctx_base == 32'd0) begin
						preempt_saved   <= 1'b1;
						preempt_pending <= 1'b0;
						preempt_active  <= 1'b1;
						preempt_pulse   <= 1'b1;
						active_qid      <= 2'd0;
						buf_valid       <= 8'd0;
						st              <= R_IDLE;
					end else begin
						st <= R_CTX_SAVE_REQ;
					end
				end else begin
					st <= R_IDLE;
				end
			end

			R_REQ: begin
				if (req_ready && demand_req)
					st <= R_RSP;
			end

			R_RSP: begin
				if (rsp_valid && (rsp_tag == 8'd0)) begin
					if (rsp_error) begin
						f_pulse <= 1'b1;
						f_kind  <= GHCI_FAULT_APERTURE;
`ifdef SYNTH_KINTEX7
						if (fa_we_b[0]) f_addr[15:0] <= want_addr[15:0];
						if (fa_we_b[1]) f_addr[31:16] <= want_addr[31:16];
`else
						f_addr  <= want_addr[31:0];
`endif
						st      <= R_FAULT;
					end else begin
						buf_valid[want_idx] <= 1'b1;
						buf_tag[want_idx]   <= want_line;
`ifndef SYNTH_KINTEX7
						buf_data[want_idx]  <= rsp_rdata;
`else
						hdr_wait <= 1'b0;
`endif
						st <= ret_n ? R_N : R_HDR;
					end
				end
			end

			R_CTX_SAVE_REQ: begin
				if (req_ready && ctx_save_req)
					st <= R_CTX_SAVE_RSP;
			end

			R_CTX_SAVE_RSP: begin
				if (rsp_valid && (rsp_tag == 8'd2)) begin
					preempt_saved   <= 1'b1;
					preempt_pending <= 1'b0;
					preempt_active  <= 1'b1;
					preempt_pulse   <= 1'b1;
					active_qid      <= 2'd0;
					buf_valid       <= 8'd0;
					st              <= R_IDLE;
				end
			end

			R_CTX_REST_REQ: begin
				if (req_ready && ctx_rest_req)
					st <= R_CTX_REST_RSP;
			end

			R_CTX_REST_RSP: begin
				if (rsp_valid && (rsp_tag == 8'd3)) begin
					preempt_active        <= 1'b0;
					preempt_saved         <= 1'b0;
					preempt_pulse         <= 1'b1;
					active_qid            <= interrupted_qid;
`ifndef SYNTH_KINTEX7
					rptr[interrupted_qid] <= saved_rptr;
`endif
					buf_valid             <= 8'd0;
					st                    <= R_IDLE;
				end
			end

			default: ;
			endcase

`ifdef SYNTH_KINTEX7
			if (st == R_HDR || st == R_DEC || st == R_DEC2) begin
				tag_match_r <= tag_match;
			end else if (st == R_RSP && rsp_valid && (rsp_tag == 8'd0) && !rsp_error) begin
				tag_match_r <= 1'b1;
			end else if (st == R_N && n_ready && !k_eq_n && (want_word == 3'b111)) begin
				tag_match_r <= next_tag_match;
			end

			if (pa_we_b[0]) pa[15:0] <= (st == R_IDLE) ? pa_hdr[15:0] : pa_4[15:0];
			if (pa_we_b[1]) pa[ADDR_W-1:16] <= (st == R_IDLE) ? pa_hdr[ADDR_W-1:16] : pa_4[ADDR_W-1:16];
			if (pf_line_we_b[0]) pf_line[13:0] <= next_line_r[13:0];
			if (pf_line_we_b[1]) pf_line[LA_W-1:14] <= next_line_r[LA_W-1:14];
`endif
		end
	end

`ifdef SYNTH_KINTEX7
	reg [31:0] ring_rdata_comb;
	always @(*) begin
		case (hcr_ridx[7:0])
		I_BASE0_LO[7:0]: ring_rdata_comb = base[0][31:0];
		I_BASE0_HI[7:0]: ring_rdata_comb = base[0][63:32];
		I_SIZE0[7:0]:    ring_rdata_comb = {27'd0, size[0]};
		I_WPTR0[7:0]:    ring_rdata_comb = {14'd0, wptr[0]};
		I_RPTR0[7:0]:    ring_rdata_comb = {14'd0, rptr[0]};
		I_BASE1[7:0]:    ring_rdata_comb = base[1][31:0];
		I_SIZE1[7:0]:    ring_rdata_comb = {27'd0, size[1]};
		I_WPTR1[7:0]:    ring_rdata_comb = {14'd0, wptr[1]};
		I_RPTR1[7:0]:    ring_rdata_comb = {14'd0, rptr[1]};
		I_BASE2[7:0]:    ring_rdata_comb = base[2][31:0];
		I_SIZE2[7:0]:    ring_rdata_comb = {27'd0, size[2]};
		I_WPTR2[7:0]:    ring_rdata_comb = {14'd0, wptr[2]};
		I_RPTR2[7:0]:    ring_rdata_comb = {14'd0, rptr[2]};
		I_DMA_BASE[7:0]:         ring_rdata_comb = dma_base;
		I_DMA_SIZE[7:0]:         ring_rdata_comb = {27'd0, dma_size};
		I_DMA_WPTR[7:0]:         ring_rdata_comb = {14'd0, dma_wptr};
		I_DMA_RPTR[7:0]:         ring_rdata_comb = {14'd0, dma_rptr};
		I_DMA_SEM[7:0]:          ring_rdata_comb = dma_sem;
		I_DMA_DST_BASE[7:0]:     ring_rdata_comb = dma_dst_base_r;
		I_DMA_ROW_STRIDE[7:0]:   ring_rdata_comb = dma_src_row_stride_r;
		I_DMA_SLICE_STRIDE[7:0]: ring_rdata_comb = dma_src_slice_stride_r;
		I_DMA_EXTENT[7:0]:       ring_rdata_comb = {dma_copy_d_r[7:0], dma_copy_h_r[7:0], dma_copy_w_r};
		I_PREEMPT[7:0]:          ring_rdata_comb = {24'd0, interrupted_qid, 2'd0, preempt_saved, preempt_pending, preempt_active, 1'b0};
		I_PREEMPT_STATUS[7:0]:   ring_rdata_comb = {16'd0, 7'd0, has_work[2], has_work[1], has_work[0], 4'd0, active_qid};
		I_CTX_BASE[7:0]:         ring_rdata_comb = ctx_base;
		I_SEMA[7:0]:             ring_rdata_comb = {13'd0, queue_sema_wait, sema[1], sema[0]};
		default:                 ring_rdata_comb = 32'd0;
		endcase
	end
	assign hcr_rdata = (hcr_ridx[9:8] == 2'b00) ? ring_rdata_comb : 32'd0;
`else
	assign hcr_rdata =
		(hcr_ridx == I_BASE0_LO || hcr_ridx == I_BASE0) ? base[0][31:0] :
		(hcr_ridx == I_BASE0_HI) ? base[0][63:32] :
		(hcr_ridx == I_SIZE0) ? {27'd0, size[0]} :
		(hcr_ridx == I_WPTR0) ? {14'd0, wptr[0]} :
		(hcr_ridx == I_RPTR0) ? {14'd0, rptr[0]} :
		(hcr_ridx == I_BASE1) ? base[1][31:0] :
		(hcr_ridx == I_SIZE1) ? {27'd0, size[1]} :
		(hcr_ridx == I_WPTR1) ? {14'd0, wptr[1]} :
		(hcr_ridx == I_RPTR1) ? {14'd0, rptr[1]} :
		(hcr_ridx == I_BASE2) ? base[2][31:0] :
		(hcr_ridx == I_SIZE2) ? {27'd0, size[2]} :
		(hcr_ridx == I_WPTR2) ? {14'd0, wptr[2]} :
		(hcr_ridx == I_RPTR2) ? {14'd0, rptr[2]} :
		(hcr_ridx == I_DMA_BASE)         ? dma_base :
		(hcr_ridx == I_DMA_SIZE)         ? {27'd0, dma_size} :
		(hcr_ridx == I_DMA_WPTR)         ? {14'd0, dma_wptr} :
		(hcr_ridx == I_DMA_RPTR)         ? {14'd0, dma_rptr} :
		(hcr_ridx == I_DMA_SEM)          ? dma_sem :
		(hcr_ridx == I_DMA_DST_BASE)     ? dma_dst_base_r :
		(hcr_ridx == I_DMA_ROW_STRIDE)   ? dma_src_row_stride_r :
		(hcr_ridx == I_DMA_SLICE_STRIDE) ? dma_src_slice_stride_r :
		(hcr_ridx == I_DMA_EXTENT)       ? {dma_copy_d_r[7:0], dma_copy_h_r[7:0], dma_copy_w_r} :
		(hcr_ridx == I_PREEMPT) ? {24'd0, interrupted_qid, 2'd0, preempt_saved, preempt_pending, preempt_active, 1'b0} :
		(hcr_ridx == I_PREEMPT_STATUS) ? {16'd0, 7'd0, has_work[2], has_work[1], has_work[0], 4'd0, active_qid} :
		(hcr_ridx == I_CTX_BASE) ? ctx_base :
		(hcr_ridx == I_SEMA) ? {13'd0, queue_sema_wait, sema[1], sema[0]} : 32'd0;
`endif

	wire unused_ok = &{1'b0, rsp_write, h_end[18], avail_bo, h_end_co, p_end_co, pa_4_co,
		pa_hdr_co, k_co, unused_nl_co, sema_co, unused_dr_co, unused_ds_co, dma_size, ghci_n_bo,
		base_act, rem_words_bo, rem_words_bo_r, rem_words_s[18]};

endmodule

`default_nettype wire
