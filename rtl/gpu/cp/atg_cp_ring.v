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
	(* keep = "true", dont_touch = "true" *) wire ring_core_rst_high;
	(* keep = "true", dont_touch = "true" *) wire ring_rst_high;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_ring_crst (.I0(core_rst_n), .O(ring_core_rst_high));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_ring_rst  (.I0(rst_n),      .O(ring_rst_high));
`else
	reg [4:0] size [0:2];
`endif
	reg [17:0] wptr [0:2];
	reg [17:0] rptr [0:2];

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
	reg ctx_base_z_r;
	reg preempt_pending;
	reg preempt_active;
	reg preempt_saved;
	reg preempt_auto;
	reg [3:0] prio_mode;
	reg preempt_pulse;
	reg [1:0] last_non_q0;

`ifdef SYNTH_KINTEX7
	wire [31:0] wdata_a, wdata_b, wdata_c, wdata_d;
	wire [8:0] wdata_d1;
	wire [31:0] wmask_a, wmask_b, wmask_c;
	genvar g_wb;
	generate
		for (g_wb = 0; g_wb < 32; g_wb = g_wb + 1) begin : g_wdata_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wda (.I0(hcr_wdata[g_wb]), .O(wdata_a[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdb (.I0(hcr_wdata[g_wb]), .O(wdata_b[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdc (.I0(hcr_wdata[g_wb]), .O(wdata_c[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdd (.I0(hcr_wdata[g_wb]), .O(wdata_d[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wma (.I0(hcr_wmask[g_wb]), .O(wmask_a[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wmb (.I0(hcr_wmask[g_wb]), .O(wmask_b[g_wb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wmc (.I0(hcr_wmask[g_wb]), .O(wmask_c[g_wb]));
		end
		for (g_wb = 0; g_wb < 9; g_wb = g_wb + 1) begin : g_wd1_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdd1 (.I0(hcr_wdata[g_wb]), .O(wdata_d1[g_wb]));
		end
	endgenerate
`else
	wire [31:0] wdata_a = hcr_wdata;
	wire [31:0] wdata_b = hcr_wdata;
	wire [31:0] wdata_c = hcr_wdata;
	wire [31:0] wdata_d = hcr_wdata;
	wire [8:0]  wdata_d1 = hcr_wdata[8:0];
	wire [31:0] wmask_a = hcr_wmask;
	wire [31:0] wmask_b = hcr_wmask;
	wire [31:0] wmask_c = hcr_wmask;
`endif
	reg [7:0] sema [0:7];
	reg [2:0] queue_sema_id [0:2];
	reg [2:0] queue_sema_wait;

	wire [1:0] sema_cmd = wdata_d1[1:0];
	wire [2:0] sema_w_id = wdata_d1[4:2];
	wire [1:0] sema_w_qid = wdata_d1[6:5];
	wire sema_set_q_wait = wdata_d1[7];
	wire sema_clr_q_wait = wdata_d1[8];

	wire [7:0] sema_cur;
	wire [7:0] sema_op_val = (wdata_d[23:16] == 8'd0) ? 8'd1 : wdata_d[23:16];
	wire [7:0] sema_next;
	wire sema_co;

`ifdef SYNTH_KINTEX7
	genvar g_sc;
	generate
		for (g_sc = 0; g_sc < 8; g_sc = g_sc + 1) begin : g_sema_cur_mux
			wire sc_lo, sc_hi;
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFF00F0F0CCCCAAAA)) u_sc_lo (
				.I0(sema[0][g_sc]), .I1(sema[1][g_sc]), .I2(sema[2][g_sc]), .I3(sema[3][g_sc]),
				.I4(wdata_d[2]), .I5(wdata_d[3]), .O(sc_lo)
			);
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFF00F0F0CCCCAAAA)) u_sc_hi (
				.I0(sema[4][g_sc]), .I1(sema[5][g_sc]), .I2(sema[6][g_sc]), .I3(sema[7][g_sc]),
				.I4(wdata_d[2]), .I5(wdata_d[3]), .O(sc_hi)
			);
			(* DONT_TOUCH = "TRUE" *) MUXF7 u_sc_f7 (
				.I0(sc_lo), .I1(sc_hi), .S(wdata_d[4]), .O(sema_cur[g_sc])
			);
		end
	endgenerate
`else
	assign sema_cur = sema[wdata_d[4:2]];
`endif

	am_addsub #(.W(8)) u_sema_addsub (
		.a(sema_cur),
		.b(sema_op_val),
		.sub(wdata_d[1:0] == 2'd2),
		.s(sema_next),
		.co(sema_co)
	);

	/*
	 * Active Queue Signals & Status
	 */
	wire [2:0] q_empty;
`ifdef SYNTH_KINTEX7
	genvar g_qe, g_qeb;
	generate
		for (g_qe = 0; g_qe < 3; g_qe = g_qe + 1) begin : gen_q_empty
			wire [5:0] qe_grp;
			for (g_qeb = 0; g_qeb < 6; g_qeb = g_qeb + 1) begin : gen_qe_grp
				(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h8040201008040201)) u_qeg (
					.I0(wptr[g_qe][g_qeb*3 + 0]), .I1(wptr[g_qe][g_qeb*3 + 1]), .I2(wptr[g_qe][g_qeb*3 + 2]),
					.I3(rptr[g_qe][g_qeb*3 + 0]), .I4(rptr[g_qe][g_qeb*3 + 1]), .I5(rptr[g_qe][g_qeb*3 + 2]),
					.O(qe_grp[g_qeb])
				);
			end
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h8000000000000000)) u_qe_all (
				.I0(qe_grp[0]), .I1(qe_grp[1]), .I2(qe_grp[2]),
				.I3(qe_grp[3]), .I4(qe_grp[4]), .I5(qe_grp[5]),
				.O(q_empty[g_qe])
			);
		end
	endgenerate
`else
	assign q_empty[0] = (wptr[0] == rptr[0]);
	assign q_empty[1] = (wptr[1] == rptr[1]);
	assign q_empty[2] = (wptr[2] == rptr[2]);
