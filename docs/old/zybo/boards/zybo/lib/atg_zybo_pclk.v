/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_pclk: The ZYBO DC's pixel clocks from FCLK_CLK0 (100 MHz),
 * selected by a BUFGMUX pair (design §1.3, §5.1).  See
 * spec/boards/zybo/lib/atg_zybo_pclk.md.
 *
 * One MMCM cannot make both modes: 25.2 and 74.25 MHz (and their fifths of
 * the bit rate) need a VCO of a common multiple far above the MMCM's 1200
 * MHz.  So each mode has its own: a PLLE2_BASE and an MMCME2_BASE of the
 * same CMT (the 7010's two MMCMs are in different halves of the device,
 * and a BUFGMUX cannot take clocks from both halves on dedicated routes),
 * each with the pixel clock on CLKOUT0 and 5 x pixel clock on CLKOUT1 from
 * one VCO (so the pair is phase related for the OSERDESE2):
 *
 *   sel 0 (640x480), PLL: DIVCLK 3, MULT 34: VCO 1133.3 MHz (PFD 33.3),
 *          O0 45 -> 25.185 MHz (VESA 25.175: +0.04 %), O1 9 -> 125.93.
 *   sel 1 (720p), MMCM: DIVCLK 8, MULT 59.375: VCO 742.1875 MHz (PFD
 *          12.5), O0 10 -> 74.21875 MHz (CEA 74.25: -0.04 %), O1 2 ->
 *          371.09375.
 *
 * Values referenced: UG472 (7 Series clocking: MMCM VCO 600-1200 MHz and
 * PFD 10-450 MHz, PLL VCO 800-1600 MHz and PFD 19-450 MHz for -1; the
 * MMCM's CLKFBOUT_MULT_F and CLKOUT0_DIVIDE_F in steps of 0.125; BUFGMUX
 * switching).  sel comes from gclk: BUFGMUX switches without a glitch when
 * both inputs run, so the DC changes it with ENABLE = 0 (PCLK_SEL is
 * quasi-static).
 *
 * prst_n is rst_n and both locked, taken into pclk through two flops;
 * locked goes to gclk the same way.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_pclk (
	input wire clk,
	input wire rst_n,
	input wire sel,
	output wire pclk,
	output wire pclk5,
	output wire prst_n,
	output wire locked
);
	wire a_fb, a_px, a_px5, a_locked;
	wire b_fb, b_px, b_px5, b_locked;

	PLLE2_BASE #(
		.CLKIN1_PERIOD(10.000),
		.DIVCLK_DIVIDE(3),
		.CLKFBOUT_MULT(34),
		.CLKOUT0_DIVIDE(45),
		.CLKOUT1_DIVIDE(9)
	) pll_a (
		.CLKIN1(clk), .CLKFBIN(a_fb), .CLKFBOUT(a_fb), .RST(!rst_n), .PWRDWN(1'b0),
		.CLKOUT0(a_px), .CLKOUT1(a_px5), .LOCKED(a_locked),
		.CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5()
	);

	MMCME2_BASE #(
		.CLKIN1_PERIOD(10.000),
		.DIVCLK_DIVIDE(8),
		.CLKFBOUT_MULT_F(59.375),
		.CLKOUT0_DIVIDE_F(10.000),
		.CLKOUT1_DIVIDE(2)
	) mmcm_b (
		.CLKIN1(clk), .CLKFBIN(b_fb), .CLKFBOUT(b_fb), .RST(!rst_n), .PWRDWN(1'b0),
		.CLKOUT0(b_px), .CLKOUT1(b_px5), .LOCKED(b_locked),
		.CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(),
		.CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
	);

	BUFGMUX mux_px (.I0(a_px), .I1(b_px), .S(sel), .O(pclk));
	BUFGMUX mux_px5 (.I0(a_px5), .I1(b_px5), .S(sel), .O(pclk5));

	wire ok = rst_n && a_locked && b_locked;

	am_sync sync_prst (.clk(pclk), .rst_n(1'b1), .d(ok), .q(prst_n));
	am_sync sync_locked (.clk(clk), .rst_n(rst_n), .d(a_locked && b_locked), .q(locked));
endmodule

`default_nettype wire
