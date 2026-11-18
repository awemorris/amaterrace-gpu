# SU test: reduction of 256 fp32 values a[0..255] (0x8400) by one workgroup
# of 128 lanes: each lane adds a[lidn] and a[lidn + 128], then a tree in LDS
# with a barrier per level; lane 0 stores the sum at 0x9000.  Every lane
# also adds lidn to the word at 0x9004 with atom.add (8128 in all).  Then
# the shared-memory atomics (atoms): every operation on a private LDS word
# per lane, two lanes (l and l + 8) on one word in lane order, and all 128
# lanes adding lidn to one LDS word (8128 after a barrier).
	slli r1, lidn, 2
	movi r2, 0x8400
	add r2, r2, r1
	lw r3, 0(r2)
	lw r4, 512(r2)
	fadd.s r3, r3, r4
	sts r3, 0(r1)
	movi r5, 64                 # s
	exec.save r30
loop:
	bar
	exec.set r30
	slt r6, lidn, r5            # lidn < s
	exec.and r6
	slli r7, r5, 2
	add r7, r7, r1
	lds r8, 0(r1)
	lds r9, 0(r7)
	fadd.s r8, r8, r9
	sts r8, 0(r1)
	exec.set r30
	srli r5, r5, 1
	movi r10, 0
	slt r11, r10, r5            # s > 0 (the same in every lane)
	bany r11, loop
	movi r15, 0x9004
	atom.add r16, (r15), lidn   # all 128 lanes (4 warps) on one word
	movi r16, 0                 # (the old value depends on the order)
	bar
	sltiu r12, lidn, 1
	exec.and r12                # lane 0 of warp 0
	lds r13, 0(zero)
	movi r14, 0x9000
	sw r13, 0(r14)
	exec.set r30
	addi r17, r1, 0x400         # LDS word 256 + lidn: private
	sts lidn, 0(r17)
	andi r28, r1, -33           # lidn with bit 3 cleared: lanes l, l + 8
	addi r28, r28, 0x800
	sts zero, 0(r28)
	movi r19, 0x200
	sts zero, 0(r19)            # the shared sum
	bar
	atoms.add r18, (r19), lidn  # all 128 lanes on one word
	movi r18, 0                 # (the old value depends on the warps' order)
	atoms.add r20, (r17), onei  # lidn -> lidn + 1
	atoms.xchg r21, (r17), r1   # -> 4 lidn
	atoms.cmpxchg r22, (r17), lane, r1  # equal: lane stored
	atoms.cmpxchg r23, (r17), r1, r5    # not equal (but lane 0): no store
	atoms.umax r24, (r17), r15  # 0x9004
	atoms.smin r25, (r17), r10  # 0
	atoms.or r26, (r17), r1
	atoms.xor r27, (r17), lidn
	atoms.sub r29, (r17), mone
	atoms.smax r31, (r17), r29
	atoms.umin r0, (r17), r21
	atoms.and r3, (r17), r31
	lds r4, 0(r17)
	atoms.add r6, (r28), lidn   # lane l + 8 sees lane l's add
	atoms.xchg r7, (r28), r6    # in lane order again
	lds r8, 0(r28)
	bar
	lds r19, 0x200(zero)        # 8128
	end
