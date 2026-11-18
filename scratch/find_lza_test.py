import random

def count_lz(val, bits=27):
    if val == 0:
        return 27
    s = bin(val)[2:].zfill(bits)
    for i in range(bits):
        if s[i] == '1':
            return i
    return bits

# Standard Bruguera & Lang LZA for A - B:
# For each bit i from n-1 down to 1:
# Let A_i, B_i be bits of A and B.
# In subtraction A - B:
# Let P_i = A_i ^ B_i
# Let G_i = A_i & ~B_i
# Let Z_i = ~A_i & ~B_i  (or ~A_i & B_i depending on convention)
# Let's test the exact indicator bit E_i:
# A known formula for A >= B:
# E_i = P_i ^ ( (A_{i-1} & ~B_{i-1}) ? 0 : (~A_{i-1} & B_{i-1}) ? 0 : ... )
# Let's write a small brute-force finder:

def find_exact_lz():
    # Test on 10,000 cases of d=0 and d=1:
    cases = []
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
            if px2 < py2:
                continue
        diff = px2 - py2
        lz = count_lz(diff, 27)
        cases.append((px2, py2, lz))
    return cases

cases = find_exact_lz()
print(f"Generated {len(cases)} valid cases.")
