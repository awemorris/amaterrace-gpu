# SU test: reduction of 256 fp32 values a[0..255] (0x8400) by one workgroup
# of 128 lanes: each lane adds a[lidn] and a[lidn + 128], then a tree in LDS
# with a barrier per level; lane 0 stores the sum at 0x9000 (no atomics:
# the board program, the ZYBO's atg_mc_atom is a stub).
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
	bar
	sltiu r12, lidn, 1
	exec.and r12                # lane 0 of warp 0
	lds r13, 0(zero)
	movi r14, 0x9000
	sw r13, 0(r14)
	exec.set r30
	end
