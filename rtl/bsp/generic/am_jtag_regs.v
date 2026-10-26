/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_jtag_regs: KC705 JTAG register bridge: a BSCANE2 USER2 data register
 * of 72 bits {cmd, addr, data} that becomes a second master on the GHCI
 * register bus (DBG capability).  See spec/bsp/generic/am_jtag_regs.md.
 *
 * The data register, LSB first: [7:0] cmd, [39:8] addr, [71:40] data.
 * cmd 1 writes data to addr, cmd 2 reads addr (the value comes back in the
 * data field of a later scan), cmd 3 (status) and the others only scan.
 * CAPTURE loads {read data, addr, status}: status [0] done (no access
 * pending), [1] dropped (a command came while one was pending and was
 * ignored; cleared by the next accepted command).
 *
 * Two clock domains by design (the only crossing of the bridge): the scan
 * side in tck, the bus side in clk.  UPDATE of an accepted write or read
 * latches the command and toggles req_t; the toggle reaches clk through
 * am_sync, and the latched command is stable until the acknowledge
 * toggle (ack_g) comes back through am_sync, so clk reads it as a
 * quasi-static bus.  The read data is held in clk from the access to the
 * next one, so tck samples it at CAPTURE the same way.  The tck side has
 * no reset (the TAP gives none on these ports): its registers start at 0
 * from the configuration.  A reset of clk drops a pending access by
 * acknowledging it.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_jtag_regs (
	input wire clk,
	input wire rst_n,
	/* From BSCANE2 (tck domain) */
	input wire tck,
	input wire tdi,
	output wire tdo,
	input wire sel,
	input wire capture,
	input wire shift,
	input wire update,
	/* Register bus master (gclk) */
	output wire reg_wr,
	output wire [16:0] reg_waddr,
	output wire [31:0] reg_wdata,
	output wire [3:0] reg_wstrb,
	output wire reg_rd,
	output wire [16:0] reg_raddr,
	input wire [31:0] reg_rdata,
	input wire bus_busy
);
	localparam [7:0] CMD_WRITE = 8'd1;
	localparam [7:0] CMD_READ = 8'd2;

	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_WAIT_BUS = 2'd1;
	localparam [1:0] S_READ_DATA = 2'd2;
	localparam [1:0] S_DONE = 2'd3;

	/* tck side (no reset: configuration values). */
	reg [71:0] sr = 72'd0;
	reg req_t = 1'b0;
	reg is_read_t = 1'b0;
	reg dropped_t = 1'b0;
	reg [31:0] addr_t = 32'd0;
	reg [31:0] data_t = 32'd0;
	wire ack_t;

	/* clk side. */
	reg [1:0] state;
	reg req_seen;
	reg ack_g;
	reg [31:0] rdata_g;
	wire req_g;

	/* The toggles cross unreset (the tck side has no reset to pair with). */
	am_sync sync_req (.clk(clk), .rst_n(1'b1), .d(req_t), .q(req_g));
	am_sync sync_ack (.clk(tck), .rst_n(1'b1), .d(ack_g), .q(ack_t));

	wire done_t = req_t == ack_t;
	wire [7:0] cmd_in = sr[7:0];
	wire is_access = cmd_in == CMD_WRITE || cmd_in == CMD_READ;

	assign tdo = sr[0];

	always @(posedge tck) begin
		if (sel && capture)
			sr <= {rdata_g, addr_t, 6'd0, dropped_t, done_t};
		else if (sel && shift)
			sr <= {tdi, sr[71:1]};
		if (sel && update && is_access) begin
			if (done_t) begin
				addr_t <= sr[39:8];
				data_t <= sr[71:40];
				is_read_t <= cmd_in == CMD_READ;
				dropped_t <= 1'b0;
				req_t <= !req_t;
			end else begin
				dropped_t <= 1'b1;
			end
		end
	end

	/* clk side: one access per request, in a cycle without the AXI slave. */
	wire go = state == S_WAIT_BUS && !bus_busy;

	assign reg_wr = go && !is_read_t;
	assign reg_rd = go && is_read_t;
	assign reg_waddr = addr_t[16:0];
	assign reg_raddr = addr_t[16:0];
	assign reg_wdata = data_t;
	assign reg_wstrb = 4'hF;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			req_seen <= req_g;
			ack_g <= req_g;
			rdata_g <= 32'd0;
		end else begin
			case (state)
			S_IDLE:
				if (req_g != req_seen) begin
					req_seen <= req_g;
					state <= S_WAIT_BUS;
				end
			S_WAIT_BUS:
				if (go)
					state <= is_read_t ? S_READ_DATA : S_DONE;
			S_READ_DATA: begin
				rdata_g <= reg_rdata;
				state <= S_DONE;
			end
			default: begin
				ack_g <= req_seen;
				state <= S_IDLE;
			end
			endcase
		end
	end

	wire unused_ok = &{1'b0, addr_t[31:17]};
endmodule

`default_nettype wire
