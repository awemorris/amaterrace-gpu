/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_3d: 3D volume texture & buffer copy engine (Vulkan 1.0 vkCmdCopyBufferToImage 3D).
 *
 * Implements a 3-level nested loop state machine (Z -> Y -> X) transferring 3D slices
 * with independent depth slice strides and 2D row strides. Dispatched by the dedicated
 * asynchronous DMA transfer queue (RING_DMA) or secondary blitter engine.
 *
 * Guardrails: All 3D address offset calculations (z * slice_stride + y * row_stride)
 * strictly instantiate am_mul and am_add; zero raw arithmetic operators.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_3d #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5
) (
	input  wire        clk,
	input  wire        rst_n,

	// 3D コピー要求
	input  wire        req_valid,
	output wire        req_ready,
	input  wire [31:0] src_base, dst_base,
	input  wire [31:0] src_row_stride, dst_row_stride,
	input  wire [31:0] src_slice_stride, dst_slice_stride,
	input  wire [15:0] copy_w, copy_h, copy_d, // 幅・高さ・スライス数

	// 完了通知
	output reg         done,

	// AMB メモリポート
	output reg         m_req_valid,
	input  wire        m_req_ready,
	output reg         m_req_write,
	output reg  [ADDR_W-LINE_SHIFT-1:0] m_req_line,
	output reg  [LINE_BYTES-1:0] m_req_be,
	output reg  [LINE_BYTES*8-1:0] m_req_wdata,
	output reg  [7:0]  m_req_tag,
	input  wire        m_rsp_valid,
	input  wire        m_rsp_write,
	input  wire [7:0]  m_rsp_tag,
	input  wire [LINE_BYTES*8-1:0] m_rsp_rdata,
	input  wire        m_rsp_error
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;

	localparam [2:0] S_IDLE      = 3'd0;
	localparam [2:0] S_READ_REQ  = 3'd1;
	localparam [2:0] S_READ_RSP  = 3'd2;
	localparam [2:0] S_WRITE_REQ = 3'd3;
	localparam [2:0] S_WRITE_RSP = 3'd4;
	localparam [2:0] S_STEP      = 3'd5;
	localparam [2:0] S_DONE      = 3'd6;

	reg [2:0] state;

	// Request parameters
	reg [31:0] r_src_base, r_dst_base;
	reg [31:0] r_src_row_stride, r_dst_row_stride;
	reg [31:0] r_src_slice_stride, r_dst_slice_stride;
	reg [15:0] r_copy_w, r_copy_h, r_copy_d;

	// 3D loop counters
	reg [15:0] z_cnt;
	reg [15:0] y_cnt;
	reg [15:0] x_cnt;

	// Line buffer
	reg [LINE_BITS-1:0] line_buf;

	// Multipliers for 3D offset calculation (z * slice_stride + y * row_stride)
	wire [47:0] p_z_src, p_y_src;
	wire [47:0] p_z_dst, p_y_dst;

	am_mul #(.AW(16), .BW(32), .SIGNED(0), .LAT(0)) u_mul_z_src (
		.clk(clk), .en(1'b1), .a(z_cnt), .b(r_src_slice_stride), .p(p_z_src)
	);
	am_mul #(.AW(16), .BW(32), .SIGNED(0), .LAT(0)) u_mul_y_src (
		.clk(clk), .en(1'b1), .a(y_cnt), .b(r_src_row_stride), .p(p_y_src)
	);
	am_mul #(.AW(16), .BW(32), .SIGNED(0), .LAT(0)) u_mul_z_dst (
		.clk(clk), .en(1'b1), .a(z_cnt), .b(r_dst_slice_stride), .p(p_z_dst)
	);
	am_mul #(.AW(16), .BW(32), .SIGNED(0), .LAT(0)) u_mul_y_dst (
		.clk(clk), .en(1'b1), .a(y_cnt), .b(r_dst_row_stride), .p(p_y_dst)
	);

	// Adders for source addresses
	wire [31:0] zy_offset_src, row_base_src, cur_src_addr;
	wire co_zy_src, co_rb_src, co_x_src;

	am_add #(.W(32)) u_add_zy_src (
		.a(p_z_src[31:0]), .b(p_y_src[31:0]), .ci(1'b0),
		.s(zy_offset_src), .co(co_zy_src)
	);
	am_add #(.W(32)) u_add_base_src (
		.a(r_src_base), .b(zy_offset_src), .ci(1'b0),
		.s(row_base_src), .co(co_rb_src)
	);
	am_add #(.W(32)) u_add_x_src (
		.a(row_base_src), .b({16'd0, x_cnt}), .ci(1'b0),
		.s(cur_src_addr), .co(co_x_src)
	);

	// Adders for destination addresses
	wire [31:0] zy_offset_dst, row_base_dst, cur_dst_addr;
	wire co_zy_dst, co_rb_dst, co_x_dst;

	am_add #(.W(32)) u_add_zy_dst (
		.a(p_z_dst[31:0]), .b(p_y_dst[31:0]), .ci(1'b0),
		.s(zy_offset_dst), .co(co_zy_dst)
	);
	am_add #(.W(32)) u_add_base_dst (
		.a(r_dst_base), .b(zy_offset_dst), .ci(1'b0),
		.s(row_base_dst), .co(co_rb_dst)
	);
	am_add #(.W(32)) u_add_x_dst (
		.a(row_base_dst), .b({16'd0, x_cnt}), .ci(1'b0),
		.s(cur_dst_addr), .co(co_x_dst)
	);

	// Loop counter increments
	wire [15:0] x_cnt_next, y_cnt_next, z_cnt_next;
	wire co_x_next, co_y_next, co_z_next;

	am_add #(.W(16)) u_add_x_cnt (
		.a(x_cnt), .b(16'd1 << LINE_SHIFT), .ci(1'b0),
		.s(x_cnt_next), .co(co_x_next)
	);
	am_add #(.W(16)) u_add_y_cnt (
		.a(y_cnt), .b(16'd1), .ci(1'b0),
		.s(y_cnt_next), .co(co_y_next)
	);
	am_add #(.W(16)) u_add_z_cnt (
		.a(z_cnt), .b(16'd1), .ci(1'b0),
		.s(z_cnt_next), .co(co_z_next)
	);

	assign req_ready = (state == S_IDLE);

	always @(posedge clk) begin
		if (!rst_n) begin
			state               <= S_IDLE;
			done                <= 1'b0;
			m_req_valid         <= 1'b0;
			m_req_write         <= 1'b0;
			m_req_line          <= {LA_W{1'b0}};
			m_req_be            <= {LINE_BYTES{1'b0}};
			m_req_wdata         <= {LINE_BITS{1'b0}};
			m_req_tag           <= 8'd0;
			r_src_base          <= 32'd0;
			r_dst_base          <= 32'd0;
			r_src_row_stride    <= 32'd0;
			r_dst_row_stride    <= 32'd0;
			r_src_slice_stride  <= 32'd0;
			r_dst_slice_stride  <= 32'd0;
			r_copy_w            <= 16'd0;
			r_copy_h            <= 16'd0;
			r_copy_d            <= 16'd0;
			z_cnt               <= 16'd0;
			y_cnt               <= 16'd0;
			x_cnt               <= 16'd0;
			line_buf            <= {LINE_BITS{1'b0}};
		end else begin
			done <= 1'b0;

			case (state)
			S_IDLE: begin
				if (req_valid) begin
					r_src_base         <= src_base;
					r_dst_base         <= dst_base;
					r_src_row_stride   <= src_row_stride;
					r_dst_row_stride   <= dst_row_stride;
					r_src_slice_stride <= src_slice_stride;
					r_dst_slice_stride <= dst_slice_stride;
					r_copy_w           <= copy_w;
					r_copy_h           <= copy_h;
					r_copy_d           <= copy_d;
					z_cnt              <= 16'd0;
					y_cnt              <= 16'd0;
					x_cnt              <= 16'd0;
					if (copy_w == 16'd0 || copy_h == 16'd0 || copy_d == 16'd0) begin
						state <= S_DONE;
					end else begin
						state <= S_READ_REQ;
					end
				end
			end

			S_READ_REQ: begin
				m_req_valid <= 1'b1;
				m_req_write <= 1'b0;
				m_req_line  <= cur_src_addr[ADDR_W-1:LINE_SHIFT];
				m_req_be    <= {LINE_BYTES{1'b0}};
				m_req_wdata <= {LINE_BITS{1'b0}};
				m_req_tag   <= 8'h3D;
				if (m_req_ready) begin
					m_req_valid <= 1'b0;
					state       <= S_READ_RSP;
				end
			end

			S_READ_RSP: begin
				if (m_rsp_valid && (m_rsp_tag == 8'h3D) && !m_rsp_write) begin
					line_buf <= m_rsp_rdata;
					state    <= S_WRITE_REQ;
				end
			end

			S_WRITE_REQ: begin
				m_req_valid <= 1'b1;
				m_req_write <= 1'b1;
				m_req_line  <= cur_dst_addr[ADDR_W-1:LINE_SHIFT];
				m_req_be    <= {LINE_BYTES{1'b1}};
				m_req_wdata <= line_buf;
				m_req_tag   <= 8'h3D;
				if (m_req_ready) begin
					m_req_valid <= 1'b0;
					state       <= S_WRITE_RSP;
				end
			end

			S_WRITE_RSP: begin
				if (m_rsp_valid && (m_rsp_tag == 8'h3D) && m_rsp_write) begin
					state <= S_STEP;
				end
			end

			S_STEP: begin
				if (x_cnt_next < r_copy_w) begin
					x_cnt <= x_cnt_next;
					state <= S_READ_REQ;
				end else begin
					x_cnt <= 16'd0;
					if (y_cnt_next < r_copy_h) begin
						y_cnt <= y_cnt_next;
						state <= S_READ_REQ;
					end else begin
						y_cnt <= 16'd0;
						if (z_cnt_next < r_copy_d) begin
							z_cnt <= z_cnt_next;
							state <= S_READ_REQ;
						end else begin
							state <= S_DONE;
						end
					end
				end
			end

			S_DONE: begin
				done  <= 1'b1;
				state <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0,
		co_zy_src, co_rb_src, co_x_src,
		co_zy_dst, co_rb_dst, co_x_dst,
		co_x_next, co_y_next, co_z_next,
		p_z_src[47:32], p_y_src[47:32],
		p_z_dst[47:32], p_y_dst[47:32],
		cur_src_addr[LINE_SHIFT-1:0],
		cur_dst_addr[LINE_SHIFT-1:0],
		m_rsp_error
	};

endmodule

`default_nettype wire
