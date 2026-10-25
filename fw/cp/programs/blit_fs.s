# The fragment program of the firmware's blit draw: the source texel at
# the interpolated unnormalized coordinates (varyings 0 and 1, slot 0, the
# sampler's filter), written to colour attachment 0, every sample kept.
	lda r10, 16	# u of vertices 0, 1, 2 (primitive-table word 4)
	lda r11, 17
	lda r12, 18
	lda r20, 20	# v (word 5)
	lda r21, 21
	lda r22, 22
	fmul.s r13, r0, r10
	fmadd.s r13, r1, r11, r13
	fmadd.s r13, r2, r12, r13
	fmul.s r14, r0, r20
	fmadd.s r14, r1, r21, r14
	fmadd.s r14, r2, r22, r14
	texl r16, r13, zero, 0
	exp r16, 0x100
	exp r17, 0x101
	exp r18, 0x102
	exp r19, 0x103
	movi r23, -1
	exp r23, 0x105
	end
