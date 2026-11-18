/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_fifo: Asynchronous BRAM Pixel AFIFO with clean 1-cycle latency
 * interfaces meeting ASIC 5nm 1.5 GHz rules (Rule 4 clean memory pipeline,
 * Rule 2 fanout <= 16, Rule 5 skid buffer isolation).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_fifo #(
	parameter W = 32,
	parameter DEPTH_LOG2 = 11
) (
	// Write domain (w_clk)
	input wire w_clk,
	input wire w_rst_n,
	input wire w_valid,
	output wire w_ready,
	input wire [W-1:0] w_data,

	// Read domain (r_clk)
	input wire r_clk,
	input wire r_rst_n,
	output wire r_valid,
	input wire r_ready,
	output wire [W-1:0] r_data,

	// Watermark count (r_clk domain)
	output wire [DEPTH_LOG2:0] r_count
);
	localparam P = DEPTH_LOG2 + 1;

	// Dual-port Block RAM (split into 16-bit halves to constrain write enable fanout <= 16)
	(* ram_style = "block" *) reg [15:0] mem_lo [0:(1 << DEPTH_LOG2) - 1];
	(* ram_style = "block" *) reg [15:0] mem_hi [0:(1 << DEPTH_LOG2) - 1];

	(* keep = "true" *) wire w_rst_high = !w_rst_n;
	(* keep = "true" *) wire r_rst_high = !r_rst_n;

	// -------------------------------------------------------------
	// Write side (w_clk domain)
	// -------------------------------------------------------------
	(* max_fanout = 16 *) reg [P-1:0] w_bin;
	reg [P-1:0] w_gray;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] w_rgray1;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] w_rgray2;

	wire w_push = w_valid && w_ready;
	wire [P-1:0] w_bin_next;
	wire unused_w_co;
	am_add #(.W(P)) u_w_bin (
		.a(w_bin), .b({P{1'b0}}), .ci(w_push), .s(w_bin_next), .co(unused_w_co)
	);
	wire [P-1:0] w_gray_next = w_bin_next ^ (w_bin_next >> 1);

	wire [P-1:0] full_gray = {~w_rgray2[P-1:P-2], w_rgray2[P-3:0]};
	wire [3:0] w_diff_eq;
	assign w_diff_eq[0] = (w_gray[2:0]   == full_gray[2:0]);
	assign w_diff_eq[1] = (w_gray[5:3]   == full_gray[5:3]);
	assign w_diff_eq[2] = (w_gray[8:6]   == full_gray[8:6]);
	assign w_diff_eq[3] = (w_gray[11:9]  == full_gray[11:9]);
	(* max_fanout = 16 *) wire w_ready_w = !(&w_diff_eq);
	assign w_ready = w_ready_w;

`ifdef SYNTH_KINTEX7
	wire w_push_lo, w_push_hi;
	LUT1 #(.INIT(2'b10)) u_buf_wp0 (.I0(w_push), .O(w_push_lo));
	LUT1 #(.INIT(2'b10)) u_buf_wp1 (.I0(w_push), .O(w_push_hi));
`else
	wire w_push_lo = w_push;
	wire w_push_hi = w_push;
`endif

	// Write port (0 logic levels to RAM address pin)
	always @(posedge w_clk) begin
		if (w_push_lo)
			mem_lo[w_bin[DEPTH_LOG2-1:0]] <= w_data[15:0];
		if (w_push_hi)
			mem_hi[w_bin[DEPTH_LOG2-1:0]] <= w_data[31:16];
	end

	always @(posedge w_clk) begin
		if (w_rst_high) begin
			w_bin    <= {P{1'b0}};
			w_gray   <= {P{1'b0}};
			w_rgray1 <= {P{1'b0}};
			w_rgray2 <= {P{1'b0}};
		end else begin
			w_bin    <= w_bin_next;
			w_gray   <= w_gray_next;
			w_rgray1 <= r_gray;
			w_rgray2 <= w_rgray1;
		end
	end

	// -------------------------------------------------------------
	// Read side (r_clk domain) - BRAM Synchronous Read
	// -------------------------------------------------------------
	(* max_fanout = 16 *) reg [P-1:0] r_bin;
	reg [P-1:0] r_gray;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] r_wgray1;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] r_wgray2;

	// BRAM synchronous read register (absorbed into BRAM primitive)
	reg [W-1:0] ram_rdata;
	reg ram_rvalid;

	// Unconditional direct register stage (strictly 0 logic levels from BRAM DO)
	(* keep = "true" *) reg [W-1:0] ram_pipe;
	(* max_fanout = 16 *) reg ram_pipe_valid;

	// Clean 4-entry flop buffer to isolate BRAM DO pins with strictly 0 LUTs
	(* max_fanout = 16 *) reg [W-1:0] f_entry_0, f_entry_1, f_entry_2, f_entry_3;
	(* max_fanout = 16 *) reg [1:0] f_wptr, f_rptr;
	(* max_fanout = 16 *) reg [2:0] f_count;
	(* max_fanout = 16 *) reg [2:0] occ;

	wire r_pop = r_valid && r_ready;
	wire [3:0] r_diff_eq;
	assign r_diff_eq[0] = (r_gray[2:0]  == r_wgray2[2:0]);
	assign r_diff_eq[1] = (r_gray[5:3]  == r_wgray2[5:3]);
	assign r_diff_eq[2] = (r_gray[8:6]  == r_wgray2[8:6]);
	assign r_diff_eq[3] = (r_gray[11:9] == r_wgray2[11:9]);
	wire bram_has_data = !(&r_diff_eq);

	// Zero-bubble space tracking: occ tracks total items fetched from BRAM not yet consumed
	wire fetch_space = !occ[2] || r_pop;
	wire ram_ren = bram_has_data && fetch_space;
`ifdef SYNTH_KINTEX7
	wire ram_ren_lo, ram_ren_hi, ram_ren_ctl, ram_ren_bin, ram_ren_gray;
	LUT1 #(.INIT(2'b10)) u_buf_ren_l (.I0(ram_ren), .O(ram_ren_lo));
	LUT1 #(.INIT(2'b10)) u_buf_ren_h (.I0(ram_ren), .O(ram_ren_hi));
	LUT1 #(.INIT(2'b10)) u_buf_ren_c (.I0(ram_ren), .O(ram_ren_ctl));
	LUT1 #(.INIT(2'b10)) u_buf_ren_b (.I0(ram_ren), .O(ram_ren_bin));
	LUT1 #(.INIT(2'b10)) u_buf_ren_g (.I0(ram_ren), .O(ram_ren_gray));
`else
	wire ram_ren_lo = ram_ren;
	wire ram_ren_hi = ram_ren;
	wire ram_ren_ctl = ram_ren;
	wire ram_ren_bin = ram_ren;
	wire ram_ren_gray = ram_ren;
`endif

	wire [P-1:0] r_bin_inc;
	wire unused_r_co;
	am_add #(.W(P)) u_r_bin (
		.a(r_bin), .b({P{1'b0}}), .ci(1'b1), .s(r_bin_inc), .co(unused_r_co)
	);
	wire [P-1:0] r_gray_inc = r_bin_inc ^ (r_bin_inc >> 1);
	wire [P-1:0] r_bin_next = ram_ren_bin ? r_bin_inc : r_bin;
	wire [P-1:0] r_gray_next = ram_ren_gray ? r_gray_inc : r_gray;

	// Synchronous BRAM read (0 logic levels to RAM address pin)
	always @(posedge r_clk) begin
		if (ram_ren_lo)
			ram_rdata[15:0]  <= mem_lo[r_bin[DEPTH_LOG2-1:0]];
	end

	always @(posedge r_clk) begin
		if (ram_ren_hi)
			ram_rdata[31:16] <= mem_hi[r_bin[DEPTH_LOG2-1:0]];
	end

	// Direct unconditional flop of ram_rdata (strictly 0 logic levels from BRAM DO)
	always @(posedge r_clk) begin
		ram_pipe <= ram_rdata;
		if (r_rst_high)
			ram_pipe_valid <= 1'b0;
		else
			ram_pipe_valid <= ram_rvalid;
	end

	// Direct flop of ram_pipe into discrete slice registers
	always @(posedge r_clk) begin
		if (ram_pipe_valid) begin
			case (f_wptr)
			2'd0: f_entry_0 <= ram_pipe;
			2'd1: f_entry_1 <= ram_pipe;
			2'd2: f_entry_2 <= ram_pipe;
			2'd3: f_entry_3 <= ram_pipe;
			endcase
		end
	end

	wire [1:0] f_wptr_next, f_rptr_next;
	wire [2:0] f_cnt_inc, f_cnt_dec;
	wire [2:0] occ_inc, occ_dec;
	wire [5:0] unused_f_co;
	am_add #(.W(2)) u_fw (.a(f_wptr), .b(2'd0), .ci(1'b1), .s(f_wptr_next), .co(unused_f_co[0]));
	am_add #(.W(2)) u_fr (.a(f_rptr), .b(2'd0), .ci(1'b1), .s(f_rptr_next), .co(unused_f_co[1]));
	am_add #(.W(3)) u_fc_inc (.a(f_count), .b(3'd0), .ci(1'b1), .s(f_cnt_inc), .co(unused_f_co[2]));
	am_sub #(.W(3)) u_fc_dec (.a(f_count), .b(3'd0), .bi(1'b1), .d(f_cnt_dec), .bo(unused_f_co[3]));
	am_add #(.W(3)) u_occ_inc (.a(occ), .b(3'd0), .ci(1'b1), .s(occ_inc), .co(unused_f_co[4]));
	am_sub #(.W(3)) u_occ_dec (.a(occ), .b(3'd0), .bi(1'b1), .d(occ_dec), .bo(unused_f_co[5]));

	always @(posedge r_clk) begin
		if (r_rst_high) begin
			r_bin           <= {P{1'b0}};
			r_gray          <= {P{1'b0}};
			r_wgray1        <= {P{1'b0}};
			r_wgray2        <= {P{1'b0}};
			ram_rvalid      <= 1'b0;
			f_wptr          <= 2'd0;
			f_rptr          <= 2'd0;
			f_count         <= 3'd0;
			occ             <= 3'd0;
		end else begin
			r_bin           <= r_bin_next;
			r_gray          <= r_gray_next;
			r_wgray1        <= w_gray;
			r_wgray2        <= r_wgray1;
			ram_rvalid      <= ram_ren_ctl;

			if (ram_pipe_valid)
				f_wptr <= f_wptr_next;

			if (r_pop)
				f_rptr <= f_rptr_next;

			case ({ram_pipe_valid, r_pop})
			2'b10: f_count <= f_cnt_inc;
			2'b01: f_count <= f_cnt_dec;
			default: ;
			endcase

			case ({ram_ren_ctl, r_pop})
			2'b10: occ <= occ_inc;
			2'b01: occ <= occ_dec;
			default: ;
			endcase
		end
	end

	reg [W-1:0] r_data_mux;
	always @(*) begin
		case (f_rptr)
		2'd0: r_data_mux = f_entry_0;
		2'd1: r_data_mux = f_entry_1;
		2'd2: r_data_mux = f_entry_2;
		2'd3: r_data_mux = f_entry_3;
		endcase
	end

	assign r_valid = (f_count != 3'd0);
	assign r_data  = r_data_mux;

	// -------------------------------------------------------------
	// Watermark calculation (r_clk domain)
	// -------------------------------------------------------------
	wire [P-1:0] w_bin_in_rclk;
	assign w_bin_in_rclk[P-1] = r_wgray2[P-1];
	genvar gi;
	generate
		for (gi = 0; gi < P - 1; gi = gi + 1) begin : g2b
			assign w_bin_in_rclk[gi] = ^r_wgray2[P-1:gi];
		end
	endgenerate

	wire [P-1:0] bram_count;
	wire unused_bram_bo;
`ifdef SYNTH_KINTEX7
	reg [P-1:0] w_bin_in_rclk_q, r_bin_wm_q;
	always @(posedge r_clk) begin
		w_bin_in_rclk_q <= w_bin_in_rclk;
		r_bin_wm_q      <= r_bin;
	end
	am_sub #(.W(P)) u_bram_count (
		.a(w_bin_in_rclk_q), .b(r_bin_wm_q), .bi(1'b0), .d(bram_count), .bo(unused_bram_bo)
	);
`else
	am_sub #(.W(P)) u_bram_count (
		.a(w_bin_in_rclk), .b(r_bin), .bi(1'b0), .d(bram_count), .bo(unused_bram_bo)
	);
`endif

	wire [P-1:0] total_count;
	wire unused_tot_co;
	am_add #(.W(P)) u_tot_count (
		.a(bram_count), .b({{(P-3){1'b0}}, occ}), .ci(1'b0), .s(total_count), .co(unused_tot_co)
	);

	reg [P-1:0] r_count_q;
	always @(posedge r_clk) begin
		r_count_q <= total_count;
	end

	assign r_count = r_count_q;

	wire unused_ok = &{1'b0, unused_f_co, unused_bram_bo, unused_tot_co};
endmodule

`default_nettype wire