`endif

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
	reg q0_empty_r;
	wire [2:0] hw_sel = has_work_r;
	wire q0_empty_sel = q0_empty_r;
`else
	wire [2:0] hw_sel = has_work;
	wire q0_empty_sel = q_empty[0];
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

	(* max_fanout = 16, extract_enable = "no" *) reg [3:0] st;
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
	(* DONT_TOUCH = "TRUE" *) reg [2:0] pf_idx_r;
	wire rsp_ok_tag1 = rsp_valid && (rsp_tag == 8'd1) && !rsp_error;
	wire rsp_ok_tag0 = rsp_valid && (rsp_tag == 8'd0) && !rsp_error;
	wire pf_wr_lo, pf_wr_hi, dm_wr_lo, dm_wr_hi;
	(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'h40)) u_pfw_lo (.I0(pf_st[0]), .I1(pf_st[1]), .I2(rsp_ok_tag1), .O(pf_wr_lo));
	(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'h40)) u_pfw_hi (.I0(pf_st[0]), .I1(pf_st[1]), .I2(rsp_ok_tag1), .O(pf_wr_hi));
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00400000)) u_dmw_lo (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .I4(rsp_ok_tag0), .O(dm_wr_lo));
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00400000)) u_dmw_hi (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .I4(rsp_ok_tag0), .O(dm_wr_hi));
	wire [1:0] dm_wr_b;
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00400000)) u_dmwb0 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .I4(rsp_ok_tag0), .O(dm_wr_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00400000)) u_dmwb1 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .I4(rsp_ok_tag0), .O(dm_wr_b[1]));
	wire [LA_W-1:0] wr_line_mux;
	genvar g_wlm;
	generate
		for (g_wlm = 0; g_wlm < LA_W; g_wlm = g_wlm + 1) begin : g_wlm_gen
			(* DONT_TOUCH = "TRUE" *) LUT3 #(.INIT(8'hCA)) u_wlm (
				.I0(pf_line[g_wlm]),
				.I1(want_line[g_wlm]),
				.I2(dm_wr_b[g_wlm >= 14 ? 1 : 0]),
				.O(wr_line_mux[g_wlm])
			);
		end
	endgenerate
	wire [15:0] buf_slice_we [0:7];
	genvar g_bi, g_sl;
	generate
		for (g_bi = 0; g_bi < 8; g_bi = g_bi + 1) begin : g_buf_wr
			wire pf_hit_lo, pf_hit_hi, dm_hit_lo, dm_hit_hi;
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0100 << g_bi)) u_pfh_lo (
				.I0(pf_idx[0]), .I1(pf_idx[1]), .I2(pf_idx[2]), .I3(pf_wr_lo), .O(pf_hit_lo)
			);
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0100 << g_bi)) u_pfh_hi (
				.I0(pf_idx_r[0]), .I1(pf_idx_r[1]), .I2(pf_idx_r[2]), .I3(pf_wr_hi), .O(pf_hit_hi)
			);
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0100 << g_bi)) u_dmh_lo (
				.I0(pa_widx_lo[0]), .I1(pa_widx_lo[1]), .I2(pa_widx_lo[2]), .I3(dm_wr_lo), .O(dm_hit_lo)
			);
			(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0100 << g_bi)) u_dmh_hi (
				.I0(pa_widx_hi[0]), .I1(pa_widx_hi[1]), .I2(pa_widx_hi[2]), .I3(dm_wr_hi), .O(dm_hit_hi)
			);
			for (g_sl = 0; g_sl < 16; g_sl = g_sl + 1) begin : g_sl_gen
				(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_sl_we (
					.I0(g_sl < 8 ? pf_hit_lo : pf_hit_hi),
					.I1(g_sl < 8 ? dm_hit_lo : dm_hit_hi),
					.O(buf_slice_we[g_bi][g_sl])
				);
				always @(posedge clk) begin
					if (buf_slice_we[g_bi][g_sl])
						buf_data[g_bi][g_sl*16 +: 16] <= rsp_rdata[g_sl*16 +: 16];
				end
			end
			wire [1:0] tag_sl_we;
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_tl_we0 (.I0(pf_hit_lo), .I1(dm_hit_lo), .O(tag_sl_we[0]));
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_tl_we1 (.I0(pf_hit_hi), .I1(dm_hit_hi), .O(tag_sl_we[1]));
			always @(posedge clk) begin
				if (tag_sl_we[0]) buf_tag[g_bi][13:0] <= wr_line_mux[13:0];
				if (tag_sl_we[1]) buf_tag[g_bi][LA_W-1:14] <= wr_line_mux[LA_W-1:14];
			end
		end
	endgenerate
`endif

	/*
	 * The dword wanted as byte address in memory
	 */
`ifdef SYNTH_KINTEX7
	(* DONT_TOUCH = "TRUE" *) reg [ADDR_W-1:0] pa;
	(* DONT_TOUCH = "TRUE" *) reg [2:0] pa_word_r [0:3];
	(* DONT_TOUCH = "TRUE" *) reg [2:0] pa_idx_r [0:3];
	(* DONT_TOUCH = "TRUE" *) reg [2:0] pa_widx_r [0:1];
	wire [2:0] pa_widx_lo, pa_widx_hi;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pwl0 (.I0(pa_widx_r[1][0]), .O(pa_widx_lo[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pwl1 (.I0(pa_widx_r[1][1]), .O(pa_widx_lo[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pwl2 (.I0(pa_widx_r[1][2]), .O(pa_widx_lo[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pwh0 (.I0(pa_widx_r[1][0]), .O(pa_widx_hi[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pwh1 (.I0(pa_widx_r[1][1]), .O(pa_widx_hi[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pwh2 (.I0(pa_widx_r[1][2]), .O(pa_widx_hi[2]));
`else
	(* max_fanout = 16 *) reg [ADDR_W-1:0] pa;
`endif
	wire [ADDR_W-1:0] want_addr = pa;
	wire [LA_W-1:0] want_line = want_addr[ADDR_W-1:LINE_SHIFT];
	wire [WS-1:0] want_word = want_addr[LINE_SHIFT-1:2];
	wire [2:0] want_idx = want_line[2:0];

`ifdef SYNTH_KINTEX7
	wire [2:0] widx_tag0, widx_tag1, widx_tag2, widx_tag3;
	genvar g_wt;
	generate
		for (g_wt = 0; g_wt < 3; g_wt = g_wt + 1) begin : g_widx_tag_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wt0 (.I0(pa_widx_r[0][g_wt]), .O(widx_tag0[g_wt]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wt1 (.I0(pa_widx_r[0][g_wt]), .O(widx_tag1[g_wt]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wt2 (.I0(pa_widx_r[0][g_wt]), .O(widx_tag2[g_wt]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wt3 (.I0(pa_widx_r[0][g_wt]), .O(widx_tag3[g_wt]));
		end
	endgenerate

	reg [LA_W-1:0] cur_tag_r;
	reg cur_valid_r;
	wire [8:0] cm_grp;
	wire cur_hit_lo, cur_hit_hi, cur_hit_comb;
	genvar g_cm;
	generate
		for (g_cm = 0; g_cm < 9; g_cm = g_cm + 1) begin : gen_cm_grp
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h8040201008040201)) u_cmg (
				.I0(cur_tag_r[g_cm*3 + 0]), .I1(cur_tag_r[g_cm*3 + 1]), .I2(cur_tag_r[g_cm*3 + 2]),
				.I3(want_line[g_cm*3 + 0]), .I4(want_line[g_cm*3 + 1]), .I5(want_line[g_cm*3 + 2]),
				.O(cm_grp[g_cm])
			);
		end
	endgenerate
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h80000000)) u_ch_lo (
		.I0(cm_grp[0]), .I1(cm_grp[1]), .I2(cm_grp[2]), .I3(cm_grp[3]), .I4(cm_grp[4]),
		.O(cur_hit_lo)
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h80000000)) u_ch_hi (
		.I0(cm_grp[5]), .I1(cm_grp[6]), .I2(cm_grp[7]), .I3(cm_grp[8]), .I4(cur_valid_r),
		.O(cur_hit_hi)
	);
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_ch_all (
		.I0(cur_hit_lo), .I1(cur_hit_hi), .O(cur_hit_comb)
	);

	wire [31:0] line_word [0:7];
	wire [31:0] want_data;
	genvar g_ln, g_by, g_wb2, g_bt;
	generate
		for (g_ln = 0; g_ln < 8; g_ln = g_ln + 1) begin : gen_line_word
			for (g_by = 0; g_by < 4; g_by = g_by + 1) begin : gen_line_byte
				wire [2:0] w_sel;
				for (g_wb2 = 0; g_wb2 < 3; g_wb2 = g_wb2 + 1) begin : gen_wsel_bit
					(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wsel (
						.I0(pa_word_r[g_by][g_wb2]), .O(w_sel[g_wb2])
					);
				end
				for (g_bt = 0; g_bt < 8; g_bt = g_bt + 1) begin : gen_lw_bit
					wire lw_lo, lw_hi;
					(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFF00F0F0CCCCAAAA)) u_lw_lo (
						.I0(buf_data[g_ln][0*32 + g_by*8 + g_bt]),
						.I1(buf_data[g_ln][1*32 + g_by*8 + g_bt]),
						.I2(buf_data[g_ln][2*32 + g_by*8 + g_bt]),
						.I3(buf_data[g_ln][3*32 + g_by*8 + g_bt]),
						.I4(w_sel[0]),
						.I5(w_sel[1]),
						.O(lw_lo)
					);
					(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFF00F0F0CCCCAAAA)) u_lw_hi (
						.I0(buf_data[g_ln][4*32 + g_by*8 + g_bt]),
						.I1(buf_data[g_ln][5*32 + g_by*8 + g_bt]),
						.I2(buf_data[g_ln][6*32 + g_by*8 + g_bt]),
						.I3(buf_data[g_ln][7*32 + g_by*8 + g_bt]),
						.I4(w_sel[0]),
						.I5(w_sel[1]),
						.O(lw_hi)
					);
					(* DONT_TOUCH = "TRUE" *) MUXF7 u_lw_f7 (
						.I0(lw_lo),
						.I1(lw_hi),
						.S(w_sel[2]),
						.O(line_word[g_ln][g_by*8 + g_bt])
					);
				end
			end
		end
		for (g_by = 0; g_by < 4; g_by = g_by + 1) begin : gen_want_data
			for (g_bt = 0; g_bt < 8; g_bt = g_bt + 1) begin : gen_wd_bit
				wire wd_lo, wd_hi;
				(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFF00F0F0CCCCAAAA)) u_wd_lo (
					.I0(line_word[0][g_by*8 + g_bt]),
					.I1(line_word[1][g_by*8 + g_bt]),
					.I2(line_word[2][g_by*8 + g_bt]),
					.I3(line_word[3][g_by*8 + g_bt]),
					.I4(pa_idx_r[g_by][0]),
					.I5(pa_idx_r[g_by][1]),
					.O(wd_lo)
				);
				(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFF00F0F0CCCCAAAA)) u_wd_hi (
					.I0(line_word[4][g_by*8 + g_bt]),
					.I1(line_word[5][g_by*8 + g_bt]),
					.I2(line_word[6][g_by*8 + g_bt]),
					.I3(line_word[7][g_by*8 + g_bt]),
					.I4(pa_idx_r[g_by][0]),
					.I5(pa_idx_r[g_by][1]),
					.O(wd_hi)
				);
				(* DONT_TOUCH = "TRUE" *) MUXF7 u_wd_f7 (
					.I0(wd_lo),
					.I1(wd_hi),
					.S(pa_idx_r[g_by][2]),
					.O(want_data[g_by*8 + g_bt])
				);
			end
		end
	endgenerate
	(* max_fanout = 16 *) reg hit_n_r;
	reg [1:0] hdr_wait;
	wire hit_n = hit_n_r;
	wire hit = hit_n_r;
`else
	wire hit_comb = buf_valid[want_idx] && (buf_tag[want_idx] == want_line);
	wire hit_n    = hit_comb;
	wire hit      = hit_comb;
	wire [31:0] want_data = buf_data[want_idx][{want_word, 5'd0} +: 32];
`endif

`ifdef SYNTH_KINTEX7
	wire ctx_base_zero = ctx_base_z_r;
`else
	wire ctx_base_zero = (ctx_base == 32'd0);
`endif
	wire go = (run && !halt) || step_pend;

`ifdef SYNTH_KINTEX7
	wire [4:0] hcr_we_cfg_b;
	wire hcr_we_db, hcr_we_dma, hcr_we_sync;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_cfg0 (.I0(hcr_we), .O(hcr_we_cfg_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_cfg1 (.I0(hcr_we), .O(hcr_we_cfg_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_cfg2 (.I0(hcr_we), .O(hcr_we_cfg_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_cfg3 (.I0(hcr_we), .O(hcr_we_cfg_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_cfg4 (.I0(hcr_we), .O(hcr_we_cfg_b[4]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_db   (.I0(hcr_we), .O(hcr_we_db));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_dma  (.I0(hcr_we), .O(hcr_we_dma));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hwe_sync (.I0(hcr_we), .O(hcr_we_sync));
	wire [9:0] widx_a, widx_b;
	genvar g_wi;
	generate
		for (g_wi = 0; g_wi < 10; g_wi = g_wi + 1) begin : g_widx_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wia (.I0(hcr_widx[g_wi]), .O(widx_a[g_wi]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wib (.I0(hcr_widx[g_wi]), .O(widx_b[g_wi]));
		end
	endgenerate
`else
	wire hcr_we_cfg  = hcr_we;
	wire hcr_we_db   = hcr_we;
	wire hcr_we_dma  = hcr_we;
	wire hcr_we_sync = hcr_we;
	wire [9:0] widx_a = hcr_widx;
	wire [9:0] widx_b = hcr_widx;
`endif

	/* Doorbells for the 3 queues */
	wire [2:0] doorbell;
	assign doorbell[0] = hcr_we_db && (widx_b == I_WPTR0);
	assign doorbell[1] = hcr_we_db && (widx_b == I_WPTR1);
	assign doorbell[2] = hcr_we_db && (widx_b == I_WPTR2);

	wire [17:0] wptr_new0 = ((wptr[0] & ~wmask_c[17:0]) | (wdata_c[17:0] & wmask_c[17:0])) & mask[0];
	wire [17:0] wptr_new1 = ((wptr[1] & ~wmask_c[17:0]) | (wdata_c[17:0] & wmask_c[17:0])) & mask[1];
	wire [17:0] wptr_new2 = ((wptr[2] & ~wmask_c[17:0]) | (wdata_c[17:0] & wmask_c[17:0])) & mask[2];

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
`ifdef SYNTH_KINTEX7
		if (ring_rst_high)
`else
		if (!rst_n)
`endif
			avail_r <= 18'd0;
		else
			avail_r <= avail;
	end

`ifdef SYNTH_KINTEX7
	wire [17:0] avail_check = avail_r;
	reg [18:0] nwords_act_r;
	always @(posedge clk) begin
		if (ring_rst_high)
			nwords_act_r <= 19'd0;
		else
			nwords_act_r <= nwords_act;
	end
	wire [18:0] rem_sub_a = nwords_act_r;
`else
	wire [17:0] avail_check = avail;
	wire [18:0] rem_sub_a = nwords_act;
`endif

	wire [18:0] rem_words_s;
	wire rem_words_bo;
	am_sub #(.W(19)) u_rem_sub (
		.a(rem_sub_a), .b({1'b0, cur}), .bi(1'b1), .d(rem_words_s), .bo(rem_words_bo)
	);

	(* max_fanout = 16 *) reg [18:0] rem_words_r;
	(* max_fanout = 16 *) reg rem_words_bo_r;
	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (ring_rst_high) begin
`else
		if (!rst_n) begin
`endif
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

`ifdef SYNTH_KINTEX7
	wire [7:0] st_idle_sel_b;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis0 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis1 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis2 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis3 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis4 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[4]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis5 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[5]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis6 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[6]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_sis7 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_idle_sel_b[7]));

	wire [4:0] st_radv_b;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0010)) u_sra0 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_radv_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0010)) u_sra1 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_radv_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0010)) u_sra2 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_radv_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0010)) u_sra3 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_radv_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0010)) u_sra4 (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(st_radv_b[4]));

	wire rptr_adv_q0 = st_radv_b[4] && (active_qid == 2'd0);
	wire rptr_adv_q1 = st_radv_b[4] && (active_qid == 2'd1);
	wire rptr_adv_q2 = st_radv_b[4] && (active_qid == 2'd2);
	wire rptr_rst_en = (st == R_CTX_REST_RSP) && rsp_valid && (rsp_tag == 8'd3);
	wire rptr_save_en = (st == R_CTX_SAVE_RSP) && rsp_valid && (rsp_tag == 8'd2);
	wire imm_rest_en = (st_idle_sel_b[6]) && preempt_active && ctx_base_z_r;
	wire st_is_radv_hw = st_radv_b[4];
	wire hw_rst_all;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'hFFF8)) u_hw_rst (
		.I0(q0_empty_r), .I1(imm_rest_en), .I2(st_is_radv_hw), .I3(ring_core_rst_high),
		.O(hw_rst_all)
	);
	always @(posedge clk) begin
		if (hw_rst_all)
			has_work_r <= 3'd0;
		else
			has_work_r <= has_work;
	end
	always @(posedge clk) begin
		if (hw_rst_all || doorbell[0])
			q0_empty_r <= 1'b0;
		else
			q0_empty_r <= q_empty[0];
	end
	wire rptr_we_q0, rptr_we_q1, rptr_we_q2;
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hAAAAAAAAAAAAFEEE)) u_rwe_q0 (
		.I0(rptr_adv_q0), .I1(rptr_rst_en), .I2(imm_rest_en),
		.I3(q0_empty_r), .I4(interrupted_qid[0]), .I5(interrupted_qid[1]),
		.O(rptr_we_q0)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hAAAAAAAAFEEEAAAA)) u_rwe_q1 (
		.I0(rptr_adv_q1), .I1(rptr_rst_en), .I2(imm_rest_en),
		.I3(q0_empty_r), .I4(interrupted_qid[0]), .I5(interrupted_qid[1]),
		.O(rptr_we_q1)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hAAAAFEEEAAAAAAAA)) u_rwe_q2 (
		.I0(rptr_adv_q2), .I1(rptr_rst_en), .I2(imm_rest_en),
		.I3(q0_empty_r), .I4(interrupted_qid[0]), .I5(interrupted_qid[1]),
		.O(rptr_we_q2)
	);

	always @(posedge clk) begin
		if (ring_core_rst_high) begin
			rptr[0] <= 18'd0;
			rptr[1] <= 18'd0;
			rptr[2] <= 18'd0;
		end else begin
			if (rptr_we_q0) begin
				rptr[0][13:0]  <= st_radv_b[0] ? p_end[13:0]  : saved_rptr[13:0];
				rptr[0][17:14] <= st_radv_b[1] ? p_end[17:14] : saved_rptr[17:14];
			end
			if (rptr_we_q1) begin
				rptr[1][9:0]   <= st_radv_b[1] ? p_end[9:0]   : saved_rptr[9:0];
				rptr[1][17:10] <= st_radv_b[2] ? p_end[17:10] : saved_rptr[17:10];
			end
			if (rptr_we_q2) begin
				rptr[2][5:0]   <= st_radv_b[2] ? p_end[5:0]   : saved_rptr[5:0];
				rptr[2][17:6]  <= st_radv_b[3] ? p_end[17:6]  : saved_rptr[17:6];
			end
		end
	end
`endif

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
	reg [LA_W-1:0] nxt_tag_r;
	reg nxt_valid_r;
	reg next_hit_r;
	reg [2:0] nl_settle_r;

	wire [8:0] nm_grp;
	wire nxt_hit_lo, nxt_hit_hi, nxt_hit_comb;
	genvar g_nm;
	generate
		for (g_nm = 0; g_nm < 9; g_nm = g_nm + 1) begin : gen_nm_grp
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h8040201008040201)) u_nmg (
				.I0(nxt_tag_r[g_nm*3 + 0]),   .I1(nxt_tag_r[g_nm*3 + 1]),   .I2(nxt_tag_r[g_nm*3 + 2]),
				.I3(next_line_r[g_nm*3 + 0]), .I4(next_line_r[g_nm*3 + 1]), .I5(next_line_r[g_nm*3 + 2]),
				.O(nm_grp[g_nm])
			);
		end
	endgenerate
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h80000000)) u_nh_lo (
		.I0(nm_grp[0]), .I1(nm_grp[1]), .I2(nm_grp[2]), .I3(nm_grp[3]), .I4(nm_grp[4]),
		.O(nxt_hit_lo)
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h80000000)) u_nh_hi (
		.I0(nm_grp[5]), .I1(nm_grp[6]), .I2(nm_grp[7]), .I3(nm_grp[8]), .I4(nxt_valid_r),
		.O(nxt_hit_hi)
	);
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'h8)) u_nh_all (
		.I0(nxt_hit_lo), .I1(nxt_hit_hi), .O(nxt_hit_comb)
	);
	wire next_hit = next_hit_r;
`else
	wire [2:0] next_idx = next_line[2:0];
	wire next_hit = buf_valid[next_idx] && (buf_tag[next_idx] == next_line);
`endif

	reg [1:0] pf_st;
	(* max_fanout = 16, extract_enable = "no" *) reg [LA_W-1:0] pf_line;
	wire [2:0] pf_idx = pf_line[2:0];
`ifdef SYNTH_KINTEX7
	wire [2:0] next_idx = next_line_r[2:0];
	wire [2:0] nidx_tag0, nidx_tag1, nidx_tag2, nidx_tag3;
	genvar g_nt;
	generate
		for (g_nt = 0; g_nt < 3; g_nt = g_nt + 1) begin : g_nidx_tag_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_nt0 (.I0(next_idx[g_nt]), .O(nidx_tag0[g_nt]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_nt1 (.I0(next_idx[g_nt]), .O(nidx_tag1[g_nt]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_nt2 (.I0(next_idx[g_nt]), .O(nidx_tag2[g_nt]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_nt3 (.I0(next_idx[g_nt]), .O(nidx_tag3[g_nt]));
		end
	endgenerate
`endif

	wire ctx_save_req = (st == R_CTX_SAVE_REQ);
	wire ctx_rest_req = (st == R_CTX_REST_REQ);
	wire ctx_req = ctx_save_req || ctx_rest_req;

	// Prefetch next line while executing Class N packet before boundary hit
`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg k_eq_n_r;
	reg [15:0] n_m1_r;
	wire [15:0] n_m1_s;
	wire unused_nm1_bo;
	am_sub #(.W(16)) u_n_m1_sub (
		.a(n), .b(16'd1), .bi(1'b0), .d(n_m1_s), .bo(unused_nm1_bo)
	);
	wire k_eq_n = k_eq_n_r;
`else
	wire k_eq_n = (k[15:8] == n[15:8]) && (k[7:0] == n[7:0]);
`endif

`ifdef SYNTH_KINTEX7
	wire pf_trigger = (st == R_N) && !k_eq_n && !next_hit_r && !nl_settle_r[0] && (pf_st == PF_IDLE) && !ctx_req && go;
	reg pf_trigger_r;
	always @(posedge clk) begin
		if (ring_core_rst_high)
			pf_trigger_r <= 1'b0;
		else
			pf_trigger_r <= pf_trigger;
	end
	wire pf_start = pf_trigger_r;
	wire [1:0] pf_line_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pfl0 (.I0(pf_st == PF_IDLE && pf_start), .O(pf_line_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pfl1 (.I0(pf_st == PF_IDLE && pf_start), .O(pf_line_we_b[1]));
`else
	wire pf_trigger = (st == R_N) && (k != n) && !next_hit && (pf_st == PF_IDLE) &&
		(st != R_REQ) && (st != R_RSP) && !ctx_req && go;
	wire pf_start = pf_trigger;
`endif

	reg f_pulse;
	reg [3:0] f_kind;
	reg [31:0] f_addr;
	reg ret_pulse;

`ifdef SYNTH_KINTEX7
	wire pa_we_hdr;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0001)) u_pa_hdr_lut (.I0(st[0]), .I1(st[1]), .I2(st[2]), .I3(st[3]), .O(pa_we_hdr));
	wire st_is_rn_raw = (st == R_N);
	wire pa_we_adv, pa_we_adv_b;
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0080)) u_pa_adv_a (
		.I0(st_is_rn_raw), .I1(hit_n_r), .I2(n_ready), .I3(k_eq_n), .O(pa_we_adv)
	);
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0080)) u_pa_adv_b (
		.I0(st_is_rn_raw), .I1(hit_n_r), .I2(n_ready), .I3(k_eq_n), .O(pa_we_adv_b)
	);
	wire [3:0] pa_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pawe0 (.I0(pa_we_hdr), .I1(pa_we_adv), .O(pa_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pawe1 (.I0(pa_we_hdr), .I1(pa_we_adv), .O(pa_we_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pawe2 (.I0(pa_we_hdr), .I1(pa_we_adv), .O(pa_we_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pawe3 (.I0(pa_we_hdr), .I1(pa_we_adv), .O(pa_we_b[3]));

	wire [5:0] pa_nxt_7_2_raw = st_idle_sel_b[2] ? pa_hdr[7:2] : pa_4[7:2];
	wire [5:0] pa_nxt_7_2;
	genvar g_pn;
	generate
		for (g_pn = 0; g_pn < 6; g_pn = g_pn + 1) begin : gen_pa_nxt
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pn (.I0(pa_nxt_7_2_raw[g_pn]), .O(pa_nxt_7_2[g_pn]));
		end
	endgenerate

	wire f_addr_we_bad = (st == R_DEC);
	wire f_addr_we_rsp = (st == R_RSP) && rsp_valid && (rsp_tag == 8'd0) && rsp_error;
	wire [1:0] fa_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_fawe0 (.I0(f_addr_we_bad), .I1(f_addr_we_rsp), .O(fa_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_fawe1 (.I0(f_addr_we_bad), .I1(f_addr_we_rsp), .O(fa_we_b[1]));

	wire save_rptr_raw = (st_idle_sel_b[6] || st_radv_b[4]) && preempt_pending && (active_qid != 2'd0);
	wire bvc_db, bvc_pre_rsp, bvc_arb_en, bvc_arb_hw, bv_clr_fsm;
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'h00F0CCAA)) u_bvc_db (
		.I0(doorbell[0]), .I1(doorbell[1]), .I2(doorbell[2]),
		.I3(active_qid[0]), .I4(active_qid[1]),
		.O(bvc_db)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFFFFFFFFFF888)) u_bvc_pre_rsp (
		.I0(save_rptr_raw), .I1(ctx_base_z_r), .I2(imm_rest_en),
		.I3(q0_empty_r), .I4(rptr_save_en), .I5(rptr_rst_en),
		.O(bvc_pre_rsp)
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0202020200000200)) u_bvc_arb_en (
		.I0(st_idle_sel_b[6]), .I1(preempt_pending), .I2(preempt_active),
		.I3(run), .I4(halt), .I5(step_pend),
		.O(bvc_arb_en)
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'hFE0E3254)) u_bvc_arb_hw (
		.I0(hw_sel[0]), .I1(hw_sel[1]), .I2(hw_sel[2]),
		.I3(active_qid[0]), .I4(active_qid[1]),
		.O(bvc_arb_hw)
	);
	(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'hFFFFFFF8)) u_bv_clr_fsm (
		.I0(bvc_arb_en), .I1(bvc_arb_hw), .I2(bvc_db), .I3(bvc_pre_rsp), .I4(ring_core_rst_high),
		.O(bv_clr_fsm)
	);

	wire hn_hdr_en = (st == R_HDR) && (hdr_wait == 2'b01);
	wire hn_set_other = (pa_we_adv && (want_word == 3'b111) && next_hit_r) || dm_wr_lo;
	wire hn_clr_other = (pa_we_adv && (want_word == 3'b111) && !next_hit_r) || bvc_db;
	wire hit_n_next;
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h00008F8F00008F80)) u_hn_lut (
		.I0(cur_hit_lo), .I1(cur_hit_hi), .I2(hn_hdr_en),
		.I3(hn_set_other), .I4(hn_clr_other), .I5(hit_n_r),
		.O(hit_n_next)
	);
	always @(posedge clk) begin
		if (ring_core_rst_high)
			hit_n_r <= 1'b0;
		else
			hit_n_r <= hit_n_next;
	end

	always @(posedge clk) begin
		if (bv_clr_fsm) begin
			buf_valid  <= 8'd0;
			next_hit_r <= 1'b0;
		end else begin
			next_hit_r <= nxt_hit_comb;
			if (pf_wr_lo)
				buf_valid[pf_idx] <= 1'b1;
			if (dm_wr_lo)
				buf_valid[pa_widx_r[1]] <= 1'b1;
		end
	end

	reg empty_r;
	always @(posedge clk) begin
		if (ring_core_rst_high)
			empty_r <= 1'b1;
		else if (doorbell[0] || doorbell[1] || doorbell[2])
			empty_r <= 1'b0;
		else
			empty_r <= q_empty[0] && q_empty[1] && q_empty[2];
	end
`endif

	assign fault = f_pulse;
	assign fault_kind = f_kind;
	assign fault_addr = f_addr;
	assign fault_tag = tag;
	assign retire = ret_pulse;
`ifdef SYNTH_KINTEX7
	assign empty = empty_r;
`else
	assign empty = q_empty[0] && q_empty[1] && q_empty[2];
`endif
	assign busy = (st != R_IDLE && st != R_FAULT) || (pf_st != PF_IDLE) ||
		preempt_pending || preempt_active;
	assign queue_id = active_qid;
	assign preempt_ev = preempt_pulse;

	assign n_valid = (st == R_N) && hit_n;
	assign n_data = want_data;
`ifdef SYNTH_KINTEX7
	assign n_last = k_eq_n_r;
`else
	assign n_last = (k == n);
`endif

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
`ifdef SYNTH_KINTEX7
	wire [1:0] ctx_req_b, demand_req_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_crb0 (.I0(ctx_req),    .O(ctx_req_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_crb1 (.I0(ctx_req),    .O(ctx_req_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_drb0 (.I0(demand_req), .O(demand_req_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_drb1 (.I0(demand_req), .O(demand_req_b[1]));
	assign req_line = {
		ctx_req_b[1] ? ctx_line[LA_W-1:14] : (demand_req_b[1] ? want_line[LA_W-1:14] : pf_line[LA_W-1:14]),
		ctx_req_b[0] ? ctx_line[13:0]      : (demand_req_b[0] ? want_line[13:0]      : pf_line[13:0])
	};
`else
	assign req_line = ctx_req ? ctx_line : (demand_req ? want_line : pf_line);
`endif
	assign req_be = ctx_save_req ? {LINE_BYTES{1'b1}} : {LINE_BYTES{1'b0}};
`ifdef SYNTH_KINTEX7
	assign req_wdata = ctx_save_wdata;
`else
	assign req_wdata = ctx_save_req ? ctx_save_wdata : {(LINE_BYTES * 8){1'b0}};
`endif
	assign req_tag = ctx_save_req ? 8'd2 : (ctx_rest_req ? 8'd3 : (demand_req ? 8'd0 : 8'd1));

	/* Registers surviving CTRL.RESET */
`ifdef SYNTH_KINTEX7
	wire we_b0lo_raw = hcr_we_cfg_b[0] && open && (widx_a == I_BASE0_LO || widx_a == I_BASE0);
	wire we_b0hi_raw = hcr_we_cfg_b[0] && open && (widx_a == I_BASE0_HI);
	wire we_b1_raw   = hcr_we_cfg_b[0] && open && (widx_a == I_BASE1);
	wire we_b2_raw   = hcr_we_cfg_b[0] && open && (widx_a == I_BASE2);
	wire we_dmab_raw = hcr_we_cfg_b[1] && open && (widx_a == I_DMA_BASE);
	wire we_dmad_raw = hcr_we_cfg_b[1] && open && (widx_a == I_DMA_DST_BASE);
	wire we_rs_raw   = hcr_we_cfg_b[1] && open && (widx_a == I_DMA_ROW_STRIDE);
	wire we_ss_raw   = hcr_we_cfg_b[1] && open && (widx_a == I_DMA_SLICE_STRIDE);
	wire we_ctxb_raw = hcr_we_cfg_b[2] && open && (widx_a == I_CTX_BASE);
	wire we_dext_raw = hcr_we_cfg_b[2] && open && (widx_a == I_DMA_EXTENT);

	wire [1:0] we_b0lo_b, we_b0hi_b, we_b1_b, we_b2_b, we_dmab_b, we_dmad_b, we_ctxb_b, we_dext_b;
	wire [3:0] we_rs_b, we_ss_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb0l0 (.I0(we_b0lo_raw), .O(we_b0lo_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb0l1 (.I0(we_b0lo_raw), .O(we_b0lo_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb0h0 (.I0(we_b0hi_raw), .O(we_b0hi_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb0h1 (.I0(we_b0hi_raw), .O(we_b0hi_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb1_0 (.I0(we_b1_raw),   .O(we_b1_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb1_1 (.I0(we_b1_raw),   .O(we_b1_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb2_0 (.I0(we_b2_raw),   .O(we_b2_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wb2_1 (.I0(we_b2_raw),   .O(we_b2_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdb_0 (.I0(we_dmab_raw), .O(we_dmab_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdb_1 (.I0(we_dmab_raw), .O(we_dmab_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdd_0 (.I0(we_dmad_raw), .O(we_dmad_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wdd_1 (.I0(we_dmad_raw), .O(we_dmad_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wrs_0 (.I0(we_rs_raw),   .O(we_rs_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wrs_1 (.I0(we_rs_raw),   .O(we_rs_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wrs_2 (.I0(we_rs_raw),   .O(we_rs_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wrs_3 (.I0(we_rs_raw),   .O(we_rs_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wss_0 (.I0(we_ss_raw),   .O(we_ss_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wss_1 (.I0(we_ss_raw),   .O(we_ss_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wss_2 (.I0(we_ss_raw),   .O(we_ss_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wss_3 (.I0(we_ss_raw),   .O(we_ss_b[3]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wcb_0 (.I0(we_ctxb_raw), .O(we_ctxb_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wcb_1 (.I0(we_ctxb_raw), .O(we_ctxb_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wde_0 (.I0(we_dext_raw), .O(we_dext_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wde_1 (.I0(we_dext_raw), .O(we_dext_b[1]));

	wire dmasem_hcr_we = hcr_we_dma && (widx_b == I_DMA_SEM);
	wire dmasem_inc_we = dma_active && dma_done;
	wire [1:0] dmasem_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_dsm0 (.I0(dmasem_hcr_we), .I1(dmasem_inc_we), .O(dmasem_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_dsm1 (.I0(dmasem_hcr_we), .I1(dmasem_inc_we), .O(dmasem_we_b[1]));

	wire st_is_rhdr_raw = (st == R_HDR);
	wire [2:0] st_rhdr_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srh0 (.I0(st_is_rhdr_raw), .O(st_rhdr_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srh1 (.I0(st_is_rhdr_raw), .O(st_rhdr_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srh2 (.I0(st_is_rhdr_raw), .O(st_rhdr_b[2]));

	wire st_is_rdec_raw = (st == R_DEC);
	wire [1:0] st_rdec_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srd0 (.I0(st_is_rdec_raw), .O(st_rdec_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srd1 (.I0(st_is_rdec_raw), .O(st_rdec_b[1]));

	wire st_is_rdec2_raw = (st == R_DEC2);
	wire [1:0] st_rdec2_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srd2_0 (.I0(st_is_rdec2_raw), .O(st_rdec2_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srd2_1 (.I0(st_is_rdec2_raw), .O(st_rdec2_b[1]));

	wire [1:0] save_rptr_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srp0 (.I0(save_rptr_raw), .O(save_rptr_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_srp1 (.I0(save_rptr_raw), .O(save_rptr_we_b[1]));

	wire [1:0] dma_wptr_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_dww0 (.I0(hcr_we_dma && widx_b == I_DMA_WPTR), .O(dma_wptr_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_dww1 (.I0(hcr_we_dma && widx_b == I_DMA_WPTR), .O(dma_wptr_we_b[1]));

	wire we_sz0_raw = hcr_we_cfg_b[3] && open && (widx_b == I_SIZE0) && wmask_c[0];
	wire we_sz1_raw = hcr_we_cfg_b[3] && open && (widx_b == I_SIZE1) && wmask_c[0];
	wire we_sz2_raw = hcr_we_cfg_b[4] && open && (widx_b == I_SIZE2) && wmask_c[0];
	wire [1:0] we_sz0_b, we_sz1_b, we_sz2_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wsz0_0 (.I0(we_sz0_raw), .O(we_sz0_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wsz0_1 (.I0(we_sz0_raw), .O(we_sz0_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wsz1_0 (.I0(we_sz1_raw), .O(we_sz1_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wsz1_1 (.I0(we_sz1_raw), .O(we_sz1_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wsz2_0 (.I0(we_sz2_raw), .O(we_sz2_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_wsz2_1 (.I0(we_sz2_raw), .O(we_sz2_b[1]));
	wire [4:0] sz_clamp_c = wdata_c[4:0] < 5'd10 ? 5'd10 : (wdata_c[4:0] > 5'd20 ? 5'd20 : wdata_c[4:0]);
`endif

	integer bi;
	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (ring_rst_high) begin
`else
		if (!rst_n) begin
`endif
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
			ctx_base_z_r <= 1'b1;
			prio_mode <= 4'd0;
			preempt_auto <= 1'b0;
		end else begin
`ifdef SYNTH_KINTEX7
			ctx_base_z_r <= (ctx_base == 32'd0);
			if (we_b0lo_b[0]) base[0][15:0]  <= ((base[0][15:0]  & ~wmask_a[15:0])  | (wdata_a[15:0]  & wmask_a[15:0])) & 16'hFFE0;
			if (we_b0lo_b[1]) base[0][31:16] <=  (base[0][31:16] & ~wmask_a[31:16]) | (wdata_a[31:16] & wmask_a[31:16]);
			if (we_b0hi_b[0]) base[0][47:32] <=  (base[0][47:32] & ~wmask_a[15:0])  | (wdata_a[15:0]  & wmask_a[15:0]);
			if (we_b0hi_b[1]) base[0][63:48] <=  (base[0][63:48] & ~wmask_a[31:16]) | (wdata_a[31:16] & wmask_a[31:16]);

			if (we_b1_b[0])   base[1][15:0]  <= ((base[1][15:0]  & ~wmask_a[15:0])  | (wdata_a[15:0]  & wmask_a[15:0])) & 16'hFFE0;
			if (we_b1_b[1])   base[1][31:16] <=  (base[1][31:16] & ~wmask_a[31:16]) | (wdata_a[31:16] & wmask_a[31:16]);

			if (we_b2_b[0])   base[2][15:0]  <= ((base[2][15:0]  & ~wmask_a[15:0])  | (wdata_a[15:0]  & wmask_a[15:0])) & 16'hFFE0;
			if (we_b2_b[1])   base[2][31:16] <=  (base[2][31:16] & ~wmask_a[31:16]) | (wdata_a[31:16] & wmask_a[31:16]);

			if (we_dmab_b[0]) dma_base[15:0]  <= ((dma_base[15:0]  & ~wmask_b[15:0])  | (wdata_b[15:0]  & wmask_b[15:0])) & 16'hFFE0;
			if (we_dmab_b[1]) dma_base[31:16] <=  (dma_base[31:16] & ~wmask_b[31:16]) | (wdata_b[31:16] & wmask_b[31:16]);

			if (we_dmad_b[0]) dma_dst_base_r[15:0]  <= (dma_dst_base_r[15:0]  & ~wmask_b[15:0])  | (wdata_b[15:0]  & wmask_b[15:0]);
			if (we_dmad_b[1]) dma_dst_base_r[31:16] <= (dma_dst_base_r[31:16] & ~wmask_b[31:16]) | (wdata_b[31:16] & wmask_b[31:16]);

			if (we_rs_b[0]) dma_src_row_stride_r[15:0]  <= (dma_src_row_stride_r[15:0]  & ~wmask_b[15:0])  | (wdata_b[15:0]  & wmask_b[15:0]);
			if (we_rs_b[1]) dma_src_row_stride_r[31:16] <= (dma_src_row_stride_r[31:16] & ~wmask_b[31:16]) | (wdata_b[31:16] & wmask_b[31:16]);
			if (we_rs_b[2]) dma_dst_row_stride_r[15:0]  <= (dma_dst_row_stride_r[15:0]  & ~wmask_b[15:0])  | (wdata_b[15:0]  & wmask_b[15:0]);
			if (we_rs_b[3]) dma_dst_row_stride_r[31:16] <= (dma_dst_row_stride_r[31:16] & ~wmask_b[31:16]) | (wdata_b[31:16] & wmask_b[31:16]);

			if (we_ss_b[0]) dma_src_slice_stride_r[15:0]  <= (dma_src_slice_stride_r[15:0]  & ~wmask_b[15:0])  | (wdata_b[15:0]  & wmask_b[15:0]);
			if (we_ss_b[1]) dma_src_slice_stride_r[31:16] <= (dma_src_slice_stride_r[31:16] & ~wmask_b[31:16]) | (wdata_b[31:16] & wmask_b[31:16]);
			if (we_ss_b[2]) dma_dst_slice_stride_r[15:0]  <= (dma_dst_slice_stride_r[15:0]  & ~wmask_b[15:0])  | (wdata_b[15:0]  & wmask_b[15:0]);
			if (we_ss_b[3]) dma_dst_slice_stride_r[31:16] <= (dma_dst_slice_stride_r[31:16] & ~wmask_b[31:16]) | (wdata_b[31:16] & wmask_b[31:16]);

			if (we_ctxb_b[0]) ctx_base[15:0]  <= ((ctx_base[15:0]  & ~wmask_a[15:0])  | (wdata_a[15:0]  & wmask_a[15:0])) & 16'hFFE0;
			if (we_ctxb_b[1]) ctx_base[31:16] <=  (ctx_base[31:16] & ~wmask_a[31:16]) | (wdata_a[31:16] & wmask_a[31:16]);

			if (we_dext_b[0]) dma_copy_w_r <= wdata_b[15:0];
			if (we_dext_b[1]) begin
				dma_copy_h_r <= wdata_b[23:16] != 8'd0 ? {8'd0, wdata_b[23:16]} : 16'd128;
				dma_copy_d_r <= wdata_b[31:24] != 8'd0 ? {8'd0, wdata_b[31:24]} : 16'd64;
			end

			if (we_sz0_b[0]) size[0][2:0] <= sz_clamp_c[2:0];
			if (we_sz0_b[1]) size[0][4:3] <= sz_clamp_c[4:3];
			if (we_sz1_b[0]) size[1][2:0] <= sz_clamp_c[2:0];
			if (we_sz1_b[1]) size[1][4:3] <= sz_clamp_c[4:3];
			if (we_sz2_b[0]) size[2][2:0] <= sz_clamp_c[2:0];
			if (we_sz2_b[1]) size[2][4:3] <= sz_clamp_c[4:3];
			if (hcr_we_cfg_b[4]) begin
				if (open) begin
					if (widx_b == I_DMA_SIZE && wmask_c[0])
						dma_size <= sz_clamp_c;
				end
				if (widx_b == I_PREEMPT && wmask_c[0]) begin
					prio_mode <= wdata_c[7:4];
					preempt_auto <= wdata_c[4];
				end
			end
`else
			if (hcr_we_cfg) begin
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
`endif
		end
	end

	/* Main sequential logic */
	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (ring_core_rst_high) begin
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
`ifndef SYNTH_KINTEX7
			buf_valid <= 8'd0;
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
			for (bi = 0; bi < 4; bi = bi + 1) begin
				pa_word_r[bi] <= 3'd0;
				pa_idx_r[bi]  <= 3'd0;
			end
			pa_widx_r[0] <= 3'd0;
			pa_widx_r[1] <= 3'd0;
			pf_idx_r    <= 3'd0;
			k_eq_n_r    <= 1'b0;
			n_m1_r      <= 16'd0;
			cur_tag_r   <= {LA_W{1'b0}};
			cur_valid_r <= 1'b0;
			hdr_wait    <= 2'b10;
			next_line_r <= {LA_W{1'b0}};
			nxt_tag_r   <= {LA_W{1'b0}};
			nxt_valid_r <= 1'b0;
			nl_settle_r <= 3'b000;
`endif
		end else begin
			f_pulse       <= 1'b0;
			ret_pulse     <= 1'b0;
			preempt_pulse <= 1'b0;
`ifdef SYNTH_KINTEX7
			cur_tag_r[6:0]       <= buf_tag[widx_tag0][6:0];
			cur_tag_r[13:7]      <= buf_tag[widx_tag1][13:7];
			cur_tag_r[20:14]     <= buf_tag[widx_tag2][20:14];
			cur_tag_r[LA_W-1:21] <= buf_tag[widx_tag3][LA_W-1:21];
			cur_valid_r          <= buf_valid[widx_tag0];
			next_line_r <= next_line;
			nxt_tag_r[6:0]       <= buf_tag[nidx_tag0][6:0];
			nxt_tag_r[13:7]      <= buf_tag[nidx_tag1][13:7];
			nxt_tag_r[20:14]     <= buf_tag[nidx_tag2][20:14];
			nxt_tag_r[LA_W-1:21] <= buf_tag[nidx_tag3][LA_W-1:21];
			nxt_valid_r          <= buf_valid[nidx_tag0];
			nl_settle_r <= {1'b0, nl_settle_r[2:1]};
			if (st_rhdr_b[0]) hdr_data[15:0]  <= want_data[15:0];
			if (st_rhdr_b[1]) hdr_data[31:16] <= want_data[31:16];
			if (st_rhdr_b[2]) k <= 16'd0;
			if (st_rdec_b[0]) n <= h_n;
			if (st_rdec_b[1]) begin
				tag       <= hdr_data[23:16];
				h_novf_r  <= h_novf;
				h_class_r <= h_class;
			end
			if (st_rdec2_b[0]) begin
				k_eq_n_r <= (n == 16'd0);
				n_m1_r[7:0] <= n_m1_s[7:0];
			end
			if (st_rdec2_b[1]) begin
				n_m1_r[15:8] <= n_m1_s[15:8];
			end
			if (save_rptr_we_b[0]) begin
				interrupted_qid <= active_qid;
				saved_rptr[8:0] <= st_idle_sel_b[3] ? rptr[active_qid][8:0] : p_end[8:0];
			end
			if (save_rptr_we_b[1]) begin
				saved_rptr[17:9] <= st_idle_sel_b[7] ? rptr[active_qid][17:9] : p_end[17:9];
			end
			if (st_idle_sel_b[4]) cur[8:0] <= rptr_act[8:0];
			if (st_idle_sel_b[5]) cur[17:9] <= rptr_act[17:9];
			if (fa_we_b[0]) f_addr[15:0] <= want_addr[15:0];
			if (fa_we_b[1]) f_addr[31:16] <= want_addr[31:16];
`endif

			/* Doorbells */
			if (doorbell[0]) begin
				wptr[0] <= wptr_new0;
				if (active_qid == 2'd0) begin
					stale     <= 1'b1;
`ifndef SYNTH_KINTEX7
					buf_valid <= 8'd0;
`endif
				end
			end
			if (doorbell[1]) begin
				wptr[1] <= wptr_new1;
				if (active_qid == 2'd1) begin
					stale     <= 1'b1;
`ifndef SYNTH_KINTEX7
					buf_valid <= 8'd0;
`endif
				end
			end
			if (doorbell[2]) begin
				wptr[2] <= wptr_new2;
				if (active_qid == 2'd2) begin
					stale     <= 1'b1;
`ifndef SYNTH_KINTEX7
					buf_valid <= 8'd0;
`endif
				end
			end

`ifdef SYNTH_KINTEX7
			if (dma_wptr_we_b[0])
				dma_wptr[8:0]  <= (dma_wptr[8:0]  & ~wmask_c[8:0])  | (wdata_c[8:0]  & wmask_c[8:0]);
			if (dma_wptr_we_b[1])
				dma_wptr[17:9] <= (dma_wptr[17:9] & ~wmask_c[17:9]) | (wdata_c[17:9] & wmask_c[17:9]);
			if (dmasem_we_b[0])
				dma_sem[15:0] <= dmasem_inc_we ? dma_sem_next[15:0] : ((dma_sem[15:0] & ~wmask_c[15:0]) | (wdata_c[15:0] & wmask_c[15:0]));
			if (dmasem_we_b[1])
				dma_sem[31:16] <= dmasem_inc_we ? dma_sem_next[31:16] : ((dma_sem[31:16] & ~wmask_c[31:16]) | (wdata_c[31:16] & wmask_c[31:16]));
`else
			if (hcr_we_dma && widx_b == I_DMA_WPTR)
				dma_wptr <= (dma_wptr & ~wmask_c[17:0]) | (wdata_c[17:0] & wmask_c[17:0]);
			if (hcr_we_dma && hcr_widx == I_DMA_SEM)
				dma_sem <= (dma_sem & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
`endif

			if (!dma_active && (dma_wptr != dma_rptr) && go) begin
				dma_active <= 1'b1;
				dma_req_v  <= 1'b1;
			end else if (dma_req_v && dma_req_ready) begin
				dma_req_v  <= 1'b0;
			end

			if (dma_active && dma_done) begin
				dma_active <= 1'b0;
				dma_rptr   <= dma_rptr_next;
`ifndef SYNTH_KINTEX7
				dma_sem    <= dma_sem_next;
`endif
			end

			/* Preemption request from host */
			if (hcr_we_sync && (widx_b == I_PREEMPT)) begin
				if (wdata_d[0] && !preempt_active)
					preempt_pending <= 1'b1;
			end

			/* Auto-preempt when Queue 0 receives work during Queue 1/2 execution */
			if (preempt_auto && hw_sel[0] && (active_qid != 2'd0) && !preempt_active)
				preempt_pending <= 1'b1;

			/* Semaphore update from host or ring */
			if (hcr_we_sync && (widx_b == I_SEMA)) begin
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
					sema[sema_w_id] <= wdata_d[23:16];
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
				if (pf_start) begin
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
`ifndef SYNTH_KINTEX7
					if (!rsp_error) begin
						buf_data[pf_idx]  <= rsp_rdata;
						buf_tag[pf_idx]   <= pf_line;
						buf_valid[pf_idx] <= 1'b1;
					end
`endif
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
`ifndef SYNTH_KINTEX7
					interrupted_qid <= active_qid;
					saved_rptr      <= rptr[active_qid];
`endif
					if (ctx_base_zero) begin
						/* Instant shadow context switch */
						preempt_saved   <= 1'b1;
						preempt_pending <= 1'b0;
						preempt_active  <= 1'b1;
						preempt_pulse   <= 1'b1;
						active_qid      <= 2'd0;
`ifndef SYNTH_KINTEX7
						buf_valid       <= 8'd0;
`endif
					end else begin
						st <= R_CTX_SAVE_REQ;
					end
				end else if (preempt_active && q0_empty_sel) begin
					/* High-priority Queue 0 finished: restore interrupted queue */
					if (ctx_base_zero) begin
						preempt_active  <= 1'b0;
						preempt_saved   <= 1'b0;
						preempt_pulse   <= 1'b1;
						active_qid      <= interrupted_qid;
`ifndef SYNTH_KINTEX7
						rptr[interrupted_qid] <= saved_rptr;
						buf_valid       <= 8'd0;
`endif
					end else begin
						st <= R_CTX_REST_REQ;
					end
				end else if (go) begin
`ifdef SYNTH_KINTEX7
					if (hw_sel[active_qid]) begin
						step_pend <= 1'b0;
						hdr_wait  <= 2'b10;
						st        <= R_HDR;
					end else if (|hw_sel) begin
						/* Arbiter switches to next active queue */
						active_qid <= next_qid;
						if (next_qid != 2'd0)
							last_non_q0 <= next_qid;
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
				if (hdr_wait == 2'b10) begin
					hdr_wait <= 2'b01;
				end else if (hdr_wait == 2'b01) begin
					hdr_wait <= 2'b00;
				end else begin
					hdr_wait <= 2'b10;
					if (!hit_n_r || stale) begin
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
`ifndef SYNTH_KINTEX7
				tag       <= hdr_data[23:16];
				n         <= h_n;
				f_addr    <= want_addr[31:0];
				h_bad_r   <= h_bad;
				h_novf_r  <= h_novf;
				h_class_r <= h_class;
`endif
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
`ifndef SYNTH_KINTEX7
					end else begin
						k  <= k_n;
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
`ifndef SYNTH_KINTEX7
					interrupted_qid <= active_qid;
					saved_rptr      <= p_end;
`endif
					if (ctx_base_zero) begin
						preempt_saved   <= 1'b1;
						preempt_pending <= 1'b0;
						preempt_active  <= 1'b1;
						preempt_pulse   <= 1'b1;
						active_qid      <= 2'd0;
`ifndef SYNTH_KINTEX7
						buf_valid       <= 8'd0;
`endif
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
`ifndef SYNTH_KINTEX7
						f_addr  <= want_addr[31:0];
`endif
						st      <= R_FAULT;
					end else begin
`ifndef SYNTH_KINTEX7
						buf_valid[want_idx] <= 1'b1;
						buf_tag[want_idx]   <= want_line;
						buf_data[want_idx]  <= rsp_rdata;
`else
						hdr_wait <= 2'b00;
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
`ifndef SYNTH_KINTEX7
					buf_valid       <= 8'd0;
`endif
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
					buf_valid             <= 8'd0;
`endif
					st                    <= R_IDLE;
				end
			end

			default: ;
			endcase

`ifdef SYNTH_KINTEX7
			if (pa_we_adv_b) begin
				k        <= k_n;
				k_eq_n_r <= (k[15:8] == n_m1_r[15:8]) && (k[7:0] == n_m1_r[7:0]);
				if (want_word == 3'b111)
					nl_settle_r <= 3'b111;
			end
			if (pa_we_b[0]) pa[15:0] <= st_idle_sel_b[0] ? pa_hdr[15:0] : pa_4[15:0];
			if (pa_we_b[1]) pa[ADDR_W-1:16] <= st_idle_sel_b[1] ? pa_hdr[ADDR_W-1:16] : pa_4[ADDR_W-1:16];
			if (pa_we_b[2]) begin
				pa_word_r[0] <= pa_nxt_7_2[2:0];
				pa_word_r[1] <= pa_nxt_7_2[2:0];
				pa_idx_r[0]  <= pa_nxt_7_2[5:3];
				pa_idx_r[1]  <= pa_nxt_7_2[5:3];
				pa_widx_r[0] <= pa_nxt_7_2[5:3];
			end
			if (pa_we_b[3]) begin
				pa_word_r[2] <= pa_nxt_7_2[2:0];
				pa_word_r[3] <= pa_nxt_7_2[2:0];
				pa_idx_r[2]  <= pa_nxt_7_2[5:3];
				pa_idx_r[3]  <= pa_nxt_7_2[5:3];
				pa_widx_r[1] <= pa_nxt_7_2[5:3];
			end
			if (pf_line_we_b[0]) begin
				pf_line[13:0] <= next_line_r[13:0];
				pf_idx_r      <= next_line_r[2:0];
			end
			if (pf_line_we_b[1]) pf_line[LA_W-1:14] <= next_line_r[LA_W-1:14];
`endif
		end
	end

`ifdef SYNTH_KINTEX7
	wire [1:0] ridx_sel_lo [0:5];
	wire [1:0] ridx_sel_hi [0:5];
	wire [5:0] rgrp_en_lo, rgrp_en_hi;
	wire ridx_b3_lo, ridx_b3_hi;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rb3_lo (.I0(hcr_ridx[3]), .O(ridx_b3_lo));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rb3_hi (.I0(hcr_ridx[3]), .O(ridx_b3_hi));
	genvar g_rg;
	generate
		for (g_rg = 0; g_rg < 6; g_rg = g_rg + 1) begin : gen_ridx_sel
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rsl0 (.I0(hcr_ridx[0]), .O(ridx_sel_lo[g_rg][0]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rsl1 (.I0(hcr_ridx[1]), .O(ridx_sel_lo[g_rg][1]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rsh0 (.I0(hcr_ridx[0]), .O(ridx_sel_hi[g_rg][0]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rsh1 (.I0(hcr_ridx[1]), .O(ridx_sel_hi[g_rg][1]));
		end
	endgenerate
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0020)) u_rge0_lo (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_lo[0]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0020)) u_rge0_hi (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_hi[0]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0800)) u_rge1_lo (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_lo[1]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h0800)) u_rge1_hi (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_hi[1]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h1000)) u_rge2_lo (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_lo[2]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h1000)) u_rge2_hi (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_hi[2]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h4000)) u_rge3_lo (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_lo[3]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h4000)) u_rge3_hi (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_hi[3]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h8000)) u_rge4_lo (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_lo[4]));
	(* DONT_TOUCH = "TRUE" *) LUT4 #(.INIT(16'h8000)) u_rge4_hi (.I0(hcr_ridx[2]), .I1(hcr_ridx[3]), .I2(hcr_ridx[4]), .I3(hcr_ridx[5]), .O(rgrp_en_hi[4]));
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0010000000000600)) u_rge5_lo (
		.I0(hcr_ridx[0]), .I1(hcr_ridx[1]), .I2(hcr_ridx[2]),
		.I3(hcr_ridx[3]), .I4(hcr_ridx[4]), .I5(hcr_ridx[5]), .O(rgrp_en_lo[5])
	);
	(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'h0010000000000600)) u_rge5_hi (
		.I0(hcr_ridx[0]), .I1(hcr_ridx[1]), .I2(hcr_ridx[2]),
		.I3(hcr_ridx[3]), .I4(hcr_ridx[4]), .I5(hcr_ridx[5]), .O(rgrp_en_hi[5])
	);

	(* keep = "true" *) wire [31:0] rgrp0 = {
		ridx_sel_hi[0] == 2'd0 ? base[0][31:16] : ridx_sel_hi[0] == 2'd1 ? 16'd0 : ridx_sel_hi[0] == 2'd2 ? {14'd0, wptr[0][17:16]} : {14'd0, rptr[0][17:16]},
		ridx_sel_lo[0] == 2'd0 ? base[0][15:0]  : ridx_sel_lo[0] == 2'd1 ? {11'd0, size[0]} : ridx_sel_lo[0] == 2'd2 ? wptr[0][15:0] : rptr[0][15:0]
	};
	(* keep = "true" *) wire [31:0] rgrp1 = {
		ridx_sel_hi[1] == 2'd0 ? base[1][31:16] : ridx_sel_hi[1] == 2'd1 ? 16'd0 : ridx_sel_hi[1] == 2'd2 ? {14'd0, wptr[1][17:16]} : {14'd0, rptr[1][17:16]},
		ridx_sel_lo[1] == 2'd0 ? base[1][15:0]  : ridx_sel_lo[1] == 2'd1 ? {11'd0, size[1]} : ridx_sel_lo[1] == 2'd2 ? wptr[1][15:0] : rptr[1][15:0]
	};
	(* keep = "true" *) wire [31:0] rgrp2 = {
		ridx_sel_hi[2] == 2'd0 ? dma_sem[31:16] : ridx_sel_hi[2] == 2'd1 ? dma_dst_base_r[31:16] : ridx_sel_hi[2] == 2'd2 ? dma_src_row_stride_r[31:16] : dma_src_slice_stride_r[31:16],
		ridx_sel_lo[2] == 2'd0 ? dma_sem[15:0]  : ridx_sel_lo[2] == 2'd1 ? dma_dst_base_r[15:0]  : ridx_sel_lo[2] == 2'd2 ? dma_src_row_stride_r[15:0]  : dma_src_slice_stride_r[15:0]
	};
	(* keep = "true" *) wire [31:0] rgrp3 = {
		ridx_sel_hi[3] == 2'd0 ? base[2][31:16] : ridx_sel_hi[3] == 2'd1 ? 16'd0 : ridx_sel_hi[3] == 2'd2 ? {14'd0, wptr[2][17:16]} : {14'd0, rptr[2][17:16]},
		ridx_sel_lo[3] == 2'd0 ? base[2][15:0]  : ridx_sel_lo[3] == 2'd1 ? {11'd0, size[2]} : ridx_sel_lo[3] == 2'd2 ? wptr[2][15:0] : rptr[2][15:0]
	};
	wire [31:0] pr_val   = {24'd0, interrupted_qid, 2'd0, preempt_saved, preempt_pending, preempt_active, 1'b0};
	wire [31:0] prst_val = {16'd0, 7'd0, hw_sel[2], hw_sel[1], hw_sel[0], 4'd0, active_qid};
	wire [31:0] sema_val = {13'd0, queue_sema_wait, sema[1], sema[0]};
	(* keep = "true" *) wire [31:0] rgrp4 = {
		ridx_sel_hi[4] == 2'd0 ? pr_val[31:16] : ridx_sel_hi[4] == 2'd1 ? prst_val[31:16] : ridx_sel_hi[4] == 2'd2 ? ctx_base[31:16] : sema_val[31:16],
		ridx_sel_lo[4] == 2'd0 ? pr_val[15:0]  : ridx_sel_lo[4] == 2'd1 ? prst_val[15:0]  : ridx_sel_lo[4] == 2'd2 ? ctx_base[15:0]  : sema_val[15:0]
	};
	wire [31:0] dext_val = {dma_copy_d_r[7:0], dma_copy_h_r[7:0], dma_copy_w_r};
	(* keep = "true" *) wire [31:0] rgrp5 = {
		ridx_sel_hi[5] == 2'd0 ? dext_val[31:16] : ridx_sel_hi[5] == 2'd1 ? base[0][31:16] : ridx_sel_hi[5] == 2'd2 ? base[0][63:48] : 16'd0,
		ridx_sel_lo[5] == 2'd0 ? dext_val[15:0]  : ridx_sel_lo[5] == 2'd1 ? base[0][15:0]  : ridx_sel_lo[5] == 2'd2 ? base[0][47:32] : 16'd0
	};

	wire [31:0] ring_half_0, ring_half_1;
	genvar g_rh;
	generate
		for (g_rh = 0; g_rh < 32; g_rh = g_rh + 1) begin : gen_ring_rdata_mux
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_rh0 (
				.I0(rgrp0[g_rh]), .I1(g_rh < 16 ? rgrp_en_lo[0] : rgrp_en_hi[0]),
				.I2(rgrp2[g_rh]), .I3(g_rh < 16 ? rgrp_en_lo[2] : rgrp_en_hi[2]),
				.I4(rgrp5[g_rh]), .I5(g_rh < 16 ? rgrp_en_lo[5] : rgrp_en_hi[5]),
				.O(ring_half_0[g_rh])
			);
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_rh1 (
				.I0(rgrp1[g_rh]), .I1(g_rh < 16 ? rgrp_en_lo[1] : rgrp_en_hi[1]),
				.I2(rgrp3[g_rh]), .I3(g_rh < 16 ? rgrp_en_lo[3] : rgrp_en_hi[3]),
				.I4(rgrp4[g_rh]), .I5(g_rh < 16 ? rgrp_en_lo[4] : rgrp_en_hi[4]),
				.O(ring_half_1[g_rh])
			);
			(* DONT_TOUCH = "TRUE" *) MUXF7 u_rmf7 (
				.I0(ring_half_0[g_rh]),
				.I1(ring_half_1[g_rh]),
				.S(g_rh < 16 ? ridx_b3_lo : ridx_b3_hi),
				.O(hcr_rdata[g_rh])
			);
		end
	endgenerate
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
		base_act, rem_words_bo, rem_words_bo_r, rem_words_s[18], hit, next_hit,
		h_bad_r, h_bad_words_r, h_bad_avail_r, h_bad};

endmodule

`default_nettype wire
