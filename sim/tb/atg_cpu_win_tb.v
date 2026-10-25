/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_win_tb: drives atg_cpu_win's core data port like atg_cpu_core
 * (valid held until ready) with a DMEM model (read latency 1), sub-bus
 * models, a STATE model (data the cycle after the index) and a ring model
 * for v_valid/v_done.  decode: DMEM, window, sub-bus and unmapped
 * accesses go to the right place with the right latency.  uop: the FIFO
 * fills, a full FIFO stalls (stall = 1) and the dwords come out in order
 * with their last bits.  packet: PKT_* reflect v_*, DONE waits for the
 * FIFO to drain and pulses v_done once.  irq: the three causes and IRQ_EN.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_win_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg d_valid = 1'b0, d_write = 1'b0;
	reg [31:0] d_addr = 0, d_wdata = 0;
	reg [3:0] d_be = 4'hF;
	wire d_ready;
	wire [31:0] d_rdata;
	wire m_en;
	wire [3:0] m_we;
	wire [31:0] m_addr, m_wdata;
	reg [31:0] m_rdata = 0;
	wire sb_we, sb_re;
	wire [5:0] sb_idx;
	wire [31:0] sb_wdata;
	wire [31:0] dma_rdata = sb_re && sb_idx == 6'h13 ? 32'h0000_0D13 : 32'd0;
	wire [31:0] fw_rdata = sb_re && sb_idx == 6'h22 ? 32'h0000_F022 : 32'd0;
	reg v_valid = 1'b0;
	reg [31:0] v_addr = 0;
	reg [15:0] v_dwords = 0;
	reg [7:0] v_tag = 0;
	wire v_done;
	wire fw_valid, fw_last, fw_active;
	reg fw_ready = 1'b0;
	wire [31:0] fw_data;
	wire [9:0] st_ridx;
	reg [31:0] st_rdata = 0;
	reg [31:0] fence_last = 32'h0FE0_0001;
	reg fence_ev = 1'b0;
	reg halt_req = 1'b0;
	wire irq, ev_result, stall;

	integer seed = 1;
	integer errors = 0;
	integer e0, i, n, lat;
	integer sb_writes = 0;
	integer m_accesses = 0;
	integer v_dones = 0;
	integer results = 0;
	integer stalls = 0;
	reg [5:0] last_sb_idx;
	reg [31:0] last_sb_data;
	reg [31:0] rd;
	reg [31:0] dmem [0:16383];
	reg [31:0] pop_data [0:63];
	reg pop_last [0:63];
	integer pops = 0;

	always #5 clk = !clk;

	atg_cpu_win dut (
		.clk(clk), .rst_n(rst_n),
		.d_valid(d_valid), .d_write(d_write), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be),
		.d_ready(d_ready), .d_rdata(d_rdata),
		.m_en(m_en), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_rdata(m_rdata),
		.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata),
		.dma_rdata(dma_rdata), .fw_rdata(fw_rdata),
		.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag), .v_done(v_done),
		.fw_valid(fw_valid), .fw_ready(fw_ready), .fw_data(fw_data), .fw_last(fw_last),
		.fw_active(fw_active),
		.st_ridx(st_ridx), .st_rdata(st_rdata), .fence_last(fence_last), .fence_ev(fence_ev),
		.halt_req(halt_req), .irq(irq), .ev_result(ev_result), .stall(stall)
	);

	/* DMEM model, STATE model and event counters. */
	always @(posedge clk) begin
		if (m_en) begin
			m_rdata <= dmem[m_addr[15:2]];
			if (m_we[0]) dmem[m_addr[15:2]][7:0] <= m_wdata[7:0];
			if (m_we[1]) dmem[m_addr[15:2]][15:8] <= m_wdata[15:8];
			if (m_we[2]) dmem[m_addr[15:2]][23:16] <= m_wdata[23:16];
			if (m_we[3]) dmem[m_addr[15:2]][31:24] <= m_wdata[31:24];
			m_accesses = m_accesses + 1;
		end
		st_rdata <= {23'h5A5A5A, st_ridx[8:0]};
		if (sb_we) begin
			sb_writes = sb_writes + 1;
			last_sb_idx = sb_idx;
			last_sb_data = sb_wdata;
		end
		if (v_done)
			v_dones = v_dones + 1;
		if (ev_result)
			results = results + 1;
		if (stall)
			stalls = stalls + 1;
		if (fw_valid && fw_ready) begin
			pop_data[pops] = fw_data;
			pop_last[pops] = fw_last;
			pops = pops + 1;
		end
	end

	/* One access; returns the latency in lat and the load data in rd. */
	task access;
		input w;
		input [31:0] a;
		input [31:0] data;
		begin
			@(negedge clk);
			d_valid = 1'b1;
			d_write = w;
			d_addr = a;
			d_wdata = data;
			lat = 1;
			#1;
			while (!d_ready) begin
				@(negedge clk);
				#1;
				lat = lat + 1;
			end
			rd = d_rdata;
			@(posedge clk);
			#1;
			d_valid = 1'b0;
		end
	endtask

	task expect;
		input [8*24-1:0] what;
		input [31:0] got;
		input [31:0] want;
		begin
			if (got !== want) begin
				$display("FAIL %0s: %h want %h", what, got, want);
				errors = errors + 1;
			end
		end
	endtask

	localparam [31:0] WIN = 32'hF000_0000;

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		for (i = 0; i < 16384; i = i + 1)
			dmem[i] = 32'hDEAD_0000 + i;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;

		/* decode */
		e0 = errors;
		access(1, 32'h0001_0100, 32'h1234_5678);
		expect("dmem store lat", lat, 2);
		access(0, 32'h0001_0100, 0);
		expect("dmem load", rd, 32'h1234_5678);
		expect("dmem load lat", lat, 2);
		access(0, 32'h0001_FFFC, 0);
		expect("dmem top", rd, 32'hDEAD_3FFF);
		expect("m_accesses", m_accesses, 3);
		access(1, WIN + 4 * 6'h10, 32'hAB);	/* DMA_AMB */
		expect("sb idx", last_sb_idx, 6'h10);
		expect("sb data", last_sb_data, 32'hAB);
		expect("sb lat", lat, 2);
		access(0, WIN + 4 * 6'h13, 0);
		expect("sb dma read", rd, 32'h0D13);
		access(0, WIN + 4 * 6'h22, 0);
		expect("sb fw read", rd, 32'hF022);
		expect("sb writes", sb_writes, 1);
		access(0, WIN + 4 * 6'h09, 0);
		expect("FENCE_LAST", rd, 32'h0FE0_0001);
		access(0, WIN + 4 * 6'h0A, 0);
		n = rd;
		access(0, WIN + 4 * 6'h0A, 0);
		if (rd - n < 2 || rd - n > 4) begin
			$display("FAIL CYCLE %0d then %0d", n, rd);
			errors = errors + 1;
		end
		access(1, WIN + 4 * 6'h07, 32'h1E3);
		expect("st_ridx", st_ridx, 9'h1E3);
		access(0, WIN + 4 * 6'h08, 0);
		expect("STATE_DATA", rd, {23'h5A5A5A, 9'h1E3});
		expect("STATE_DATA lat", lat, 2);
		/* Unmapped: answered at once with 0; a store goes nowhere. */
		access(1, 32'h0000_0100, 32'h55);
		access(1, 32'hF000_0100, 32'h55);
		access(0, 32'h8000_0000, 0);
		expect("unmapped", rd, 0);
		expect("unmapped lat", lat, 2);
		access(0, WIN + 4 * 6'h0E, 0);
		expect("own unused", rd, 0);
		expect("m_accesses 2", m_accesses, 3);
		expect("sb writes 2", sb_writes, 1);
		if (errors == e0)
			$display("PASS atg_cpu_win.decode");

		/* uop: fill 16 with fw_ready = 0, the 17th stalls. */
		e0 = errors;
		access(0, WIN + 4 * 6'h06, 0);
		expect("UOP_FREE empty", rd, 16);
		for (i = 0; i < 16; i = i + 1)
			access(1, WIN + 4 * ((i % 4 == 3) ? 6'h05 : 6'h04), 32'hC000_0000 + i);
		access(0, WIN + 4 * 6'h06, 0);
		expect("UOP_FREE full", rd, 0);
		expect("stalls before", stalls, 0);
		fork
			access(1, WIN + 4 * 6'h05, 32'hC000_0010);
			begin
				repeat (6) @(negedge clk);
				if (!stall) begin
					$display("FAIL no stall on a full FIFO");
					errors = errors + 1;
				end
				fw_ready = 1'b1;
			end
		join
		if (lat < 6) begin
			$display("FAIL full FIFO answered after %0d cycles", lat);
			errors = errors + 1;
		end
		/* Drain: 17 dwords in order (the TB pops while fw_ready). */
		while (pops < 17)
			@(negedge clk);
		fw_ready = 1'b0;
		for (n = 0; n < 17; n = n + 1) begin
			expect("uop data", pop_data[n], 32'hC000_0000 + n);
			expect("uop last", pop_last[n], (n % 4 == 3) || n == 16);
		end
		#1;
		expect("drained", fw_valid, 0);
		if (errors == e0)
			$display("PASS atg_cpu_win.uop");

		/* packet */
		e0 = errors;
		access(0, WIN + 4 * 6'h02, 0);
		expect("no packet", rd[31], 0);
		expect("fw_active idle", fw_active, 0);
		@(negedge clk);
		v_valid = 1'b1;
		v_addr = 32'h0040_1004;
		v_dwords = 16'd37;
		v_tag = 8'h5C;
		access(0, WIN + 4 * 6'h00, 0);
		expect("PKT_ADDR", rd, 32'h0040_1004);
		access(0, WIN + 4 * 6'h01, 0);
		expect("PKT_DWORDS", rd, 37);
		access(0, WIN + 4 * 6'h02, 0);
		expect("PKT_INFO", rd, 32'h8000_005C);
		expect("fw_active", fw_active, 1);
		access(1, WIN + 4 * 6'h04, 32'hAAAA_0001);
		access(1, WIN + 4 * 6'h05, 32'hAAAA_0002);
		access(1, WIN + 4 * 6'h03, 0);	/* DONE with 2 µops waiting */
		repeat (5) @(negedge clk);
		expect("v_done early", v_dones, 0);
		expect("fw_active held", fw_active, 1);
		/* While DONE waits for the FIFO the firmware does not see the packet again. */
		access(0, WIN + 4 * 6'h02, 0);
		expect("PKT_INFO in DONE wait", rd[31], 0);
		expect("fw_active in DONE wait", fw_active, 1);
		@(negedge clk);
		fw_ready = 1'b1;
		repeat (2) @(negedge clk);
		fw_ready = 1'b0;
		repeat (2) @(negedge clk);
		expect("v_done once", v_dones, 1);
		/* The ring drops v_valid a few cycles later; until then no packet. */
		access(0, WIN + 4 * 6'h02, 0);
		expect("after DONE", rd[31], 0);
		expect("fw_active after", fw_active, 0);
		@(negedge clk);
		v_valid = 1'b0;
		@(negedge clk);
		v_valid = 1'b1;
		v_tag = 8'h5D;
		access(0, WIN + 4 * 6'h02, 0);
		expect("next packet", rd, 32'h8000_005D);
		access(1, WIN + 4 * 6'h03, 0);	/* DONE, FIFO empty */
		repeat (4) @(negedge clk);
		expect("v_done 2", v_dones, 2);
		v_valid = 1'b0;
		access(1, WIN + 4 * 6'h03, 0);	/* DONE without a packet: ignored */
		repeat (3) @(negedge clk);
		expect("v_done 3", v_dones, 2);
		if (errors == e0)
			$display("PASS atg_cpu_win.packet");

		/* irq */
		e0 = errors;
		access(0, WIN + 4 * 6'h0D, 0);
		expect("IRQ_EN reset", rd, 0);
		@(negedge clk);
		v_valid = 1'b1;
		fence_ev = 1'b1;
		halt_req = 1'b1;
		@(negedge clk);
		fence_ev = 1'b0;
		#1;
		expect("masked", irq, 0);
		access(0, WIN + 4 * 6'h0C, 0);
		expect("IRQ causes", rd, 7);
		access(1, WIN + 4 * 6'h0D, 1);
		expect("packet irq", irq, 1);
		access(0, WIN + 4 * 6'h02, 0);	/* take the packet */
		#1;
		expect("taken", irq, 0);
		access(1, WIN + 4 * 6'h0D, 2);
		expect("fence irq", irq, 1);
		access(1, WIN + 4 * 6'h0C, 2);	/* W1C */
		#1;
		expect("fence cleared", irq, 0);
		access(1, WIN + 4 * 6'h0D, 4);
		expect("halt irq", irq, 1);
		@(negedge clk);
		halt_req = 1'b0;
		#1;
		expect("halt gone", irq, 0);
		access(1, WIN + 4 * 6'h0D, 7);
		access(0, WIN + 4 * 6'h0C, 0);
		expect("IRQ after", rd, 0);
		/* Packet done → the next packet raises the cause again. */
		access(1, WIN + 4 * 6'h03, 0);
		@(negedge clk);
		v_valid = 1'b0;
		@(negedge clk);
		v_valid = 1'b1;
		#1;
		expect("new packet irq", irq, 1);
		access(1, WIN + 4 * 6'h0B, 0);	/* RESULT */
		repeat (3) @(negedge clk);
		expect("ev_result", results, 1);
		if (errors == e0)
			$display("PASS atg_cpu_win.irq");
		if (errors == 0)
			$display("PASS atg_cpu_win");
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL timeout");
		$finish;
	end
endmodule

`default_nettype wire
