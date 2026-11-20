/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_mmu_bridge_tb: Unit verification of am_mmu_bridge + atg_cp_mmu + atg_mmu
 * across 40-bit VA / 48-bit PA, L1 hit, multi-level walk, page fault
 * suppression, cached-TLB permission violation trapping, MC response vs
 * error collision arbitration, and exact multi-client in-flight counting.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_mmu_bridge_tb;
	localparam VA_BITS     = 40;
	localparam PA_BITS     = 48;
	localparam UNIT_ADDR_W = 40;
	localparam MC_ADDR_W   = 48;
	localparam LINE_BYTES  = 64;
	localparam LINE_SHIFT  = 6;
	localparam LINE_BITS   = LINE_BYTES * 8;
	localparam UNIT_LA_W   = UNIT_ADDR_W - LINE_SHIFT;
	localparam MC_LA_W     = MC_ADDR_W - LINE_SHIFT;
	localparam PPN_BITS    = PA_BITS - 12;
	localparam NUM_CLIENTS = 2;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	/* Two unit ports feeding two am_mmu_bridge instances */
	reg  [NUM_CLIENTS-1:0]            u_req_valid = 0;
	wire [NUM_CLIENTS-1:0]            u_req_ready;
	reg  [NUM_CLIENTS-1:0]            u_req_write = 0;
	reg  [NUM_CLIENTS-1:0]            u_req_exec = 0;
	reg  [NUM_CLIENTS*UNIT_LA_W-1:0]  u_req_line = 0;
	reg  [NUM_CLIENTS*LINE_BYTES-1:0] u_req_be = 0;
	reg  [NUM_CLIENTS*LINE_BITS-1:0]  u_req_wdata = 0;
	reg  [NUM_CLIENTS*8-1:0]          u_req_tag = 0;
	reg  [NUM_CLIENTS*4-1:0]          u_req_sess = 0;
	wire [NUM_CLIENTS-1:0]            u_rsp_valid;
	wire [NUM_CLIENTS-1:0]            u_rsp_write;
	wire [NUM_CLIENTS*8-1:0]          u_rsp_tag;
	wire [NUM_CLIENTS*LINE_BITS-1:0]  u_rsp_rdata;
	wire [NUM_CLIENTS-1:0]            u_rsp_error;

	wire [NUM_CLIENTS-1:0]            mmu_req_valid;
	wire [NUM_CLIENTS*4-1:0]          mmu_req_sess;
	wire [NUM_CLIENTS*VA_BITS-1:0]    mmu_req_va;
	wire [NUM_CLIENTS*2-1:0]          mmu_req_type;
	wire [NUM_CLIENTS-1:0]            mmu_ack;
	wire [NUM_CLIENTS*PA_BITS-1:0]    mmu_pa;
	wire [NUM_CLIENTS*6-1:0]          mmu_flags;
	wire [NUM_CLIENTS-1:0]            mmu_fault;

	wire [NUM_CLIENTS-1:0]            m_req_valid;
	reg  [NUM_CLIENTS-1:0]            m_req_ready = {NUM_CLIENTS{1'b1}};
	wire [NUM_CLIENTS-1:0]            m_req_write;
	wire [NUM_CLIENTS*MC_LA_W-1:0]    m_req_line;
	wire [NUM_CLIENTS*LINE_BYTES-1:0] m_req_be;
	wire [NUM_CLIENTS*LINE_BITS-1:0]  m_req_wdata;
	wire [NUM_CLIENTS*8-1:0]          m_req_tag;
	wire [NUM_CLIENTS-1:0]            m_req_chk;
	wire [NUM_CLIENTS-1:0]            m_req_tbl;
	wire [NUM_CLIENTS*6-1:0]          m_req_slot;
	wire [NUM_CLIENTS*4-1:0]          m_req_sess;
	wire [NUM_CLIENTS*2-1:0]          m_req_exec_type;
	reg  [NUM_CLIENTS-1:0]            m_rsp_valid = 0;
	reg  [NUM_CLIENTS-1:0]            m_rsp_write = 0;
	reg  [NUM_CLIENTS*8-1:0]          m_rsp_tag = 0;
	reg  [NUM_CLIENTS*LINE_BITS-1:0]  m_rsp_rdata = 0;
	reg  [NUM_CLIENTS-1:0]            m_rsp_error = 0;

	wire [NUM_CLIENTS-1:0]            perm_fv;
	wire [NUM_CLIENTS*4-1:0]          perm_fs;
	wire [NUM_CLIENTS*VA_BITS-1:0]    perm_fa;
	wire [NUM_CLIENTS*8-1:0]          brg_inflight;

	genvar gc;
	generate
		for (gc = 0; gc < NUM_CLIENTS; gc = gc + 1) begin : g_brg
			am_mmu_bridge #(
				.UNIT_ADDR_W(UNIT_ADDR_W), .MC_ADDR_W(MC_ADDR_W),
				.VA_BITS(VA_BITS), .PA_BITS(PA_BITS),
				.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
				.CHECK_PERM(1)
			) u_brg (
				.clk(clk), .rst_n(rst_n),
				.u_req_valid(u_req_valid[gc]), .u_req_ready(u_req_ready[gc]),
				.u_req_write(u_req_write[gc]), .u_req_exec(u_req_exec[gc]),
				.u_req_line(u_req_line[gc*UNIT_LA_W +: UNIT_LA_W]),
				.u_req_be(u_req_be[gc*LINE_BYTES +: LINE_BYTES]),
				.u_req_wdata(u_req_wdata[gc*LINE_BITS +: LINE_BITS]),
				.u_req_tag(u_req_tag[gc*8 +: 8]),
				.u_req_session(u_req_sess[gc*4 +: 4]),
				.u_req_chk(1'b0), .u_req_tbl(1'b0), .u_req_slot(6'd0),
				.u_rsp_valid(u_rsp_valid[gc]), .u_rsp_write(u_rsp_write[gc]),
				.u_rsp_tag(u_rsp_tag[gc*8 +: 8]),
				.u_rsp_rdata(u_rsp_rdata[gc*LINE_BITS +: LINE_BITS]),
				.u_rsp_error(u_rsp_error[gc]),
				.mmu_req_valid(mmu_req_valid[gc]),
				.mmu_req_session(mmu_req_sess[gc*4 +: 4]),
				.mmu_req_va(mmu_req_va[gc*VA_BITS +: VA_BITS]),
				.mmu_req_type(mmu_req_type[gc*2 +: 2]),
				.mmu_ack(mmu_ack[gc]),
				.mmu_pa(mmu_pa[gc*PA_BITS +: PA_BITS]),
				.mmu_flags(mmu_flags[gc*6 +: 6]),
				.mmu_fault(mmu_fault[gc]),
				.m_req_valid(m_req_valid[gc]), .m_req_ready(m_req_ready[gc]),
				.m_req_write(m_req_write[gc]),
				.m_req_line(m_req_line[gc*MC_LA_W +: MC_LA_W]),
				.m_req_be(m_req_be[gc*LINE_BYTES +: LINE_BYTES]),
				.m_req_wdata(m_req_wdata[gc*LINE_BITS +: LINE_BITS]),
				.m_req_tag(m_req_tag[gc*8 +: 8]),
				.m_req_chk(m_req_chk[gc]), .m_req_tbl(m_req_tbl[gc]),
				.m_req_slot(m_req_slot[gc*6 +: 6]),
				.m_req_session(m_req_sess[gc*4 +: 4]),
				.m_req_exec_type(m_req_exec_type[gc*2 +: 2]),
				.m_rsp_valid(m_rsp_valid[gc]), .m_rsp_write(m_rsp_write[gc]),
				.m_rsp_tag(m_rsp_tag[gc*8 +: 8]),
				.m_rsp_rdata(m_rsp_rdata[gc*LINE_BITS +: LINE_BITS]),
				.m_rsp_error(m_rsp_error[gc]),
				.perm_fault_valid(perm_fv[gc]),
				.perm_fault_session(perm_fs[gc*4 +: 4]),
				.perm_fault_addr(perm_fa[gc*VA_BITS +: VA_BITS]),
				.inflight_cnt(brg_inflight[gc*8 +: 8])
			);
		end
	endgenerate

	reg sb_we = 0, sb_re = 0;
	reg [5:0] sb_idx = 0;
	reg [31:0] sb_wdata = 0;
	wire [31:0] sb_rdata;
	wire cp_pt_we, cp_fl_trig, cp_fl_all;
	wire [3:0] cp_pt_sess, cp_fl_sess;
	wire [PPN_BITS-1:0] cp_pt_base;
	wire mmu_f_valid;
	wire [3:0] mmu_f_kind, mmu_f_sess;
	wire [2:0] mmu_f_client;
	wire [VA_BITS-1:0] mmu_f_addr;
	wire [15:0] mmu_inflight_unused;
	wire ctl_fv;
	wire [3:0] ctl_fk, ctl_fs;
	wire [7:0] ctl_fc;
	wire [VA_BITS-1:0] ctl_fa;

	atg_cp_mmu #(
		.VA_BITS(VA_BITS), .PA_BITS(PA_BITS), .NUM_CLIENTS(NUM_CLIENTS),
		.CLIENT_MC_MAP({8'd4, 8'd3})
	) u_cp_mmu (
		.clk(clk), .rst_n(rst_n),
		.sb_we(sb_we), .sb_re(sb_re), .sb_idx(sb_idx), .sb_wdata(sb_wdata), .sb_rdata(sb_rdata),
		.boot_caps(32'h00008A03), .device_caps(32'h12345678),
		.cp_pt_root_we(cp_pt_we), .cp_pt_root_session(cp_pt_sess), .cp_pt_root_base(cp_pt_base),
		.cp_flush_trigger(cp_fl_trig), .cp_flush_all(cp_fl_all), .cp_flush_session(cp_fl_sess),
		.bridge_inflight(brg_inflight),
		.client_mc_map({NUM_CLIENTS{8'd0}}),
		.mmu_fault_valid(mmu_f_valid), .mmu_fault_kind(mmu_f_kind),
		.mmu_fault_session(mmu_f_sess), .mmu_fault_client(mmu_f_client), .mmu_fault_addr(mmu_f_addr),
		.brg_fault_valid(perm_fv), .brg_fault_session(perm_fs), .brg_fault_addr(perm_fa),
		.ctl_fault_valid(ctl_fv), .ctl_fault_kind(ctl_fk), .ctl_fault_session(ctl_fs),
		.ctl_fault_mc_client(ctl_fc), .ctl_fault_addr(ctl_fa),
		.hcr_ridx(10'd0), .hcr_rdata(), .fault_session_clear(1'b0), .fault_session_tag(8'd0)
	);

	wire wlk_req_v;
	wire [PA_BITS-1:0] wlk_req_addr;
	reg wlk_rsp_v = 0;
	reg [63:0] wlk_rsp_d = 0;

	atg_mmu #(.NUM_CLIENTS(NUM_CLIENTS), .VA_BITS(VA_BITS), .PA_BITS(PA_BITS)) u_mmu (
		.clk(clk), .rst_n(rst_n),
		.client_req_valid(mmu_req_valid), .client_req_session(mmu_req_sess),
		.client_req_va(mmu_req_va), .client_req_type(mmu_req_type),
		.client_ack(mmu_ack), .client_pa(mmu_pa), .client_flags(mmu_flags), .client_fault(mmu_fault),
		.mem_req_fire(1'b0), .mem_rsp_fire(1'b0), .inflight_count(mmu_inflight_unused),
		.cp_pt_root_we(cp_pt_we), .cp_pt_root_session(cp_pt_sess), .cp_pt_root_base(cp_pt_base),
		.cp_flush_trigger(cp_fl_trig), .cp_flush_all(cp_fl_all), .cp_flush_session(cp_fl_sess),
		.fault_valid(mmu_f_valid), .fault_kind(mmu_f_kind), .fault_session(mmu_f_sess),
		.fault_client(mmu_f_client), .fault_addr(mmu_f_addr),
		.walker_mem_req_valid(wlk_req_v), .walker_mem_req_addr(wlk_req_addr),
		.walker_mem_req_ready(1'b1), .walker_mem_rsp_valid(wlk_rsp_v), .walker_mem_rsp_data(wlk_rsp_d)
	);

	/* 64-bit Page Table RAM indexed by low 16 bits of PA (aligned to 8 bytes) */
	reg [63:0] pt_mem [0:8191];
	always @(posedge clk) begin
		wlk_rsp_v <= 1'b0;
		if (!rst_n) begin
			wlk_rsp_v <= 1'b0;
			wlk_rsp_d <= 64'd0;
		end else if (wlk_req_v) begin
			wlk_rsp_v <= 1'b1;
			wlk_rsp_d <= pt_mem[wlk_req_addr[15:3]];
		end
	end

	task sb_wr;
		input [5:0] idx;
		input [31:0] val;
		begin
			@(posedge clk); #1;
			sb_we = 1'b1; sb_idx = idx; sb_wdata = val;
			@(posedge clk); #1;
			sb_we = 1'b0;
		end
	endtask

	task sb_rd_check;
		input [5:0] idx;
		input [31:0] exp;
		input [8*32-1:0] name;
		begin
			@(posedge clk); #1;
			sb_re = 1'b1; sb_idx = idx;
			#1;
			if (sb_rdata !== exp) begin
				$display("FAIL %0s: got 0x%08x expected 0x%08x", name, sb_rdata, exp);
				errors = errors + 1;
			end
			@(posedge clk); #1;
			sb_re = 1'b0;
		end
	endtask

	integer errors = 0;
	integer cyc;
	integer saw_mc_req0 = 0;
	integer saw_mc_bad = 0;
	integer saw_rsp0 = 0;
	integer saw_perm_ctl = 0;

	/* Monitor ctl_fv pulses */
	reg last_ctl_fv = 0;
	reg [3:0] cap_fk = 0, cap_fs = 0;
	reg [7:0] cap_fc = 0;
	reg [VA_BITS-1:0] cap_fa = 0;
	always @(posedge clk) begin
		if (ctl_fv) begin
			cap_fk <= ctl_fk;
			cap_fs <= ctl_fs;
			cap_fc <= ctl_fc;
			cap_fa <= ctl_fa;
			saw_perm_ctl <= saw_perm_ctl + 1;
		end
	end

	initial begin : main
		integer m;
		for (m = 0; m < 8192; m = m + 1) pt_mem[m] = 64'd0;
		/*
		 * VA_BITS = 40 -> 4-level 64b PT (9 bits/level: [39:39]=1, [38:30]=0, [29:21]=0x091, [20:12]=0x145):
		 * Root (session 1) = PPN 0x800000001 (PA 0x008000001000, low 16b = 0x1000)
		 * Test VA = 0x80_1234_5100 -> L3=0x001, L2=0x000, L1=0x091, L0=0x145
		 * Mapped RO (W=0, V=1) -> PPN 0x900000ABC (PA 0x9000_00AB_C000)
		 */
		pt_mem[(16'h1000 >> 3) + 16'h001] = {16'd0, 36'h000000002, 12'h001};
		pt_mem[(16'h2000 >> 3) + 16'h000] = {16'd0, 36'h000000003, 12'h001};
		pt_mem[(16'h3000 >> 3) + 16'h091] = {16'd0, 36'h000000004, 12'h001};
		pt_mem[(16'h4000 >> 3) + 16'h145] = {16'd0, 36'h900000ABC, 12'h003}; /* V=1, LOCAL=1, W=0, X=0 */

		repeat (3) @(posedge clk);
		rst_n = 1'b1;

		sb_rd_check(6'h36, 32'h00008A03, "boot_caps");
		sb_rd_check(6'h3E, 32'h12345678, "device_caps");

		/* Program 36-bit root PPN for session 1 via ROOT_PT_HI + ROOT_PT */
		sb_wr(6'h38, 32'd1);
		sb_wr(6'h3F, 32'h00000008);
		sb_wr(6'h39, 32'h00000001);

		/* 1. Client 0 Read of VA 0x80_1234_5100 -> 4-level walk -> PA 0x9000_00AB_C100 */
		@(posedge clk); #1;
		u_req_valid[0] = 1'b1;
		u_req_write[0] = 1'b0;
		u_req_exec[0]  = 1'b0;
		u_req_line[0*UNIT_LA_W +: UNIT_LA_W] = 40'h80_1234_5100 >> LINE_SHIFT;
		u_req_be[0*LINE_BYTES +: LINE_BYTES] = {LINE_BYTES{1'b1}};
		u_req_tag[0*8 +: 8] = 8'h2A;
		u_req_sess[0*4 +: 4] = 4'd1;
		@(posedge clk); #1;
		u_req_valid[0] = 1'b0;

		cyc = 0;
		while (!m_req_valid[0] && cyc < 40) begin
			@(posedge clk); #1;
			cyc = cyc + 1;
		end
		if (!m_req_valid[0]) begin
			$display("FAIL c0_walk: timeout waiting for m_req_valid");
			errors = errors + 1;
		end else if (m_req_line[0*MC_LA_W +: MC_LA_W] != (48'h9000_00AB_C100 >> LINE_SHIFT)) begin
			$display("FAIL c0_walk: wrong PA line 0x%x", m_req_line[0*MC_LA_W +: MC_LA_W]);
			errors = errors + 1;
		end

		/*Wait for adder tree to reflect inflight=1 before completing rsp */
		repeat (6) @(posedge clk);
		sb_rd_check(6'h3B, 32'd1, "inflight_1");

		/* Return response for Client 0 (u_rsp_valid registers m_rsp_valid at the posedge) */
		@(posedge clk); #1;
		m_rsp_valid[0] = 1'b1; m_rsp_tag[0*8 +: 8] = 8'h2A; m_rsp_rdata[0*LINE_BITS +: 32] = 32'hCAFEBABE;
		@(posedge clk); #1;
		m_rsp_valid[0] = 1'b0;
		if (!u_rsp_valid[0] || u_rsp_error[0] || u_rsp_tag[0*8 +: 8] != 8'h2A ||
		    u_rsp_rdata[0*LINE_BITS +: 32] != 32'hCAFEBABE) begin
			$display("FAIL c0_rsp: v=%b err=%b tag=%x data=%x", u_rsp_valid[0], u_rsp_error[0],
				u_rsp_tag[0*8 +: 8], u_rsp_rdata[0*LINE_BITS +: 32]);
			errors = errors + 1;
		end
		repeat (6) @(posedge clk);
		sb_rd_check(6'h3B, 32'd0, "inflight_0_after_rsp");

		/* 2. Cached L1-Hit Write on same Read-Only page -> perm fault without MC request! */
		saw_perm_ctl = 0;
		saw_mc_bad = 0;
		@(posedge clk); #1;
		u_req_valid[0] = 1'b1;
		u_req_write[0] = 1'b1;
		u_req_tag[0*8 +: 8] = 8'h33;
		@(posedge clk); #1;
		u_req_valid[0] = 1'b0;
		for (cyc = 0; cyc < 10; cyc = cyc + 1) begin
			@(posedge clk); #1;
			if (m_req_valid[0]) saw_mc_bad = 1;
			if (u_rsp_valid[0]) begin
				saw_rsp0 = saw_rsp0 + 1;
				if (!u_rsp_error[0] || u_rsp_tag[0*8 +: 8] != 8'h33) begin
					$display("FAIL c0_perm_rsp: err=%b tag=%x", u_rsp_error[0], u_rsp_tag[0*8 +: 8]);
					errors = errors + 1;
				end
			end
		end
		if (saw_mc_bad || saw_rsp0 != 1 || saw_perm_ctl != 1 || cap_fk != 4'd10 || cap_fc != 8'd3) begin
			$display("FAIL c0_perm_trap: mc=%0d rsp=%0d ctl=%0d fk=%0d fc=%0d",
				saw_mc_bad, saw_rsp0, saw_perm_ctl, cap_fk, cap_fc);
			errors = errors + 1;
		end
		sb_rd_check(6'h37, 32'h00000080, "fault_va_hi");
		sb_rd_check(6'h3D, 32'h12345100, "fault_va_lo");

		/* Clear sticky status via W1C */
		sb_wr(6'h3C, 32'd1);
		sb_rd_check(6'h3C, {19'd0, 4'd0, 4'd1, 4'd10, 1'b0}, "status_cleared");

		/* 3. Unmapped VA on Client 1 -> Walker fault (kind 9, client MC ID 4), suppressed from MC */
		saw_perm_ctl = 0;
		saw_mc_bad = 0;
		@(posedge clk); #1;
		u_req_valid[1] = 1'b1;
		u_req_write[1] = 1'b0;
		u_req_line[1*UNIT_LA_W +: UNIT_LA_W] = 40'h90_0000_2040 >> LINE_SHIFT;
		u_req_tag[1*8 +: 8] = 8'h77;
		u_req_sess[1*4 +: 4] = 4'd1;
		@(posedge clk); #1;
		u_req_valid[1] = 1'b0;
		for (cyc = 0; cyc < 25; cyc = cyc + 1) begin
			@(posedge clk); #1;
			if (m_req_valid[1]) saw_mc_bad = 1;
			if (u_rsp_valid[1] && !u_rsp_error[1]) errors = errors + 1;
		end
		if (saw_mc_bad || saw_perm_ctl != 1 || cap_fk != 4'd9 || cap_fc != 8'd4 || cap_fa != 40'h90_0000_2040) begin
			$display("FAIL c1_page_fault: mc=%0d ctl=%0d fk=%0d fc=%0d fa=%x",
				saw_mc_bad, saw_perm_ctl, cap_fk, cap_fc, cap_fa);
			errors = errors + 1;
		end

		repeat (6) @(posedge clk);
		sb_rd_check(6'h3B, 32'd0, "inflight_final_zero");

		/* 4. Response collision: Read 0x55 stays outstanding in MC while Exec (X=0) faults on L1 hit,
		 *    and m_rsp_valid[0] arrives on the exact cycle ST_ERR_RSP wants to emit error for 0x66. */
		@(posedge clk); #1;
		u_req_valid[0] = 1'b1;
		u_req_write[0] = 1'b0;
		u_req_exec[0]  = 1'b0;
		u_req_line[0*UNIT_LA_W +: UNIT_LA_W] = 40'h80_1234_5100 >> LINE_SHIFT;
		u_req_tag[0*8 +: 8] = 8'h55;
		u_req_sess[0*4 +: 4] = 4'd1;
		@(posedge clk); #1;
		u_req_valid[0] = 1'b0;
		cyc = 0;
		while (!m_req_valid[0] && cyc < 10) begin
			@(posedge clk); #1;
			cyc = cyc + 1;
		end
		while (!u_req_ready[0]) begin
			@(posedge clk); #1;
		end

		/* Now send Exec (X=0) on mapped page and inject m_rsp_valid right as perm_fault puts bridge in ST_ERR_RSP */
		@(posedge clk); #1;
		u_req_valid[0] = 1'b1;
		u_req_exec[0]  = 1'b1;
		u_req_tag[0*8 +: 8] = 8'h66;
		@(posedge clk); #1;
		u_req_valid[0] = 1'b0;
		u_req_exec[0]  = 1'b0;
		@(posedge clk); #1; /* bridge reaches ST_ERR_RSP at this posedge */
		m_rsp_valid[0] = 1'b1; m_rsp_tag[0*8 +: 8] = 8'h55; m_rsp_rdata[0*LINE_BITS +: 32] = 32'hDEADBEEF;
		saw_rsp0 = 0;
		@(posedge clk); #1;
		m_rsp_valid[0] = 1'b0;
		if (!u_rsp_valid[0] || u_rsp_error[0] || u_rsp_tag[0*8 +: 8] != 8'h55 ||
		    u_rsp_rdata[0*LINE_BITS +: 32] != 32'hDEADBEEF) begin
			$display("FAIL collision_mc_rsp: v=%b err=%b tag=%x", u_rsp_valid[0], u_rsp_error[0], u_rsp_tag[0*8 +: 8]);
			errors = errors + 1;
		end else begin
			saw_rsp0 = saw_rsp0 + 1;
		end
		@(posedge clk); #1;
		if (!u_rsp_valid[0] || !u_rsp_error[0] || u_rsp_tag[0*8 +: 8] != 8'h66) begin
			$display("FAIL collision_err_rsp: v=%b err=%b tag=%x", u_rsp_valid[0], u_rsp_error[0], u_rsp_tag[0*8 +: 8]);
			errors = errors + 1;
		end else begin
			saw_rsp0 = saw_rsp0 + 1;
		end
		if (saw_rsp0 != 2) errors = errors + 1;

		repeat (6) @(posedge clk);
		sb_rd_check(6'h3B, 32'd0, "inflight_after_collision");

		if (errors == 0)
			$display("PASS am_mmu_bridge");
		else
			$display("FAIL am_mmu_bridge (%0d errors)", errors);
		$finish;
	end
endmodule

`default_nettype wire
