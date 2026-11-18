# The compute program of a copy from the stencil byte of D24_UNORM_S8_UINT
# texels to a buffer of 1-byte values: one lane per texel; the lanes of
# one buffer word merge their bytes with atomics (the other bytes of the
# word stay).  The constant bank as for s8_to_image.
	slli r0, wgx, 6
	add r0, r0, lidn
	sltu r1, r0, c1
	exec.and r1
	divu r2, r0, c0
	remu r3, r0, c0
	mul r4, r2, c3
	add r4, r4, r3
	add r4, r4, c2
	andi r5, r4, -4
	andi r6, r4, 3
	slli r6, r6, 3
	mul r7, r2, c5
	slli r8, r3, 2
	add r7, r7, r8
	add r7, r7, c4
	lw r9, 0(r7)
	srli r9, r9, 24
	sll r9, r9, r6		# the value in its byte
	addi r10, zero, 255
	sll r10, r10, r6
	xori r10, r10, -1	# every other byte
	atom.and r11, (r5), r10
	atom.or r11, (r5), r9
	end
