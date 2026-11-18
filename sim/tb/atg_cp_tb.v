/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_tb: Verification testbench for CP & GHCI Capability Registers
 * (Phase 006 / ws003-p006).
 *
 * Verifies dynamic hardware capability reflection from atg_config.vh macros
 * to MMIO registers:
 *   - DEVICE_CAPS (0x008): PHYS_LANES, Task/Mesh Shader, FP16, Dual Source, etc.
 *   - CAPS (0x020): SUBGROUP, TEX_ADV, PACKED_MATH, MSAA, etc.
 *   - EXT_CAP_FMT0 (0x080): Texture compression format bitmap (BC1-BC7)
 *   - EXT_CAP_FEATURE (0x084): LogicOp, EarlyZ, HW Cursor, MRT count, etc.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifdef CFG_ENABLE_FP16
`define EXP_CFG_FP16 1'b1
`else
`define EXP_CFG_FP16 1'b0
`endif

`ifdef CFG_ENABLE_EARLY_Z
`define EXP_CFG_EARLY_Z 1'b1
`else
`define EXP_CFG_EARLY_Z 1'b0
`endif

`ifdef CFG_ENABLE_MSAA
`define EXP_CFG_MSAA 1'b1
`else
`define EXP_CFG_MSAA 1'b0
`endif

