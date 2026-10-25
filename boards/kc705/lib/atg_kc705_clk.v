/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_kc705_clk: The KC705's clocks: SYSCLK 200 MHz (differential) →
 * MMCME2 → gclk (1000 MHz / GCLK_DIVIDE), the MIG reference, and the pixel clocks (BUFGMUX
 * by PCLK_SEL); resets synchronised per domain.  See
 * spec/boards/kc705/lib/atg_kc705_clk.md.
 *
 * SYSCLK goes through IBUFDS.  Its output, sys_cc, goes straight to the
 * MIG's PLL (the MIG's system clock "No Buffer": the dedicated route from
 * the clock-capable pin AD12 to the CMT of bank 33, as the MIG's own
 * IBUFGDS has in the KC705 reference; ws288 p024: through a BUFG the
 * calibration did not complete) and to a BUFG: that is ref_clk (200 MHz,
 * the MIG's IDELAYCTRL reference, "No Buffer") and the input of three
 * clock managers:
 *
 *   gclk, MMCM: DIVCLK 1, MULT 5: VCO 1000 MHz, O0 GCLK_DIVIDE (2 to
 *          128; the board top gives it, with GCLK_HZ to match).  The
 *          default 50 (20 MHz) is a placeholder, not the target: the
 *          clock is chosen in the timing work (ws288 p025).
 *   sel 0 (640x480), PLL: DIVCLK 5, MULT 34: VCO 1360 MHz (PFD 40),
 *          O0 54 -> 25.185 MHz (VESA 25.175: +0.04 %).
 *   sel 1 (720p), MMCM: DIVCLK 10, MULT 59.375: VCO 1187.5 MHz (PFD 20),
 *          O0 16 -> 74.21875 MHz (CEA 74.25: -0.04 %).
 *
 * Values referenced: DS182 / UG472 (7 Series -2: MMCM VCO 600-1440 MHz,
 * PFD 10-500 MHz; PLL VCO 800-1866 MHz, PFD 19-500 MHz; CLKFBOUT_MULT_F
 * and CLKOUT0_DIVIDE_F in steps of 0.125), not re-checked against the
 * data sheet (not built yet).  The KC705 needs no 5 x pixel
 * clock: its HDMI is the ADV7511's parallel input.  sel comes from gclk:
 * BUFGMUX switches without a glitch while both inputs run, and the DC
 * changes PCLK_SEL with ENABLE = 0.
 *
 * Resets: each domain's reset is "CPU_RESET released and its clock
 * manager locked", taken into the domain through am_sync (two flops).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_kc705_clk #(
	parameter integer GCLK_DIVIDE = 50	/* gclk = 1000 MHz / GCLK_DIVIDE */
) (
	input wire sys_clk_p,
	input wire sys_clk_n,
	input wire cpu_reset,
	input wire pclk_sel,
	output wire gclk,
	output wire grst_n,
	output wire sys_cc,
	output wire ref_clk,
	output wire ref_rst_n,
	output wire pclk,
	output wire prst_n
);
	wire sys_ibuf;
	wire g_fb, g_out, g_locked;
	wire a_fb, a_px, a_locked;
	wire b_fb, b_px, b_locked;

	IBUFDS sys_buf (.I(sys_clk_p), .IB(sys_clk_n), .O(sys_ibuf));
	assign sys_cc = sys_ibuf;
	BUFG ref_bufg (.I(sys_ibuf), .O(ref_clk));

	MMCME2_BASE #(
		.CLKIN1_PERIOD(5.000),
		.DIVCLK_DIVIDE(1),
		.CLKFBOUT_MULT_F(5.000),
		.CLKOUT0_DIVIDE_F(GCLK_DIVIDE)
	) mmcm_g (
		.CLKIN1(ref_clk), .CLKFBIN(g_fb), .CLKFBOUT(g_fb), .RST(cpu_reset), .PWRDWN(1'b0),
		.CLKOUT0(g_out), .LOCKED(g_locked),
		.CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
		.CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
	);
	BUFG g_bufg (.I(g_out), .O(gclk));

	PLLE2_BASE #(
		.CLKIN1_PERIOD(5.000),
		.DIVCLK_DIVIDE(5),
		.CLKFBOUT_MULT(34),
		.CLKOUT0_DIVIDE(54)
	) pll_a (
		.CLKIN1(ref_clk), .CLKFBIN(a_fb), .CLKFBOUT(a_fb), .RST(cpu_reset), .PWRDWN(1'b0),
		.CLKOUT0(a_px), .LOCKED(a_locked),
		.CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5()
	);

	MMCME2_BASE #(
		.CLKIN1_PERIOD(5.000),
		.DIVCLK_DIVIDE(10),
		.CLKFBOUT_MULT_F(59.375),
		.CLKOUT0_DIVIDE_F(16.000)
	) mmcm_b (
		.CLKIN1(ref_clk), .CLKFBIN(b_fb), .CLKFBOUT(b_fb), .RST(cpu_reset), .PWRDWN(1'b0),
		.CLKOUT0(b_px), .LOCKED(b_locked),
		.CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
		.CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
	);

	BUFGMUX mux_px (.I0(a_px), .I1(b_px), .S(pclk_sel), .O(pclk));

	am_sync sync_g (.clk(gclk), .rst_n(1'b1), .d(!cpu_reset && g_locked), .q(grst_n));
	am_sync sync_ref (.clk(ref_clk), .rst_n(1'b1), .d(!cpu_reset), .q(ref_rst_n));
	am_sync sync_p (.clk(pclk), .rst_n(1'b1), .d(!cpu_reset && a_locked && b_locked),
		.q(prst_n));
endmodule

`default_nettype wire
