/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_setup_uc.vh: the micro-program of atg_rx_setup, written by
 * tools/rx-ucode.py (do not edit).  {op, d, a, b}: op 0 END, 1 ADD,
 * 2 SUB, 3 MUL, 4 DIV, 5 MOV, 6 INT, 7 JMP d, 8 ENDR.  Entry 0 for raw
 * triangles, ATG_RX_UC_PERSP for the others.
 */

localparam [6:0] ATG_RX_UC_PERSP = 7'd10;

function [24:0] atg_rx_uc;
	input [6:0] pc;
	case (pc)
	7'd0: atg_rx_uc = {4'd5, 7'd31, 7'd0, 7'd0};	/* MOV */
	7'd1: atg_rx_uc = {4'd5, 7'd32, 7'd1, 7'd0};	/* MOV */
	7'd2: atg_rx_uc = {4'd5, 7'd33, 7'd2, 7'd0};	/* MOV */
	7'd3: atg_rx_uc = {4'd5, 7'd34, 7'd4, 7'd0};	/* MOV */
	7'd4: atg_rx_uc = {4'd5, 7'd35, 7'd5, 7'd0};	/* MOV */
	7'd5: atg_rx_uc = {4'd5, 7'd36, 7'd6, 7'd0};	/* MOV */
	7'd6: atg_rx_uc = {4'd5, 7'd37, 7'd8, 7'd0};	/* MOV */
	7'd7: atg_rx_uc = {4'd5, 7'd38, 7'd9, 7'd0};	/* MOV */
	7'd8: atg_rx_uc = {4'd5, 7'd39, 7'd10, 7'd0};	/* MOV */
	7'd9: atg_rx_uc = {4'd7, 7'd46, 7'd0, 7'd0};	/* JMP */
	7'd10: atg_rx_uc = {4'd4, 7'd28, 7'd27, 7'd3};	/* DIV */
	7'd11: atg_rx_uc = {4'd3, 7'd48, 7'd0, 7'd28};	/* MUL */
	7'd12: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd21};	/* MUL */
	7'd13: atg_rx_uc = {4'd1, 7'd31, 7'd48, 7'd23};	/* ADD */
	7'd14: atg_rx_uc = {4'd3, 7'd48, 7'd1, 7'd28};	/* MUL */
	7'd15: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd22};	/* MUL */
	7'd16: atg_rx_uc = {4'd1, 7'd32, 7'd48, 7'd24};	/* ADD */
	7'd17: atg_rx_uc = {4'd3, 7'd48, 7'd2, 7'd28};	/* MUL */
	7'd18: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd25};	/* MUL */
	7'd19: atg_rx_uc = {4'd1, 7'd33, 7'd48, 7'd26};	/* ADD */
	7'd20: atg_rx_uc = {4'd3, 7'd52, 7'd12, 7'd28};	/* MUL */
	7'd21: atg_rx_uc = {4'd3, 7'd55, 7'd13, 7'd28};	/* MUL */
	7'd22: atg_rx_uc = {4'd4, 7'd29, 7'd27, 7'd7};	/* DIV */
	7'd23: atg_rx_uc = {4'd3, 7'd48, 7'd4, 7'd29};	/* MUL */
	7'd24: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd21};	/* MUL */
	7'd25: atg_rx_uc = {4'd1, 7'd34, 7'd48, 7'd23};	/* ADD */
	7'd26: atg_rx_uc = {4'd3, 7'd48, 7'd5, 7'd29};	/* MUL */
	7'd27: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd22};	/* MUL */
	7'd28: atg_rx_uc = {4'd1, 7'd35, 7'd48, 7'd24};	/* ADD */
	7'd29: atg_rx_uc = {4'd3, 7'd48, 7'd6, 7'd29};	/* MUL */
	7'd30: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd25};	/* MUL */
	7'd31: atg_rx_uc = {4'd1, 7'd36, 7'd48, 7'd26};	/* ADD */
	7'd32: atg_rx_uc = {4'd3, 7'd53, 7'd15, 7'd29};	/* MUL */
	7'd33: atg_rx_uc = {4'd3, 7'd56, 7'd16, 7'd29};	/* MUL */
	7'd34: atg_rx_uc = {4'd4, 7'd30, 7'd27, 7'd11};	/* DIV */
	7'd35: atg_rx_uc = {4'd3, 7'd48, 7'd8, 7'd30};	/* MUL */
	7'd36: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd21};	/* MUL */
	7'd37: atg_rx_uc = {4'd1, 7'd37, 7'd48, 7'd23};	/* ADD */
	7'd38: atg_rx_uc = {4'd3, 7'd48, 7'd9, 7'd30};	/* MUL */
	7'd39: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd22};	/* MUL */
	7'd40: atg_rx_uc = {4'd1, 7'd38, 7'd48, 7'd24};	/* ADD */
	7'd41: atg_rx_uc = {4'd3, 7'd48, 7'd10, 7'd30};	/* MUL */
	7'd42: atg_rx_uc = {4'd3, 7'd48, 7'd48, 7'd25};	/* MUL */
	7'd43: atg_rx_uc = {4'd1, 7'd39, 7'd48, 7'd26};	/* ADD */
	7'd44: atg_rx_uc = {4'd3, 7'd54, 7'd18, 7'd30};	/* MUL */
	7'd45: atg_rx_uc = {4'd3, 7'd57, 7'd19, 7'd30};	/* MUL */
	7'd46: atg_rx_uc = {4'd6, 7'd0, 7'd0, 7'd0};	/* INT */
	7'd47: atg_rx_uc = {4'd4, 7'd47, 7'd27, 7'd44};	/* DIV */
	7'd48: atg_rx_uc = {4'd2, 7'd48, 7'd36, 7'd33};	/* SUB */
	7'd49: atg_rx_uc = {4'd2, 7'd49, 7'd39, 7'd33};	/* SUB */
	7'd50: atg_rx_uc = {4'd3, 7'd50, 7'd48, 7'd43};	/* MUL */
	7'd51: atg_rx_uc = {4'd3, 7'd51, 7'd49, 7'd41};	/* MUL */
	7'd52: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd53: atg_rx_uc = {4'd3, 7'd64, 7'd50, 7'd47};	/* MUL */
	7'd54: atg_rx_uc = {4'd3, 7'd50, 7'd49, 7'd40};	/* MUL */
	7'd55: atg_rx_uc = {4'd3, 7'd51, 7'd48, 7'd42};	/* MUL */
	7'd56: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd57: atg_rx_uc = {4'd3, 7'd65, 7'd50, 7'd47};	/* MUL */
	7'd58: atg_rx_uc = {4'd3, 7'd50, 7'd64, 7'd45};	/* MUL */
	7'd59: atg_rx_uc = {4'd3, 7'd51, 7'd65, 7'd46};	/* MUL */
	7'd60: atg_rx_uc = {4'd1, 7'd50, 7'd50, 7'd51};	/* ADD */
	7'd61: atg_rx_uc = {4'd1, 7'd66, 7'd33, 7'd50};	/* ADD */
	7'd62: atg_rx_uc = {4'd8, 7'd0, 7'd0, 7'd0};	/* ENDR */
	7'd63: atg_rx_uc = {4'd2, 7'd48, 7'd29, 7'd28};	/* SUB */
	7'd64: atg_rx_uc = {4'd2, 7'd49, 7'd30, 7'd28};	/* SUB */
	7'd65: atg_rx_uc = {4'd3, 7'd50, 7'd48, 7'd43};	/* MUL */
	7'd66: atg_rx_uc = {4'd3, 7'd51, 7'd49, 7'd41};	/* MUL */
	7'd67: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd68: atg_rx_uc = {4'd3, 7'd67, 7'd50, 7'd47};	/* MUL */
	7'd69: atg_rx_uc = {4'd3, 7'd50, 7'd49, 7'd40};	/* MUL */
	7'd70: atg_rx_uc = {4'd3, 7'd51, 7'd48, 7'd42};	/* MUL */
	7'd71: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd72: atg_rx_uc = {4'd3, 7'd68, 7'd50, 7'd47};	/* MUL */
	7'd73: atg_rx_uc = {4'd3, 7'd50, 7'd67, 7'd45};	/* MUL */
	7'd74: atg_rx_uc = {4'd3, 7'd51, 7'd68, 7'd46};	/* MUL */
	7'd75: atg_rx_uc = {4'd1, 7'd50, 7'd50, 7'd51};	/* ADD */
	7'd76: atg_rx_uc = {4'd1, 7'd69, 7'd28, 7'd50};	/* ADD */
	7'd77: atg_rx_uc = {4'd2, 7'd48, 7'd53, 7'd52};	/* SUB */
	7'd78: atg_rx_uc = {4'd2, 7'd49, 7'd54, 7'd52};	/* SUB */
	7'd79: atg_rx_uc = {4'd3, 7'd50, 7'd48, 7'd43};	/* MUL */
	7'd80: atg_rx_uc = {4'd3, 7'd51, 7'd49, 7'd41};	/* MUL */
	7'd81: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd82: atg_rx_uc = {4'd3, 7'd70, 7'd50, 7'd47};	/* MUL */
	7'd83: atg_rx_uc = {4'd3, 7'd50, 7'd49, 7'd40};	/* MUL */
	7'd84: atg_rx_uc = {4'd3, 7'd51, 7'd48, 7'd42};	/* MUL */
	7'd85: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd86: atg_rx_uc = {4'd3, 7'd71, 7'd50, 7'd47};	/* MUL */
	7'd87: atg_rx_uc = {4'd3, 7'd50, 7'd70, 7'd45};	/* MUL */
	7'd88: atg_rx_uc = {4'd3, 7'd51, 7'd71, 7'd46};	/* MUL */
	7'd89: atg_rx_uc = {4'd1, 7'd50, 7'd50, 7'd51};	/* ADD */
	7'd90: atg_rx_uc = {4'd1, 7'd72, 7'd52, 7'd50};	/* ADD */
	7'd91: atg_rx_uc = {4'd2, 7'd48, 7'd56, 7'd55};	/* SUB */
	7'd92: atg_rx_uc = {4'd2, 7'd49, 7'd57, 7'd55};	/* SUB */
	7'd93: atg_rx_uc = {4'd3, 7'd50, 7'd48, 7'd43};	/* MUL */
	7'd94: atg_rx_uc = {4'd3, 7'd51, 7'd49, 7'd41};	/* MUL */
	7'd95: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd96: atg_rx_uc = {4'd3, 7'd73, 7'd50, 7'd47};	/* MUL */
	7'd97: atg_rx_uc = {4'd3, 7'd50, 7'd49, 7'd40};	/* MUL */
	7'd98: atg_rx_uc = {4'd3, 7'd51, 7'd48, 7'd42};	/* MUL */
	7'd99: atg_rx_uc = {4'd2, 7'd50, 7'd50, 7'd51};	/* SUB */
	7'd100: atg_rx_uc = {4'd3, 7'd74, 7'd50, 7'd47};	/* MUL */
	7'd101: atg_rx_uc = {4'd3, 7'd50, 7'd73, 7'd45};	/* MUL */
	7'd102: atg_rx_uc = {4'd3, 7'd51, 7'd74, 7'd46};	/* MUL */
	7'd103: atg_rx_uc = {4'd1, 7'd50, 7'd50, 7'd51};	/* ADD */
	7'd104: atg_rx_uc = {4'd1, 7'd75, 7'd55, 7'd50};	/* ADD */
	7'd105: atg_rx_uc = {4'd0, 7'd0, 7'd0, 7'd0};	/* END */
	default: atg_rx_uc = 25'd0;
	endcase
endfunction
