# The compute program of a copy from a buffer of 1-byte stencil values to
# the stencil byte ([31:24]) of D24_UNORM_S8_UINT texels: one lane per
# texel.  Constant bank: c0 the width, c1 the texels, c2 the buffer's
# first byte, c3 its row in bytes, c4 the image's first texel, c5 its row
# in bytes.  Workgroups of 64 lanes.
	slli r0, wgx, 6
	add r0, r0, lidn	# the texel's index
	sltu r1, r0, c1
	exec.and r1		# the texels of the region only
	divu r2, r0, c0		# y
	remu r3, r0, c0		# x
	mul r4, r2, c3
	add r4, r4, r3
	add r4, r4, c2		# the value's byte
	andi r5, r4, -4
	andi r6, r4, 3
	slli r6, r6, 3		# its shift in the word
	mul r7, r2, c5
	slli r8, r3, 2
	add r7, r7, r8
	add r7, r7, c4		# the texel
	lw r9, 0(r5)
	srl r9, r9, r6
	andi r9, r9, 255
	slli r9, r9, 24
	lw r10, 0(r7)
	slli r10, r10, 8
	srli r10, r10, 8
	or r10, r10, r9
	sw r10, 0(r7)
	end
