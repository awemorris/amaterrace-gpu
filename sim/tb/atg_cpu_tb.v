/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_tb: the whole atg_cpu (32-byte lines) running
 * sim/tb/cpu/cpu_top.S from its init images, with models of the ring
 * (v_valid until v_done), the sequencer (random fw_ready while
 * fw_active), STATE (data the cycle after the index), the host (HCR
 * reads and writes) and the AMB memory (random acceptance, in-order
 * responses after a delay).  packet: the class V packet is taken by the
 * interrupt, read by DMA, and comes out as µops in order with the STATE
 * word, then v_done once.  dma: the firmware's DMA write lands in memory,
 * MBOX1 and RESULT follow.  halt: halt_req parks the core (STOPPED).
 * reload: CPFW LOAD of cpu_reload.S from memory, which runs (its .data
 * word in MBOX3) and then faults with its PC (fault, CPFW_STATUS.FAULT).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_tb;
`include "ghci_regs.vh"

	localparam LB = 32;
	localparam LS = 5;
	localparam [31:0] MBASE = 32'h0040_0000;
	localparam MLINES = 2048;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg hcr_we = 1'b0;
	reg [9:0] hcr_widx = 0, hcr_ridx = 0;
	reg [31:0] hcr_wdata = 0, hcr_wmask = 32'hFFFF_FFFF;
	wire [31:0] hcr_rdata;
	reg v_valid = 1'b0;
	reg [31:0] v_addr = 0;
	reg [15:0] v_dwords = 0;
	reg [7:0] v_tag = 0;
	wire v_done;
	wire fw_valid, fw_last, fw_active;
	reg fw_ready = 1'b0;
	wire [31:0] fw_data;
	wire [8:0] st_ridx;
	reg [31:0] st_rdata = 0;
	reg fence_ev = 1'b0, halt_req = 1'b0, open = 1'b1;
	wire ev_result, stall, fault;
	wire [31:0] fault_addr;
	wire req_valid, req_write;
	reg req_ready = 1'b0;
	wire [31-LS:0] req_line;
	wire [LB-1:0] req_be;
	wire [LB*8-1:0] req_wdata;
	wire [7:0] req_tag;
	reg rsp_valid = 1'b0, rsp_write = 1'b0, rsp_error = 1'b0;
	reg [7:0] rsp_tag = 0;
	reg [LB*8-1:0] rsp_rdata = 0;

	integer seed = 1;
	integer errors = 0;
	integer e0, i, n;
	integer v_dones = 0, results = 0, faults = 0, nuops = 0;
	reg [31:0] r, w;
	reg [31:0] uop_d [0:31];
	reg uop_l [0:31];
	reg [31:0] last_fault;

	always #5 clk = !clk;

	atg_cpu #(
		.ADDR_W(32), .LINE_BYTES(LB), .LINE_SHIFT(LS),
		.IMEM_INIT("sim/tb/cpu/cpu_top.imem.hex"), .DMEM_INIT("sim/tb/cpu/cpu_top.dmem.hex")
	) dut (
		.clk(clk), .rst_n(rst_n),
		.hcr_we(hcr_we), .hcr_widx(hcr_widx), .hcr_wdata(hcr_wdata), .hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx), .hcr_rdata(hcr_rdata),
		.v_valid(v_valid), .v_addr(v_addr), .v_dwords(v_dwords), .v_tag(v_tag), .v_done(v_done),
		.fw_valid(fw_valid), .fw_ready(fw_ready), .fw_data(fw_data), .fw_last(fw_last),
		.fw_active(fw_active),
		.st_ridx(st_ridx), .st_rdata(st_rdata), .fence_last(32'h0000_0F0F), .fence_ev(fence_ev),
		.halt_req(halt_req), .open(open), .ev_result(ev_result), .stall(stall),
		.fault(fault), .fault_addr(fault_addr),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
		.req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	/* AMB memory: lines from MBASE, responses in order 3-10 cycles later. */
	reg [LB*8-1:0] amem [0:MLINES-1];
	reg [31-LS:0] q_line [0:63];
	reg q_wr [0:63];
	reg [7:0] q_tag [0:63];
	integer q_w = 0, q_r = 0, q_t = 0;

	always @(posedge clk) begin
		rsp_valid <= 1'b0;
		if (req_valid && req_ready) begin
			if (req_write)
				amem[req_line - (MBASE >> LS)] <= req_wdata;
			q_line[q_w % 64] = req_line;
			q_wr[q_w % 64] = req_write;
			q_tag[q_w % 64] = req_tag;
			q_w = q_w + 1;
		end
		if (q_w != q_r && q_t <= 0) begin
			rsp_valid <= 1'b1;
			rsp_write <= q_wr[q_r % 64];
			rsp_tag <= q_tag[q_r % 64];
			rsp_error <= 1'b0;
			rsp_rdata <= amem[q_line[q_r % 64] - (MBASE >> LS)];
			q_r = q_r + 1;
			q_t = 3 + ({$random(seed)} % 8);
		end else begin
			q_t = q_t - 1;
		end
	end

	/* Ring, sequencer and STATE models; event counters. */
	always @(posedge clk) begin
		st_rdata <= {23'h0ABCD, st_ridx};
		if (v_done) begin
			v_dones = v_dones + 1;
			v_valid <= 1'b0;
		end
		if (fw_valid && fw_ready) begin
			if (!fw_active) begin
				$display("FAIL µop taken outside a packet");
				errors = errors + 1;
			end
			uop_d[nuops % 32] = fw_data;
			uop_l[nuops % 32] = fw_last;
			nuops = nuops + 1;
		end
		if (ev_result)
			results = results + 1;
		if (fault) begin
			faults = faults + 1;
			last_fault = fault_addr;
		end
	end

	always @(negedge clk) begin
		req_ready = ($random(seed) & 3) != 0;
		fw_ready = fw_active && ($random(seed) & 1);
	end

	task hw;
		input [16:0] off;
		input [31:0] data;
		begin
			@(negedge clk);
			hcr_we = 1'b1;
			hcr_widx = off[11:2];
			hcr_wdata = data;
			@(negedge clk);
			hcr_we = 1'b0;
		end
	endtask

	task hr;
		input [16:0] off;
		begin
			@(negedge clk);
			hcr_ridx = off[11:2];
			#1;
			r = hcr_rdata;
		end
	endtask

	/* Poll an HCR word until (r & mask) == want, up to limit reads. */
	task poll;
		input [16:0] off;
		input [31:0] mask;
		input [31:0] want;
		input [8*24-1:0] what;
		begin
			n = 0;
			hr(off);
			while ((r & mask) != want && n < 20000) begin
				hr(off);
				n = n + 1;
			end
			if ((r & mask) != want) begin
				$display("FAIL %0s: %h", what, r);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		if ($value$plusargs("seed=%d", seed))
			;
		for (i = 0; i < MLINES; i = i + 1)
			amem[i] = {8{i[15:0], 16'hA5A5}};
		/* The packet: 6 dwords at line 16. */
		for (i = 0; i < 8; i = i + 1)
			amem[16][32 * i +: 32] = 32'hC0DE_0000 + i;
		repeat (3) @(negedge clk);
		rst_n = 1'b1;
		hw(GHCI_CPFW_MBOX0, MBASE + 100 * LB);
		hw(GHCI_CPFW_CTRL, 32'h2);	/* RUN */
		poll(GHCI_CPFW_STATUS, 32'hFF04, 32'h0104, "boot state and ALIVE");
		hr(GHCI_CPFW_VERSION);
		if (r != 32'h0001_0002) begin
			$display("FAIL CPFW_VERSION %h", r);
			errors = errors + 1;
		end

		/* packet */
		e0 = errors;
		repeat (20) @(negedge clk);
		v_addr = MBASE + 16 * LB;
		v_dwords = 6;
		v_tag = 8'h42;
		v_valid = 1'b1;
		n = 0;
		while (v_dones == 0 && n < 20000) begin
			@(negedge clk);
			n = n + 1;
		end
		repeat (5) @(negedge clk);
		if (v_dones != 1 || nuops != 7) begin
			$display("FAIL packet: %0d v_done, %0d µops", v_dones, nuops);
			errors = errors + 1;
		end
		for (i = 0; i < 7; i = i + 1) begin
			w = (i < 5) ? 32'hC0DE_0000 + i : (i == 5) ? {23'h0ABCD, 9'h1E3} : 32'hC0DE_0005;
			if (uop_d[i] !== w || uop_l[i] !== (i == 6)) begin
				$display("FAIL µop %0d: %h last %b want %h", i, uop_d[i], uop_l[i], w);
				errors = errors + 1;
			end
		end
		if (errors == e0)
			$display("PASS atg_cpu.packet");

		/* dma */
		e0 = errors;
		poll(GHCI_CPFW_MBOX0 + 4, 32'hFFFF_FFFF, 32'h600D_0001, "MBOX1");
		for (i = 0; i < 8; i = i + 1)
			if (amem[100][32 * i +: 32] !== 32'h5A00_0000 + 32'h111 * i) begin
				$display("FAIL DMA write word %0d: %h", i, amem[100][32 * i +: 32]);
				errors = errors + 1;
			end
		repeat (3) @(negedge clk);
		if (results != 1) begin
			$display("FAIL RESULT pulses %0d", results);
			errors = errors + 1;
		end
		if (errors == e0)
			$display("PASS atg_cpu.dma");

		/* halt */
		e0 = errors;
		halt_req = 1'b1;
		poll(GHCI_CPFW_STATUS, 32'hFF08, 32'h0208, "parked and stopped");
		if (dut.core_run) begin
			$display("FAIL core_run while parked");
			errors = errors + 1;
		end
		if (errors == e0)
			$display("PASS atg_cpu.halt");

		/* reload: cpu_reload.S at line 200 (IMEM) and 300 (DMEM). */
		e0 = errors;
		n = $fopen("sim/tb/cpu/cpu_reload.imem.hex", "r");
		for (i = 0; i < 32; i = i + 1)
			if ($fscanf(n, "%h", w) == 1)
				amem[200 + i / 8][32 * (i % 8) +: 32] = w;
		$fclose(n);
		n = $fopen("sim/tb/cpu/cpu_reload.dmem.hex", "r");
		if ($fscanf(n, "%h", w) == 1)
			amem[300][31:0] = w;
		$fclose(n);
		hw(GHCI_CPFW_IBASE, MBASE + 200 * LB);
		hw(GHCI_CPFW_IWORDS, 32);
		hw(GHCI_CPFW_DBASE, MBASE + 300 * LB);
		hw(GHCI_CPFW_DWORDS, 1);
		hw(GHCI_CPFW_CTRL, 32'h3);	/* LOAD, RUN */
		halt_req = 1'b0;
		poll(GHCI_CPFW_STATUS, 32'h13, 32'h01, "READY after LOAD");
		poll(GHCI_CPFW_MBOX0 + 8, 32'hFFFF_FFFF, 32'h600D_0002, "reloaded image runs");
		hr(GHCI_CPFW_MBOX0 + 12);
		if (r != 32'hDA7A_0001) begin
			$display("FAIL reloaded .data %h", r);
			errors = errors + 1;
		end
		hw(GHCI_CPFW_MBOX0, 1);
		poll(GHCI_CPFW_STATUS, 32'h2, 32'h2, "FAULT");
		repeat (2) @(negedge clk);
		if (faults != 1 || last_fault != 32'h28) begin
			$display("FAIL fault: %0d pulses, PC %h", faults, last_fault);
			errors = errors + 1;
		end
		if (errors == e0)
			$display("PASS atg_cpu.reload");
		if (errors == 0)
			$display("PASS atg_cpu");
		$finish;
	end

	initial begin
		#5000000;
		$display("FAIL timeout");
		$finish;
	end
endmodule

`default_nettype wire
