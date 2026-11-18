import struct
import numpy as np

def f2u(f):
    return struct.unpack('>I', struct.pack('>f', f))[0]

def u2f(u):
    return struct.unpack('>f', struct.pack('>I', u))[0]

def ref_sub1(u):
    # What IEEE 754 1.0 - x does
    f = u2f(u)
    res_f = np.float32(1.0) - np.float32(f)
    return f2u(res_f)

print("Test 0.0:", hex(ref_sub1(0x00000000)))  # 1.0 = 0x3f800000
print("Test 1.0:", hex(ref_sub1(0x3f800000)))  # 0.0 = 0x00000000
print("Test 0.5:", hex(ref_sub1(0x3f000000)))  # 0.5 = 0x3f000000
print("Test 0.25:", hex(ref_sub1(0x3e800000))) # 0.75 = 0x3f400000
print("Test 0.75:", hex(ref_sub1(0x3f400000))) # 0.25 = 0x3e800000
