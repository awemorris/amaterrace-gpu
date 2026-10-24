#!/usr/bin/env python3
# rx-ucode.py: writes include/atg_rx_setup_uc.vh, the micro-program of
# atg_rx_setup (spec/gpu/rx/atg_rx_setup.md §4), from the listing below,
# and include/atg_rop_unorm8.vh, the table c -> fp32(c / 255) of the ROP's
# DEBUG_COLOR (tools/rxmodel.py's UNORM8).
# A micro-instruction is {op[3:0], d[7:0], a[6:0], b[6:0]} (d is a
# register, or the target of JMP and BRA); the fp register numbers are the
# spec's, 120-127 read constants and STATE (K_* below).
#   tools/rx-ucode.py
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import sys

OPS = {'END': 0, 'ADD': 1, 'SUB': 2, 'MUL': 3, 'DIV': 4, 'MOV': 5, 'INT': 6, 'JMP': 7,
       'ENDR': 8, 'ABS': 9, 'MAX': 10, 'ULP': 11, 'BCL': 12, 'BRA': 13, 'OUT': 14}
# BRA d, c: jump to d when condition c holds
C_POINT, C_LINE, C_NOBIAS, C_NOT_D32, C_NORECT = range(5)
# read-only registers
K_CONST, K_SLOPE, K_CLAMP, K_HALF, K_ZERO, K_RFMT = range(120, 126)


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
RX0, RX1, RY0, RY1 = 76, 77, 78, 79


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
    # labels are resolved below: ('JMP', 'name') / ('BRA', 'name', cond)
    rect = [('BRA', 'rect_end', C_NORECT, 0), ('ABS', T0, XS, 0), ('SUB', RX0, XO, T0),
            ('ADD', RX1, XO, T0), ('ABS', T0, YS, 0), ('SUB', RY0, YO, T0),
            ('ADD', RY1, YO, T0), ('LBL', 'rect_end'),
            ('BRA', 'point', C_POINT, 0), ('BRA', 'line', C_LINE, 0)]
    # depth bias: o = max(|A_z|, |B_z|) SLOPE + r CONST, clamped, into C_z
    bias = [('BRA', 'bias_end', C_NOBIAS, 0), ('ABS', T0, AZ, 0), ('ABS', T1, AZ + 1, 0),
            ('MAX', T0, T0, T1), ('MUL', T0, T0, K_SLOPE), ('BRA', 'rconst', C_NOT_D32, 0),
            ('ABS', T1, Z(0), 0), ('ABS', T2, Z(1), 0), ('MAX', T1, T1, T2),
            ('ABS', T2, Z(2), 0), ('MAX', T1, T1, T2), ('ULP', T1, T1, 0),
            ('JMP', 'rmul'), ('LBL', 'rconst'), ('MOV', T1, K_RFMT, 0), ('LBL', 'rmul'),
            ('MUL', T1, T1, K_CONST), ('ADD', T0, T0, T1), ('BCL', T0, T0, K_CLAMP),
            ('ADD', AZ + 2, AZ + 2, T0), ('LBL', 'bias_end')]
    tri = [('LBL', 'int'), ('INT', 0, 0, 0), ('DIV', RD, ONE, DF)]
    tri += plane([Z(0), Z(1), Z(2)], AZ)
    tri += [('ENDR', 0, 0, 0)]
    tri += bias
    tri += plane([RW(0), RW(1), RW(2)], AW)
    tri += plane([B0W(0), B0W(1), B0W(2)], A0)
    tri += plane([B1W(0), B1W(1), B1W(2)], A1)
    tri += [('END', 0, 0, 0)]
    # a line: the planes of (a, b, c), c with a's values; two sub-triangles
    line = [('LBL', 'line'), ('MOV', Z(2), Z(0), 0), ('MOV', RW(2), RW(0), 0),
            ('MOV', B0W(2), B0W(0), 0), ('MOV', B1W(2), B1W(0), 0),
            ('INT', 0, 0, 0), ('DIV', RD, ONE, DF)]
    line += plane([Z(0), Z(1), Z(2)], AZ)
    line += plane([RW(0), RW(1), RW(2)], AW)
    line += plane([B0W(0), B0W(1), B0W(2)], A0)
    line += plane([B1W(0), B1W(1), B1W(2)], A1)
    line += [('OUT', 0, 0, 0), ('INT', 0, 0, 0), ('END', 0, 0, 0)]
    # a point: z constant, 1/w = 1, b0/w and b1/w are PointCoord s and t
    point = [('LBL', 'point'), ('INT', 0, 0, 0),
             ('MOV', AZ, K_ZERO, 0), ('MOV', AZ + 1, K_ZERO, 0), ('MOV', AZ + 2, Z(0), 0),
             ('MOV', AW, K_ZERO, 0), ('MOV', AW + 1, K_ZERO, 0), ('MOV', AW + 2, ONE, 0),
             ('MOV', A0, ONE, 0), ('MOV', A0 + 1, K_ZERO, 0), ('ADD', A0 + 2, K_HALF, OX),
             ('MOV', A1, K_ZERO, 0), ('MOV', A1 + 1, ONE, 0), ('ADD', A1 + 2, K_HALF, OY),
             ('OUT', 0, 0, 0), ('INT', 0, 0, 0), ('END', 0, 0, 0)]
    prog = raw + [('JMP', 'int')] + [('LBL', 'persp')] + persp + rect + tri + line + point
    lbl, out = {}, []
    for ins in prog:
        if ins[0] == 'LBL':
            lbl[ins[1]] = len(out)
        else:
            out.append(ins)
    res = []
    for ins in out:
        if ins[0] == 'JMP':
            res.append(('JMP', lbl[ins[1]], 0, 0))
        elif ins[0] == 'BRA':
            res.append(('BRA', lbl[ins[1]], ins[2], 0))
        else:
            res.append(ins)
    assert len(res) <= 256
    return res, lbl['persp'], lbl['int']


def main():
    prog, pc_persp, _ = program()
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    out = os.path.join(root, 'include', 'atg_rx_setup_uc.vh')
    with open(out, 'w') as fp:
        fp.write('/*\n * Amaterrace GPU\n * Copyright (C) 2026 Awe Morris\n *\n'
                 ' * SPDX-License-Identifier: Zlib\n */\n\n'
                 '/*\n * atg_rx_setup_uc.vh: the micro-program of atg_rx_setup, written by\n'
                 ' * tools/rx-ucode.py (do not edit).  {op, d, a, b}: op 0 END, 1 ADD,\n'
                 ' * 2 SUB, 3 MUL, 4 DIV, 5 MOV, 6 INT, 7 JMP d, 8 ENDR, 9 ABS, 10 MAX,\n'
                 ' * 11 ULP, 12 BCL, 13 BRA d if condition a, 14 OUT.  Entry 0 for raw\n'
                 ' * triangles, ATG_RX_UC_PERSP for the others.\n */\n\n')
        fp.write('localparam [7:0] ATG_RX_UC_PERSP = 8\'d%d;\n\n' % pc_persp)
        fp.write('function [25:0] atg_rx_uc;\n\tinput [7:0] pc;\n\tcase (pc)\n')
        for pc, (op, d, a, b) in enumerate(prog):
            fp.write("\t8'd%d: atg_rx_uc = {4'd%d, 8'd%d, 7'd%d, 7'd%d};\t/* %s */\n"
                     % (pc, OPS[op], d, a, b, op))
        fp.write("\tdefault: atg_rx_uc = 26'd0;\n\tendcase\nendfunction\n")
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
