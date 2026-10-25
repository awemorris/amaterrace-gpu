/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_prot: the CP's side of session protection
 * (spec/gpu/cp/atg_cp_prot.md, docs/ghci.md section 11.6).
 *
 *   - SLOT_MAP (job tag -> protected slot, 0 = not checked; tag 0 always 0)
 *     and SLOT_TAG (slot -> tag), written by the firmware (PROT_SLOT).
 *   - The slot of the µop in the sequencer: a ring µop's is SLOT_MAP of its
 *     tag, a firmware µop's comes with it from the UOP_FIFO (u_side, with
 *     SELF).  The fence unit's µops of the firmware are checked for that
 *     slot unless SELF (f_chk, f_slot); the ring's are not (the driver's).
 *   - The units run for one session at a time, prot_unit (their requests
 *     carry it).  A µop that starts a unit (u_req[0]) for another slot
 *     waits (u_ok = 0) while this module switches: DRAIN (drain_ok: the
 *     units idle, no unit request waiting at a leaf or in the MC, every
 *     unit request answered), INV (sw_inv for one cycle: the caches and
 *     the occlusion counter), SCRUB (only when the slot is not 0 and the
 *     shader units still hold another owner's data: scrub, then wait for
 *     !scrub_busy), then prot_unit = the slot.
 *   - resid, the owner of the data in the shader units: none (scrubbed), a
 *     slot (0, unchecked work, is an owner too) or mixed.  A µop that uses
 *     the shader units (u_req[1]) adds prot_unit.  Reset: mixed (RESET does
 *     not clear those memories).  Clearing a slot's SLOT_MAP entry makes a
 *     resid of that slot mixed and a prot_unit of that slot 0 (unknown), so
 *     that a new session in the same slot does not see the old one's data.
 *   - The registers: PROT_CAPS, PROT_TABLE (4 KiB aligned, written only
 *     while no slot is mapped; writes of APERTURE_* and the reset set it
 *     to 0), PROT_TABLE_BYTES, at the PROT capability's offset (hcr_*);
 *     the firmware's window (sub-bus 0x28-0x33): PROT_SLOT, PROT_INV_G,
 *     PROT_INV_N (writing it invalidates the MC's PLB), the CAM's
 *     GIDX/GBASE/GLIMIT/GCTL (writing GCTL writes the entry), PROT_INFO,
 *     PROT_TBASE, PROT_G0, PROT_G1 (0x32 UOP_SELF is atg_cpu_win's).
 *   - Faults: fault_tag = SLOT_TAG of the MC's refused request's slot,
 *     unit_tag = SLOT_TAG of prot_unit.
 *
 * rst_n is the CP's core reset (CTRL.RESET).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_prot #(
	parameter ADDR_W = 32,
	parameter [7:0] SLOTS = 8'd31,	/* PROT_CAPS[7:0] */
	parameter [15:0] GRANTS = 16'd8,	/* PROT_CAPS[31:16] */
	parameter GIDX_W = 3,	/* clog2(GRANTS) */
	parameter [11:0] REG_OFF = 12'h1D0	/* the capability's registers */
) (
	input wire clk,
	input wire rst_n,

	/* Host registers (atg_cp_regs' snoop bus). */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output reg [31:0] hcr_rdata,
	input wire [ADDR_W-1:0] aperture_base,
	input wire [ADDR_W-1:0] aperture_limit,

	/* The firmware's window (atg_cpu's sub-bus). */
	input wire sb_we,
	input wire [5:0] sb_idx,
	input wire [31:0] sb_wdata,
	output reg [31:0] sb_rdata,
	input wire [7:0] v_tag,
	output wire [5:0] v_slot,

	/* The sequencer's µop. */
	input wire [7:0] u_tag,
	input wire u_fw,
	input wire [6:0] u_side,
	input wire [1:0] u_req,	/* [0] it starts a unit, [1] it uses the shader units */
	output wire u_ok,
	output wire f_chk,
	output wire [5:0] f_slot,

	/* The units. */
	input wire drain_ok,
	output wire sw_inv,
	output wire scrub,
	input wire scrub_busy,
	output reg [5:0] prot_unit,

	/* The MC (atg_mc_prot). */
	output reg [ADDR_W-1:0] tbase,
	output wire inv_valid,
	output reg [ADDR_W-13:0] inv_g,
	output reg [31:0] inv_n,
	input wire inv_pending,
	output wire gw_valid,
	output reg [GIDX_W-1:0] gw_idx,
	output wire [49:0] gw_data,

	/* Faults. */
	input wire [5:0] fault_slot,
	output wire [7:0] fault_tag,
	output wire [7:0] unit_tag
);
	`include "ghci_regs.vh"

	localparam GW = ADDR_W - 12;
	localparam [9:0] I_CAPS = REG_OFF[11:2];
	localparam [9:0] I_TABLE = REG_OFF[11:2] + 10'd1;
	localparam [9:0] I_TBYTES = REG_OFF[11:2] + 10'd2;
	localparam [9:0] I_AP_BASE = GHCI_APERTURE_BASE[11:2];
	localparam [9:0] I_AP_LIMIT = GHCI_APERTURE_LIMIT[11:2];

	localparam [5:0] W_SLOT = 6'h28;
	localparam [5:0] W_INV_G = 6'h29;
	localparam [5:0] W_GIDX = 6'h2A;
	localparam [5:0] W_GBASE = 6'h2B;
	localparam [5:0] W_GLIMIT = 6'h2C;
	localparam [5:0] W_GCTL = 6'h2D;
	localparam [5:0] W_INFO = 6'h2E;
	localparam [5:0] W_TBASE = 6'h2F;
	localparam [5:0] W_G0 = 6'h30;
	localparam [5:0] W_G1 = 6'h31;
	localparam [5:0] W_INV_N = 6'h33;

	/* ------------------------------------------- SLOT_MAP, SLOT_TAG */

	reg [255:0] map_v;
	reg [5:0] map_d [0:255];
	reg [63:0] tag_v;
	reg [7:0] tag_d [0:63];
	reg [6:0] n_slots;

	wire [5:0] map_u = map_v[u_tag] ? map_d[u_tag] : 6'd0;
	assign v_slot = map_v[v_tag] ? map_d[v_tag] : 6'd0;
	wire [7:0] w_tag = sb_wdata[7:0];
	wire [5:0] w_slot = sb_wdata[13:8];
	wire [5:0] w_old = map_v[w_tag] ? map_d[w_tag] : 6'd0;
	wire slot_wr = sb_we && sb_idx == W_SLOT && w_tag != 8'd0;
	/* A slot whose sessions ends: cleared, or replaced by another. */
	wire slot_gone = slot_wr && w_old != 6'd0 && w_old != w_slot;
	assign fault_tag = tag_v[fault_slot] ? tag_d[fault_slot] : 8'd0;
	assign unit_tag = tag_v[prot_unit] ? tag_d[prot_unit] : 8'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			map_v <= 256'd0;
			tag_v <= 64'd0;
			n_slots <= 7'd0;
		end else if (slot_wr) begin
			map_v[w_tag] <= w_slot != 6'd0;
			if (slot_gone)
				tag_v[w_old] <= 1'b0;
			if (w_slot != 6'd0)
				tag_v[w_slot] <= 1'b1;
			if (w_old == 6'd0 && w_slot != 6'd0)
				n_slots <= n_slots + 7'd1;
			else if (w_old != 6'd0 && w_slot == 6'd0)
				n_slots <= n_slots - 7'd1;
		end
	end

	always @(posedge clk) begin
		if (slot_wr) begin
			map_d[w_tag] <= w_slot;
			if (w_slot != 6'd0)
				tag_d[w_slot] <= w_tag;
		end
	end

	/* ------------------------------------------- the µop's slot */

	wire [5:0] cur_slot = u_fw ? u_side[5:0] : map_u;
`ifdef MUT_CPPROT_FCHK
	assign f_chk = 1'b0;
`else
	assign f_chk = u_fw && !u_side[6] && cur_slot != 6'd0;
`endif
	assign f_slot = cur_slot;

	/* ------------------------------------------- the switch */

	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_DRAIN = 3'd1;
	localparam [2:0] S_INV = 3'd2;
	localparam [2:0] S_SCRUB = 3'd3;
	localparam [2:0] S_SWAIT = 3'd4;
	localparam [1:0] R_NONE = 2'd0;
	localparam [1:0] R_SLOT = 2'd1;
	localparam [1:0] R_MIXED = 2'd2;

	reg [2:0] st;
	reg known;
	reg [5:0] tgt;
	reg [1:0] r_kind;
	reg [5:0] r_slot;
	reg [1:0] sw_cnt;

	wire need = u_req[0] && (cur_slot != prot_unit || !known);
	assign u_ok = st == S_IDLE && !need;
`ifdef MUT_CPPROT_NOINV
	assign sw_inv = 1'b0;
`else
	assign sw_inv = st == S_INV;
`endif
	assign scrub = st == S_SCRUB;
`ifdef MUT_CPPROT_NOSCRUB
	wire scrub_need = 1'b0;
`else
	wire scrub_need = tgt != 6'd0 && r_kind != R_NONE && !(r_kind == R_SLOT && r_slot == tgt);
`endif
`ifdef MUT_CPPROT_NODRAIN
	wire drained = 1'b1;
`else
	wire drained = drain_ok;
`endif
`ifdef MUT_CPPROT_RESID0
	localparam [1:0] R_RESET = R_NONE;
`else
	localparam [1:0] R_RESET = R_MIXED;
`endif
`ifdef MUT_CPPROT_CLOSEKEEP
	wire gone = 1'b0;
`else
	wire gone = slot_gone;
`endif

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			known <= 1'b0;
			prot_unit <= 6'd0;
			tgt <= 6'd0;
			r_kind <= R_RESET;
			r_slot <= 6'd0;
			sw_cnt <= 2'd0;
		end else begin
			case (st)
			S_IDLE:
				if (need) begin
					tgt <= cur_slot;
					st <= S_DRAIN;
				end else if (u_req[1]) begin
					/* The shader units get prot_unit's data. */
					if (r_kind == R_NONE) begin
						r_kind <= R_SLOT;
						r_slot <= prot_unit;
					end else if (r_kind == R_SLOT && r_slot != prot_unit) begin
						r_kind <= R_MIXED;
					end
				end
			S_DRAIN:
				if (drained)
					st <= S_INV;
			S_INV:
				st <= scrub_need ? S_SCRUB : S_IDLE;
			S_SCRUB: begin
				sw_cnt <= 2'd0;
				st <= S_SWAIT;
			end
			default:	/* S_SWAIT: the SUs' busy rises after scrub, then falls */
				if (sw_cnt != 2'd2)
					sw_cnt <= sw_cnt + 2'd1;
				else if (!scrub_busy) begin
					r_kind <= R_NONE;
					st <= S_IDLE;
				end
			endcase
			if (st == S_INV && !scrub_need || st == S_SWAIT && sw_cnt == 2'd2 && !scrub_busy) begin
				prot_unit <= tgt;
				known <= 1'b1;
			end
			/* A slot's session ended: its data and its prot_unit are not its successor's. */
			if (gone) begin
				if (r_kind == R_SLOT && r_slot == w_old)
					r_kind <= R_MIXED;
				if (prot_unit == w_old) begin
					prot_unit <= 6'd0;
					known <= 1'b0;
				end
			end
		end
	end

	/* ------------------------------------------- registers */

	wire [GW-1:0] g0 = aperture_base[ADDR_W-1:12];
	wire [ADDR_W:0] lim_up = {1'b0, aperture_limit} + 4095;
	wire [GW:0] g1 = lim_up[ADDR_W:12];
	wire [ADDR_W:0] tgran = {{(ADDR_W-GW){1'b0}}, g1 - {1'b0, g0}} + 4095;
	wire [ADDR_W-1:0] tbytes = {tgran[ADDR_W-1:12], 12'd0};

	reg inv_p, gw_p;
	reg [19:0] gbase;
	reg [20:0] glimit;
	reg [9:0] gctl;
	assign inv_valid = inv_p;
	assign gw_valid = gw_p;
	assign gw_data = {glimit, gbase, gctl[2], gctl[1], gctl[9:4], gctl[0]};

	always @(posedge clk) begin
		if (!rst_n) begin
			tbase <= {ADDR_W{1'b0}};
			inv_p <= 1'b0;
			inv_g <= {GW{1'b0}};
			inv_n <= 32'd0;
			gw_p <= 1'b0;
			gw_idx <= {GIDX_W{1'b0}};
			gbase <= 20'd0;
			glimit <= 21'd0;
			gctl <= 10'd0;
		end else begin
			inv_p <= 1'b0;
			gw_p <= 1'b0;
			if (hcr_we && (hcr_widx == I_AP_BASE || hcr_widx == I_AP_LIMIT))
				tbase <= {ADDR_W{1'b0}};
			else if (hcr_we && hcr_widx == I_TABLE && n_slots == 7'd0)
				tbase <= ((tbase & ~hcr_wmask) | (hcr_wdata & hcr_wmask)) &
					~{{(ADDR_W-12){1'b0}}, 12'hFFF};
			if (sb_we) begin
				case (sb_idx)
				W_INV_G: inv_g <= sb_wdata[GW-1:0];
				W_INV_N: begin
					inv_n <= sb_wdata;
					inv_p <= 1'b1;
				end
				W_GIDX: gw_idx <= sb_wdata[GIDX_W-1:0];
				W_GBASE: gbase <= sb_wdata[19:0];
				W_GLIMIT: glimit <= sb_wdata[20:0];
				W_GCTL: begin
					gctl <= {sb_wdata[13:8], 1'b0, sb_wdata[2:0]};
					gw_p <= 1'b1;
				end
				default: ;
				endcase
			end
		end
	end

	always @(*) begin
		hcr_rdata = 32'd0;
		case (hcr_ridx)
		I_CAPS: hcr_rdata = {GRANTS, 8'd12, SLOTS};
		I_TABLE: hcr_rdata = tbase;
		I_TBYTES: hcr_rdata = tbytes;
		default: ;
		endcase
		sb_rdata = 32'd0;
		case (sb_idx)
		W_INFO: sb_rdata = {GRANTS, 2'd0, SLOTS[5:0], 4'd0, inv_pending, drain_ok, tbase != 0,
			1'b1};
		W_TBASE: sb_rdata = tbase;
		W_G0: sb_rdata = {{(32-GW){1'b0}}, g0};
		W_G1: sb_rdata = {{(31-GW){1'b0}}, g1};
		default: ;
		endcase
	end

	wire unused_ok = &{1'b0, lim_up, tgran, hcr_wdata, SLOTS[7:6], gctl[3], aperture_base[11:0]};
endmodule

`default_nettype wire
