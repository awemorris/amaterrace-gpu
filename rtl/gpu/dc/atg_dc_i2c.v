/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_i2c: A small I2C master for the KC705's ADV7511 HDMI transmitter
 * configuration (I2C_CTRL/DATA/STATUS of design §5.1).  See
 * spec/gpu/dc/atg_dc_i2c.md.
 *
 * Registers (i_idx): 0 CTRL, 1 DATA, 2 STATUS.  A write of CTRL while
 * idle starts one command: [0] START (a repeated start if the bus is
 * held), then [2] WRITE the byte DATA[7:0] or [3] READ a byte into
 * DATA[7:0] answering [4] ACK (1) or NACK (0), then [1] STOP.  STATUS [0]
 * busy, [1] NACK (the last written byte was not acknowledged).  A write
 * of CTRL or DATA while busy is ignored.  CTRL reads back the last
 * command.
 *
 * Each SCL period is four quarters of CLK_DIV cycles.  A quarter in which
 * SCL is released does not count while SCL is still low (clock
 * stretching, and the rise time).  SDA changes only while SCL is low,
 * except for START and STOP; the master samples SDA at the end of the
 * second high quarter.  Between commands of one transfer SCL stays low
 * (the bus is held).  The pins are open drain: *_t = 1 releases the line;
 * the inputs go through am_sync.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_i2c #(
	parameter CLK_DIV = 250	/* gclk cycles per quarter SCL period (100 MHz → 100 kHz) */
) (
	input wire clk,
	input wire rst_n,
	input wire i_we,
	input wire [1:0] i_idx,
	input wire [31:0] i_wdata,
	output wire [31:0] i_rdata,
	output wire scl_t,
	input wire scl_i,
	output wire sda_t,
	input wire sda_i
);
	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_START = 3'd1;
	localparam [2:0] S_BIT = 3'd2;
	localparam [2:0] S_ACK = 3'd3;
	localparam [2:0] S_STOP = 3'd4;

	localparam [1:0] R_CTRL = 2'd0;
	localparam [1:0] R_DATA = 2'd1;
	localparam [1:0] R_STATUS = 2'd2;

	localparam DIV_W = CLK_DIV > 1 ? $clog2(CLK_DIV) : 1;
	/* verilator lint_off WIDTHTRUNC */
	localparam [DIV_W-1:0] DIV_LAST = CLK_DIV - 1;
	/* verilator lint_on WIDTHTRUNC */

	reg [2:0] state;
	reg [1:0] q;
	reg [DIV_W-1:0] div;
	reg [2:0] bitn;
	reg [4:0] cmd;
	reg [7:0] data;
	reg nack;
	reg held;
	reg scl_low, sda_low;
	wire scl_s, sda_s;

	am_sync #(.W(2), .RESET_VALUE(2'b11)) sync_in (
		.clk(clk), .rst_n(rst_n), .d({scl_i, sda_i}), .q({scl_s, sda_s})
	);

	wire c_stop = cmd[1];
	wire c_write = cmd[2];
	wire c_read = cmd[3] && !cmd[2];	/* WRITE wins */
	wire c_ack = cmd[4];
	wire busy = state != S_IDLE;

	/* The lines of the current quarter (1 = drive low). */
	reg want_scl_low, want_sda_low;

	always @(*) begin
		want_scl_low = scl_low;
		want_sda_low = sda_low;
		case (state)
		S_START:
			case (q)
			2'd0: begin want_scl_low = held; want_sda_low = 1'b0; end
			2'd1: begin want_scl_low = 1'b0; want_sda_low = 1'b0; end
			2'd2: begin want_scl_low = 1'b0; want_sda_low = 1'b1; end
			default: begin want_scl_low = 1'b1; want_sda_low = 1'b1; end
			endcase
		S_BIT: begin
			want_sda_low = c_write && !data[bitn];
			want_scl_low = q == 2'd0 || q == 2'd3;
		end
		S_ACK: begin
			want_sda_low = c_read && c_ack;
			want_scl_low = q == 2'd0 || q == 2'd3;
		end
		S_STOP:
			case (q)
			2'd0: begin want_scl_low = 1'b1; want_sda_low = 1'b1; end
			2'd1: begin want_scl_low = 1'b0; want_sda_low = 1'b1; end
			default: begin want_scl_low = 1'b0; want_sda_low = 1'b0; end
			endcase
		default: ;
		endcase
	end

	/* A quarter ends after CLK_DIV cycles; one with SCL released waits for
	 * SCL to be high first. */
	wire stretch = !want_scl_low && !scl_s;
	wire tick = busy && div == DIV_LAST && !stretch;

	/* The counters' next values: the divider, the quarter of the bit and the bit of the byte. */
	wire [DIV_W-1:0] div_inc;
	wire [1:0] q_inc;
	wire [2:0] bitn_dec;
	wire [2:0] cnt_co_unused;

	am_add #(.W(DIV_W)) a_div (.a(div), .b({DIV_W{1'b0}}), .ci(1'b1), .s(div_inc), .co(cnt_co_unused[0]));
	am_add #(.W(2)) a_q (.a(q), .b(2'd0), .ci(1'b1), .s(q_inc), .co(cnt_co_unused[1]));
	am_sub #(.W(3)) s_bitn (.a(bitn), .b(3'd0), .bi(1'b1), .d(bitn_dec), .bo(cnt_co_unused[2]));

	/* What follows the byte: STOP, or the end of the command. */
	wire [2:0] after_byte = c_stop ? S_STOP : S_IDLE;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			q <= 2'd0;
			div <= {DIV_W{1'b0}};
			bitn <= 3'd7;
			cmd <= 5'd0;
			data <= 8'd0;
			nack <= 1'b0;
			held <= 1'b0;
			scl_low <= 1'b0;
			sda_low <= 1'b0;
		end else begin
			scl_low <= want_scl_low;
			sda_low <= want_sda_low;
			if (!busy) begin
				div <= {DIV_W{1'b0}};
				q <= 2'd0;
				if (i_we && i_idx == R_DATA)
					data <= i_wdata[7:0];
				if (i_we && i_idx == R_CTRL) begin
					cmd <= i_wdata[4:0];
					bitn <= 3'd7;
					if (i_wdata[0])
						state <= S_START;
					else if (i_wdata[2] || i_wdata[3])
						state <= S_BIT;
					else if (i_wdata[1])
						state <= S_STOP;
				end
			end else if (!stretch) begin
				div <= tick ? {DIV_W{1'b0}} : div_inc;
			end
			if (tick) begin
				q <= q_inc;
				if (q == 2'd2 && state == S_BIT && c_read)
					data[bitn] <= sda_s;
				if (q == 2'd2 && state == S_ACK && c_write)
					nack <= sda_s;
				if (q == 2'd3) begin
					case (state)
					S_START: begin
						held <= 1'b1;
						state <= c_write || c_read ? S_BIT : after_byte;
					end
					S_BIT: begin
						bitn <= bitn_dec;
						if (bitn == 3'd0)
							state <= S_ACK;
					end
					S_ACK:
						state <= after_byte;
					default: begin
						held <= 1'b0;
						state <= S_IDLE;
					end
					endcase
				end
			end
		end
	end

	assign scl_t = !scl_low;
	assign sda_t = !sda_low;

	assign i_rdata = i_idx == R_CTRL ? {27'd0, cmd} :
		i_idx == R_DATA ? {24'd0, data} :
		i_idx == R_STATUS ? {30'd0, nack, busy} : 32'd0;

	wire unused_ok = &{1'b0, i_wdata[31:5], cnt_co_unused};
endmodule

`default_nettype wire
