/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_ghci2_slim_tb: verification testbench for GHCI 2.0 Slim MMIO architecture,
 * host STATE MMIO elimination, and structured command packets
 * (Phase 007 / ws001-p007).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_ghci2_slim_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer errors = 0;

	/* -------------------------------------------------------------
	 * 1. GHCI 2.0 Slim MMIO Register Bus Signals
	 * ------------------------------------------------------------- */
	reg reg_wr = 1'b0;
	reg [16:0] reg_waddr = 17'd0;
	reg [31:0] reg_wdata = 32'd0;
	reg [3:0] reg_wstrb = 4'h0;
	reg reg_rd = 1'b0;
	reg [16:0] reg_raddr = 17'd0;
	wire [31:0] reg_rdata;

	wire hcr_we;
	wire [9:0] hcr_widx;
	wire [31:0] hcr_wdata;
	wire [31:0] hcr_wmask;
	wire [9:0] hcr_ridx;
	wire alias_we;
	wire [9:0] alias_idx;
	wire [9:0] alias_ridx;

	wire [31:0] tb_ctl_rdata = (hcr_ridx == GHCI_STATUS[11:2]) ? 32'h00000001 : 32'h00000000;
	wire [31:0] tb_irq_rdata = 32'h00000000;
	wire [31:0] tb_ring_rdata = (hcr_ridx == GHCI_RING_BASE[11:2]) ? 32'h10000000 :
	                            (hcr_ridx == GHCI_RING_SIZE[11:2]) ? 32'h00001000 : 32'h00000000;
	wire [31:0] tb_fence_rdata = 32'h00000000;
	wire [31:0] tb_dbg_rdata = 32'h00000000;
	wire [31:0] tb_state_rdata = 32'h12345678;

	atg_cp_regs #(
		.CAPS(32'h00500002),
		.SLIM_MMIO(1)
	) u_slim_regs (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(reg_wr),
		.reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata),
		.reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd),
		.reg_raddr(reg_raddr),
		.reg_rdata(reg_rdata),
		.hcr_we(hcr_we),
		.hcr_widx(hcr_widx),
		.hcr_wdata(hcr_wdata),
		.hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx),
		.alias_we(alias_we),
		.alias_idx(alias_idx),
		.alias_ridx(alias_ridx),
		.ctl_rdata(tb_ctl_rdata),
		.irq_rdata(tb_irq_rdata),
		.ring_rdata(tb_ring_rdata),
		.fence_rdata(tb_fence_rdata),
		.dbg_rdata(tb_dbg_rdata),
		.state_rdata(tb_state_rdata),
		.x_rdata(32'd0),
		.perf_busy(4'd0),
		.perf_reset(1'b0),
		.win_en(),
		.diag_cp_pc(32'h00000100),
		.diag_cp_status(32'h00000002),
		.diag_pipe_fsm(32'h00000003)
	);

	/* -------------------------------------------------------------
	 * 2. Structured Command Sequencer & Decoder
	 * ------------------------------------------------------------- */
	reg [31:0] test_hdr = 32'd0;
	wire h_known;
	wire h_absent;
	wire [7:0] h_need;

	atg_cp_seq_dec #(.UNITS(8'hFF)) u_seq_dec (
		.hdr(test_hdr),
		.hdr_fw(1'b0),
		.h_known(h_known),
		.h_absent(h_absent),
		.h_need(h_need),
		.vendor(1'b0),
		.op(test_hdr[5:0]),
		.p(8'd0),
		.in_data(32'd0),
		.pay_bad()
	);

	reg seq_valid = 1'b0;
	wire seq_ready;
	reg [31:0] seq_data = 32'd0;
	wire kick;
	wire [2:0] kick_code;
	wire f_valid;
	wire [31:0] f_addr;
	wire [31:0] f_value;

	atg_cp_seq #(.UNITS(8'hFF)) u_seq (
		.clk(clk),
		.rst_n(rst_n),
		.n_valid(seq_valid),
		.n_ready(seq_ready),
		.n_data(seq_data),
		.fw_valid(1'b0),
		.fw_ready(),
		.fw_data(32'd0),
		.fw_active(1'b0),
		.fw_side(7'd0),
		.halt(1'b0),
		.uop_we(),
		.uop_idx(),
		.uop_wdata(),
		.kick(kick),
		.kick_code(kick_code),
		.inv(),
		.busy_in(9'd0),
		.vsync(1'b0),
		.f_valid(f_valid),
		.f_ready(1'b1),
		.f_op(),
		.f_addr(f_addr),
		.f_value(f_value),
		.f_aux(),
		.f_irq(),
		.f_busy(1'b0),
		.occ_count(40'd0),
		.occ_clear(),
		.busy(),
		.cmd_active(),
		.fault(),
		.fault_kind(),
		.fault_addr(),
		.fault_tag(),
		.u_fw(),
		.u_side(),
		.u_req(),
		.u_ok(1'b1)
	);

	/* -------------------------------------------------------------
	 * Helper tasks for MMIO reads/writes
	 * ------------------------------------------------------------- */
	task mmio_write;
		input [16:0] addr;
		input [31:0] data;
		begin
			@(posedge clk);
			reg_wr <= 1'b1;
			reg_waddr <= addr;
			reg_wdata <= data;
			reg_wstrb <= 4'hF;
			@(posedge clk);
			reg_wr <= 1'b0;
			reg_wstrb <= 4'h0;
		end
	endtask

	task mmio_read;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(posedge clk);
			reg_rd <= 1'b1;
			reg_raddr <= addr;
			@(posedge clk);
			reg_rd <= 1'b0;
			@(posedge clk);
			data = reg_rdata;
		end
	endtask

	/* Feed a packet dword into the sequencer */
	task seq_feed_dword;
		input [31:0] dw;
		begin
			@(posedge clk);
			seq_valid <= 1'b1;
			seq_data <= dw;
			@(posedge clk);
			while (!seq_ready) @(posedge clk);
			seq_valid <= 1'b0;
		end
	endtask

	reg [31:0] rdata;
	integer k;

	initial begin
		#20;
		rst_n = 1'b1;
		#20;

		$display("=== atg_ghci2_slim_tb: Starting Verification ===");

		/* ---------------------------------------------------------
		 * Step 1: Verify GHCI 2.0 Slim Identification & Capability Regs
		 * --------------------------------------------------------- */
		mmio_read(GHCI_2_REG_MAGIC, rdata);
		if (rdata !== GHCI_MAGIC_VALUE) begin
			$display("FAIL: MAGIC = %h (expected %h)", rdata, GHCI_MAGIC_VALUE);
			errors = errors + 1;
		end else begin
			$display("PASS: GHCI 2.0 MAGIC = 'GHCI'");
		end

		mmio_read(GHCI_2_REG_VERSION, rdata);
		if (rdata !== 32'h00020000) begin
			$display("FAIL: VERSION = %h (expected 00020000)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: GHCI 2.0 VERSION = 2.0 (0x00020000)");
		end

		mmio_read(GHCI_2_REG_DEVICE_CAPS, rdata);
		if (rdata !== 32'h00500002) begin
			$display("FAIL: DEVICE_CAPS = %h (expected 00500002)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: GHCI 2.0 DEVICE_CAPS = %h", rdata);
		end

		mmio_read(GHCI_2_REG_EXTCAP_PTR, rdata);
		if (rdata !== 32'h00000000) begin
			$display("FAIL: EXTCAP_PTR = %h (expected 00000000)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: GHCI 2.0 EXTCAP_PTR = 0 (no extended caps list)");
		end

		/* ---------------------------------------------------------
		 * Step 2: Verify Diagnostics & Scratchpad in Slim MMIO
		 * --------------------------------------------------------- */
		mmio_read(GHCI_2_REG_DIAG_CP_PC, rdata);
		if (rdata !== 32'h00000100) begin
			$display("FAIL: DIAG_CP_PC = %h (expected 00000100)", rdata);
			errors = errors + 1;
		end

		mmio_read(GHCI_2_REG_DIAG_CP_STATUS, rdata);
		if (rdata !== 32'h00000002) begin
			$display("FAIL: DIAG_CP_STATUS = %h (expected 00000002)", rdata);
			errors = errors + 1;
		end

		mmio_write(GHCI_2_REG_SCRATCH, 32'hCAFEBABE);
		mmio_read(GHCI_2_REG_SCRATCH, rdata);
		if (rdata !== 32'hCAFEBABE) begin
			$display("FAIL: SCRATCH = %h (expected CAFEBABE)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: GHCI 2.0 SCRATCH write/read at 0x048 successful");
		end

		/* ---------------------------------------------------------
		 * Step 3: Verify Control, Status, IRQ, Ring Registers Translation
		 * --------------------------------------------------------- */
		mmio_write(GHCI_2_REG_CTRL, 32'h00000001);
		if (hcr_widx !== GHCI_CTRL[11:2]) begin
			$display("FAIL: CTRL write translated to widx %d (expected %d)", hcr_widx, GHCI_CTRL[11:2]);
			errors = errors + 1;
		end

		mmio_write(GHCI_2_REG_RING_BASE_LO, 32'h10000000);
		if (hcr_widx !== GHCI_RING_BASE[11:2]) begin
			$display("FAIL: RING_BASE write translated to widx %d (expected %d)", hcr_widx, GHCI_RING_BASE[11:2]);
			errors = errors + 1;
		end

		mmio_write(GHCI_2_REG_RING_SIZE, 32'h00001000);
		if (hcr_widx !== GHCI_RING_SIZE[11:2]) begin
			$display("FAIL: RING_SIZE write translated to widx %d (expected %d)", hcr_widx, GHCI_RING_SIZE[11:2]);
			errors = errors + 1;
		end

		mmio_write(GHCI_2_REG_RING_WPTR, 32'h00000020);
		if (hcr_widx !== GHCI_RING_WPTR[11:2]) begin
			$display("FAIL: RING_WPTR (doorbell) write translated to widx %d (expected %d)", hcr_widx, GHCI_RING_WPTR[11:2]);
			errors = errors + 1;
		end else begin
			$display("PASS: GHCI 2.0 Doorbell (RING_WPTR) write to 0x030 verified");
		end

		/* ---------------------------------------------------------
		 * Step 4: Verify Complete Elimination of Host STATE MMIO
		 * --------------------------------------------------------- */
		/* Host writes to legacy STATE (0x1000..0x1BFC) must be blocked */
		mmio_write(17'h01000, 32'hA5A5A5A5);
		if (alias_we !== 1'b0) begin
			$display("FAIL: alias_we asserted on write to 0x1000! STATE still accessible via host MMIO!");
			errors = errors + 1;
		end

		mmio_write(17'h01100, 32'h5A5A5A5A);
		if (alias_we !== 1'b0) begin
			$display("FAIL: alias_we asserted on write to 0x1100!");
			errors = errors + 1;
		end

		/* Host reads from legacy STATE must return 0 */
		mmio_read(17'h01000, rdata);
		if (rdata !== 32'h00000000) begin
			$display("FAIL: Read from 0x1000 returned %h (expected 0)", rdata);
			errors = errors + 1;
		end

		/* Host reads outside 0x000..0x048 must return 0 */
		mmio_read(17'h00050, rdata);
		if (rdata !== 32'h00000000) begin
			$display("FAIL: Read from 0x050 returned %h (expected 0)", rdata);
			errors = errors + 1;
		end

		mmio_read(17'h00100, rdata);
		if (rdata !== 32'h00000000) begin
			$display("FAIL: Read from 0x100 returned %h (expected 0)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: Host STATE (0x1000..0x1BFC) and legacy offsets fully eliminated from MMIO");
		end

		/* ---------------------------------------------------------
		 * Step 5: Verify Structured Command Packet Decoding
		 * --------------------------------------------------------- */
		/* CMD_BIND_PIPELINE (0x20): 3 dwords */
		test_hdr = {16'd0, 8'd3, 8'h20};
		#1;
		if (!h_known || h_need !== 8'd2) begin
			$display("FAIL: CMD_BIND_PIPELINE decode failed: known=%b need=%d", h_known, h_need);
			errors = errors + 1;
		end

		/* CMD_SET_VIEWPORT (0x24): 7 dwords */
		test_hdr = {16'd0, 8'd7, 8'h24};
		#1;
		if (!h_known || h_need !== 8'd6) begin
			$display("FAIL: CMD_SET_VIEWPORT decode failed: known=%b need=%d", h_known, h_need);
			errors = errors + 1;
		end

		/* CMD_DRAW (0x27): 5 dwords */
		test_hdr = {16'd0, 8'd5, 8'h27};
		#1;
		if (!h_known || h_need !== 8'd4) begin
			$display("FAIL: CMD_DRAW decode failed: known=%b need=%d", h_known, h_need);
			errors = errors + 1;
		end

		/* CMD_DISPATCH (0x30): 4 dwords */
		test_hdr = {16'd0, 8'd4, 8'h30};
		#1;
		if (!h_known || h_need !== 8'd3) begin
			$display("FAIL: CMD_DISPATCH decode failed: known=%b need=%d", h_known, h_need);
			errors = errors + 1;
		end

		/* CMD_BARRIER (0x31): 4 dwords */
		test_hdr = {16'd0, 8'd4, 8'h31};
		#1;
		if (!h_known || h_need !== 8'd3) begin
			$display("FAIL: CMD_BARRIER decode failed: known=%b need=%d", h_known, h_need);
			errors = errors + 1;
		end

		/* CMD_EXECUTE_COMMANDS (0x32): 4 dwords */
		test_hdr = {16'd0, 8'd4, 8'h32};
		#1;
		if (!h_known || h_need !== 8'd3) begin
			$display("FAIL: CMD_EXECUTE_COMMANDS decode failed: known=%b need=%d", h_known, h_need);
			errors = errors + 1;
		end else begin
			$display("PASS: All GHCI 2.0 Structured Command Opcodes decoded correctly");
		end

		/* ---------------------------------------------------------
		 * Step 6: Verify Structured Command Execution in Sequencer
		 * --------------------------------------------------------- */
		/* Execute CMD_DRAW (0x27, 5 dwords: hdr, v_cnt, inst_cnt, first_v, first_inst) */
		seq_feed_dword({16'd0, 8'd5, 8'h27}); /* Header */
		seq_feed_dword(32'd3);                /* vertex_count = 3 */
		seq_feed_dword(32'd1);                /* instance_count = 1 */
		seq_feed_dword(32'd0);                /* first_vertex = 0 */
		seq_feed_dword(32'd0);                /* first_instance = 0 */

		/* Wait for kick pulse */
		for (k = 0; k < 10; k = k + 1) begin
			@(posedge clk);
			if (kick && kick_code === 3'd1) /* K_DRAW */
				k = 20;
		end
		if (k < 20) begin
			$display("FAIL: CMD_DRAW kick not received!");
			errors = errors + 1;
		end else begin
			$display("PASS: CMD_DRAW executed and triggered DRAW kick");
		end

		/* Execute CMD_DISPATCH (0x30, 4 dwords: hdr, gx, gy, gz) */
		seq_feed_dword({16'd0, 8'd4, 8'h30}); /* Header */
		seq_feed_dword(32'd16);               /* gx = 16 */
		seq_feed_dword(32'd1);                /* gy = 1 */
		seq_feed_dword(32'd1);                /* gz = 1 */

		for (k = 0; k < 10; k = k + 1) begin
			@(posedge clk);
			if (kick && kick_code === 3'd2) /* K_CS */
				k = 20;
		end
		if (k < 20) begin
			$display("FAIL: CMD_DISPATCH kick not received!");
			errors = errors + 1;
		end else begin
			$display("PASS: CMD_DISPATCH executed and triggered CS kick");
		end

		/* Execute CMD_FENCE (0x33, 5 dwords: hdr, addr_lo, addr_hi, seq_lo, seq_hi/flags) */
		seq_feed_dword({16'd0, 8'd5, 8'h33}); /* Header */
		seq_feed_dword(32'h00004000);         /* addr_lo */
		seq_feed_dword(32'h00000000);         /* addr_hi */
		seq_feed_dword(32'h00000042);         /* seq_lo */
		seq_feed_dword(32'h00000000);         /* seq_hi */

		for (k = 0; k < 10; k = k + 1) begin
			@(posedge clk);
			if (f_valid && f_addr === 32'h00004000 && f_value === 32'h00000042)
				k = 20;
		end
		if (k < 20) begin
			$display("FAIL: CMD_FENCE request not emitted!");
			errors = errors + 1;
		end else begin
			$display("PASS: CMD_FENCE executed and issued fence request (addr=%h, val=%h)", f_addr, f_value);
		end

		/* ---------------------------------------------------------
		 * Final Report
		 * --------------------------------------------------------- */
		#20;
		if (errors == 0) begin
			$display("PASS atg_ghci2_slim");
		end else begin
			$display("FAIL atg_ghci2_slim: %0d errors", errors);
		end
		$finish;
	end

endmodule
`default_nettype wire
