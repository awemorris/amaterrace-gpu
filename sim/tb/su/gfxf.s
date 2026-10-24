# SU test (sim/tb/atg_su_gfx_tb.v, the loop): the fragment program: r0 is
# a loop count (the same in every lane of a warp), so warps end out of
# their sequence order; COLOR0 R gets the count of iterations, G-A r0.
	addi r6, zero, 0
loop:
	addi r6, r6, 1
	slt r7, r6, r0
	bany r7, loop
	exp r6, 0x100
	exp r0, 0x101
	exp r0, 0x102
	exp r0, 0x103
	end
