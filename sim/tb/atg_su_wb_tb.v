/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_wb_tb: the write-back arbiter (NPHYS 8, 6 short and 6 long
 * sources).  prio: a short result always takes the port, a long beat that
 * writes waits for a free cycle and raises wb_stall after 4 cycles, a
 * beat without data is taken at once; release: random long traffic under
 * random short traffic gives one release per l_last, also without data,
 * and every write lands in a model RF; input: VF/RX lane words become
 * one-lane group writes, also while short results hold the port.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_wb_tb;
	localparam NPHYS = 8;
	localparam DW = NPHYS * 32;
	localparam NS = 6, NL = 6;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg [NS-1:0] s_valid = 0;
	reg [NS*2-1:0] s_warp = 0;
	reg [NS*2-1:0] s_grp = 0;
	reg [NS*7-1:0] s_rd = 0;
	reg [NS*DW-1:0] s_data = 0;
	reg [NS*NPHYS-1:0] s_lanes = 0;
	reg [NL-1:0] l_valid = 0;
	wire [NL-1:0] l_ready;
	reg [NL*2-1:0] l_warp = 0;
	reg [NL*2-1:0] l_grp = 0;
	reg [NL*7-1:0] l_rd = 0;
	reg [NL*DW-1:0] l_data = 0;
	reg [NL*NPHYS-1:0] l_lanes = 0;
	reg [NL-1:0] l_wr = 0, l_last = 0;
	reg [NL*3-1:0] l_sbe = 0, l_cls = 0;
	reg [1:0] in_we = 0;
	reg [3:0] in_warp = 0;
	reg [11:0] in_reg = 0;
	reg [9:0] in_lane = 0;
	reg [63:0] in_data = 0;
	wire w_en, rel_valid, rq_push, wb_stall;
	wire [1:0] w_warp, w_grp, rel_warp;
	wire [5:0] w_reg;
	wire [DW-1:0] w_data, rq_data;
	wire [NPHYS-1:0] w_lanes;
	wire [2:0] rel_sbe, rel_cls;
	integer seed = 1;
	integer errors = 0;
	integer i, k, n_last, n_rel, n_acc, n_beats, cyc;

	always #5 clk = !clk;

	atg_su_wb #(.NPHYS(NPHYS), .NS(NS), .NL(NL)) dut (
		.clk(clk), .rst_n(rst_n), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp),
		.s_rd(s_rd), .s_data(s_data), .s_lanes(s_lanes), .l_valid(l_valid),
		.l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data),
		.l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls),
		.in_we(in_we), .in_warp(in_warp), .in_reg(in_reg), .in_lane(in_lane),
		.in_data(in_data), .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg),
		.w_data(w_data), .w_lanes(w_lanes), .rel_valid(rel_valid), .rel_warp(rel_warp),
		.rel_sbe(rel_sbe), .rel_cls(rel_cls), .rq_push(rq_push), .rq_data(rq_data),
		.wb_stall(wb_stall)
	);

	/* The model RF, filled from w_*. */
	reg [31:0] rf [0:4*64*4*NPHYS-1];
	always @(posedge clk)
		if (w_en)
			for (k = 0; k < NPHYS; k = k + 1)
				if (w_lanes[k])
					rf[((w_warp * 64 + w_reg) * 4 + w_grp) * NPHYS + k] <= w_data[k*32 +: 32];

	task fail;
		input [8*40-1:0] what;
		begin
			$display("FAIL atg_su_wb.%0s", what);
			errors = errors + 1;
		end
	endtask

	/* Release traffic: each long source sends random beats; the TB checks
	 * at every accepted beat. */
	reg [31:0] beat_id [0:NL-1];
	reg [6:0] want_rd;
	integer src;

	task new_beat;
		input integer s0;
		begin
			l_valid[s0] = 1'b1;
			l_wr[s0] = $random(seed) & 1;
			l_last[s0] = $random(seed) & 1;
			l_warp[s0*2 +: 2] = s0 & 3;
			l_grp[s0*2 +: 2] = beat_id[s0] & 3;
			l_rd[s0*7 +: 7] = (s0 * 8 + (beat_id[s0] >> 2) % 8) & 63;
			l_sbe[s0*3 +: 3] = beat_id[s0] & 7;
			l_cls[s0*3 +: 3] = 3'd2;
			l_lanes[s0*NPHYS +: NPHYS] = 8'hFF;
			for (k = 0; k < NPHYS; k = k + 1)
				l_data[s0*DW + k*32 +: 32] = {s0[7:0], beat_id[s0][15:0], k[7:0]};
		end
	endtask

	initial begin
		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		@(negedge clk);
		/* prio */
		s_valid = 6'b000001;
		s_rd[6:0] = 7'd3;
		s_lanes[7:0] = 8'h0F;
		s_data[31:0] = 32'hAAAA0001;
		l_valid = 6'b010100;
		l_wr = 6'b000100;
		l_last = 6'b010000;
		l_rd[2*7 +: 7] = 7'd5;
		l_data[2*DW +: 32] = 32'hBBBB0002;
		l_sbe[4*3 +: 3] = 3'd2;
		for (i = 0; i < 10; i = i + 1) begin
			#1;
			if (!w_en || w_reg !== 6'd3 || w_data[31:0] !== 32'hAAAA0001 || w_lanes !== 8'h0F)
				fail("prio short");
			if (l_ready[2])
				fail("prio long beat during short");
			if (i == 0 && (l_ready[4] !== 1'b1 || !rel_valid || rel_sbe !== 3'd2))
				fail("prio beat without data");
			if ((i >= 5) !== wb_stall)
				fail("prio wb_stall");
			@(negedge clk);
			l_valid[4] = 1'b0;
		end
		s_valid = 0;
		#1;
		if (!l_ready[2] || !w_en || w_reg !== 6'd5 || w_data[31:0] !== 32'hBBBB0002 || rel_valid)
			fail("prio long beat in free cycle");
		@(negedge clk);
		l_valid = 0;
		#1;
		if (wb_stall)
			fail("prio wb_stall after");
		if (errors == 0)
			$display("PASS atg_su_wb.prio");
		/* release */
		n_last = 0;
		n_rel = 0;
		n_acc = 0;
		n_beats = 0;
		for (i = 0; i < NL; i = i + 1) begin
			beat_id[i] = 0;
			new_beat(i);
		end
		for (cyc = 0; cyc < 3000; cyc = cyc + 1) begin
			/* Short traffic to registers 48-63 of warp 0 (not used by beats). */
			s_valid = ($random(seed) & 1) ? (6'd1 << ($unsigned($random(seed)) % NS)) : 6'd0;
			for (k = 0; k < NS; k = k + 1) begin
				s_rd[k*7 +: 7] = 7'd48 + ($unsigned($random(seed)) % 15);
				s_warp[k*2 +: 2] = 2'd0;
				s_grp[k*2 +: 2] = $random(seed);
				s_lanes[k*NPHYS +: NPHYS] = $random(seed);
			end
			#1;
			if (rel_valid !== (|(l_ready & l_last)))
				fail("release pulse");
			if (|(l_ready & (l_ready - 1'b1)))
				fail("release two beats");
			for (src = 0; src < NL; src = src + 1) begin
				if (l_ready[src]) begin
					n_acc = n_acc + 1;
					if (l_last[src]) begin
						n_last = n_last + 1;
						if (rel_sbe !== (beat_id[src] & 7) || rel_warp !== (src & 3))
							fail("release entry");
					end
					if (l_wr[src] && (|s_valid))
						fail("release write beat with short");
				end
			end
			if (rel_valid)
				n_rel = n_rel + 1;
			@(negedge clk);
			for (src = 0; src < NL; src = src + 1) begin
				if (l_ready[src]) begin
					/* Check the beat landed (written beats only). */
					beat_id[src] = beat_id[src] + 1;
					n_beats = n_beats + 1;
					new_beat(src);
					if (($random(seed) & 3) == 0)
						l_valid[src] = 1'b0;
				end else if (!l_valid[src] && ($random(seed) & 1)) begin
					new_beat(src);
				end
			end
		end
		s_valid = 0;
		l_valid = 0;
		@(negedge clk);
		if (n_rel != n_last || n_acc < 1000)
			fail("release counts");
		if (errors == 0)
			$display("PASS atg_su_wb.release");
		/* input: VF lane words while short results hold the port, then RX too. */
		s_valid = 6'b000010;
		s_rd[7 +: 7] = 7'd60;
		s_warp[2 +: 2] = 2'd1;
		for (i = 0; i < 6; i = i + 1) begin
			in_we = i < 4 ? 2'b01 : 2'b11;
			in_warp = {2'd3, 2'd2};
			in_reg = {6'd20, 6'd10};
			in_lane = {5'd31 - i[4:0], i[4:0] * 5'd5};
			in_data = {32'hC0DE0000 | i, 32'hF00D0000 | i};
			#1;
			if (!wb_stall && i > 0)
				fail("input wb_stall");
			@(negedge clk);
		end
		in_we = 0;
		s_valid = 0;
		repeat (12) @(negedge clk);
		for (i = 0; i < 6; i = i + 1) begin
			if (rf[((2 * 64 + 10) * 4 + (i * 5) / 8) * NPHYS + (i * 5) % 8] !== (32'hF00D0000 | i))
				fail("input VF word");
			if (i >= 4 && rf[((3 * 64 + 20) * 4 + (31 - i) / 8) * NPHYS + (31 - i) % 8] !==
			    (32'hC0DE0000 | i))
				fail("input RX word");
		end
		if (errors == 0)
			$display("PASS atg_su_wb.input");
		if (errors == 0)
			$display("PASS atg_su_wb");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL atg_su_wb timeout");
		$finish;
	end
endmodule

`default_nettype wire
