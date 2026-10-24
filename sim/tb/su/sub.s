# SU test: the lane unit: qd, and the subgroup instructions (shfl in every
# mode with in-range, out-of-range and non-EXEC sources, vote, ballot) with
# EXEC full, partial and empty, back to back and in dependent chains.
# Needs SUBGROUP (an ISA fault at the first shfl without it).
	slli r2, lidn, 2
	movi r3, 0x8000
	add r2, r2, r3
	lw r1, 0(r2)                 # random per lane
	lw r20, 512(r2)              # random per lane (the controls)
	andi r4, r20, 63             # source lane / mask 0..63 (half out of range)
	srli r5, r20, 8
	andi r5, r5, 15              # delta 0..15
	qdx r21, r1
	qbcast r22, r1
	shfl.idx r6, r1, r4
	shfl.xor r7, r1, r4
	shfl.up r8, r1, r5
	shfl.down r9, r1, r5
	shfl.bfly r10, r1, r4
	shfl.up r11, r1, r20         # huge deltas: own value
	shfl.idx r12, r6, onei       # chain: reads the shfl result at once
	shfl.down r13, r12, o98
	add r14, r13, r6
	vote.any r15, r4
	vote.all r16, r4
	ballot r17, r4
	vote.all r18, onei
	vote.any r19, zero
	# EXEC: a random half of the lanes.
	srli r23, r20, 16
	andi r23, r23, 1
	slt r23, zero, r23           # Boolean
	exec.save r24
	exec.and r23
	shfl.idx r6, r1, r4
	shfl.xor r7, r1, r4
	shfl.up r8, r1, r5
	shfl.down r9, r1, r5
	shfl.bfly r10, r1, lane
	ballot r25, r4
	vote.all r26, r4
	vote.any r27, r23
	vote.all r28, r23            # true: every EXEC lane has r23
	qswap1 r29, r1
	# EXEC empty: vote/ballot still write every lane.
	exec.and zero
	ballot r30, onei
	vote.all r31, zero           # vacuously true
	vote.any r3, onei            # false
	shfl.idx r1, r1, zero        # writes nothing
	exec.set r24
	shfl.xor r2, r1, r5
	end
