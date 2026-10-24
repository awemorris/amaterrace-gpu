# SU test (sim/tb/atg_su_gfx_tb.v): one program for a vertex warp (slot 0)
# and three fragment warps (slots 1-3) started through vl_*/fl_* with
# r0-r5 already written (fragment: b0, b1, b2, z, x + 0.5, y + 0.5 of the
# quads; vertex: attributes).  Fragment EXEC is whole quads, the mask
# operand the coverage, so the uncovered lanes of a quad are helper lanes
# (design §3.1, M10): they take part in qd, shfl, vote and ballot, but have
# no side effects (sw, atom, sts, exp); neither have killed lanes.  Also the
# packed arithmetic (PACKED) and the export targets of both warp kinds.
# Needs SUBGROUP and PACKED.
	slli r6, warp, 7
	slli r7, lane, 2
	add r6, r6, r7
	movi r7, 0x9000
	add r6, r6, r7               # 0x9000 + 128 warp + 4 lane
	lw r8, 0(r6)                 # random per lane (helper lanes load too)
	# Quad differences: helper lanes are the partners.
	qdx r9, r0
	qdy r10, r1
	qswap1 r11, r2
	qswap3 r12, r3
	qbcast r13, r5
	fadd.s r14, r9, r10
	sw r14, 0(r6)                # not from helper lanes
	# The mask operand and the subgroup instructions over the helper lanes.
	srl r15, mask, lane
	andi r15, r15, 1
	slt r15, zero, r15           # Boolean: the lane is covered (a valid vertex)
	ballot r16, r15              # mask & EXEC
	vote.all r17, r15            # false when the warp has helper lanes
	ballot r18, one              # EXEC, helper lanes included
	shfl.xor r19, r0, onei       # the partner's b0 (a helper is a source)
	andi r20, r8, 31
	shfl.idx r20, r13, r20       # a random source lane
	# LDS: every lane of a quad stores its lane number into the quad's word;
	# the highest covered lane wins (helper lanes store nothing).
	srli r21, lane, 2
	slli r21, r21, 2
	slli r22, warp, 5
	add r21, r21, r22            # 32 warp + 4 quad
	sts lane, 0(r21)
	fence 2
	lds r22, 0(r21)
	# A per-warp counter: one add per side-effect lane.
	slli r23, warp, 2
	movi r24, 0xA000
	add r23, r23, r24
	atom.add r24, (r23), onei
	# Kill a random set of lanes (covered and helper); killed lanes stay in
	# EXEC for qd and ballot but have no side effects.
	srli r25, r8, 3
	andi r25, r25, 1
	slt r25, zero, r25
	kill r25
	add r26, killed, zero
	qdx r27, r3
	ballot r28, r26
	vote.any r7, r26
	sw r27, 1024(r6)             # covered lanes not killed
	# Packed fp16 (PACKED).
	packh r29, r0, r1
	ffma2 r30, r29, r29, oneh2
	fmul2 r31, r30, r29
	# Fragment exports: colour from every EXEC lane, depth from some lanes.
	exp r9, 0x100
	exp r14, 0x101
	exp r31, 0x102
	exp r22, 0x103
	srli r12, r8, 4
	andi r12, r12, 1
	slt r12, zero, r12
	exec.save r10
	exec.and r12
	exp r30, 0x104
	exec.set r10
	# SAMPLE_MASK (0x105): the last value counts, ANDed with the RX's r6.
	exp r8, 0x105
	srli r4, r8, 8
	exp r4, 0x105
	# Vertex exports (a fragment warp ignores them, and a vertex warp the
	# fragment targets): position, varyings 0 and 15, then targets that are
	# not stored (point size, varying 16 beyond VARY_WORDS).
	exp r0, 0x000
	exp r1, 0x001
	exp r2, 0x002
	exp r3, 0x003
	exp r14, 0x010
	exp r31, 0x01F
	exp r9, 0x004
	exp r9, 0x020
	end