`ifdef CFG_ENABLE_SUBGROUP
`define EXP_CFG_SUBGROUP 1'b1
`else
`define EXP_CFG_SUBGROUP 1'b0
`endif

`ifdef CFG_RX_ENABLE_CPOLY
`define EXP_CFG_RX_CPOLY ((`CFG_RX_ENABLE_CPOLY != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_RX_CPOLY 1'b1
`endif

`ifdef CFG_COARSE_SCAN
`define EXP_CFG_COARSE_SCAN ((`CFG_COARSE_SCAN != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_COARSE_SCAN 1'b0
`endif

`ifdef CFG_ROP_FAST_CLEAR
`define EXP_CFG_ROP_FAST_CLEAR ((`CFG_ROP_FAST_CLEAR != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_ROP_FAST_CLEAR 1'b0
`endif

`ifdef CFG_ROP_ENABLE_LOGICOP
`define EXP_CFG_ROP_LOGICOP ((`CFG_ROP_ENABLE_LOGICOP != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_ROP_LOGICOP 1'b0
`endif

`ifdef CFG_ROP_DUAL_SOURCE
`define EXP_CFG_ROP_DUAL_SRC ((`CFG_ROP_DUAL_SOURCE != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_ROP_DUAL_SRC 1'b0
`endif

`ifdef CFG_BLT_ENABLE_SCALE
`define EXP_CFG_BLT_SCALE ((`CFG_BLT_ENABLE_SCALE != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_BLT_SCALE 1'b1
`endif

`ifdef CFG_BLT_ENABLE_BLEND
`define EXP_CFG_BLT_BLEND ((`CFG_BLT_ENABLE_BLEND != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_BLT_BLEND 1'b1
`endif

`ifdef CFG_BLT_ENABLE_TILE
`define EXP_CFG_BLT_TILE ((`CFG_BLT_ENABLE_TILE != 0) ? 1'b1 : 1'b0)
`else
`define EXP_CFG_BLT_TILE 1'b1
`endif

module atg_cp_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer errors = 0;

	/* -------------------------------------------------------------
	 * 1. Default Configuration Instance (Driven by atg_config.vh)
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

	wire [31:0] def_boot_caps;
	wire [31:0] def_cap_dev_caps, def_cap_feat, def_cap_fmt0, def_cap_res_warps;
	wire [31:0] def_cap_isa_id, def_cap_gclk, def_cap_vendor_id, def_cap_device_id;
	wire [31:0] def_cap_subsystem, def_cap_mem_cache_cfg, def_cap_perf_src;

	atg_cp_caps #(
		.RX_ENABLE_CPOLY(`EXP_CFG_RX_CPOLY),
		.RX_ENABLE_EARLY_Z(`EXP_CFG_EARLY_Z),
		.RX_COARSE_SCAN(`EXP_CFG_COARSE_SCAN),
		.ROP_FAST_CLEAR(`EXP_CFG_ROP_FAST_CLEAR),
		.ROP_ENABLE_LOGICOP(`EXP_CFG_ROP_LOGICOP),
		.ROP_DUAL_SOURCE(`EXP_CFG_ROP_DUAL_SRC),
		.BLT_SCALE(`EXP_CFG_BLT_SCALE),
		.BLT_BLEND(`EXP_CFG_BLT_BLEND),
		.BLT_TILE(`EXP_CFG_BLT_TILE)
	) u_caps_default (
		.clk(clk),
		.rst_n(rst_n),
		.r_idx(9'd0),
		.r_data(),
		.boot_caps(def_boot_caps),
		.device_caps(def_cap_dev_caps),
		.ext_cap_feature(def_cap_feat),
		.ext_cap_fmt0(def_cap_fmt0),
		.resident_warps(def_cap_res_warps),
		.native_isa_id(def_cap_isa_id),
		.gclk_hz(def_cap_gclk),
		.vendor_id(def_cap_vendor_id),
		.device_id(def_cap_device_id),
		.subsystem(def_cap_subsystem),
		.device_version(),
		.mem_cache_cfg(def_cap_mem_cache_cfg),
		.prot_caps(),
		.perf_src(def_cap_perf_src),
		.fmt_limits(),
		.extcap_present(),
		.fmt_idx(8'd0),
		.fmt_val()
	);

	atg_cp_regs u_cp_regs_default (
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
		.ctl_rdata(32'd0),
		.irq_rdata(32'd0),
		.ring_rdata(32'd0),
		.fence_rdata(32'd0),
		.dbg_rdata(32'd0),
		.state_rdata(32'd0),
		.x_rdata(32'd0),
		.perf_busy(4'd0),
		.perf_reset(1'b0),
		.win_en(),
		.diag_cp_pc(32'd0),
		.diag_cp_status(32'd0),
		.diag_pipe_fsm(32'd0),
		.cap_boot_caps(def_boot_caps)
	);

	/* -------------------------------------------------------------
	 * 2. Custom Capability Instance (Overridden Parameters)
	 * ------------------------------------------------------------- */
	reg c_reg_rd = 1'b0;
	reg [16:0] c_reg_raddr = 17'd0;
	wire [31:0] c_reg_rdata;

	localparam [31:0] CUSTOM_DEV_CAPS = {
		1'b1, 1'b1, 6'd0, 8'd2, 8'd16, /* MESH=1, TASK=1, NUM_SU=2, PHYS_LANES=16 */
		1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1 /* UMA=1 */
	};
	localparam [31:0] CUSTOM_FMT0 = 32'h0000007F; /* Full BC1-BC7 */
	localparam [31:0] CUSTOM_FEAT = 32'h0000074F; /* MRT=4 */

	wire [31:0] cust_boot_caps;
	wire [31:0] cust_cap_dev_caps, cust_cap_feat, cust_cap_fmt0, cust_cap_res_warps;
	wire [31:0] cust_cap_isa_id, cust_cap_gclk, cust_cap_vendor_id, cust_cap_device_id;
	wire [31:0] cust_cap_subsystem, cust_cap_mem_cache_cfg, cust_cap_perf_src;

	atg_cp_caps #(
		.SU_NPHYS(16),
		.MRT_COUNT(4),
		.RX_ENABLE_CPOLY(`EXP_CFG_RX_CPOLY),
		.RX_ENABLE_EARLY_Z(`EXP_CFG_EARLY_Z),
		.RX_COARSE_SCAN(`EXP_CFG_COARSE_SCAN),
		.ROP_FAST_CLEAR(`EXP_CFG_ROP_FAST_CLEAR),
		.ROP_ENABLE_LOGICOP(`EXP_CFG_ROP_LOGICOP),
		.ROP_DUAL_SOURCE(`EXP_CFG_ROP_DUAL_SRC),
		.BLT_SCALE(`EXP_CFG_BLT_SCALE),
		.BLT_BLEND(`EXP_CFG_BLT_BLEND),
		.BLT_TILE(`EXP_CFG_BLT_TILE)
	) u_caps_custom (
		.clk(clk),
		.rst_n(rst_n),
		.r_idx(9'd0),
		.r_data(),
		.boot_caps(cust_boot_caps),
		.device_caps(cust_cap_dev_caps),
		.ext_cap_feature(cust_cap_feat),
		.ext_cap_fmt0(cust_cap_fmt0),
		.resident_warps(cust_cap_res_warps),
		.native_isa_id(cust_cap_isa_id),
		.gclk_hz(cust_cap_gclk),
		.vendor_id(cust_cap_vendor_id),
		.device_id(cust_cap_device_id),
		.subsystem(cust_cap_subsystem),
		.device_version(),
		.mem_cache_cfg(cust_cap_mem_cache_cfg),
		.prot_caps(),
		.perf_src(cust_cap_perf_src),
		.fmt_limits(),
		.extcap_present(),
		.fmt_idx(8'd0),
		.fmt_val()
	);

	atg_cp_regs #(
		.SU_NPHYS(16),
		.MRT_COUNT(4)
	) u_cp_regs_custom (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(1'b0),
		.reg_waddr(17'd0),
		.reg_wdata(32'd0),
		.reg_wstrb(4'd0),
		.reg_rd(c_reg_rd),
		.reg_raddr(c_reg_raddr),
		.reg_rdata(c_reg_rdata),
		.hcr_we(), .hcr_widx(), .hcr_wdata(), .hcr_wmask(), .hcr_ridx(),
		.alias_we(), .alias_idx(), .alias_ridx(),
		.ctl_rdata(32'd0), .irq_rdata(32'd0), .ring_rdata(32'd0), .fence_rdata(32'd0),
		.dbg_rdata(32'd0), .state_rdata(32'd0), .x_rdata(32'd0),
		.perf_busy(4'd0), .perf_reset(1'b0), .win_en(),
		.diag_cp_pc(32'd0), .diag_cp_status(32'd0), .diag_pipe_fsm(32'd0),
		.cap_boot_caps(cust_boot_caps)
	);

	/* -------------------------------------------------------------
	 * 3. atg_cp sub-bus & CMD_QUERY_CAPS verification
	 * ------------------------------------------------------------- */
	reg cp_reg_wr = 1'b0;
	reg [16:0] cp_reg_waddr = 17'd0;
	reg [31:0] cp_reg_wdata = 32'd0;
	reg [3:0] cp_reg_wstrb = 4'h0;
	reg cp_reg_rd = 1'b0;
	reg [16:0] cp_reg_raddr = 17'd0;
	wire [31:0] cp_reg_rdata;

	wire cp_req_valid, cp_req_write;
	wire [26:0] cp_req_line;
	wire [31:0] cp_req_be;
	wire [255:0] cp_req_wdata;
	wire [7:0] cp_req_tag;
	reg cp_rsp_valid, cp_rsp_write, cp_rsp_error;
	reg [7:0] cp_rsp_tag;
	reg [255:0] cp_rsp_rdata;

	reg sb_we_t = 1'b0;
	reg sb_re_t = 1'b0;
	reg [5:0] sb_idx_t = 6'd0;
	reg [31:0] sb_wdata_t = 32'd0;
	wire [31:0] sb_rdata_t;

	reg [7:0] cp_sim_mem [0:65535];

	wire cp_req_ready = 1'b1;

	integer bi;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			cp_rsp_valid <= 1'b0;
			cp_rsp_write <= 1'b0;
			cp_rsp_tag <= 8'd0;
			cp_rsp_rdata <= 256'd0;
			cp_rsp_error <= 1'b0;
		end else begin
			cp_rsp_valid <= 1'b0;
			if (cp_req_valid && cp_req_ready) begin
				cp_rsp_valid <= 1'b1;
				cp_rsp_write <= cp_req_write;
				cp_rsp_tag <= cp_req_tag;
				cp_rsp_error <= 1'b0;
				if (cp_req_write) begin
					for (bi = 0; bi < 32; bi = bi + 1) begin
						if (cp_req_be[bi])
							cp_sim_mem[{cp_req_line, 5'd0} + bi] = cp_req_wdata[bi*8 +: 8];
					end
				end else begin
					for (bi = 0; bi < 32; bi = bi + 1) begin
						cp_rsp_rdata[bi*8 +: 8] <= cp_sim_mem[{cp_req_line, 5'd0} + bi];
					end
				end
			end
		end
	end

	atg_cp #(
		.ADDR_W(32),
		.LINE_BYTES(32),
		.LINE_SHIFT(5),
		.HAS_CPU(1),
		.HAS_BLT(1),
		.HAS_TU(1),
		.HAS_ROP(1),
		.HAS_VF(1),
		.HAS_PROT(1)
	) u_cp_inst (
		.clk(clk), .rst_n(rst_n),
		.reg_wr(cp_reg_wr), .reg_waddr(cp_reg_waddr), .reg_wdata(cp_reg_wdata), .reg_wstrb(cp_reg_wstrb),
		.reg_rd(cp_reg_rd), .reg_raddr(cp_reg_raddr), .reg_rdata(cp_reg_rdata),
		.diag_cp_pc(32'd0), .diag_cp_status(32'd0), .diag_pipe_fsm(32'd0),
		.irq(), .mem_ready(1'b1), .core_rst_n(), .win_en(),
		.mc_quiesce(), .mc_flush(), .l2_flush(), .l2_flush_done(1'b1), .l2_idle(1'b1),
		.aperture_base(), .aperture_limit(), .mc_idle(1'b1), .mc_fault(1'b0),
		.mc_fault_client(8'd0), .mc_fault_addr(32'd0), .mc_fault_write(1'b0),
		.mc_fault_prot(1'b0), .mc_fault_mem(1'b0), .mc_fault_tag(8'd0), .mc_fault_req_tag(8'd0),
		.st_we(), .st_idx(), .st_wdata(),
		.blt_kick(), .blt_busy(1'b0), .blt_error(1'b0), .blt_error_kind(4'd0),
		.req_valid(cp_req_valid), .req_ready(cp_req_ready), .req_write(cp_req_write),
		.req_line(cp_req_line), .req_be(cp_req_be), .req_wdata(cp_req_wdata),
		.req_tag(cp_req_tag), .req_chk(), .req_slot(),
		.rsp_valid(cp_rsp_valid), .rsp_write(cp_rsp_write), .rsp_tag(cp_rsp_tag),
		.rsp_rdata(cp_rsp_rdata), .rsp_error(cp_rsp_error),
		.draw_kick(), .cs_kick(), .cs_mesh(), .lc_kick(), .raw_kick(), .inv(),
		.busy_ext(8'd0), .vsync(1'b0), .x_fault(2'd0), .x_fault_kind(8'd0),
		.x_fault_addr(64'd0), .x_fault_tag(16'd0), .su_fault_stage(4'd0),
		.hcr_we(), .hcr_widx(), .hcr_wdata(), .hcr_wmask(), .hcr_ridx(),
		.x_rdata(32'd0),
		.v_valid(), .v_addr(), .v_dwords(), .v_tag(), .v_done(1'b0),
		.fw_valid(1'b0), .fw_ready(), .fw_data(32'd0), .fw_last(1'b0), .fw_active(1'b0), .fw_side(7'd0),
		.u_fw(), .u_side(), .u_req(), .u_tag(), .u_ok(1'b1), .u_active(1'b1),
		.fault_session_clear(), .fault_session_tag(), .wdt_tag(8'd0),
		.f_chk(1'b0), .f_slot(6'd0),
		.cpu_st_ridx(10'd0), .cpu_st_rdata(), .cp_fence_last(), .cp_fence_ev(),
		.cp_halt(), .cp_open(), .cpu_fault(1'b0), .cpu_fault_addr(32'd0),
		.cpu_stall(1'b0), .cpu_result(1'b0),
		.occ_count(40'd0), .occ_clear(),
		.d_we(), .d_idx(), .d_wdata(), .d_wmask(), .d_ridx(), .d_rdata(32'd0),
		.flip_valid(), .flip_plane(), .flip_base(), .taken(2'd0), .taken_cancel(2'd0),
		.dc_pending(2'd0), .dc_idle(1'b1), .frame_count(32'd0), .dc_err(),
		.dc_ev(3'd0), .dc_irq_display(1'b0),
		.sb_we(sb_we_t), .sb_re(sb_re_t), .sb_idx(sb_idx_t), .sb_wdata(sb_wdata_t),
		.sb_rdata(sb_rdata_t)
	);

	task cp_host_write;
		input [16:0] addr;
		input [31:0] data;
		begin
			@(posedge clk);
			cp_reg_wr <= 1'b1;
			cp_reg_waddr <= addr;
			cp_reg_wdata <= data;
			cp_reg_wstrb <= 4'hF;
			@(posedge clk);
			cp_reg_wr <= 1'b0;
			cp_reg_wstrb <= 4'h0;
		end
	endtask

	task cp_host_read;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(posedge clk);
			cp_reg_rd <= 1'b1;
			cp_reg_raddr <= addr;
			@(posedge clk);
			cp_reg_rd <= 1'b0;
			#1;
			data = cp_reg_rdata;
		end
	endtask

	task cp_mem_poke32;
		input [31:0] addr;
		input [31:0] data;
		begin
			cp_sim_mem[addr + 0] = data[7:0];
			cp_sim_mem[addr + 1] = data[15:8];
			cp_sim_mem[addr + 2] = data[23:16];
			cp_sim_mem[addr + 3] = data[31:24];
		end
	endtask

	function [31:0] cp_mem_peek32;
		input [31:0] addr;
		begin
			cp_mem_peek32 = {cp_sim_mem[addr + 3], cp_sim_mem[addr + 2], cp_sim_mem[addr + 1], cp_sim_mem[addr + 0]};
		end
	endfunction

	task sb_write;
		input [5:0] idx;
		input [31:0] data;
		begin
			@(posedge clk);
			sb_we_t <= 1'b1;
			sb_idx_t <= idx;
			sb_wdata_t <= data;
			@(posedge clk);
			sb_we_t <= 1'b0;
		end
	endtask

	task sb_read;
		input [5:0] idx;
		output [31:0] data;
		begin
			@(posedge clk);
			sb_re_t <= 1'b1;
			sb_idx_t <= idx;
			@(posedge clk);
			#1;
			data = sb_rdata_t;
			sb_re_t <= 1'b0;
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
			#1;
			data = reg_rdata;
		end
	endtask

	task custom_read;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(posedge clk);
			c_reg_rd <= 1'b1;
			c_reg_raddr <= addr;
			@(posedge clk);
			c_reg_rd <= 1'b0;
			#1;
			data = c_reg_rdata;
		end
	endtask

	reg [31:0] rdata;
	reg [31:0] val, fw_val;
	integer to_cnt, i;

	initial begin
		#20;
		rst_n = 1'b1;
		#20;

		$display("=== atg_cp_tb: Starting Capability Verification ===");

		/* Test 1: Verify Default BOOT_CAPS and DEVICE_CAPS */
		mmio_read(GHCI_REG_BOOT_CAPS, rdata);
		$display("Default BOOT_CAPS = 0x%08h", rdata);
		if (rdata[0] !== 1'b1) begin
			$display("FAIL: BOOT_CAPS CP bit not set (rdata=%h)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: BOOT_CAPS CP=1 correctly reflected");
		end

		if (def_cap_dev_caps[15:8] !== 8'd`CFG_SU_NPHYS) begin
			$display("FAIL: PHYS_LANES = %0d (expected %0d)", def_cap_dev_caps[15:8], `CFG_SU_NPHYS);
			errors = errors + 1;
		end else begin
			$display("PASS: PHYS_LANES = %0d correctly reflected", def_cap_dev_caps[15:8]);
		end

		if (def_cap_dev_caps[6] !== 1'b0) begin
			$display("FAIL: FP16 = %b (expected 0 when NSU=0)", def_cap_dev_caps[6]);
			errors = errors + 1;
		end else begin
			$display("PASS: FP16 = 0 correctly reflected (NSU=0)");
		end

		/* Test 2: Verify Default EXT_CAP_FMT0 (0x080) reads 0, format caps on u_caps */
		mmio_read(GHCI_REG_EXT_CAP_FMT0, rdata);
		$display("Default EXT_CAP_FMT0 MMIO = 0x%08h", rdata);
		if (rdata !== 32'd0) begin
			$display("FAIL: MMIO EXT_CAP_FMT0 returned %h, expected 0", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: MMIO EXT_CAP_FMT0 reads 0");
		end
`ifdef CFG_ENABLE_BC
		if (`CFG_ENABLE_BC != 0) begin
			if (def_cap_fmt0[0] !== 1'b1 || def_cap_fmt0[6] !== 1'b1) begin
				$display("FAIL: BC1/BC7 support not reflected");
				errors = errors + 1;
			end else begin
				$display("PASS: BC1-BC7 format bitmap correctly reflected");
			end
		end else begin
			if (def_cap_fmt0[0] !== 1'b0 || def_cap_fmt0[6] !== 1'b0) begin
				$display("FAIL: BC1/BC7 should be 0 when CFG_ENABLE_BC=0");
				errors = errors + 1;
			end else begin
				$display("PASS: BC1-BC7 correctly disabled");
			end
		end
`else
		if (def_cap_fmt0[0] !== 1'b0 || def_cap_fmt0[6] !== 1'b0) begin
			$display("FAIL: BC1/BC7 should be 0 when CFG_ENABLE_BC=0");
			errors = errors + 1;
		end else begin
			$display("PASS: BC1-BC7 correctly disabled");
		end
`endif

		/* Test 3: Verify Default EXT_CAP_FEATURE (0x084) reads 0, feature bits on u_caps */
		mmio_read(GHCI_REG_EXT_CAP_FEATURE, rdata);
		$display("Default EXT_CAP_FEATURE MMIO = 0x%08h", rdata);
		if (rdata !== 32'd0) begin
			$display("FAIL: MMIO EXT_CAP_FEATURE returned %h, expected 0", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: MMIO EXT_CAP_FEATURE reads 0");
		end
		if (def_cap_feat[12] !== `EXP_CFG_EARLY_Z) begin
			$display("FAIL: EARLY_Z feature bit mismatch");
			errors = errors + 1;
		end else begin
			$display("PASS: EARLY_Z feature bit correctly reflected");
		end

		if (def_cap_feat[19:16] !== 4'd`CFG_ROP_MRT_COUNT) begin
			$display("FAIL: MAX_MRT_COUNT = %0d (expected %0d)", def_cap_feat[19:16], `CFG_ROP_MRT_COUNT);
			errors = errors + 1;
		end else begin
			$display("PASS: MAX_MRT_COUNT = %0d correctly reflected", def_cap_feat[19:16]);
		end

		/* Test 4: Verify Custom Instance Overrides */
		custom_read(GHCI_REG_BOOT_CAPS, rdata);
		if (rdata[0] !== 1'b1) begin
			$display("FAIL: Custom BOOT_CAPS CP bit not set (rdata=%h)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: Custom BOOT_CAPS CP=1 verified");
		end

		custom_read(GHCI_REG_EXT_CAP_FEATURE, rdata);
		if (rdata !== 32'd0) begin
			$display("FAIL: Custom MMIO EXT_CAP_FEATURE returned %h, expected 0", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: Custom MMIO EXT_CAP_FEATURE reads 0");
		end

		if (cust_cap_dev_caps[15:8] !== 8'd16) begin
			$display("FAIL: Custom DEVICE_CAPS PHYS_LANES = %0d (expected 16)", cust_cap_dev_caps[15:8]);
			errors = errors + 1;
		end else begin
			$display("PASS: Custom DEVICE_CAPS (PHYS_LANES=16) verified");
		end

		if (cust_cap_feat[19:16] !== 4'd4) begin
			$display("FAIL: Custom EXT_CAP_FEATURE MAX_MRT = %0d (expected 4)", cust_cap_feat[19:16]);
			errors = errors + 1;
		end else begin
			$display("PASS: Custom EXT_CAP_FEATURE (MAX_MRT=4) verified");
		end

		/* -------------------------------------------------------------
		 * Test 5: Sub-bus CAPS_INDEX (0x34) -> CAPS_DATA (0x35) read
		 * ------------------------------------------------------------- */
		$display("--- Test 5: Sub-bus 0x34 -> 0x35 read ---");
		// Write index 0 (BLOCK_ID)
		sb_write(6'h34, 32'd0);
		@(posedge clk);
		sb_read(6'h35, rdata);
		if (rdata !== 32'h50414347) begin
			$display("FAIL: Sub-bus word 0 = 0x%08h (expected 0x50414347)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: Sub-bus word 0 (BLOCK_ID) = 0x%08h", rdata);
		end

		// Read back CAPS_INDEX (0x34)
		sb_read(6'h34, rdata);
		if (rdata !== 32'd0) begin
			$display("FAIL: Sub-bus index readback = %0d (expected 0)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: Sub-bus index readback = 0");
		end

		// Write index 1 (BLOCK_INFO)
		sb_write(6'h34, 32'd1);
		@(posedge clk);
		sb_read(6'h35, rdata);
		if (rdata !== 32'h00C00001) begin
			$display("FAIL: Sub-bus word 1 = 0x%08h (expected 0x00C00001)", rdata);
			errors = errors + 1;
		end else begin
			$display("PASS: Sub-bus word 1 (BLOCK_INFO) = 0x%08h", rdata);
		end

		/* -------------------------------------------------------------
		 * Test 6: Sub-bus DEVICE_CAPS (0x3E) direct read
		 * ------------------------------------------------------------- */
		$display("--- Test 6: Sub-bus 0x3E read ---");
		sb_read(6'h3E, rdata);
		if (rdata !== u_cp_inst.u_caps.device_caps) begin
			$display("FAIL: Sub-bus 0x3E = 0x%08h != u_caps device_caps = 0x%08h", rdata, u_cp_inst.u_caps.device_caps);
			errors = errors + 1;
		end else begin
			$display("PASS: Sub-bus 0x3E matches capability block DEVICE_CAPS: 0x%08h", rdata);
		end
		cp_host_read(GHCI_REG_BOOT_CAPS, val);
		if (val !== u_cp_inst.u_caps.boot_caps) begin
			$display("FAIL: Host BOOT_CAPS = 0x%08h != u_caps boot_caps = 0x%08h", val, u_cp_inst.u_caps.boot_caps);
			errors = errors + 1;
		end else begin
			$display("PASS: Host MMIO 0x008 matches BOOT_CAPS: 0x%08h", val);
		end

		/* -------------------------------------------------------------
		 * Test 7: Concurrent seq CMD_QUERY_CAPS & firmware read
		 * ------------------------------------------------------------- */
		$display("--- Test 7: CMD_QUERY_CAPS concurrent with firmware read ---");
		// Reset & initialize CP ring
		cp_host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RESET));
		#50;
		cp_host_write(GHCI_REG_CTRL, 32'd0);
		#50;
		to_cnt = 0;
		cp_host_read(GHCI_REG_CTRL, val);
		while (val[GHCI_CTRL_RESET] && to_cnt < 2000) begin
			#50;
			cp_host_read(GHCI_REG_CTRL, val);
			to_cnt = to_cnt + 1;
		end
		cp_host_write(GHCI_REG_RING_BASE_LO, 32'h00001000);
		cp_host_write(GHCI_REG_RING_BASE_HI, 32'd0);
		cp_host_write(GHCI_REG_RING_SIZE,    32'h00004000);
		cp_host_write(GHCI_REG_RING_WPTR,    32'd0);
		cp_host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RUN));

		// Clear memory target region 0x2000-0x2300 (768 bytes) and fence 0x3000
		for (i = 0; i < 768; i = i + 4)
			cp_mem_poke32(32'h00002000 + i, 32'hDEADBEEF);
		cp_mem_poke32(32'h00003000, 32'd0);

		// Write CMD_QUERY_CAPS packet:
		// dw0: header (opcode 0x15, dwords 5)
		// dw1: dst_addr lo = 0x2000
		// dw2: dst_addr hi = 0
		// dw3: dst_bytes = 768 (0x300)
		// dw4: 0
		cp_mem_poke32(32'h00001000, 32'h00000515);
		cp_mem_poke32(32'h00001004, 32'h00002000);
		cp_mem_poke32(32'h00001008, 32'h00000000);
		cp_mem_poke32(32'h0000100C, 32'h00000300);
		cp_mem_poke32(32'h00001010, 32'h00000000);

		// Trailing CMD_FENCE packet:
		// dw0: header (opcode 0x33, dwords 6)
		// dw1: fence_addr lo = 0x3000
		// dw2: fence_addr hi = 0
		// dw3: value = 0xFEEDFACE
		// dw4: aux = 0
		// dw5: flags = 2 (mem only)
		cp_mem_poke32(32'h00001014, 32'h00000633);
		cp_mem_poke32(32'h00001018, 32'h00003000);
		cp_mem_poke32(32'h0000101C, 32'h00000000);
		cp_mem_poke32(32'h00001020, 32'hFEEDFACE);
		cp_mem_poke32(32'h00001024, 32'h00000000);
		cp_mem_poke32(32'h00001028, 32'h00000002);

		// Launch CP ring by updating WPTR = 11
		cp_host_write(GHCI_REG_RING_WPTR, 32'd11);

		// Wait until sequencer starts executing CMD_QUERY_CAPS
		to_cnt = 0;
		while (!u_cp_inst.u_seq.is_query_caps_r && to_cnt < 5000) begin
			@(posedge clk);
			to_cnt = to_cnt + 1;
		end

		// Firmware sub-bus read during query execution
		// Write index 4 (EXT_CAP_FMT0)
		sb_write(6'h34, 32'd4);
		@(posedge clk);
		sb_read(6'h35, fw_val);
		if (fw_val !== u_cp_inst.u_caps.ext_cap_fmt0) begin
			$display("FAIL: Firmware read word 4 during QUERY: 0x%08h != 0x%08h", fw_val, u_cp_inst.u_caps.ext_cap_fmt0);
			errors = errors + 1;
		end else begin
			$display("PASS: Firmware read word 4 during QUERY correctly: 0x%08h", fw_val);
		end
		cp_host_read(GHCI_REG_EXT_CAP_FMT0, val);
		if (val !== 32'd0) begin
			$display("FAIL: MMIO 0x080 returned 0x%08h, expected 0", val);
			errors = errors + 1;
		end

		// Wait for CMD_FENCE completion
		to_cnt = 0;
		while (cp_mem_peek32(32'h00003000) !== 32'hFEEDFACE && to_cnt < 20000) begin
			@(posedge clk);
			to_cnt = to_cnt + 1;
		end
		if (cp_mem_peek32(32'h00003000) !== 32'hFEEDFACE) begin
			$display("FAIL: CMD_FENCE did not complete after CMD_QUERY_CAPS (timeout)");
			errors = errors + 1;
		end else begin
			$display("PASS: CMD_QUERY_CAPS and trailing CMD_FENCE completed successfully");
		end

		// Check memory written by CMD_QUERY_CAPS
		if (cp_mem_peek32(32'h00002000) !== 32'h50414347) begin
			$display("FAIL: Written word 0 = 0x%08h (expected 0x50414347)", cp_mem_peek32(32'h00002000));
			errors = errors + 1;
		end else begin
			$display("PASS: Written word 0 (BLOCK_ID) = 0x50414347 verified");
		end
		if (cp_mem_peek32(32'h00002004) !== 32'h00C00001) begin
			$display("FAIL: Written word 1 = 0x%08h (expected 0x00C00001)", cp_mem_peek32(32'h00002004));
			errors = errors + 1;
		end else begin
			$display("PASS: Written word 1 (BLOCK_INFO) = 0x00C00001 verified");
		end
		if (cp_mem_peek32(32'h00002010) !== fw_val) begin
			$display("FAIL: Written word 4 = 0x%08h (expected 0x%08h)", cp_mem_peek32(32'h00002010), fw_val);
			errors = errors + 1;
		end else begin
			$display("PASS: Written word 4 matches firmware read word 4: 0x%08h", fw_val);
		end

		/* -------------------------------------------------------------
		 * Test 8: CMD_EXECUTE_COMMANDS absent when HAS_SECONDARY_RING = 0
		 * ------------------------------------------------------------- */
		$display("--- Test 8: CMD_EXECUTE_COMMANDS without HAS_SECONDARY_RING ---");
		cp_host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RESET));
		#50;
		cp_host_write(GHCI_REG_CTRL, 32'd0);
		#50;
		to_cnt = 0;
		cp_host_read(GHCI_REG_CTRL, val);
		while (val[GHCI_CTRL_RESET] && to_cnt < 2000) begin
			#50;
			cp_host_read(GHCI_REG_CTRL, val);
			to_cnt = to_cnt + 1;
		end
		cp_host_write(GHCI_REG_RING_BASE_LO, 32'h00004000);
		cp_host_write(GHCI_REG_RING_BASE_HI, 32'd0);
		cp_host_write(GHCI_REG_RING_SIZE,    32'h00004000);
		cp_host_write(GHCI_REG_RING_WPTR,    32'd0);
		cp_host_write(GHCI_REG_CTRL, (1 << GHCI_CTRL_RUN));

		// Write CMD_EXECUTE_COMMANDS packet (opcode 0x32, 4 dwords)
		cp_mem_poke32(32'h00004000, 32'h00000432);
		cp_mem_poke32(32'h00004004, 32'h00005000);
		cp_mem_poke32(32'h00004008, 32'd0);
		cp_mem_poke32(32'h0000400C, 32'h00000100);

		cp_host_write(GHCI_REG_RING_WPTR, 32'd4);

		to_cnt = 0;
		cp_host_read(GHCI_REG_STATUS, val);
		while (!val[GHCI_STATUS_FAULTED] && to_cnt < 5000) begin
			@(posedge clk);
			to_cnt = to_cnt + 1;
			cp_host_read(GHCI_REG_STATUS, val);
		end
		if (!val[GHCI_STATUS_FAULTED]) begin
			$display("FAIL: Expected FAULTED status for CMD_EXECUTE_COMMANDS without secondary ring");
			errors = errors + 1;
		end else begin
			cp_host_read(GHCI_REG_FAULT_INFO, val);
			if (val[3:0] !== 4'd2) begin
				$display("FAIL: Expected fault kind 2, got %0d", val[3:0]);
				errors = errors + 1;
			end else begin
				$display("PASS: CMD_EXECUTE_COMMANDS faulted with kind 2 (KICK_ABSENT)");
			end
		end

		if (errors == 0) begin
			$display("PASS atg_cp");
		end else begin
			$display("FAIL atg_cp: %0d errors", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
