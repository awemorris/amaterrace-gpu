/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * i2c_slave: simulation only.  An I2C slave with a 7-bit address ADDR and
 * 256 byte registers, the usual register-pointer protocol (the ADV7511's
 * and most configuration chips'): after the address with R/W 0 the first
 * byte sets the pointer and later bytes write regs[ptr++]; after the
 * address with R/W 1 the slave sends regs[ptr++] while the master
 * acknowledges.  A wrong address is not acknowledged and the slave ignores
 * the bus until the next START.  STRETCH_NS > 0 holds SCL low that long
 * after each acknowledge (clock stretching).  The lines are open drain
 * (the testbench puts pull-ups on them).
 *
 * Counters for the testbench: starts, stops, wbytes (data bytes written,
 * the pointer byte included), naddr (addresses not acknowledged), last
 * (the last byte written), and master_nacked (the master's NACK ended a
 * read).
 */

`timescale 1ns / 1ps
`default_nettype none

module i2c_slave #(
	parameter [6:0] ADDR = 7'h39,
	parameter integer STRETCH_NS = 0
) (
	inout wire scl,
	inout wire sda
);
	localparam P_IDLE = 0;
	localparam P_ADDR = 1;
	localparam P_WDATA = 2;
	localparam P_RDATA = 3;

	reg sda_drv = 1'b0;
	reg scl_drv = 1'b0;

	assign sda = sda_drv ? 1'b0 : 1'bz;
	assign scl = scl_drv ? 1'b0 : 1'bz;

	reg [7:0] regs [0:255];
	reg [7:0] ptr = 8'd0;
	reg [7:0] sh = 8'd0;
	reg [7:0] tx = 8'd0;
	reg [7:0] last = 8'd0;
	reg rw = 1'b0;
	reg first = 1'b0;
	reg m_ack = 1'b0;
	reg master_nacked = 1'b0;
	reg clocked = 1'b0;	/* a rising SCL edge since the last falling one */
	integer phase = P_IDLE;
	integer bitc = 0;
	integer starts = 0;
	integer stops = 0;
	integer wbytes = 0;
	integer naddr = 0;
	integer k;

	initial
		for (k = 0; k < 256; k = k + 1)
			regs[k] = 8'd0;

	/* START (also a repeated one) and STOP: SDA moves while SCL is high
	 * (from a known level: the power-up x -> 1 is neither). */
	reg sda_q = 1'b1;

	always @(sda) begin
		if (scl === 1'b1 && sda_q === 1'b1 && sda === 1'b0) begin
			phase = P_ADDR;
			bitc = 0;
			clocked = 1'b0;
			sda_drv = 1'b0;
			starts = starts + 1;
		end
		if (scl === 1'b1 && sda_q === 1'b0 && sda !== 1'b0) begin
			phase = P_IDLE;
			sda_drv = 1'b0;
			stops = stops + 1;
		end
		sda_q = sda === 1'b0 ? 1'b0 : 1'b1;
	end

	always @(posedge scl)
		if (phase != P_IDLE) begin
			clocked = 1'b1;
			if (bitc < 8) begin
				if (phase != P_RDATA)
					sh = {sh[6:0], sda === 1'b0 ? 1'b0 : 1'b1};
			end else if (phase == P_RDATA) begin
				m_ack = sda === 1'b0;
			end
		end

	/* The falling edge that ends a clock (not the one after START). */
	always @(negedge scl)
		if (phase != P_IDLE && clocked) begin
			clocked = 1'b0;
			if (bitc < 8) begin
				bitc = bitc + 1;
				if (bitc == 8) begin
					/* The acknowledge clock. */
					if (phase == P_ADDR) begin
						if (sh[7:1] == ADDR) begin
							rw = sh[0];
							sda_drv = 1'b1;
						end else begin
							naddr = naddr + 1;
							phase = P_IDLE;
						end
					end else if (phase == P_WDATA) begin
						if (first)
							ptr = sh;
						else begin
							regs[ptr] = sh;
							ptr = ptr + 8'd1;
						end
						first = 1'b0;
						last = sh;
						wbytes = wbytes + 1;
						sda_drv = 1'b1;
					end else begin
						sda_drv = 1'b0;
					end
				end else if (phase == P_RDATA) begin
					sda_drv = !tx[7 - bitc];
				end
			end else begin
				/* The end of the acknowledge clock. */
				bitc = 0;
				if (phase == P_ADDR) begin
					if (rw) begin
						phase = P_RDATA;
						tx = regs[ptr];
						sda_drv = !tx[7];
					end else begin
						phase = P_WDATA;
						first = 1'b1;
						sda_drv = 1'b0;
					end
				end else if (phase == P_WDATA) begin
					sda_drv = 1'b0;
				end else begin
					if (m_ack) begin
						ptr = ptr + 8'd1;
						tx = regs[ptr];
						sda_drv = !tx[7];
					end else begin
						master_nacked = 1'b1;
						sda_drv = 1'b0;
						phase = P_IDLE;
					end
				end
				if (STRETCH_NS > 0) begin
					scl_drv = 1'b1;
					#(STRETCH_NS) scl_drv = 1'b0;
				end
			end
		end
endmodule

`default_nettype wire
