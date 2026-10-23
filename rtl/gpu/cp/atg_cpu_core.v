/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_core: The RV32IM pipeline of the CP's control processor: fetch,
 * decode/register read, execute, writeback (4 stages), Machine mode only,
 * one interrupt line, no CSRs (the control window replaces them).
 *
 * F: i_en with i_addr = pc_f; the word comes back on i_rdata the next
 * cycle and stays there while i_en is 0 (BRAM output register).
 * D: register read of i_rdata's rs1/rs2 (with W's value of this cycle)
 * into E's operand registers.  E: decode, atg_cpu_alu, branch resolve, the
 * data access (d_valid held with its payload until d_ready) and the
 * atg_cpu_muldiv start; its operands take W's value when W holds the
 * instruction just before (program order).  W: the result register and
 * the register file write.  A taken branch, jump, mret or interrupt
 * refetches (2 bubbles).
 *
 * run = 0 stops before the next instruction starts (an access or a
 * multiply/divide already started completes); stopped is then 1.  An
 * interrupt (irq = 1, not in the handler) is taken before an instruction
 * starts: the hidden mepc gets its PC (a WFI's next PC), the core jumps
 * to 0x10, and mret (0x30200073) returns.  WFI waits for irq.  A fault
 * (illegal instruction, CSR/ECALL/EBREAK, misaligned access or jump
 * target, fetch outside 0x0000_0000-0x0000_FFFF) pulses fault with the
 * PC and stops the core until reset.  See spec/gpu/cp/atg_cpu_core.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_core (
	input wire clk,
	input wire rst_n,
	input wire run,
	output wire stopped,
	input wire irq,
	/* Instruction port (IMEM, synchronous BRAM read) */
	output wire i_en,
	output wire [31:0] i_addr,
	input wire [31:0] i_rdata,
	/* Data port (to atg_cpu_win) */
	output wire d_valid,
	output wire d_write,
	output wire [31:0] d_addr,
	output reg [31:0] d_wdata,
	output reg [3:0] d_be,
	input wire d_ready,
	input wire [31:0] d_rdata,
	/* Faults (to atg_cpu_fw) */
	output reg fault,
	output reg [31:0] fault_pc
);
	localparam [31:0] IRQ_VECTOR = 32'h0000_0010;
	/* SYSTEM: only these two; CSR*, ECALL, EBREAK fault. */
	localparam [31:0] MRET = 32'h3020_0073;
	localparam [31:0] WFI = 32'h1050_0073;

	localparam [6:0] OPC_LUI = 7'b0110111;
	localparam [6:0] OPC_AUIPC = 7'b0010111;
	localparam [6:0] OPC_JAL = 7'b1101111;
	localparam [6:0] OPC_JALR = 7'b1100111;
	localparam [6:0] OPC_BRANCH = 7'b1100011;
	localparam [6:0] OPC_LOAD = 7'b0000011;
	localparam [6:0] OPC_STORE = 7'b0100011;
	localparam [6:0] OPC_IMM = 7'b0010011;
	localparam [6:0] OPC_OP = 7'b0110011;
	localparam [6:0] OPC_FENCE = 7'b0001111;

	/* atg_cpu_alu op codes. */
	localparam [3:0] A_ADD = 4'd0;
	localparam [3:0] A_SUB = 4'd1;
	localparam [3:0] A_SLL = 4'd2;
	localparam [3:0] A_SLT = 4'd3;
	localparam [3:0] A_SLTU = 4'd4;
	localparam [3:0] A_XOR = 4'd5;
	localparam [3:0] A_SRL = 4'd6;
	localparam [3:0] A_SRA = 4'd7;
	localparam [3:0] A_OR = 4'd8;
	localparam [3:0] A_AND = 4'd9;
	localparam [3:0] A_PASS_B = 4'd10;

	/* Pipeline state. */
	reg [31:0] pc_f;	/* address fetched this cycle */
	reg [31:0] pc_d;	/* address of the instruction in D (i_rdata) */
	reg d_vld;
	reg [31:0] pc_e;	/* address of the instruction in E */
	reg [31:0] ir_e;
	reg [31:0] rs1_e, rs2_e;	/* its operands as read in D */
	reg fwd1_e, fwd2_e;	/* take them from W instead (decided in D: timing) */
	reg e_vld;
	reg e_busy;	/* its access or multiply/divide has started */
	reg w_wen;	/* W: the last completed instruction writes w_rd */
	reg [4:0] w_rd;
	reg [31:0] w_val;
	reg faulted;
	reg in_irq;
	reg [31:0] mepc;
	reg [31:0] rf [1:31];

	/* D: register read, with the value W writes in this cycle. */
	wire [4:0] d_ra = i_rdata[19:15];
	wire [4:0] d_rb = i_rdata[24:20];
	wire [31:0] d_rs1 = (d_ra == 5'd0) ? 32'd0 : (w_wen && w_rd == d_ra) ? w_val : rf[d_ra];
	wire [31:0] d_rs2 = (d_rb == 5'd0) ? 32'd0 : (w_wen && w_rd == d_rb) ? w_val : rf[d_rb];

	/* E: decode of ir_e. */
	wire [31:0] ir = ir_e;
	wire [6:0] opc = ir[6:0];
	wire [4:0] rd = ir[11:7];
	wire [2:0] f3 = ir[14:12];
	wire [6:0] f7 = ir[31:25];

	wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
	wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
	wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
	wire [31:0] imm_u = {ir[31:12], 12'd0};
	wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

	wire is_lui = opc == OPC_LUI;
	wire is_auipc = opc == OPC_AUIPC;
	wire is_jal = opc == OPC_JAL;
	wire is_jalr = opc == OPC_JALR && f3 == 3'd0;
	wire is_br = opc == OPC_BRANCH && f3[2:1] != 2'b01;
	wire is_ld = opc == OPC_LOAD && (f3 == 3'd0 || f3 == 3'd1 || f3 == 3'd2 ||
		f3 == 3'd4 || f3 == 3'd5);
	wire is_st = opc == OPC_STORE && (f3 == 3'd0 || f3 == 3'd1 || f3 == 3'd2);
	wire is_imm = opc == OPC_IMM && (f3 == 3'd1 ? f7 == 7'd0 :
		f3 == 3'd5 ? (f7 == 7'd0 || f7 == 7'h20) : 1'b1);
	wire is_op = opc == OPC_OP && (f7 == 7'd0 ||
		(f7 == 7'h20 && (f3 == 3'd0 || f3 == 3'd5)));
	wire is_m = opc == OPC_OP && f7 == 7'd1;
	wire is_fence = opc == OPC_FENCE && f3[2:1] == 2'b00;
	wire is_mret = ir == MRET;
	wire is_wfi = ir == WFI;
	wire legal = is_lui || is_auipc || is_jal || is_jalr || is_br || is_ld || is_st ||
		is_imm || is_op || is_m || is_fence || is_mret || is_wfi;
	wire is_mem = is_ld || is_st;
	wire has_rd = is_lui || is_auipc || is_jal || is_jalr || is_ld || is_imm || is_op || is_m;

	/* E's operands: W holds the instruction just before it (program order). */
	wire [31:0] rs1 = fwd1_e ? w_val : rs1_e;
	wire [31:0] rs2 = fwd2_e ? w_val : rs2_e;

	/* ALU: a = rs1; b = an immediate or rs2. */
	reg [3:0] alu_op;
	reg [31:0] alu_b;
	wire [31:0] alu_y;
	wire alu_eq, alu_lt, alu_ltu;

	always @(*) begin
		alu_b = rs2;
		alu_op = A_ADD;
		if (is_lui) begin
			alu_op = A_PASS_B;
			alu_b = imm_u;
		end else if (is_jalr || is_ld) begin
			alu_b = imm_i;
		end else if (is_st) begin
			alu_b = imm_s;
		end else if (is_imm || is_op) begin
			if (is_imm)
				alu_b = imm_i;
			case (f3)
			3'd0: alu_op = (is_op && f7[5]) ? A_SUB : A_ADD;
			3'd1: alu_op = A_SLL;
			3'd2: alu_op = A_SLT;
			3'd3: alu_op = A_SLTU;
			3'd4: alu_op = A_XOR;
			3'd5: alu_op = f7[5] ? A_SRA : A_SRL;
			3'd6: alu_op = A_OR;
			default: alu_op = A_AND;
			endcase
		end
	end

	atg_cpu_alu alu (
		.op(alu_op), .a(rs1), .b(alu_b),
		.y(alu_y), .eq(alu_eq), .lt(alu_lt), .ltu(alu_ltu)
	);

	/* The branch compare: a second ALU on rs1 and rs2 directly, so the
	 * compare does not wait for the decode of alu_b (timing at 200 MHz);
	 * only its eq/lt/ltu are used. */
	wire [31:0] br_y;
	wire br_eq, br_lt, br_ltu;

	atg_cpu_alu alu_br (
		.op(A_SUB), .a(rs1), .b(rs2),
		.y(br_y), .eq(br_eq), .lt(br_lt), .ltu(br_ltu)
	);

	/* Branch condition (b = rs2 for branches). */
	reg br_cond;

	always @(*) begin
		case (f3)
		3'd0: br_cond = br_eq;
		3'd1: br_cond = !br_eq;
		3'd4: br_cond = br_lt;
		3'd5: br_cond = !br_lt;
		3'd6: br_cond = br_ltu;
		default: br_cond = !br_ltu;
		endcase
	end

	/* PC arithmetic. */
	wire [31:0] pc_imm = pc_e + (is_jal ? imm_j : is_br ? imm_b : imm_u);
	wire [31:0] link = pc_e + 32'd4;
	wire [31:0] jalr_t = {alu_y[31:1], 1'b0};
	wire taken = is_jal || is_jalr || (is_br && br_cond) || is_mret;
	wire [31:0] target = is_mret ? mepc : is_jalr ? jalr_t : pc_imm;

	/* Multiply/divide. */
	wire md_busy, md_done;
	wire [31:0] md_y;

	/* Faults of the instruction in E. */
	/* The data address has its own adder (not through the ALU's result mux: timing). */
	wire [31:0] ea_full = rs1 + (is_st ? imm_s : imm_i);
	wire [1:0] ea = ea_full[1:0];
	wire mis_mem = is_mem && (f3[1:0] == 2'd2 ? ea != 2'd0 :
		f3[1:0] == 2'd1 ? ea[0] : 1'b0);
	wire mis_jump = taken && target[1:0] != 2'd0;
	wire pc_out = pc_e[31:16] != 16'd0;
	wire bad = !legal || mis_mem || mis_jump || pc_out;

	/* Execution control. */
	wire take_irq = e_vld && !e_busy && !faulted && run && irq && !in_irq;
	wire exec = e_vld && !faulted && !take_irq && (run || e_busy);
	wire do_fault = exec && bad;
	/* A faulting instruction may still "complete" (it writes nothing and
	 * the core stops the next cycle), so e_done does not wait for the
	 * fault checks (timing). */
	wire md_start = exec && is_m && !e_busy && !pc_out;
	reg e_done;

	always @(*) begin
		if (!exec)
			e_done = 1'b0;
		else if (is_mem)
			e_done = d_ready;
		else if (is_m)
			e_done = e_busy && md_done;
		else if (is_wfi)
			e_done = irq;
		else
			e_done = 1'b1;
	end

	wire redirect = take_irq || (e_done && taken);
	/* D moves into E when E is empty or completes (and nothing is flushed). */
	/* E takes D's instruction when it is empty or completes; a redirect
	 * only marks it invalid (the data registers do not wait for it). */
	wire e_free = !e_vld || e_done;
	wire d_adv = d_vld && e_free;

	assign i_en = !faulted && (!d_vld || e_free);
	assign i_addr = {pc_f[31:2], 2'b00};
	assign stopped = faulted || (!run && !e_busy);

	/* Data port. */
	/* Only the checks that can hit a load/store gate it (not the branch's). */
	assign d_valid = exec && is_mem && !mis_mem && !pc_out;
	assign d_write = is_st;
	assign d_addr = ea_full;

	always @(*) begin
		case (f3[1:0])
		2'd0: begin
			d_be = 4'b0001 << ea;
			d_wdata = {4{rs2[7:0]}};
		end
		2'd1: begin
			d_be = ea[1] ? 4'b1100 : 4'b0011;
			d_wdata = {2{rs2[15:0]}};
		end
		default: begin
			d_be = 4'b1111;
			d_wdata = rs2;
		end
		endcase
	end

	/* Load extraction. */
	wire [31:0] ld_sh = d_rdata >> {ea, 3'b000};
	reg [31:0] ld_val;

	always @(*) begin
		case (f3)
		3'd0: ld_val = {{24{ld_sh[7]}}, ld_sh[7:0]};
		3'd1: ld_val = {{16{ld_sh[15]}}, ld_sh[15:0]};
		3'd4: ld_val = {24'd0, ld_sh[7:0]};
		3'd5: ld_val = {16'd0, ld_sh[15:0]};
		default: ld_val = ld_sh;
		endcase
	end

	/* Write-back value. */
	reg [31:0] wb;

	always @(*) begin
		if (is_ld)
			wb = ld_val;
		else if (is_m)
			wb = md_y;
		else if (is_jal || is_jalr)
			wb = link;
		else if (is_auipc)
			wb = pc_imm;
		else
			wb = alu_y;
	end

	/* W: the register write (repeated while W holds it: harmless). */
	always @(posedge clk) begin
		if (w_wen)
			rf[w_rd] <= w_val;
	end

	atg_cpu_muldiv muldiv (
		.clk(clk), .rst_n(rst_n), .start(md_start), .op(f3), .a(rs1), .b(rs2),
		.busy(md_busy), .done(md_done), .y(md_y)
	);

	always @(posedge clk) begin
		if (!rst_n) begin
			pc_f <= 32'd0;
			d_vld <= 1'b0;
			e_vld <= 1'b0;
			w_wen <= 1'b0;
			e_busy <= 1'b0;
			faulted <= 1'b0;
			in_irq <= 1'b0;
			mepc <= 32'd0;
			fault <= 1'b0;
			fault_pc <= 32'd0;
		end else begin
			fault <= 1'b0;
			if (do_fault) begin
				faulted <= 1'b1;
				fault <= 1'b1;
			end
			/* Follows E until the fault, then holds (no enable on the
			 * fault checks: timing). */
			if (!faulted)
				fault_pc <= pc_e;
			if (e_done)
				e_busy <= 1'b0;
			else if ((d_valid && !d_ready) || md_start)
				e_busy <= 1'b1;
			if (take_irq) begin
				mepc <= is_wfi ? link : pc_e;
				in_irq <= 1'b1;
			end else if (e_done && is_mret) begin
				in_irq <= 1'b0;
			end
			if (e_done)
				w_wen <= has_rd && rd != 5'd0 && !bad;
			/* E. */
			if (d_adv)
				e_vld <= !redirect;
			else if (e_done || take_irq)
				e_vld <= 1'b0;
			/* F and D. */
			if (redirect) begin
				pc_f <= take_irq ? IRQ_VECTOR : target;
				d_vld <= 1'b0;
			end else if (i_en) begin
				pc_f <= pc_f + 32'd4;
				d_vld <= 1'b1;
			end
		end
	end

	/* Data registers of the stages (no reset: their valid bits guard them). */
	always @(posedge clk) begin
		if (i_en)
			pc_d <= pc_f;
		if (d_adv) begin
			pc_e <= pc_d;
			ir_e <= i_rdata;
			rs1_e <= d_rs1;
			rs2_e <= d_rs2;
			/* What W will hold while this instruction is in E. */
			fwd1_e <= d_ra != 5'd0 && (e_done ? (has_rd && rd == d_ra) : (w_wen && w_rd == d_ra));
			fwd2_e <= d_rb != 5'd0 && (e_done ? (has_rd && rd == d_rb) : (w_wen && w_rd == d_rb));
		end
		if (e_done) begin
			w_rd <= rd;
			w_val <= wb;
		end
	end

	wire unused_ok = &{1'b0, md_busy, alu_eq, alu_lt, alu_ltu, br_y};
endmodule

`default_nettype wire
