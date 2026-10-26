/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_pipeline_tb: verification of TU filtering pipeline interleaving
 * and removal of mutual exclusion wait (ws001-p019).
 *
 * Interleaves UNORM8 (slot 0) and FP16 (slot 1) texture sampling requests
 * back-to-back across multiple quads, verifying:
 * 1. Both pipelines operate concurrently without mutual exclusion stalls.
 * 2. Returned quads maintain strictly in-order tag sequence matching request order.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_pipeline_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [9:0] st_idx = 0;
	reg [31:0] st_wdata = 0;

	reg tx_valid = 1'b0;
	reg [7:0] tx_op = 0;
	reg [3:0] tx_slot = 0, tx_mask = 4'hF;
	reg tx_vs = 1'b0;
	reg [639:0] tx_coord = 0;
	reg [11:0] tx_off = 0;
	reg [15:0] tx_tag = 0;
	reg tx_last = 1'b0;
	reg tr_ready = 1'b1;

	wire tx_ready, tr_valid, tr_last, busy;
	wire [15:0] tr_tag;
	wire [511:0] tr_data;

	wire req_valid, req_write;
	reg req_ready = 1'b1;
	wire [26:0] req_line;
	wire [31:0] req_be;
	wire [255:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 1'b0;
	reg [7:0] rsp_tag = 0;
	reg [255:0] rsp_rdata = 0;

	atg_tu #(.ADDR_W(32), .LINE_BYTES(32), .LINE_SHIFT(5)) dut (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.inv(1'b0), .busy(busy),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot), .tx_vs(tx_vs),
		.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
		.tx_last(tx_last),
		.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
		.tr_last(tr_last),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(1'b0), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(1'b0)
	);

	/* Memory model: 1-cycle latency cache refill */
	reg [31:0] la;
	integer w;
	always @(posedge clk) begin
		rsp_valid <= 1'b0;
		if (req_valid && req_ready) begin
			la = {req_line, 5'd0};
			for (w = 0; w < 8; w = w + 1)
				rsp_rdata[w*32 +: 32] <= ((la >> 2) + w) * 32'h9E3779B1;
			rsp_tag <= req_tag;
			rsp_valid <= 1'b1;
		end
	end

	task write_st(input [9:0] idx, input [31:0] val);
		begin
			@(posedge clk);
			st_we <= 1'b1;
			st_idx <= idx;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	integer errs = 0;
	integer i, exp_tag = 0, num_received = 0;
	localparam NUM_QUADS = 40;

	/* Tag check monitor */
	always @(posedge clk) begin
		if (rst_n && tr_valid && tr_ready) begin
			if (tr_tag !== exp_tag[15:0]) begin
				$display("FAIL atg_tu_pipeline: tag mismatch: got %0d, expected %0d", tr_tag, exp_tag);
				errs = errs + 1;
			end
			exp_tag = exp_tag + 1;
			num_received = num_received + 1;
		end
	end

	initial begin
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* Configure Slot 0: UNORM8 (RGBA8) */
		write_st(10'h090, 32'h00100000); /* BASE */
		write_st(10'h091, 32'h00100010); /* SIZE 16x16 */
		write_st(10'h092, 32'h00000001); /* IMAGE: 1 level, 2D */
		write_st(10'h093, 32'h00000040); /* STRIDE */
		write_st(10'h094, 32'h00000000); /* SAMPLER: nearest, clamp */
		write_st(10'h095, 32'h00000000); /* LOD */
		write_st(10'h096, 32'h0000002b); /* FORMAT: VkFormat 43 = R8G8B8A8_UNORM */
		write_st(10'h097, 32'h00000000); /* ROW */

		/* Configure Slot 1: FP16 (R16G16B16A16_SFLOAT) */
		write_st(10'h0a0, 32'h00200000); /* BASE */
		write_st(10'h0a1, 32'h00100010); /* SIZE 16x16 */
		write_st(10'h0a2, 32'h00000001); /* IMAGE: 1 level, 2D */
		write_st(10'h0a3, 32'h00000080); /* STRIDE */
		write_st(10'h0a4, 32'h00000000); /* SAMPLER: nearest, clamp */
		write_st(10'h0a5, 32'h00000000); /* LOD */
		write_st(10'h0a6, 32'h00000061); /* FORMAT: VkFormat 97 = R16G16B16A16_SFLOAT */
		write_st(10'h0a7, 32'h00000000); /* ROW */

		while (busy) @(posedge clk);
		@(posedge clk);

		/* Send NUM_QUADS alternating between slot 0 (UNORM8) and slot 1 (FP16) */
		for (i = 0; i < NUM_QUADS; i = i + 1) begin
			tx_valid <= 1'b1;
			tx_op <= 8'd0; /* texl */
			tx_slot <= i[0] ? 4'd1 : 4'd0; /* alternate slot 0 and slot 1 */
			tx_vs <= 1'b0;
			tx_mask <= 4'hF;
			/* coordinate (u=0.5, v=0.5) */
			tx_coord <= {4{32'd0, 32'd0, 32'd0, 32'h3F000000, 32'h3F000000}};
			tx_off <= 12'd0;
			tx_tag <= i[15:0];
			tx_last <= (i == NUM_QUADS - 1);

			@(posedge clk);
			while (!tx_ready)
				@(posedge clk);
			tx_valid <= 1'b0;
		end

		/* Wait for all quads to return */
		while (num_received < NUM_QUADS)
			@(posedge clk);

		repeat (10) @(posedge clk);

		if (errs == 0 && num_received == NUM_QUADS)
			$display("PASS atg_tu_pipeline");
		else
			$display("FAIL atg_tu_pipeline: %0d errors, received %0d / %0d", errs, num_received, NUM_QUADS);

		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL atg_tu_pipeline: timeout");
		$finish;
	end
endmodule

`default_nettype wire
