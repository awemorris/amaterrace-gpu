#!/usr/bin/env python3
# rx-ucode.py: writes include/atg_rx_setup_uc.vh, the micro-program of
# atg_rx_setup (spec/gpu/rx/atg_rx_setup.md §4), from the listing below,
# and include/atg_rop_unorm8.vh, the table c -> fp32(c / 255) of the ROP's
# DEBUG_COLOR (tools/rxmodel.py's UNORM8).
# A micro-instruction is {op[3:0], d[6:0], a[6:0], b[6:0]}; the fp
# register numbers are the spec's.
#   tools/rx-ucode.py
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import sys

OPS = {'END': 0, 'ADD': 1, 'SUB': 2, 'MUL': 3, 'DIV': 4, 'MOV': 5, 'INT': 6, 'JMP': 7,
       'ENDR': 8}


def V(i, c):
    return 4 * i + c


def W(i, j):
    return 12 + 3 * i + j


XS, YS, XO, YO, ZS, ZO, ONE = range(21, 28)


def RW(i):
    return 28 + i


def X(i):
    return 31 + 3 * i


def Y(i):
    return 32 + 3 * i


def Z(i):
    return 33 + 3 * i


DX1, DY1, DX2, DY2, DF, OX, OY, RD = range(40, 48)
T0, T1, T2, T3 = range(48, 52)


def B0W(i):
    return 52 + i


def B1W(i):
    return 55 + i


AZ, AW, A0, A1 = 64, 67, 70, 73


def plane(f, a):
    return [('SUB', T0, f[1], f[0]), ('SUB', T1, f[2], f[0]),
            ('MUL', T2, T0, DY2), ('MUL', T3, T1, DY1), ('SUB', T2, T2, T3), ('MUL', a, T2, RD),
            ('MUL', T2, T1, DX1), ('MUL', T3, T0, DX2), ('SUB', T2, T2, T3),
            ('MUL', a + 1, T2, RD),
            ('MUL', T2, a, OX), ('MUL', T3, a + 1, OY), ('ADD', T2, T2, T3),
            ('ADD', a + 2, f[0], T2)]


def program():
    raw = []
    for i in range(3):
        raw += [('MOV', X(i), V(i, 0), 0), ('MOV', Y(i), V(i, 1), 0), ('MOV', Z(i), V(i, 2), 0)]
    persp = []
    for i in range(3):
        persp += [('DIV', RW(i), ONE, V(i, 3))]
        for (dst, c, s, o) in ((X(i), 0, XS, XO), (Y(i), 1, YS, YO), (Z(i), 2, ZS, ZO)):
            persp += [('MUL', T0, V(i, c), RW(i)), ('MUL', T0, T0, s), ('ADD', dst, T0, o)]
        persp += [('MUL', B0W(i), W(i, 0), RW(i)), ('MUL', B1W(i), W(i, 1), RW(i))]
    rest = [('INT', 0, 0, 0), ('DIV', RD, ONE, DF)]
    rest += plane([Z(0), Z(1), Z(2)], AZ)
    rest += [('ENDR', 0, 0, 0)]
    rest += plane([RW(0), RW(1), RW(2)], AW)
    rest += plane([B0W(0), B0W(1), B0W(2)], A0)
    rest += plane([B1W(0), B1W(1), B1W(2)], A1)
    rest += [('END', 0, 0, 0)]
    # raw entry 0: MOVs then a jump over the perspective block
    pc_persp = len(raw) + 1
    pc_int = pc_persp + len(persp)
    return raw + [('JMP', pc_int, 0, 0)] + persp + rest, pc_persp, pc_int


def main():
    prog, pc_persp, _ = program()
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    out = os.path.join(root, 'include', 'atg_rx_setup_uc.vh')
    with open(out, 'w') as fp:
        fp.write('/*\n * Amaterrace GPU\n * Copyright (C) 2026 Awe Morris\n *\n'
                 ' * SPDX-License-Identifier: Zlib\n */\n\n'
                 '/*\n * atg_rx_setup_uc.vh: the micro-program of atg_rx_setup, written by\n'
                 ' * tools/rx-ucode.py (do not edit).  {op, d, a, b}: op 0 END, 1 ADD,\n'
                 ' * 2 SUB, 3 MUL, 4 DIV, 5 MOV, 6 INT, 7 JMP d, 8 ENDR.  Entry 0 for raw\n'
                 ' * triangles, ATG_RX_UC_PERSP for the others.\n */\n\n')
        fp.write('localparam [6:0] ATG_RX_UC_PERSP = 7\'d%d;\n\n' % pc_persp)
        fp.write('function [24:0] atg_rx_uc;\n\tinput [6:0] pc;\n\tcase (pc)\n')
        for pc, (op, d, a, b) in enumerate(prog):
            fp.write("\t7'd%d: atg_rx_uc = {4'd%d, 7'd%d, 7'd%d, 7'd%d};\t/* %s */\n"
                     % (pc, OPS[op], d, a, b, op))
        fp.write("\tdefault: atg_rx_uc = 25'd0;\n\tendcase\nendfunction\n")
    print('rx-ucode: %s (%d micro-instructions)' % (out, len(prog)))
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import rxmodel as M
    out = os.path.join(root, 'include', 'atg_rop_unorm8.vh')
    with open(out, 'w') as fp:
        fp.write('/*\n * Amaterrace GPU\n * Copyright (C) 2026 Awe Morris\n *\n'
                 ' * SPDX-License-Identifier: Zlib\n */\n\n'
                 '/*\n * atg_rop_unorm8.vh: c -> fp32(c / 255), round to nearest even, written\n'
                 ' * by tools/rx-ucode.py (do not edit).\n */\n\n')
        fp.write('function [31:0] atg_rop_unorm8;\n\tinput [7:0] c;\n\tcase (c)\n')
        for c in range(256):
            fp.write("\t8'd%d: atg_rop_unorm8 = 32'h%08x;\n" % (c, M.UNORM8[c]))
        fp.write("\tdefault: atg_rop_unorm8 = 32'd0;\n\tendcase\nendfunction\n")
    print('rx-ucode: %s' % out)


if __name__ == '__main__':
    main()
