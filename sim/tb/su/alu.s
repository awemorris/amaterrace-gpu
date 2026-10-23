# SU test: the integer ALU, dependent chains (short interlock), specials.
	add r1, lane, zero          # r1 = lane
	addi r2, r1, 100            # RAW on r1 right away
	slli r3, r2, 3
	sub r4, r3, r1
	movi r5, 0x12345678
	lui r6, 0xABCDE
	xor r7, r5, r6
	srai r8, r6, 7
	srli r9, r6, 7
	slt r10, r1, onei           # Boolean
	sltiu r11, r1, 16
	slti r12, r4, -5
	min r13, r8, r4
	max r14, r8, r4
	minu r15, r8, r4
	maxu r16, r8, r4
	andn r17, r5, r1
	orn r18, r1, r5
	xnor r19, r5, r3
	sel r20, r10, r5, r6        # lanes 0: r5, others r6
	add r21, lidn, warp
	or r22, r21, exec
	and r23, mask, r22
	sll r24, onei, r1
	srl r25, r6, r1
	sra r26, r6, r1
	sltu r27, r25, r26
	addi r28, r27, -1
	xori r29, r28, 0x7FF
	ori r30, r29, 0x100
	andi r31, r30, 0x0F0
	add r0, r31, r30
	addi r0, r0, 1              # back-to-back on one register
	addi r0, r0, 1
	addi r0, r0, 1
	add r1, r0, r0
	sub r1, r1, r31
	wait 0, 0, 0
	nop
	end
