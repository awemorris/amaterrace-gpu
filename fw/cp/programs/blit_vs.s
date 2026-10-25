# The vertex program of the firmware's blit draw: a triangle strip of four
# vertices from the vertex index in r0 (bit 0: x0 or x1, bit 1: y0 or y1),
# positions in pixels (the viewport is the identity) and the source's
# unnormalized texel coordinates as varyings 0 and 1.  Constant bank: c0
# c1 the destination's x0 y0, c2 c3 its x1 y1, c4 c5 the source's u0 v0,
# c6 c7 its u1 v1 (fp32).
	andi r1, r0, 1
	sub r1, zero, r1	# all ones for x1
	srli r2, r0, 1
	andi r2, r2, 1
	sub r2, zero, r2	# all ones for y1
	sel r3, r1, c2, c0	# x
	sel r4, r2, c3, c1	# y
	sel r5, r1, c6, c4	# u
	sel r6, r2, c7, c5	# v
	exp r3, 0x000
	exp r4, 0x001
	exp zero, 0x002
	exp one, 0x003
	exp r5, 0x010
	exp r6, 0x011
	end
