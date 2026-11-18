# SU test: exec mask, divergence, loops and the branches.
	movi r1, 0
	add r2, lane, zero
	andi r3, r2, 1               # odd lanes
	slt r4, zero, r3             # Boolean odd
	exec.save r5
	exec.and r4                  # odd lanes only
	bexz skip
	addi r1, r1, 7               # only odd lanes
skip:
	exec.set r5                  # all lanes back
	addi r6, zero, 0             # loop: r6 counts to lane % 8
	andi r7, r2, 7
	exec.save r8
loop:
	slt r9, r6, r7               # still counting?
	exec.and r9
	bexz done
	addi r6, r6, 1
	j loop
done:
	exec.set r8
	addi r10, r6, 0
	bany r4, any_ok
	movi r11, 0xBAD
	j next
any_ok:
	movi r11, 0x600D
next:
	bnone r4, bad
	ball r4, bad
	slt r12, r2, o98             # r12 = lane < 1 (Boolean, lane 0)
	bany r12, l0
	movi r13, 0xBAD
l0:
	movi r13, 0x1
	bar
	sltiu r14, r2, 64
	ball r14, all_ok
bad:
	movi r15, 0xBAD
	end
all_ok:
	movi r15, 0x2
	kill r4
	add r16, killed, zero
	exec.save r17
	bexnz fin
	movi r15, 0xBAD
fin:
	end
