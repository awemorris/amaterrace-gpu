# SU test: global memory (coalesced and scattered lw/sw, a warp's sw then lw
# of the same word, masked and killed stores, atomics on private and on one
# shared word, fence), the constant bank (lwc, c operands) and LDS with a
# barrier between warps.  128 lanes; data image from gen_data.py.
	slli r1, lidn, 2            # r1 = 4 * lidn
	movi r2, 0x8400             # A
	add r3, r2, r1
	lw r4, 0(r3)                # A[lidn], coalesced
	lw r5, 512(r3)              # A[lidn + 128]
	add r6, r4, r5
	movi r7, 0x9000             # outputs
	add r8, r7, r1
	sw r6, 0(r8)                # out[lidn]
	movi r9, 37
	mul r10, lidn, r9
	andi r10, r10, 255
	slli r10, r10, 2
	add r11, r2, r10
	lw r12, 0(r11)              # gather A[(37 lidn) & 255]
	sw r12, 0x200(r8)
	lw r13, 0x200(r8)           # the warp's own store, read back
	addi r13, r13, 1
	sw r13, 0x200(r8)
	exec.save r30
	andi r14, lane, 1
	sltiu r15, r14, 1           # even lanes
	exec.and r15
	sw lidn, 0x400(r8)          # only even lanes
	exec.set r30
	lwc r16, 3(lane)            # cbank[lane + 3]
	add r17, c5, c31
	add r18, r16, c0
	lwc r19, -1(r16)            # a data-dependent index (mod 256)
	movi r20, 0x9800
	add r20, r20, r1            # private atomic words
	atom.add r21, (r20), lidn
	atom.xchg r22, (r20), r21
	atom.cmpxchg r23, (r20), r6, r22    # equal: r6 stored
	atom.umax r24, (r20), lane
	atom.smin r25, (r20), r4
	atom.and r26, (r20), r12
	atom.or r27, (r20), r5
	atom.xor r28, (r20), r9
	atom.sub r29, (r20), onei
	atom.smax r31, (r20), r29
	atom.umin r0, (r20), r31
	movi r9, 0x9A00
	atom.add r10, (r9), onei    # shared: 128 adds
	movi r10, 0                 # (the old value depends on the order)
	fence 5                     # global + acquire
	lw r11, 0(r20)              # after the atomics (the D$ was invalidated)
	sts lidn, 0(r1)             # LDS[lidn] = lidn
	bar
	xori r14, r1, 128           # the neighbouring warp's lane
	lds r15, 0(r14)
	addi r14, r1, 4
	andi r14, r14, 511
	lds r16, 0(r14)             # the next lane's word (wraps at 128 lanes)
	exec.save r30
	andi r12, lane, 7
	xori r12, r12, 5
	sltiu r12, r12, 1           # lane % 8 == 5
	kill r12
	sw r15, 0x600(r8)           # killed lanes do not store
	exec.set r30
	end
