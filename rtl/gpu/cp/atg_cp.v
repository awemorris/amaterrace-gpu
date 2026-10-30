/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp: the command processor, wiring only: its children
 * hold the GHCI host control registers and the work (spec/gpu/cp/).
 *
 *   atg_cp_regs   the register bus: identification, CAPS, the extended
 *                 capability list, PERF; the HCR snoop bus and STATE alias
 *   atg_cp_state  STATE[0..511], the broadcast to the blocks, the replay
 *                 after RESET
 *   atg_cp_ctl    CTRL/STATUS, the CP states, KICK, quiesce, the RESET
 *                 order, the watchdog, the aperture, FAULT_ADDR/INFO
 *   atg_cp_ring   the command ring and the packet envelope (design §2.4.2)
 *   atg_cp_seq    the class N µop sequencer
 *   atg_cp_fence  FENCE/RESULT writes, WAIT_FENCE polls, FENCE_LAST
 *   atg_cp_irq    IRQ_STATUS/ENABLE/SET and the line
 *   atg_cp_dbg    the asynchronous debug port
 *   atg_cp_disp   (HAS_DISP) the DISP2 display controller's side: DISP_SET,
 *                 FLIP, the host's gate to the DC's registers (window at
 *                 0x200), the plane slots and the flip records
 *
 * The ring, the fence unit, the debug port and atg_cp_disp's record
 * writer share MC client 0 through am_amb_mux (priority ring, fence,
 * debug, records; the requester in tag bits [7:6]).  The MC's quiesce does not hold client 0 (atg_top sets the MC's
 * QUIESCE_EXEMPT), so the CP's own accesses (the debug port in HALTED and
 * FAULTED, a ring line or fence already requested) go on while the blocks
 * are held.
 * Session protection (atg_cp_prot, outside): the sequencer shows its µop
 * (u_*) and waits for u_ok before it starts a unit; the fence unit's
 * requests carry f_chk and f_slot (req_chk, req_slot when the mux picked
 * the fence unit; the ring's and the debug port's are not checked); an MC
 * refusal for protection is a device fault with mc_fault_tag.
 * rst_n is the board reset; core_rst_n (CTRL.RESET's pulse) resets the
 * ring's pointers, the sequencer, the fence unit, the debug port,
 * IRQ_STATUS and the blocks outside.  atg_cp_disp is on rst_n (its slots
 * and records survive CTRL.RESET).  The sequencer's kicks come as one
 * pulse with a code, split here.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter [31:0] GCLK_HZ = 32'd100000000,
	parameter [31:0] VENDOR_ID = 32'h414D4154,	/* "AMAT" */
	parameter [31:0] DEVICE_ID = 32'h41544731,	/* "ATG1" */
	parameter [31:0] DEVICE_VERSION = 32'h00000003,	/* 0.3: CP with the ring */
	parameter [7:0] UNITS = 8'h03,	/* present blocks, STATUS busy-bit order (CP, BLT) */
	parameter HAS_CPU = 0,	/* atg_cpu takes class V packets */
	parameter HAS_VSYNC = 0,	/* vsync is connected (CAPS[10], WAIT_VSYNC) */
	parameter HAS_DISP = 0,	/* a DISP2 display controller (atg_dc in atg_top): CAPS[3], the DISP2 capability, atg_cp_disp */
	parameter DISP_PLANES = 2,	/* its planes: 2 with the cursor plane */
	parameter [7:0] DC_CLIENT = 8'hFF,	/* its MC client (refusals are not device faults) */
	parameter HAS_DBG = 0,	/* a debug bridge outside the host bus (JTAG; the DBG capability) */
	parameter PACKED = 0,	/* the SU has the packed arithmetic (CAPS[28]) */
	parameter SUBGROUP = 0,	/* the SU has shfl/vote/ballot (CAPS[24]) */
	parameter MS4 = 0,	/* 4x multisampling in the RX, ROP, TU, SU and BLT (CAPS[29]) */
	parameter CORE1 = 0,	/* Vulkan 1.0 core rendering (CAPS[30], CAPS[9]) */
	parameter HAS_FMT = 0,	/* the FMT capability (with CAPS[30]) */
	parameter HAS_ETC = 0,	/* the TU's ETC2/EAC decoder (FMT reports those formats) */
	parameter [15:0] RESIDENT_WARPS = 16'd0,	/* RESIDENT_WARPS: NSU x NWARPS (0: no shader unit) */
	parameter [7:0] NREGS = 8'd0,	/* RESIDENT_WARPS[23:16]: general registers per lane (0: no SU) */
	parameter [31:0] LOCAL_BASE = 32'd0,	/* the MEM capability (listed when LOCAL_BYTES is not 0) */
	parameter [31:0] LOCAL_BYTES = 32'd0,
	parameter [31:0] WINDOW_BYTES = 32'd0,
	parameter [31:0] HOST_LIMIT = 32'd0,
	parameter HAS_PROT = 0,	/* session protection: the PROT capability is listed (atg_cp_prot) */
	parameter SLIM_MMIO = 1	/* 1: GHCI 1.0 Slim 19 MMIO registers (0x00..0x48) */
) (
	input wire clk,
	input wire rst_n,

	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output wire [31:0] reg_rdata,

	/* Diagnostics (0x074, 0x078, 0x07C) */
	input wire [31:0] diag_cp_pc,
	input wire [31:0] diag_cp_status,
	input wire [31:0] diag_pipe_fsm,

	output wire irq,
	input wire mem_ready,

	output wire core_rst_n,
	output wire win_en,	/* MEM WINDOW_CTRL.ENABLE: the local window is open (rst_n only) */

	output wire mc_quiesce,
	output wire mc_flush,
	output wire [ADDR_W-1:0] aperture_base,
	output wire [ADDR_W-1:0] aperture_limit,
	input wire mc_idle,
	input wire mc_fault,
	input wire [7:0] mc_fault_client,
	input wire [ADDR_W-1:0] mc_fault_addr,
	input wire mc_fault_write,
	input wire mc_fault_prot,	/* the refusal was for session protection (FAULT_INFO[9]) */
	input wire mc_fault_mem,	/* a protection table read failed (kind 5) */
	input wire [7:0] mc_fault_tag,	/* the job tag of the refused request's slot */

	output reg st_we,
	output reg [9:0] st_idx,
	output reg [31:0] st_wdata,

	output wire blt_kick,
	input wire blt_busy,
	input wire blt_error,
	input wire [3:0] blt_error_kind,

	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	output wire req_chk,
	output wire [5:0] req_slot,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error,

	/* The other blocks of design §7.6 and the CPU (atg_cpu). */
	output wire draw_kick,
	output wire cs_kick,
	output wire lc_kick,
	output wire raw_kick,
	output wire [3:0] inv,
	input wire [7:0] busy_ext,	/* STATUS[7:2] bits of VF, RX, ROP, TU, SU, SA; [0] the units'
					 * memory requests not yet answered (atg_mc's !unit_idle) */
	input wire vsync,
	input wire [1:0] x_fault,	/* fault sources: 0 the SUs (ISA), 1 the other blocks */
	input wire [7:0] x_fault_kind,
	input wire [63:0] x_fault_addr,
	input wire [15:0] x_fault_tag,

	output wire hcr_we,	/* the HCR snoop bus for atg_cpu */
	output wire [9:0] hcr_widx,
	output wire [31:0] hcr_wdata,
	output wire [31:0] hcr_wmask,
	output wire [9:0] hcr_ridx,
	input wire [31:0] x_rdata,
	output wire v_valid,	/* class V packets to atg_cpu */
	output wire [31:0] v_addr,
	output wire [15:0] v_dwords,
	output wire [7:0] v_tag,
	input wire v_done,
	input wire fw_valid,	/* µops from atg_cpu */
	output wire fw_ready,
	input wire [31:0] fw_data,
	input wire fw_last,
	input wire fw_active,
	input wire [6:0] fw_side,
	output wire u_fw,	/* the sequencer's µop (session protection) */
	output wire [6:0] u_side,
	output wire [1:0] u_req,
	output wire [7:0] u_tag,
	input wire u_ok,
	input wire kick_prot_ok,	/* KICK: the units are session 0's */
	input wire [7:0] wdt_tag,	/* the job tag of a watchdog fault (the drained session's) */
	input wire f_chk,
	input wire [5:0] f_slot,
	input wire [9:0] cpu_st_ridx,
	output wire [31:0] cpu_st_rdata,
	output wire [31:0] cp_fence_last,
	output wire cp_fence_ev,
	output wire cp_halt,
	output wire cp_open,
	input wire cpu_fault,
	input wire [31:0] cpu_fault_addr,
	input wire cpu_stall,
	input wire cpu_result,
	input wire [39:0] occ_count,	/* the occlusion counter (atg_rop, QUERY) */
	output wire occ_clear,

	/* The DISP2 display controller (atg_dc; HAS_DISP), through atg_cp_disp. */
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
	input wire [2:0] dc_ev,	/* one-cycle pulses: [0] VBLANK, [1] DISP_ERROR, [2] HOTPLUG */
	input wire dc_irq_display
);
	`include "ghci_regs.vh"

	localparam SLA_W = ADDR_W - LINE_SHIFT;
	localparam SLB = LINE_BYTES * 8;
	/* verilator lint_off WIDTHTRUNC */
	localparam [3:0] LS4 = LINE_SHIFT;
	/* verilator lint_on WIDTHTRUNC */
	/* CAPS[27]: graphics (VF, RX and ROP); CAPS[28]: packed; CAPS[26]: the TU's mip linear,
	 * border, depth formats and compare; CAPS[24]: subgroup; CAPS[29]: 4x multisampling
	 * (with graphics, the TU and an SU); CAPS[30] and CAPS[9]: Vulkan 1.0 core rendering
	 * with its stencil (with graphics, the TU and an SU). */
	localparam [0:0] CORE = CORE1 != 0 && UNITS[2] && UNITS[3] && UNITS[4] && UNITS[5] && UNITS[6];
	localparam [31:0] CAPS = {1'b0, CORE,
		MS4 != 0 && UNITS[2] && UNITS[3] && UNITS[4] && UNITS[5] && UNITS[6],
		UNITS[6] && PACKED != 0, UNITS[2] && UNITS[3] && UNITS[4],
		UNITS[5], 1'b0,
		UNITS[6] && SUBGROUP != 0,
		LS4, 1'b0, HAS_CPU != 0, HAS_CPU != 0, 1'b0, 4'd1, 1'b1,
		HAS_VSYNC != 0, CORE, UNITS[5], UNITS[6] ? 4'd5 : 4'd0, HAS_DISP != 0, UNITS[6], UNITS[1], 1'b1};
	/* CAPS[8]: the TU filters bilinear; CAPS2[27:24]: its 16 texture slots / 4; CAPS2[7:0]: 3 queues. */
	localparam [31:0] CAPS2 = {4'd0, UNITS[5] ? 4'd4 : 4'd0, 16'd0, 8'd3};
	localparam [31:0] ISA = UNITS[6] ? 32'h47534931 : 32'd0;	/* "GSI1" */
	/* PERF always; CPFW with the CPU; DISP2, DBG, MEM, PROT and FMT when present (bit id - 1). */
	localparam [10:0] XCAP = 11'h004 | (HAS_CPU != 0 ? 11'h020 : 11'h000) |
		(HAS_DISP != 0 ? 11'h400 : 11'h000) | (HAS_DBG != 0 ? 11'h002 : 11'h000) |
		(LOCAL_BYTES != 32'd0 ? 11'h080 : 11'h000) | (HAS_FMT != 0 ? 11'h200 : 11'h000) |
		(HAS_PROT != 0 ? 11'h100 : 11'h000);

	/*
	 * The STATE broadcast to the blocks, one register stage after
	 * atg_cp_state (the path ring → sequencer → index decode → the
	 * blocks' shadow enables did not meet 100 MHz with the CPU in a
	 * Zynq-7010).  A kick comes at least two cycles after the last STATE write
	 * of its µops (the header after the payload, the kick a cycle after
	 * the header), so the blocks still see their state before the kick.
	 */
	wire s_st_we;
	wire [9:0] s_st_idx;
	wire [31:0] s_st_wdata;

	always @(posedge clk) begin
		if (!rst_n)
			st_we <= 1'b0;
		else
			st_we <= s_st_we;
		st_idx <= s_st_idx;
		st_wdata <= s_st_wdata;
	end

	/* The HCR snoop bus. */
	wire s_hcr_we;
	wire [9:0] s_hcr_widx, s_hcr_ridx;
	wire [31:0] s_hcr_wdata, s_hcr_wmask;
	wire s_alias_we;
	wire [9:0] s_alias_idx, s_alias_ridx;
	wire [31:0] s_ctl_rdata, s_irq_rdata, s_ring_rdata, s_fence_rdata, s_dbg_rdata;
	wire [31:0] s_state_rdata;
	wire s_perf_reset;

`ifdef SYNTH_KINTEX7
	wire hcr_we_ctl, hcr_we_ring, hcr_we_fence, hcr_we_dbg, hcr_we_disp, hcr_we_irq;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_we_ctl   (.I0(s_hcr_we), .O(hcr_we_ctl));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_we_ring  (.I0(s_hcr_we), .O(hcr_we_ring));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_we_fence (.I0(s_hcr_we), .O(hcr_we_fence));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_we_dbg   (.I0(s_hcr_we), .O(hcr_we_dbg));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_we_disp  (.I0(s_hcr_we), .O(hcr_we_disp));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_we_irq   (.I0(s_hcr_we), .O(hcr_we_irq));

	wire [9:0] hcr_ridx_ctl, hcr_ridx_ring, hcr_ridx_fence, hcr_ridx_dbg, hcr_ridx_disp, hcr_ridx_irq;
	genvar g_idx;
	generate
		for (g_idx = 0; g_idx < 10; g_idx = g_idx + 1) begin : g_idx_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rc (.I0(s_hcr_ridx[g_idx]), .O(hcr_ridx_ctl[g_idx]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rr (.I0(s_hcr_ridx[g_idx]), .O(hcr_ridx_ring[g_idx]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rf (.I0(s_hcr_ridx[g_idx]), .O(hcr_ridx_fence[g_idx]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rd (.I0(s_hcr_ridx[g_idx]), .O(hcr_ridx_dbg[g_idx]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rp (.I0(s_hcr_ridx[g_idx]), .O(hcr_ridx_disp[g_idx]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_ri (.I0(s_hcr_ridx[g_idx]), .O(hcr_ridx_irq[g_idx]));
		end
	endgenerate

	wire [31:0] hcr_wmask_ctl, hcr_wmask_fence, hcr_wmask_dbg;
	genvar g_wm;
	generate
		for (g_wm = 0; g_wm < 32; g_wm = g_wm + 1) begin : g_wm_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mc (.I0(s_hcr_wmask[g_wm]), .O(hcr_wmask_ctl[g_wm]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_mf (.I0(s_hcr_wmask[g_wm]), .O(hcr_wmask_fence[g_wm]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_md (.I0(s_hcr_wmask[g_wm]), .O(hcr_wmask_dbg[g_wm]));
		end
	endgenerate
`else
	wire hcr_we_ctl = s_hcr_we;
	wire hcr_we_ring = s_hcr_we;
	wire hcr_we_fence = s_hcr_we;
	wire hcr_we_dbg = s_hcr_we;
	wire hcr_we_disp = s_hcr_we;
	wire hcr_we_irq = s_hcr_we;
	wire [9:0] hcr_ridx_ctl = s_hcr_ridx;
	wire [9:0] hcr_ridx_ring = s_hcr_ridx;
	wire [9:0] hcr_ridx_fence = s_hcr_ridx;
	wire [9:0] hcr_ridx_dbg = s_hcr_ridx;
	wire [9:0] hcr_ridx_disp = s_hcr_ridx;
	wire [9:0] hcr_ridx_irq = s_hcr_ridx;
	wire [31:0] hcr_wmask_ctl = s_hcr_wmask;
	wire [31:0] hcr_wmask_fence = s_hcr_wmask;
	wire [31:0] hcr_wmask_dbg = s_hcr_wmask;
`endif

`ifdef SYNTH_KINTEX7
	reg [31:0] reg_rdata_r;
	wire [31:0] reg_rdata_raw;
	always @(posedge clk) begin
		reg_rdata_r <= reg_rdata_raw;
	end
	assign reg_rdata = reg_rdata_r;

	reg hcr_we_r;
	reg [9:0] hcr_widx_r;
	reg [31:0] hcr_wdata_r;
	reg [31:0] hcr_wmask_r;
	reg [9:0] hcr_ridx_r;
	always @(posedge clk) begin
		hcr_we_r <= s_hcr_we;
		hcr_widx_r <= s_hcr_widx;
		hcr_wdata_r <= s_hcr_wdata;
		hcr_wmask_r <= s_hcr_wmask;
		hcr_ridx_r <= s_hcr_ridx;
	end
	assign hcr_we = hcr_we_r;
	assign hcr_widx = hcr_widx_r;
	assign hcr_wdata = hcr_wdata_r;
	assign hcr_wmask = hcr_wmask_r;
	assign hcr_ridx = hcr_ridx_r;
`else
	wire [31:0] reg_rdata_raw;
	assign reg_rdata = reg_rdata_raw;

	assign hcr_we = s_hcr_we;
	assign hcr_widx = s_hcr_widx;
	assign hcr_wdata = s_hcr_wdata;
	assign hcr_wmask = s_hcr_wmask;
	assign hcr_ridx = s_hcr_ridx;
`endif

	wire [31:0] s_fmt_rdata, s_disp_rdata;
	atg_cp_regs #(
		.GCLK_HZ(GCLK_HZ), .VENDOR_ID(VENDOR_ID), .DEVICE_ID(DEVICE_ID),
		.DEVICE_VERSION(DEVICE_VERSION), .ISA_ID(ISA), .NATIVE_ISA_ID(ISA), .CAPS(CAPS),
		.CAPS2(CAPS2), .XCAP_MASK(XCAP), .PERF_SRC(32'hFFFF0801), .RESIDENT_WARPS(RESIDENT_WARPS),
		.NREGS(NREGS), .LOCAL_BASE(LOCAL_BASE), .LOCAL_BYTES(LOCAL_BYTES),
		.WINDOW_BYTES(WINDOW_BYTES),
		.HOST_LIMIT(HOST_LIMIT),
		.SLIM_MMIO(SLIM_MMIO)
	) u_regs (
		.clk(clk), .rst_n(rst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata_raw),
		.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx),
		.alias_we(s_alias_we), .alias_idx(s_alias_idx), .alias_ridx(s_alias_ridx),
		.ctl_rdata(s_ctl_rdata), .irq_rdata(s_irq_rdata), .ring_rdata(s_ring_rdata),
		.fence_rdata(s_fence_rdata), .dbg_rdata(s_dbg_rdata), .state_rdata(s_state_rdata),
		.x_rdata(x_rdata | s_fmt_rdata | s_disp_rdata), .perf_busy({2'd0, !mc_idle, blt_busy}),
		.perf_reset(s_perf_reset), .win_en(win_en),
		.diag_cp_pc(diag_cp_pc), .diag_cp_status(diag_cp_status), .diag_pipe_fsm(diag_pipe_fsm)
	);

	/* The FMT capability (id 10) at 0x160. */
	generate
	if (HAS_FMT != 0) begin : g_fmt
		atg_cp_fmt #(.BASE(10'h058), .HAS_ETC(HAS_ETC), .NRT(4'd4)) u_fmt (
			.clk(clk), .rst_n(rst_n),
			.hcr_we(s_hcr_we), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
			.hcr_wmask(s_hcr_wmask), .hcr_ridx(s_hcr_ridx), .hcr_rdata(s_fmt_rdata)
		);
	end else begin : g_no_fmt
		assign s_fmt_rdata = 32'd0;
	end
	endgenerate

	/* Control: state machine, RESET order, watchdog, faults. */
	wire s_run, s_halt, s_step, s_open, s_quiesce, s_mc_flush;
	(* keep = "true" *) wire s_core_rst_n;
	wire [3:0] s_cp_state;
	wire [2:0] s_host_kick;
	wire s_ev_halted, s_ev_fault, s_ev_wdt;
	wire s_replay_busy;
	wire s_ring_empty, s_retire, s_ring_busy, s_seq_busy, s_cmd_active;
	wire s_lock_fault;
	wire s_dbg_done, s_dbg_busy;
	wire s_ring_fault, s_seq_fault, s_fence_fault, s_disp_fault;
	wire [3:0] s_ring_fault_kind, s_seq_fault_kind, s_fence_fault_kind, s_disp_fault_kind;
	wire [31:0] s_ring_fault_addr, s_seq_fault_addr, s_fence_fault_addr, s_disp_fault_addr;
	wire [7:0] s_ring_fault_tag, s_seq_fault_tag, s_fence_fault_tag, s_disp_fault_tag;

`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire s_core_rst_inv;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_top_rst_inv (.I0(s_core_rst_n), .O(s_core_rst_inv));

	reg r_ring_busy;
	reg r_cp_busy0;
	always @(posedge clk) begin
		if (s_core_rst_inv) begin
			r_ring_busy <= 1'b0;
			r_cp_busy0 <= 1'b0;
		end else begin
			r_ring_busy <= s_ring_busy;
			r_cp_busy0 <= s_seq_busy || s_ring_busy || s_dbg_busy;
		end
	end
	wire ring_busy_ctl = r_ring_busy;
	wire cp_busy0_ctl = r_cp_busy0;
`else
	wire ring_busy_ctl = s_ring_busy;
	wire cp_busy0_ctl = s_seq_busy || s_ring_busy || s_dbg_busy;
`endif

	/* Fault sources: 0 ring, 1 seq, 2 state, 3 fence, 4 SU, 5 CPU, 6 BLT, 7 other blocks, 8 DISP. */
	atg_cp_ctl #(
		.LINE_SHIFT(LINE_SHIFT), .UNITS(UNITS), .NSRC(9),
		.SRC_BLOCK(72'h00_00_01_00_06_00_00_00_00), .SRC_CLIENT(72'h00_00_01_00_00_00_00_00_00),
		.DC_CLIENT(HAS_DISP != 0 ? DC_CLIENT : 8'hFF)
	) u_ctl (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we_ctl), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(hcr_wmask_ctl), .hcr_ridx(hcr_ridx_ctl), .hcr_rdata(s_ctl_rdata),
		.mc_idle(mc_idle), .mem_ready(mem_ready),
		.busy_in({busy_ext[7:2], blt_busy, cp_busy0_ctl}),
		.ring_empty(s_ring_empty), .ring_busy(ring_busy_ctl), .cmd_active(s_cmd_active || v_valid),
		.wdt_hold(!s_cmd_active && cpu_stall),
		.replay_busy(s_replay_busy),
		.mc_fault(mc_fault), .mc_fault_client(mc_fault_client), .mc_fault_addr(mc_fault_addr),
		.mc_fault_write(mc_fault_write), .mc_fault_prot(mc_fault_prot),
		.mc_fault_mem(mc_fault_mem), .mc_fault_tag(mc_fault_tag),
		.kick_prot_ok(kick_prot_ok), .wdt_tag(wdt_tag),
		.src_fault({s_disp_fault, x_fault[1], blt_error, cpu_fault, x_fault[0], s_fence_fault,
			s_lock_fault, s_seq_fault, s_ring_fault}),
		.src_kind({s_disp_fault_kind, x_fault_kind[7:4], blt_error_kind, GHCI_FAULT_WATCHDOG,
			x_fault_kind[3:0], s_fence_fault_kind, GHCI_FAULT_LOCKED, s_seq_fault_kind,
			s_ring_fault_kind}),
		.src_addr({s_disp_fault_addr, x_fault_addr[63:32], 32'd0, cpu_fault_addr,
			x_fault_addr[31:0], s_fence_fault_addr, 32'd0, s_seq_fault_addr, s_ring_fault_addr}),
		.src_tag({s_disp_fault_tag, x_fault_tag[15:8], 8'd0, 8'd0, x_fault_tag[7:0],
			s_fence_fault_tag, 8'd0, s_seq_fault_tag, s_ring_fault_tag}),
		.run(s_run), .halt(s_halt), .quiesce(s_quiesce), .mc_flush(s_mc_flush),
		.core_rst_n(s_core_rst_n), .open(s_open), .cp_state(s_cp_state),
		.host_kick(s_host_kick), .step(s_step),
		.ev_halted(s_ev_halted), .ev_fault(s_ev_fault), .ev_wdt(s_ev_wdt),
		.aperture_base(aperture_base), .aperture_limit(aperture_limit)
	);

	assign core_rst_n = s_core_rst_n;
	assign mc_flush = s_mc_flush;
	assign cp_halt = s_halt;
	assign cp_open = s_open;

	/* The state register file. */
	wire s_uop_we;
	wire [9:0] s_uop_idx;
	wire [31:0] s_uop_wdata;

	atg_cp_state u_state (
		.clk(clk), .rst_n(rst_n),
		.alias_we(s_alias_we), .alias_idx(s_alias_idx), .alias_wdata(s_hcr_wdata),
		.alias_ridx(s_alias_ridx), .alias_rdata(s_state_rdata),
		.uop_we(s_uop_we && s_uop_idx[9:8] != 2'b11), .uop_idx(s_uop_idx),
		.uop_wdata(s_uop_wdata), .open(s_open), .blt_busy(blt_busy), .lock_fault(s_lock_fault),
		.st_we(s_st_we), .st_idx(s_st_idx), .st_wdata(s_st_wdata),
		.cpu_ridx(cpu_st_ridx), .cpu_rdata(cpu_st_rdata),
		.replay(s_mc_flush), .replay_busy(s_replay_busy)
	);

	/* The CP's memory users behind MC client 0: ring, fence, dbg, the records (DISP2). */
	wire [3:0] s_i_req_valid, s_i_req_ready, s_i_req_write, s_i_rsp_valid;
	wire [4*SLA_W-1:0] s_i_req_line;
	wire [4*LINE_BYTES-1:0] s_i_req_be;
	wire [4*SLB-1:0] s_i_req_wdata;
	wire [31:0] s_i_req_tag;
	wire s_i_rsp_write, s_i_rsp_error;
	wire [7:0] s_i_rsp_tag;
	wire [SLB-1:0] s_i_rsp_rdata;

	am_amb_mux #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .N(4), .ID_W(2)
	) u_amb (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid(s_i_req_valid), .i_req_ready(s_i_req_ready),
		.i_req_write(s_i_req_write), .i_req_line(s_i_req_line), .i_req_be(s_i_req_be),
		.i_req_wdata(s_i_req_wdata), .i_req_tag(s_i_req_tag),
		.i_rsp_valid(s_i_rsp_valid), .i_rsp_write(s_i_rsp_write), .i_rsp_tag(s_i_rsp_tag),
		.i_rsp_rdata(s_i_rsp_rdata), .i_rsp_error(s_i_rsp_error),
		.o_req_valid(req_valid), .o_req_ready(req_ready), .o_req_write(req_write),
		.o_req_line(req_line), .o_req_be(req_be), .o_req_wdata(req_wdata),
		.o_req_tag(req_tag),
		.o_rsp_valid(rsp_valid), .o_rsp_write(rsp_write), .o_rsp_tag(rsp_tag),
		.o_rsp_rdata(rsp_rdata), .o_rsp_error(rsp_error)
	);

	/* Only the fence unit's (requester 1) requests carry the protection side band. */
	wire s_f_req_chk;
	wire [5:0] s_f_req_slot;
	wire s_pick_f = req_tag[7:6] == 2'd1;
	assign req_chk = s_pick_f && s_f_req_chk;
	assign req_slot = s_pick_f ? s_f_req_slot : 6'd0;

	/* The MC holds the blocks' new requests; its client 0 (this) is exempt. */
	assign mc_quiesce = s_quiesce;

	/* The ring. */
	wire s_n_valid, s_n_ready, s_n_last;
	wire [31:0] s_n_data;
	wire [1:0] s_queue_id;
	wire s_preempt_ev;
	wire s_dma_req_valid, s_dma_empty, s_dma_busy;
	wire [31:0] s_dma_src_base, s_dma_dst_base, s_dma_src_row_stride, s_dma_dst_row_stride;
	wire [31:0] s_dma_src_slice_stride, s_dma_dst_slice_stride;
	wire [15:0] s_dma_copy_w, s_dma_copy_h, s_dma_copy_d;

	wire s_n_valid_raw, s_n_ready_raw;
	wire [31:0] s_n_data_raw;

	atg_cp_ring #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
		.CLASS_V(HAS_CPU != 0)
	) u_ring (
		.clk(clk), .rst_n(rst_n), .core_rst_n(s_core_rst_n),
		.hcr_we(hcr_we_ring), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(hcr_ridx_ring), .hcr_rdata(s_ring_rdata),
		.run(s_run), .halt(s_halt), .step(s_step), .open(s_open),
		.n_valid(s_n_valid_raw), .n_ready(s_n_ready_raw), .n_data(s_n_data_raw), .n_last(s_n_last),
		.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag),
		.v_done(v_done),
		.dma_req_valid(s_dma_req_valid), .dma_req_ready(1'b1),
		.dma_src_base(s_dma_src_base), .dma_dst_base(s_dma_dst_base),
		.dma_src_row_stride(s_dma_src_row_stride), .dma_dst_row_stride(s_dma_dst_row_stride),
		.dma_src_slice_stride(s_dma_src_slice_stride), .dma_dst_slice_stride(s_dma_dst_slice_stride),
		.dma_copy_w(s_dma_copy_w), .dma_copy_h(s_dma_copy_h), .dma_copy_d(s_dma_copy_d),
		.dma_done(1'b0), .dma_empty(s_dma_empty), .dma_busy(s_dma_busy),
		.empty(s_ring_empty), .retire(s_retire), .busy(s_ring_busy),
		.queue_id(s_queue_id), .preempt_ev(s_preempt_ev),
		.fault(s_ring_fault), .fault_kind(s_ring_fault_kind), .fault_addr(s_ring_fault_addr),
		.fault_tag(s_ring_fault_tag),
		.req_valid(s_i_req_valid[0]), .req_ready(s_i_req_ready[0]),
		.req_write(s_i_req_write[0]), .req_line(s_i_req_line[0*SLA_W +: SLA_W]),
		.req_be(s_i_req_be[0*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(s_i_req_wdata[0*SLB +: SLB]), .req_tag(s_i_req_tag[0*8 +: 8]),
		.rsp_valid(s_i_rsp_valid[0]), .rsp_write(s_i_rsp_write), .rsp_tag(s_i_rsp_tag),
		.rsp_rdata(s_i_rsp_rdata), .rsp_error(s_i_rsp_error)
	);

	am_skid #(.W(32)) u_skid_ring_seq (
		.clk(clk),
		.rst_n(s_core_rst_n),
		.in_valid(s_n_valid_raw),
		.in_ready(s_n_ready_raw),
		.in_data(s_n_data_raw),
		.out_valid(s_n_valid),
		.out_ready(s_n_ready),
		.out_data(s_n_data)
	);

	/* The sequencer; it stops only in FAULTED and RESETTING. */
	wire s_kick, s_disp_wait, s_ev_flip;
	wire [2:0] s_kick_code;
	wire [3:0] s_seq_inv;
	wire s_seq_occ_clear;
	wire s_f_valid, s_f_ready, s_f_irq, s_f_busy;
	wire [1:0] s_f_op;
	wire [63:0] s_f_addr;
	wire [31:0] s_f_value, s_f_aux;
	wire s_seq_halt = s_cp_state == GHCI_ST_FAULTED || s_cp_state == GHCI_ST_RESETTING;

	wire s_fw_valid, s_fw_ready;
	wire [31:0] s_fw_data;

	am_skid #(.W(32)) u_skid_fw (
		.clk(clk),
		.rst_n(s_core_rst_n),
		.in_valid(fw_valid),
		.in_ready(fw_ready),
		.in_data(fw_data),
		.out_valid(s_fw_valid),
		.out_ready(s_fw_ready),
		.out_data(s_fw_data)
	);

	atg_cp_seq #(.UNITS(UNITS), .HAS_VSYNC(HAS_VSYNC), .HAS_DISP(HAS_DISP)) u_seq (
		.clk(clk), .rst_n(s_core_rst_n),
		.n_valid(s_n_valid), .n_ready(s_n_ready), .n_data(s_n_data),
		.fw_valid(s_fw_valid), .fw_ready(s_fw_ready), .fw_data(s_fw_data),
		.fw_active(fw_active), .fw_side(fw_side), .halt(s_seq_halt),
		.uop_we(s_uop_we), .uop_idx(s_uop_idx), .uop_wdata(s_uop_wdata),
		.kick(s_kick), .kick_code(s_kick_code), .inv(s_seq_inv),
		.busy_in({s_disp_wait, busy_ext[7:2], blt_busy, busy_ext[0]}), .vsync(vsync),
		.f_valid(s_f_valid), .f_ready(s_f_ready), .f_op(s_f_op), .f_addr(s_f_addr),
		.f_value(s_f_value), .f_aux(s_f_aux), .f_irq(s_f_irq), .f_busy(s_f_busy),
		.occ_count(occ_count), .occ_clear(s_seq_occ_clear),
		.busy(s_seq_busy), .cmd_active(s_cmd_active),
		.fault(s_seq_fault), .fault_kind(s_seq_fault_kind), .fault_addr(s_seq_fault_addr),
		.fault_tag(s_seq_fault_tag),
		.u_fw(u_fw), .u_side(u_side), .u_req(u_req), .u_ok(u_ok)
	);
	assign u_tag = s_seq_fault_tag;

	/* The kick codes (atg_cp_seq's K_*). */
`ifdef SYNTH_KINTEX7
	reg blt_kick_r, draw_kick_r, cs_kick_r, lc_kick_r, raw_kick_r, occ_clear_r;
	reg [3:0] inv_r;
	always @(posedge clk) begin
		blt_kick_r <= s_host_kick[0] || s_kick && s_kick_code == 3'd0;
		draw_kick_r <= s_host_kick[1] || s_kick && s_kick_code == 3'd1;
		cs_kick_r <= s_host_kick[2] || s_kick && s_kick_code == 3'd2;
		lc_kick_r <= s_kick && s_kick_code == 3'd3;
		raw_kick_r <= s_kick && s_kick_code == 3'd4;
		inv_r <= s_seq_inv;
		occ_clear_r <= s_seq_occ_clear;
	end
	assign blt_kick = blt_kick_r;
	assign draw_kick = draw_kick_r;
	assign cs_kick = cs_kick_r;
	assign lc_kick = lc_kick_r;
	assign raw_kick = raw_kick_r;
	assign inv = inv_r;
	assign occ_clear = occ_clear_r;
`else
	assign blt_kick = s_host_kick[0] || s_kick && s_kick_code == 3'd0;
	assign draw_kick = s_host_kick[1] || s_kick && s_kick_code == 3'd1;
	assign cs_kick = s_host_kick[2] || s_kick && s_kick_code == 3'd2;
	assign lc_kick = s_kick && s_kick_code == 3'd3;
	assign raw_kick = s_kick && s_kick_code == 3'd4;
	assign inv = s_seq_inv;
	assign occ_clear = s_seq_occ_clear;
`endif
	assign s_perf_reset = s_kick && s_kick_code == 3'd5;
	wire s_kick_flip = s_kick && s_kick_code == 3'd6;
	wire s_kick_idle = s_kick && s_kick_code == 3'd7;

	/* Fences. */
	wire s_ev_fence;
`ifdef SYNTH_KINTEX7
	reg cp_fence_ev_r;
	always @(posedge clk) begin
		cp_fence_ev_r <= s_ev_fence;
	end
	assign cp_fence_ev = cp_fence_ev_r;
`else
	assign cp_fence_ev = s_ev_fence;
`endif

	atg_cp_fence #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_fence (
		.clk(clk), .rst_n(s_core_rst_n),
		.hcr_we(hcr_we_fence), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(hcr_wmask_fence), .hcr_ridx(hcr_ridx_fence), .hcr_rdata(s_fence_rdata),
		.f_valid(s_f_valid), .f_ready(s_f_ready), .f_op(s_f_op), .f_addr(s_f_addr[ADDR_W-1:0]),
		.f_value(s_f_value), .f_aux(s_f_aux), .f_irq(s_f_irq), .f_chk(f_chk),
		.f_slot(f_slot), .f_busy(s_f_busy),
		.ev_fence(s_ev_fence), .fence_last(cp_fence_last),
		.fault(s_fence_fault), .fault_kind(s_fence_fault_kind),
		.fault_addr(s_fence_fault_addr), .fault_tag(s_fence_fault_tag),
		.req_valid(s_i_req_valid[1]), .req_ready(s_i_req_ready[1]),
		.req_write(s_i_req_write[1]), .req_line(s_i_req_line[1*SLA_W +: SLA_W]),
		.req_be(s_i_req_be[1*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(s_i_req_wdata[1*SLB +: SLB]), .req_tag(s_i_req_tag[1*8 +: 8]),
		.req_chk(s_f_req_chk), .req_slot(s_f_req_slot),
		.rsp_valid(s_i_rsp_valid[1]), .rsp_write(s_i_rsp_write), .rsp_tag(s_i_rsp_tag),
		.rsp_rdata(s_i_rsp_rdata), .rsp_error(s_i_rsp_error)
	);

	/* Interrupts and the debug port. */

	atg_cp_irq u_irq (
		.clk(clk), .rst_n(rst_n), .core_rst_n(s_core_rst_n),
		.hcr_we(hcr_we_irq), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(s_hcr_wmask), .hcr_ridx(hcr_ridx_irq), .hcr_rdata(s_irq_rdata),
		.ev({4'd0, s_retire, cpu_result, s_ev_halted, 1'b0,
			s_dbg_done, dc_irq_display, s_ev_wdt, s_ev_fault, cp_fence_ev}),
		.irq(irq)
	);

	atg_cp_dbg #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_dbg (
		.clk(clk), .rst_n(s_core_rst_n),
		.hcr_we(hcr_we_dbg), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
		.hcr_wmask(hcr_wmask_dbg), .hcr_ridx(hcr_ridx_dbg), .hcr_rdata(s_dbg_rdata),
		.ev_done(s_dbg_done), .dbg_busy(s_dbg_busy),
		.req_valid(s_i_req_valid[2]), .req_ready(s_i_req_ready[2]),
		.req_write(s_i_req_write[2]), .req_line(s_i_req_line[2*SLA_W +: SLA_W]),
		.req_be(s_i_req_be[2*LINE_BYTES +: LINE_BYTES]),
		.req_wdata(s_i_req_wdata[2*SLB +: SLB]), .req_tag(s_i_req_tag[2*8 +: 8]),
		.rsp_valid(s_i_rsp_valid[2]), .rsp_write(s_i_rsp_write), .rsp_tag(s_i_rsp_tag),
		.rsp_rdata(s_i_rsp_rdata), .rsp_error(s_i_rsp_error)
	);

	/* The DISP2 display controller's side (board reset). */
	generate
	if (HAS_DISP != 0) begin : g_disp
		atg_cp_disp #(
			.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.NPLANES(DISP_PLANES), .LOCAL_BASE(LOCAL_BASE), .LOCAL_BYTES(LOCAL_BYTES),
			.BASE_IDX(GHCI_DISP2_BASE[11:2])
		) u_disp (
			.clk(clk), .rst_n(rst_n),
			.hcr_we(hcr_we_disp), .hcr_widx(s_hcr_widx), .hcr_wdata(s_hcr_wdata),
			.hcr_wmask(s_hcr_wmask), .hcr_ridx(hcr_ridx_disp), .hcr_rdata(s_disp_rdata),
			.cp_state(s_cp_state),
			.uop_we(s_uop_we), .uop_idx(s_uop_idx), .uop_wdata(s_uop_wdata),
			.kick_flip(s_kick_flip), .kick_idle(s_kick_idle), .seq_tag(s_seq_fault_tag),
			.disp_wait(s_disp_wait), .aperture_base(aperture_base),
			.aperture_limit(aperture_limit),
			.fault(s_disp_fault), .fault_kind(s_disp_fault_kind),
			.fault_addr(s_disp_fault_addr), .fault_tag(s_disp_fault_tag),
			.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
			.d_rdata(d_rdata), .flip_valid(flip_valid), .flip_plane(flip_plane),
			.flip_base(flip_base), .taken(taken), .taken_cancel(taken_cancel),
			.dc_pending(dc_pending), .dc_idle(dc_idle), .frame_count(frame_count),
			.dc_err(dc_err),
			.req_valid(s_i_req_valid[3]), .req_ready(s_i_req_ready[3]),
			.req_write(s_i_req_write[3]), .req_line(s_i_req_line[3*SLA_W +: SLA_W]),
			.req_be(s_i_req_be[3*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(s_i_req_wdata[3*SLB +: SLB]), .req_tag(s_i_req_tag[3*8 +: 8]),
			.rsp_valid(s_i_rsp_valid[3]), .rsp_write(s_i_rsp_write), .rsp_tag(s_i_rsp_tag),
			.rsp_rdata(s_i_rsp_rdata), .rsp_error(s_i_rsp_error),
			.ev_flip(s_ev_flip)
		);
	end else begin : g_no_disp
		assign s_disp_rdata = 32'd0;
		assign s_disp_wait = 1'b0;
		assign s_disp_fault = 1'b0;
		assign s_disp_fault_kind = 4'd0;
		assign s_disp_fault_addr = 32'd0;
		assign s_disp_fault_tag = 8'd0;
		assign s_ev_flip = 1'b0;
		assign d_we = 1'b0;
		assign d_idx = 6'd0;
		assign d_wdata = 32'd0;
		assign d_wmask = 32'd0;
		assign d_ridx = 6'd0;
		assign flip_valid = 1'b0;
		assign flip_plane = 1'b0;
		assign flip_base = 32'd0;
		assign dc_err = 2'b00;
		assign s_i_req_valid[3] = 1'b0;
		assign s_i_req_write[3] = 1'b0;
		assign s_i_req_line[3*SLA_W +: SLA_W] = {SLA_W{1'b0}};
		assign s_i_req_be[3*LINE_BYTES +: LINE_BYTES] = {LINE_BYTES{1'b0}};
		assign s_i_req_wdata[3*SLB +: SLB] = {SLB{1'b0}};
		assign s_i_req_tag[3*8 +: 8] = 8'd0;
		wire unused_no_disp = &{1'b0, s_i_req_ready[3], s_i_rsp_valid[3], d_rdata, taken,
			taken_cancel, dc_pending, dc_idle, frame_count, dc_ev, s_kick_flip, s_kick_idle};
	end
	endgenerate

	/* Indirect draw fetcher (Phase 008, ws002-p008) */
	wire ind_cmd_valid = 1'b0;
	wire ind_cmd_ready;
	wire [31:0] ind_arg_buffer_addr = 32'd0;
	wire [31:0] ind_draw_count = 32'd0;
	wire [31:0] ind_stride = 32'd0;
	wire ind_is_indexed = 1'b0;
	wire ind_dma_req_valid;
	wire ind_dma_req_ready = 1'b0;
	wire [25:0] ind_dma_req_line;
	wire ind_dma_rsp_valid = 1'b0;
	wire [255:0] ind_dma_rsp_data = 256'd0;
	wire ind_draw_valid;
	wire ind_draw_ready = 1'b1;
	wire [31:0] ind_vertex_count;
	wire [31:0] ind_instance_count;
	wire [31:0] ind_first_vertex;
	wire [31:0] ind_first_instance;
	wire [31:0] ind_first_index;
	wire [31:0] ind_vertex_offset;

	atg_cp_indirect u_indirect (
		.clk(clk),
		.rst_n(s_core_rst_n),
		.cmd_valid(ind_cmd_valid),
		.cmd_ready(ind_cmd_ready),
		.arg_buffer_addr(ind_arg_buffer_addr),
		.draw_count(ind_draw_count),
		.stride(ind_stride),
		.is_indexed(ind_is_indexed),
		.dma_req_valid(ind_dma_req_valid),
		.dma_req_ready(ind_dma_req_ready),
		.dma_req_line(ind_dma_req_line),
		.dma_rsp_valid(ind_dma_rsp_valid),
		.dma_rsp_data(ind_dma_rsp_data),
		.draw_valid(ind_draw_valid),
		.draw_ready(ind_draw_ready),
		.vertex_count(ind_vertex_count),
		.instance_count(ind_instance_count),
		.first_vertex(ind_first_vertex),
		.first_instance(ind_first_instance),
		.first_index(ind_first_index),
		.vertex_offset(ind_vertex_offset)
	);

	wire unused_indirect = &{1'b0, ind_cmd_ready, ind_dma_req_valid, ind_dma_req_line,
		ind_draw_valid, ind_vertex_count, ind_instance_count, ind_first_vertex,
		ind_first_instance, ind_first_index, ind_vertex_offset};

	wire unused_ok = &{1'b0, busy_ext[1], s_i_rsp_tag, s_n_last, fw_last, s_queue_id, s_preempt_ev, unused_indirect, dc_ev, s_ev_flip,
		s_f_addr[63:32],
		s_dma_req_valid, s_dma_empty, s_dma_busy,
		s_dma_src_base, s_dma_dst_base, s_dma_src_row_stride, s_dma_dst_row_stride,
		s_dma_src_slice_stride, s_dma_dst_slice_stride,
		s_dma_copy_w, s_dma_copy_h, s_dma_copy_d};
endmodule

`default_nettype wire
