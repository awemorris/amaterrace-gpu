/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_axi_regs: an AXI slave (AXI3 or AXI4, 64-bit data) that turns host
 * accesses into a simple 32-bit register bus.
 *
 * The register bus:
 *   reg_wr     one cycle per written 32-bit beat; reg_waddr is the byte
 *              offset, reg_wdata and reg_wstrb the beat.
 *   reg_rd     one cycle per read 32-bit beat with reg_raddr; the target drives
 *              reg_rdata in the next cycle (registered, never waits).
 *
 * Write behaviour (64-bit AXI):
 *   - Lower 32-bit only (wstrb[3:0] != 0, wstrb[7:4] == 0): 1 cycle write
 *     to address {aw_addr[ADDR_BITS-1:3], 3'b000}.
 *   - Upper 32-bit only (wstrb[3:0] == 0, wstrb[7:4] != 0): 1 cycle write
 *     to address {aw_addr[ADDR_BITS-1:3], 3'b100}.
 *   - Both halves (wstrb[3:0] != 0, wstrb[7:4] != 0): 2 cycle write.
 *     Cycle 0 writes lower 32-bit.
 *     Cycle 1 writes upper 32-bit.
 *   - No strobe (wstrb == 8'h00): 1 cycle completion without reg_wr.
 *
 * Read behaviour:
 *   - Read with araddr[2] == 1: 1 cycle fetch from {araddr[ADDR_BITS-1:3], 3'b100},
 *     duplicated on both lanes {reg_rdata, reg_rdata}.
 *   - Read with araddr[2] == 0: 2 cycle fetch:
 *     Cycle 0 fetches {araddr[ADDR_BITS-1:3], 3'b000} (lower word).
 *     Cycle 1 fetches {araddr[ADDR_BITS-1:3], 3'b100} (upper word).
 *     Result presented as {upper_word, lower_word}.
 *
 * A burst does not stall the bus: every beat reads or writes the burst's
 * first address. Every access is answered OKAY. One write and one read
 * are in progress at a time.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_axi_regs #(
	parameter ADDR_BITS = 17,
	parameter ID_W = 12,
	parameter LEN_W = 4
) (
	input wire clk,
	input wire rst_n,

	input wire [ADDR_BITS-1:0] s_awaddr,
	input wire [ID_W-1:0] s_awid,
	input wire s_awvalid,
	output wire s_awready,
	input wire [63:0] s_wdata,
	input wire [7:0] s_wstrb,
	input wire s_wlast,
	input wire s_wvalid,
	output wire s_wready,
	output wire [ID_W-1:0] s_bid,
	output wire [1:0] s_bresp,
	output wire s_bvalid,
	input wire s_bready,
	input wire [ADDR_BITS-1:0] s_araddr,
	input wire [ID_W-1:0] s_arid,
	input wire [LEN_W-1:0] s_arlen,
	input wire s_arvalid,
	output wire s_arready,
	output wire [63:0] s_rdata,
	output wire [ID_W-1:0] s_rid,
	output wire [1:0] s_rresp,
	output wire s_rlast,
	output wire s_rvalid,
	input wire s_rready,

	output wire reg_wr,
	output wire [ADDR_BITS-1:0] reg_waddr,
	output wire [31:0] reg_wdata,
	output wire [3:0] reg_wstrb,
	output wire reg_rd,
	output wire [ADDR_BITS-1:0] reg_raddr,
	input wire [31:0] reg_rdata
);
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire rst_axi_regs_high;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b01)) u_rst_axi_regs (.I0(rst_n), .O(rst_axi_regs_high));
`else
	wire rst_axi_regs_high = !rst_n;
`endif

	/* Write channel: fully registered input buffer and output registers (Rule 3 compliant). */
	localparam W_IDLE = 1'b0;
	localparam W_UPPER = 1'b1;

	reg w_state;
	reg aw_full;
	reg [ADDR_BITS-1:0] aw_addr;
	reg [ID_W-1:0] aw_id;
	reg b_valid;
	reg [ID_W-1:0] b_id;

	reg w_buf_valid;
	reg [63:0] w_data_q;
	reg [7:0] w_strb_q;
	reg w_last_q;
	reg s_awready_q;
	reg s_wready_q;

	(* dont_touch = "true" *) reg r_reg_wr;
	(* dont_touch = "true" *) reg [ADDR_BITS-1:0] r_reg_waddr;
	(* dont_touch = "true" *) reg [31:0] r_reg_wdata;
	(* dont_touch = "true" *) reg [3:0] r_reg_wstrb;

	wire w_both = (w_strb_q[3:0] != 4'b0000) && (w_strb_q[7:4] != 4'b0000);
	wire w_hi_only = (w_strb_q[3:0] == 4'b0000) && (w_strb_q[7:4] != 4'b0000);
	wire w_has_strb = (w_strb_q != 8'h00);

	assign s_awready = s_awready_q;
	assign s_wready = s_wready_q;
	assign s_bvalid = b_valid;
	assign s_bid = b_id;
	assign s_bresp = 2'b00;

	assign reg_wr = r_reg_wr;
	assign reg_waddr = r_reg_waddr;
	assign reg_wdata = r_reg_wdata;
	assign reg_wstrb = r_reg_wstrb;

	wire aw_fire = s_awvalid && s_awready_q;
	wire w_fire = s_wvalid && s_wready_q;
	wire w_step_lo = (w_state == W_IDLE) && aw_full && w_buf_valid;
	wire w_step_hi = (w_state == W_UPPER);
	wire w_step_any = w_step_lo || w_step_hi;
	wire w_sel_upper = w_step_hi || (w_step_lo && w_hi_only);

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [4:0] w_fire_b;
	(* keep = "true", dont_touch = "true" *) wire [1:0] aw_fire_b;
	(* keep = "true", dont_touch = "true" *) wire [1:0] w_sel_up_b;
	(* keep = "true", dont_touch = "true" *) wire [2:0] w_step_b;
	genvar gi;
	generate
		for (gi = 0; gi < 5; gi = gi + 1) begin : g_wf_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wfb (.I0(w_fire), .O(w_fire_b[gi]));
		end
		for (gi = 0; gi < 2; gi = gi + 1) begin : g_awf_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_awfb (.I0(aw_fire), .O(aw_fire_b[gi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wsub (.I0(w_sel_upper), .O(w_sel_up_b[gi]));
		end
		for (gi = 0; gi < 3; gi = gi + 1) begin : g_wst_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wstb (.I0(w_step_any), .O(w_step_b[gi]));
		end
	endgenerate
`else
	wire [4:0] w_fire_b = {5{w_fire}};
	wire [1:0] aw_fire_b = {2{aw_fire}};
	wire [1:0] w_sel_up_b = {2{w_sel_upper}};
	wire [2:0] w_step_b = {3{w_step_any}};
`endif

	always @(posedge clk) begin
		if (rst_axi_regs_high) begin
			aw_full <= 1'b0;
			aw_addr <= {ADDR_BITS{1'b0}};
			aw_id <= {ID_W{1'b0}};
			b_valid <= 1'b0;
			b_id <= {ID_W{1'b0}};
			w_state <= W_IDLE;
			w_buf_valid <= 1'b0;
			w_data_q <= 64'd0;
			w_strb_q <= 8'd0;
			w_last_q <= 1'b0;
			s_awready_q <= 1'b0;
			s_wready_q <= 1'b0;
			r_reg_wr <= 1'b0;
			r_reg_waddr <= {ADDR_BITS{1'b0}};
			r_reg_wdata <= 32'd0;
			r_reg_wstrb <= 4'd0;
		end else begin
			if (aw_fire_b[0])
				aw_addr <= s_awaddr;
			if (aw_fire_b[1]) begin
				aw_full <= 1'b1;
				aw_id <= s_awid;
			end

			if (w_fire_b[0]) w_data_q[15:0]  <= s_wdata[15:0];
			if (w_fire_b[1]) w_data_q[31:16] <= s_wdata[31:16];
			if (w_fire_b[2]) w_data_q[47:32] <= s_wdata[47:32];
			if (w_fire_b[3]) w_data_q[63:48] <= s_wdata[63:48];
			if (w_fire_b[4]) begin
				w_strb_q <= s_wstrb;
				w_last_q <= s_wlast;
				w_buf_valid <= 1'b1;
				s_wready_q <= 1'b0;
			end

			case (w_state)
			W_IDLE: begin
				if (aw_full && w_buf_valid) begin
					r_reg_wr <= w_has_strb;
					r_reg_waddr <= {aw_addr[ADDR_BITS-1:3], w_hi_only ? 3'b100 : 3'b000};
					if (w_both) begin
						w_state <= W_UPPER;
					end else begin
						w_buf_valid <= 1'b0;
						if (w_last_q) begin
							aw_full <= 1'b0;
							b_valid <= 1'b1;
							b_id <= aw_id;
						end else begin
							s_wready_q <= 1'b1;
						end
					end
				end else begin
					r_reg_wr <= 1'b0;
				end
			end
			W_UPPER: begin
				r_reg_wr <= 1'b1;
				r_reg_waddr <= {aw_addr[ADDR_BITS-1:3], 3'b100};
				w_state <= W_IDLE;
				w_buf_valid <= 1'b0;
				if (w_last_q) begin
					aw_full <= 1'b0;
					b_valid <= 1'b1;
					b_id <= aw_id;
				end else begin
					s_wready_q <= 1'b1;
				end
			end
			endcase

			if (w_step_b[0]) r_reg_wdata[15:0]  <= w_sel_up_b[0] ? w_data_q[47:32] : w_data_q[15:0];
			else             r_reg_wdata[15:0]  <= 16'd0;
			if (w_step_b[1]) r_reg_wdata[31:16] <= w_sel_up_b[1] ? w_data_q[63:48] : w_data_q[31:16];
			else             r_reg_wdata[31:16] <= 16'd0;
			if (w_step_b[2]) r_reg_wstrb        <= w_sel_up_b[0] ? w_strb_q[7:4]   : w_strb_q[3:0];
			else             r_reg_wstrb        <= 4'd0;

			if (b_valid && s_bready)
				b_valid <= 1'b0;

			/* Ready updates for next cycle */
			if (aw_fire_b[1]) begin
				s_awready_q <= 1'b0;
				if (!w_buf_valid && !w_fire_b[4])
					s_wready_q <= 1'b1;
			end else if (!aw_full && (!b_valid || s_bready) && (w_state == W_IDLE)) begin
				s_awready_q <= 1'b1;
			end
		end
	end

	/* Read channel: fully registered reg_rd and reg_raddr outputs (Rule 3 & Rule 4 compliant).
	 *   - R_WAIT_HI: reg_rd_q == 1 at +4; next cycle R_FETCH_HI latches reg_rdata on both lanes.
	 *   - R_WAIT_LO: reg_rd_q == 1 at +0 and sets reg_rd_q <= 1 at +4;
	 *     next cycle R_FETCH_LO latches lower reg_rdata, then R_FETCH_LO_HI latches upper reg_rdata.
	 */
	localparam [2:0] R_IDLE        = 3'd0;
	localparam [2:0] R_WAIT_HI     = 3'd1;
	localparam [2:0] R_FETCH_HI    = 3'd2;
	localparam [2:0] R_WAIT_LO     = 3'd3;
	localparam [2:0] R_FETCH_LO    = 3'd4;
	localparam [2:0] R_FETCH_LO_HI = 3'd5;

	(* max_fanout = 16 *) reg [2:0] r_state;
	reg r_valid;
	reg s_arready_q;
	reg [ADDR_BITS-1:0] r_addr;
	reg [ID_W-1:0] r_id;
	reg [LEN_W-1:0] r_left;
	reg r_last_q;
	reg [63:0] r_data;
	reg [31:0] r_data_lo;
	(* dont_touch = "true" *) reg r_reg_rd;
	(* dont_touch = "true" *) reg [ADDR_BITS-1:0] r_reg_raddr;

	wire ar_fire = s_arvalid && s_arready_q;
	wire r_is_fh = (r_state == R_FETCH_HI);
	wire r_is_fl = (r_state == R_FETCH_LO);
	wire r_is_fd = (r_state == R_FETCH_HI) || (r_state == R_FETCH_LO_HI);

	assign s_arready = s_arready_q;
	assign s_rvalid = r_valid;
	assign s_rdata = r_data;
	assign s_rid = r_id;
	assign s_rresp = 2'b00;
	assign s_rlast = r_last_q;

	assign reg_rd = r_reg_rd;
	assign reg_raddr = r_reg_raddr;

	wire [LEN_W-1:0] r_left_n;
	wire unused_rl_bo;
	am_sub #(.W(LEN_W)) u_r_left (
		.a(r_left), .b({LEN_W{1'b0}}), .bi(1'b1), .d(r_left_n), .bo(unused_rl_bo)
	);

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [1:0] ar_fire_b;
	(* keep = "true", dont_touch = "true" *) wire [1:0] r_dlo_we_b;
	(* keep = "true", dont_touch = "true" *) wire [3:0] r_data_we_b;
	(* keep = "true", dont_touch = "true" *) wire [1:0] r_fh_sel_b;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_arfb0 (.I0(ar_fire), .O(ar_fire_b[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_arfb1 (.I0(ar_fire), .O(ar_fire_b[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_dlob0 (.I0(r_is_fl), .O(r_dlo_we_b[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_dlob1 (.I0(r_is_fl), .O(r_dlo_we_b[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rdwb0 (.I0(r_is_fd), .O(r_data_we_b[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rdwb1 (.I0(r_is_fd), .O(r_data_we_b[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rdwb2 (.I0(r_is_fd), .O(r_data_we_b[2]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rdwb3 (.I0(r_is_fd), .O(r_data_we_b[3]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rfhb0 (.I0(r_is_fh), .O(r_fh_sel_b[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rfhb1 (.I0(r_is_fh), .O(r_fh_sel_b[1]));
`else
	wire [1:0] ar_fire_b   = {2{ar_fire}};
	wire [1:0] r_dlo_we_b  = {2{r_is_fl}};
	wire [3:0] r_data_we_b = {4{r_is_fd}};
	wire [1:0] r_fh_sel_b  = {2{r_is_fh}};
`endif

	always @(posedge clk) begin
		if (rst_axi_regs_high) begin
			r_state <= R_IDLE;
			r_valid <= 1'b0;
			s_arready_q <= 1'b0;
			r_addr <= {ADDR_BITS{1'b0}};
			r_id <= {ID_W{1'b0}};
			r_left <= {LEN_W{1'b0}};
			r_last_q <= 1'b0;
			r_data <= 64'd0;
			r_data_lo <= 32'd0;
			r_reg_rd <= 1'b0;
			r_reg_raddr <= {ADDR_BITS{1'b0}};
		end else begin
			if (r_dlo_we_b[0]) r_data_lo[15:0]  <= reg_rdata[15:0];
			if (r_dlo_we_b[1]) r_data_lo[31:16] <= reg_rdata[31:16];
			if (r_data_we_b[0]) r_data[15:0]  <= r_fh_sel_b[0] ? reg_rdata[15:0]  : r_data_lo[15:0];
			if (r_data_we_b[1]) r_data[31:16] <= r_fh_sel_b[1] ? reg_rdata[31:16] : r_data_lo[31:16];
			if (r_data_we_b[2]) r_data[47:32] <= reg_rdata[15:0];
			if (r_data_we_b[3]) r_data[63:48] <= reg_rdata[31:16];

			case (r_state)
			R_IDLE: begin
				if (ar_fire_b[0]) begin
					r_addr <= s_araddr;
					r_reg_rd <= 1'b1;
					r_reg_raddr <= {s_araddr[ADDR_BITS-1:3], s_araddr[2] ? 3'b100 : 3'b000};
					r_state <= s_araddr[2] ? R_WAIT_HI : R_WAIT_LO;
					s_arready_q <= 1'b0;
				end else if (!r_valid) begin
					r_reg_rd <= 1'b0;
					s_arready_q <= 1'b1;
				end else begin
					r_reg_rd <= 1'b0;
				end
				if (ar_fire_b[1]) begin
					r_id <= s_arid;
					r_left <= s_arlen;
					r_last_q <= (s_arlen == {LEN_W{1'b0}});
				end
			end
			R_WAIT_HI: begin
				r_reg_rd <= 1'b0;
				r_state <= R_FETCH_HI;
			end
			R_FETCH_HI: begin
				r_reg_rd <= 1'b0;
				r_state <= R_IDLE;
				r_valid <= 1'b1;
			end
			R_WAIT_LO: begin
				r_reg_rd <= 1'b1;
				r_reg_raddr <= {r_addr[ADDR_BITS-1:3], 3'b100};
				r_state <= R_FETCH_LO;
			end
			R_FETCH_LO: begin
				r_reg_rd <= 1'b0;
				r_state <= R_FETCH_LO_HI;
			end
			R_FETCH_LO_HI: begin
				r_reg_rd <= 1'b0;
				r_state <= R_IDLE;
				r_valid <= 1'b1;
			end
			default: begin
				r_reg_rd <= 1'b0;
				r_state <= R_IDLE;
			end
			endcase

			if (r_valid && s_rready) begin
				if (r_last_q) begin
					r_valid <= 1'b0;
					s_arready_q <= 1'b1;
				end else begin
					r_left <= r_left_n;
					r_last_q <= (r_left_n == {LEN_W{1'b0}});
					r_valid <= 1'b0;
					r_reg_rd <= 1'b1;
					r_reg_raddr <= {r_addr[ADDR_BITS-1:3], r_addr[2] ? 3'b100 : 3'b000};
					r_state <= r_addr[2] ? R_WAIT_HI : R_WAIT_LO;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, aw_addr[2:0], r_addr[1:0]};
endmodule

`default_nettype wire
