/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_zybo_tmds_out: The ZYBO HDMI output stage: three OSERDESE2 10:1
 * serialisers (DDR, pclk5) for the TMDS symbols, the TMDS clock channel,
 * and OBUFDS (TMDS_33 in the XDC) for the four pairs.  See
 * spec/boards/zybo/lib/atg_zybo_tmds_out.md.
 *
 * Each channel is a MASTER/SLAVE pair of OSERDESE2 (DATA_WIDTH 10, DDR,
 * CLK = pclk5, CLKDIV = pclk): the master takes symbol bits 0..7 on D1..D8,
 * the slave bits 8 and 9 on D3 and D4 and passes them through SHIFTOUT;
 * bit 0 leaves first (DVI).  The clock channel sends 1111100000 (five ones
 * and five zeros, one pixel clock period).  Values referenced: UG471
 * (OSERDESE2 width expansion: 10:1 DDR with a slave, D1 first, RST held
 * for CLKDIV cycles after the clocks run).  The serialisers are reset by
 * rst_n (pclk), which rises after the MMCMs lock (atg_zybo_pclk).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_zybo_tmds_out (
	input wire pclk,
	input wire pclk5,
	input wire rst_n,
	input wire [29:0] tmds,
	output wire hdmi_clk_p,
	output wire hdmi_clk_n,
	output wire [2:0] hdmi_d_p,
	output wire [2:0] hdmi_d_n
);
	wire [39:0] sym = {10'b1111100000, tmds};
	wire [3:0] oq;

	genvar c;
	generate
	for (c = 0; c < 4; c = c + 1) begin : g_ch
		wire s1, s2;
		OSERDESE2 #(
			.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
			.SERDES_MODE("MASTER"), .TRISTATE_WIDTH(1)
		) master (
			.CLK(pclk5), .CLKDIV(pclk), .RST(!rst_n), .OCE(1'b1), .OQ(oq[c]),
			.D1(sym[10*c + 0]), .D2(sym[10*c + 1]), .D3(sym[10*c + 2]), .D4(sym[10*c + 3]),
			.D5(sym[10*c + 4]), .D6(sym[10*c + 5]), .D7(sym[10*c + 6]), .D8(sym[10*c + 7]),
			.SHIFTIN1(s1), .SHIFTIN2(s2), .SHIFTOUT1(), .SHIFTOUT2(),
			.T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TCE(1'b0), .TBYTEIN(1'b0),
			.OFB(), .TFB(), .TQ(), .TBYTEOUT()
		);
		OSERDESE2 #(
			.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
			.SERDES_MODE("SLAVE"), .TRISTATE_WIDTH(1)
		) slave (
			.CLK(pclk5), .CLKDIV(pclk), .RST(!rst_n), .OCE(1'b1), .OQ(),
			.D1(1'b0), .D2(1'b0), .D3(sym[10*c + 8]), .D4(sym[10*c + 9]),
			.D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
			.SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .SHIFTOUT1(s1), .SHIFTOUT2(s2),
			.T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TCE(1'b0), .TBYTEIN(1'b0),
			.OFB(), .TFB(), .TQ(), .TBYTEOUT()
		);
	end
	endgenerate

	OBUFDS buf_d0 (.I(oq[0]), .O(hdmi_d_p[0]), .OB(hdmi_d_n[0]));
	OBUFDS buf_d1 (.I(oq[1]), .O(hdmi_d_p[1]), .OB(hdmi_d_n[1]));
	OBUFDS buf_d2 (.I(oq[2]), .O(hdmi_d_p[2]), .OB(hdmi_d_n[2]));
	OBUFDS buf_clk (.I(oq[3]), .O(hdmi_clk_p), .OB(hdmi_clk_n));
endmodule

`default_nettype wire
