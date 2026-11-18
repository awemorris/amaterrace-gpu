import random

def count_lz(val, bits=27):
    if val == 0:
        return 27
    s = bin(val)[2:].zfill(bits)
    for i in range(bits):
        if s[i] == '1':
            return i
    return bits

# When d=0 or d=1 and sub2=1:
# A = px2, B = py2. A >= B.
# Both A and B are 27 bits.
# A[26] is always 1 (since mx1 >= 2^23).
# If d=0, B[26] is 1. Both A[2:0]=0, B[2:0]=0.
# If d=1, B[25] is 1, B[26]=0. A[2:0]=0, B[1:0]=0.

# Let's test standard LZA:
# For A - B:
# Propagate P_i = A_i ^ ~B_i (where ~B is bitwise NOT of B, i.e. in 2's complement A + ~B + 1)
# Generate  G_i = A_i & ~B_i
# Kill/Zero Z_i = ~A_i & B_i
#
# A bitwise indicator string e_i is:
# e_i = P_i & ~P_{i-1} (transition from P to G/Z)
# OR for positive subtraction (A >= B):
# e_i = P_{i+1} & (G_i & ~Z_{i-1} | Z_i & ~G_{i-1}) ...
# Let's test!

# Actually, why not check how many bits A and B have?
# mx1 and my1 are 24 bits.
# Can we compute the leading zeros of A - B directly?
# Wait! How many LUTs does it take to compute the leading zeros of (A - B)?
# Wait! In Kintex-7 / ASIC, why not a small subtraction?
# Wait: if we do a subtraction in LZA, does it use CARRY4?
# YES! If you write `A - B`, Vivado uses CARRY4!
# And if it uses CARRY4, then `lz` after CARRY4 has post-LUTs!
# That's why LZA DOES NOT DO SUBTRACTION!
# LZA is a BITWISE Boolean function of (A, B), followed by priority encoding!

def lza_indicators(A, B, n=27):
    # Suzuki et al. / IEEE standard LZA indicator:
    # Let p_i = A_i ^ B_i
    # Let g_i = A_i & ~B_i
    # Let z_i = ~A_i & B_i
    # For A >= B:
    # A string of G's followed by Z's or P's:
    # The leading one of A - B is indicated by:
    # w_i = p_i ^ ( (g_{i-1} & ~z_{i-2}) | (z_{i-1} & ~g_{i-2}) )
    # Let's test this formula!
    w = [0] * n
    for i in range(1, n):
        # We need p_i, and lookahead to i-1
        p_i = ((A >> i) & 1) ^ ((B >> i) & 1)
        # In subtraction A - B:
        # If A[i-1] != B[i-1]:
        # let's test simpler indicator:
        pass

# Let's find the exact indicator using brute-force search on 3-bit window (A[i..i-1], B[i..i-1])!
