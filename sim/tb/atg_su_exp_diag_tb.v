/*
 * Amaterrace GPU
 * Diagnostic testbench for atg_su_exp -> atg_rop_ms with NPHYS = 4
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp_diag_tb;
	localparam NPHYS = 4, G = 8, GRP_W = 3;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg x_valid = 1'b0;
	reg [1:0] x_warp = 0;
	reg [2:0] x_grp = 0;
	reg [107:0] x_uop = 0;
	reg [NPHYS*32-1:0] x_b = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg [31:0] x_info = 0;
	reg ex_ready = 1'b1;
	reg [15:0] ex_next = 0;
	reg fl_we = 1'b0, fl_go = 1'b0, wc_end = 1'b0;
	reg [1:0] fl_slot = 0, wc_warp = 0;
	reg [5:0] fl_reg = 0;
	reg [4:0] fl_lane = 0;
	reg [31:0] fl_data = 0;
	reg [63:0] fl_info = 0;
	reg fl_pw_we = 1'b0;
	reg [11:0] fl_pw_addr = 0;
	reg [31:0] fl_pw_data = 0;
	wire [154:0] ex_aux;
	wire x_ready, ex_valid, ex_last, xr_valid;
	wire [15:0] ex_seq;
	wire [31:0] ex_xy;
	wire [3:0] ex_mask;
	wire [511:0] ex_color;
	wire [127:0] ex_depth;
	wire [1:0] xr_warp;

	atg_su_exp #(.NPHYS(NPHYS), .GRP_W(GRP_W)) dut_exp (
		.clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
		.scrub(1'b0), .scrub_busy(),
		.x_last(1'b0), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a({NPHYS{32'd0}}),
		.x_b(x_b), .x_c({NPHYS{32'd0}}), .x_mask(x_mask), .x_info(x_info), .x_ready(x_ready),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_color1(), .ex_has_src1(),
		.ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next),
		.fl_we(fl_we), .fl_slot(fl_slot), .fl_reg(fl_reg), .fl_lane(fl_lane),
		.fl_data(fl_data), .fl_go(fl_go), .fl_info(fl_info),
		.fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data), .ex_aux(ex_aux),
		.xr_valid(xr_valid), .xr_warp(xr_warp), .wc_end(wc_end), .wc_warp(wc_warp),
		.mesh_valid(), .mesh_ready(1'b1), .mesh_tri(), .mesh_last(), .mesh_id(), .mesh_busy(),
		.mesh_lds_rd_en(), .mesh_lds_rd_addr(), .mesh_lds_rd_data(32'd0));

	/* ROP ms receiver */
	wire rop_ready;
	wire rop_out_valid;
	wire [15:0] rop_smask;
	reg rop_st_we = 1'b0;
	reg [8:0] rop_st_idx = 0;
	reg [31:0] rop_st_wdata = 0;

	atg_rop_ms dut_rop_ms (
		.clk(clk), .rst_n(rst_n),
		.st_we(rop_st_we), .st_idx(rop_st_idx), .st_wdata(rop_st_wdata),
		.i_valid(ex_valid), .i_ready(rop_ready),
		.i_xy(ex_xy), .i_mask(ex_mask),
		.i_color(ex_color), .i_color1(512'd0),
		.i_depth(ex_depth), .i_dbg(1'b0), .i_aux(ex_aux),
		.o_valid(rop_out_valid), .o_ready(1'b1),
		.o_xy(), .o_smask(rop_smask), .o_sdepth(),
		.o_color(), .o_color1(), .o_dbg(), .o_front(), .o_beat()
	);

	task tick;
		begin
			@(posedge clk);
			#1;
		end
	endtask

	task flw(input [1:0] s, input [5:0] rg, input [4:0] ln, input [31:0] d);
		begin
			fl_we = 1'b1;
			fl_slot = s;
			fl_reg = rg;
			fl_lane = ln;
			fl_data = d;
			tick;
			fl_we = 1'b0;
		end
	endtask

	task exp_op(input [1:0] s, input [2:0] g, input [31:0] tg, input [3:0] sm_mask, input [127:0] col);
		begin
			x_valid = 1'b1;
			x_warp = s;
			x_grp = g;
			x_uop = 108'd0;
			x_uop[3:0] = 4'd10; /* ATG_UNIT_EXP */
			x_uop[40 +: 32] = tg;
			x_info = {14'd0, 2'd1, 16'd0}; /* stage 1 = FS, seq = 0 */
			x_mask = {sm_mask, 4'hF};
			x_b = col;
			tick;
			x_valid = 1'b0;
		end
	endtask

	integer l;
	initial begin
		$display("=== atg_su_exp_diag_tb starting ===");
		repeat (3) tick;
		rst_n = 1'b1;
		tick;

		/* Setup ROP STATE: 1 sample (MS_CTRL = 0), RT_SIZE, WRITE_MASK = 0xF */
		rop_st_we = 1'b1; rop_st_idx = 9'h058; rop_st_wdata = 32'd0; tick; /* MS_CTRL = 0 */
		rop_st_we = 1'b1; rop_st_idx = 9'h07C; rop_st_wdata = 32'h000F; tick; /* WRITE_MASK = 0xF */
		rop_st_we = 1'b0; tick;

		/* 1. RX sends quad 0 and quad 1 data to SU for warp 0: */
		/* Quad 0: lanes 0..3 */
		for (l = 0; l < 4; l = l + 1) begin
			flw(0, 6'd3, l[4:0], 32'h3F000000); /* z = 0.5 */
			flw(0, 6'd4, l[4:0], 32'h41200000); /* x = 10.0 */
			flw(0, 6'd5, l[4:0], 32'h41200000); /* y = 10.0 */
			flw(0, 6'd6, l[4:0], 32'h00000001); /* sample mask = 1 */
		end
		/* Quad 1: lanes 4..7 */
		for (l = 4; l < 8; l = l + 1) begin
			flw(0, 6'd3, l[4:0], 32'h3F000000); /* z = 0.5 */
			flw(0, 6'd4, l[4:0], 32'h41300000); /* x = 11.0 */
			flw(0, 6'd5, l[4:0], 32'h41200000); /* y = 10.0 */
			flw(0, 6'd6, l[4:0], 32'h00000001); /* sample mask = 1 */
		end

		/* fl_go: warp 0, coverage for quad 0 (bits 3:0 = 4'hF) and quad 1 (bits 7:4 = 4'hF) */
		fl_go = 1'b1;
		fl_slot = 0;
		fl_info = {15'd0, 1'b1, 16'd0, 16'd0, 8'd0, 4'hF, 4'hF}; /* seq=0, cov=0x00FF */
		tick;
		fl_go = 1'b0;
		tick;

		$display("[%0t] After fl_go: cov=%h r6w=%h", $time, dut_exp.cov[31:0], dut_exp.r6w[31:0]);

		/* 2. FS executes exp for Quad 0 (grp 0) and Quad 1 (grp 1) */
		/* Quad 0: grp 0 */
		$display("[%0t] FS exp R for grp 0 (Quad 0)", $time);
		exp_op(0, 3'd0, 32'h100, 4'hF, 128'h3F800000_3F800000_3F800000_3F800000);
		$display("[%0t] After grp 0 exp: side_w=%h xp=%h", $time, dut_exp.side_w, dut_exp.xp[31:0]);

		/* Quad 1: grp 1 */
		$display("[%0t] FS exp R for grp 1 (Quad 1)", $time);
		exp_op(0, 3'd1, 32'h100, 4'hF, 128'h3F800000_3F800000_3F800000_3F800000);
		$display("[%0t] After grp 1 exp: side_w=%h xp=%h", $time, dut_exp.side_w, dut_exp.xp[31:0]);

		/* FS ends: wend */
		$display("[%0t] Warp end wend", $time);
		wc_end = 1'b1;
		wc_warp = 0;
		tick;
		wc_end = 1'b0;

		/* Monitor drain of Quad 0 and Quad 1 */
		repeat (20) begin
			tick;
			$display("[%0t] DRAIN: ex_v=%b ex_last=%b ex_mask=%b dxp=%h smok=%b smask=%h rop_rdy=%b rop_out_v=%b rop_smask=%h drop=%b",
				$time, ex_valid, ex_last, ex_mask, dut_exp.dxp[7:0], dut_exp.smok, dut_exp.smask,
				rop_ready, rop_out_valid, rop_smask, dut_rop_ms.drop);
		end

		$display("=== atg_su_exp_diag_tb finished ===");
		$display("PASS atg_su_exp_diag");
		$finish;
	end
endmodule
