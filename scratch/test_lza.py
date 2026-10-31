import random

def count_lz(val, bits=27):
    if val == 0:
        return 27
    s = bin(val)[2:].zfill(bits)
    for i in range(bits):
        if s[i] == '1':
            return i
    return bits

def lza_vector(a, b, bits=27):
    # Standard IEEE-754 Leading Zero Anticipator for A >= B:
    # Let P_i = A_i ^ B_i, G_i = A_i & ~B_i, Z_i = ~A_i & ~B_i
    # For subtraction, indicator string W_i:
    # W_i = P_i & ~Z_{i-1} | ~P_i & Z_{i-1} (or similar)
    # Let's test standard formulas.
    pass

# Let's check how many bits px2 and py2 have:
# px2 has leading 1 at bit 26: mx1 is 24 bits, px2 = {mx1, 3'b000} (27 bits).
# py2 has leading 1 at bit 26 (if d=0) or bit 25 (if d=1).
# In both cases, px2 >= py2!
print("Testing subtraction on d=0 and d=1:")
mismatches = 0
for _ in range(10000):
    mx1 = random.randint(1 << 23, (1 << 24) - 1)
    d = random.choice([0, 1])
    if d == 0:
        my1 = random.randint(1 << 23, mx1)
        px2 = mx1 << 3
        py2 = my1 << 3
    else:
        my1 = random.randint(1 << 23, (1 << 24) - 1)
        px2 = mx1 << 3
        py2 = my1 << 2
    diff = px2 - py2
    lz_actual = count_lz(diff, 27)

    # LZA formula:
    # Let's see: for each bit i from 26 down to 1:
    # Let A = px2, B = py2.
    # What is the leading one position of A - B?
