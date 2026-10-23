# SU test: vector add c[i] = a[i] + b[i] (fp32) over the dispatch, i = 128
# wgx + lidn; a at 0x8400, b at 0x8800, c at 0x9000 (the board's program,
# with 2 workgroups in the testbench).
	movi r1, 128
	mul r1, r1, wgx
	add r1, r1, lidn            # i
	slli r1, r1, 2
	movi r2, 0x8400
	add r2, r2, r1
	lw r3, 0(r2)                # a[i]
	lw r4, 0x400(r2)            # b[i]
	fadd.s r5, r3, r4
	movi r6, 0x9000
	add r6, r6, r1
	sw r5, 0(r6)
	end
