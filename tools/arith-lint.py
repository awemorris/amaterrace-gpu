#!/usr/bin/env python3
# arith-lint.py: counts the signal arithmetic written outside rtl/common/
# (docs/style.md, "Arithmetic"): every +, -, unary -, *, /, % and shift by a
# variable amount whose operands are not all constants after elaboration.
# Each module of rtl/ is elaborated alone with its default parameters by
# Verilator (--xml-only), and atg_top also in the KC705's shapes; the
# operators are found in the elaborated tree, so parameter and localparam
# expressions (folded to constants) are not counted.  Not counted either:
#   - a shift by a constant amount, and a *, / or % by a constant power of
#     two (wiring and bit selection);
#   - the arithmetic of a loop's index (a variable a for loop steps) and of
#     a function that is only called with constants (elaboration);
#   - initial blocks;
#   - the files of the exception table below (docs/style.md lists the
#     reasons).
# Usage: tools/arith-lint.py [--list] [--top NAME]
#   prints "arith-lint: N operators outside rtl/common" and, with --list,
#   one line per operator (file:line:column operator); exit status 1 when
#   N > 0.  Time: about a minute (one Verilator run per module).
# Outputs: build/arith-lint/ (the XML files).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import glob
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'build', 'arith-lint')

# Files whose arithmetic is allowed, with the reason (docs/style.md).
EXCEPTIONS = {
}

OPS = {
    'add': '+', 'sub': '-', 'negate': 'unary -',
    'mul': '*', 'muls': '*', 'div': '/', 'divs': '/', 'moddiv': '%', 'moddivs': '%',
    'shiftl': '<<', 'shiftr': '>>', 'shiftrs': '>>>',
}
SHIFTS = ('shiftl', 'shiftr', 'shiftrs')
POW2 = ('mul', 'muls', 'div', 'divs', 'moddiv', 'moddivs')

KC = ['-GLINE_BYTES=64', '-GLINE_SHIFT=6', '-GDATA_W=512', '-GS_ID_W=4', '-GS_LEN_W=8']
KCSU = ('-GHAS_CPU=1 -GCPU_IMEM_WORDS=32768 -GCPU_DMEM_WORDS=16384 -GHAS_VF=1 -GHAS_RX=1 '
        '-GHAS_TU=1 -GHAS_ROP=1 -GEXT_CLIENT=1 -GHAS_JTAG=1 -GMS4=1 -GROP_STENCIL=1 '
        '-GSU_NPHYS=4 -GSU_GRP_W=3 -GSU_NREGS=64 -GSU_SB_ENTRIES=8 -GSU_SBE_W=3 '
        '-GSU_PACKED=1 -GSU_SUBGROUP=1 -GSU_FRAG_RESERVE=2 -GSU_LDS_BYTES=16384 '
        '-GSU_VARY_WORDS=64 -GNSU=1').split()
# The same with the SU of NPHYS 8 (the ASIC's and a larger FPGA's).
KCSU8 = [{'-GSU_NPHYS=4': '-GSU_NPHYS=8', '-GSU_GRP_W=3': '-GSU_GRP_W=2'}.get(a, a) for a in KCSU]


def const_value(e):
    """The value of a const node, or None."""
    name = e.attrib.get('name', '')
    if "'" not in name:
        return None
    digits = name.split("'", 1)[1].lstrip('s')
    base = {'h': 16, 'd': 10, 'b': 2, 'o': 8}.get(digits[:1])
    if base is None:
        return None
    try:
        return int(digits[1:].replace('_', ''), base)
    except ValueError:
        return None


def is_pow2_const(e):
    v = const_value(e) if e.tag == 'const' else None
    return v is not None and v > 0 and v & (v - 1) == 0


def run(top, args, tag):
    """Elaborates one top; returns the XML root or None."""
    os.makedirs(OUT, exist_ok=True)
    mdir = os.path.join(OUT, tag)
    srcs = sorted(glob.glob(os.path.join('rtl', '**', '*.v'), recursive=True))
    cmd = ['verilator', '--xml-only', '-Iinclude', '--top-module', top, '--Mdir', mdir] + \
        args + srcs
    env = dict(os.environ, LC_ALL='C')
    p = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE, timeout=600)
    path = os.path.join(mdir, 'V%s.xml' % top)
    if p.returncode != 0 or not os.path.exists(path):
        sys.stderr.write('arith-lint: %s: verilator failed\n%s' % (top, p.stderr.decode()[-2000:]))
        return None
    return ET.parse(path).getroot()


def scan(root, found):
    files = {f.attrib['id']: f.attrib['filename'] for f in root.find('files')}
    parent = {}
    for p in root.iter():
        for c in p:
            parent[c] = p

    def enclosing(e, tags):
        while e in parent:
            e = parent[e]
            if e.tag in tags:
                return e
        return None

    # The variables of each scope (a module, or a function in it).
    def scope_of(e):
        f = enclosing(e, ('func', 'task'))
        m = enclosing(e, ('module',))
        return (id(m), id(f) if f is not None else None)

    decl = {}	# (scope, name) -> var element
    inputs = set()	# module inputs and inouts: never constant
    for v in root.iter('var'):
        sc = scope_of(v)
        decl[(sc, v.attrib.get('name'))] = v
        if sc[1] is None and v.attrib.get('dir') in ('input', 'inout'):
            inputs.add((sc, v.attrib.get('name')))

    def key_of(ref):
        sc = scope_of(ref)
        name = ref.attrib.get('name')
        if (sc, name) in decl:
            return (sc, name)
        return ((sc[0], None), name)

    # What is assigned to each variable, and what each function is called with.
    rhs = {}
    for tag in ('assign', 'assigndly', 'contassign', 'assignw', 'assignalias'):
        for a in root.iter(tag):
            kids = list(a)
            if len(kids) < 2:
                continue
            target = None
            for v in kids[-1].iter('varref'):
                target = key_of(v)
                break
            if target is not None:
                rhs.setdefault(target, []).append(kids[0])
    funcs = {}
    for f in root.iter('func'):
        sc = (id(enclosing(f, ('module',))), id(f))
        ins = [(sc, v.attrib.get('name')) for v in f if v.tag == 'var' and
               v.attrib.get('dir') == 'input']
        funcs[(id(enclosing(f, ('module',))), f.attrib.get('name'))] = (f, sc, ins)
    calls = {}
    for ref in root.iter('funcref'):
        fkey = (id(enclosing(ref, ('module',))), ref.attrib.get('name'))
        args = [list(a)[0] if len(list(a)) else None for a in ref if a.tag == 'arg']
        calls.setdefault(fkey, []).append((ref, args))

    # Loop indices: the variables a while's increment assigns.
    loopvars = set()
    for w in root.iter('while'):
        kids = list(w)
        if len(kids) >= 4:
            for a in kids[3].iter('assign'):
                for v in list(a)[-1].iter('varref'):
                    loopvars.add(key_of(v))
                    break

    # State: a variable assigned in a clocked block (but a loop index) holds a value over cycles.
    nonconst = set(inputs)
    for tag in ('assign', 'assigndly'):
        for a in root.iter(tag):
            kids = list(a)
            if len(kids) < 2:
                continue
            target = None
            for v in kids[-1].iter('varref'):
                target = key_of(v)
                break
            if target is None or target in loopvars:
                continue
            if tag == 'assigndly':
                nonconst.add(target)
                continue
            al = enclosing(a, ('always',))
            if al is not None and any(si.attrib.get('edgeType') in ('POS', 'NEG', 'BOTH')
                                      or 'edge' in si.attrib.get('edgeType', '').lower()
                                      for si in al.iter('senitem')):
                nonconst.add(target)

    # Constant variables: assigned only constants (a fixed point from the rest).

    def expr_const(e):
        if e is None:
            return True
        for v in e.iter('varref'):
            if key_of(v) in nonconst:
                return False
        for ref in e.iter('funcref'):
            fkey = (id(enclosing(ref, ('module',))), ref.attrib.get('name'))
            if fkey in funcs:
                f, sc, ins = funcs[fkey]
                if (sc, f.attrib.get('name')) in nonconst:
                    return False
        return True

    changed = True
    while changed:
        changed = False
        for k, exprs in rhs.items():
            if k in nonconst:
                continue
            for e in exprs:
                if not expr_const(e):
                    nonconst.add(k)
                    changed = True
                    break
        for fkey, (f, sc, ins) in funcs.items():
            for ref, args in calls.get(fkey, []):
                for i, arg in enumerate(args):
                    if i < len(ins) and ins[i] not in nonconst and not expr_const(arg):
                        nonconst.add(ins[i])
                        changed = True

    for tag, sym in OPS.items():
        for e in root.iter(tag):
            loc = e.attrib.get('loc', '')
            fid = loc.split(',')[0]
            fname = files.get(fid, '')
            counted = fname.startswith('rtl/') or fname.startswith('include/')
            if not counted or fname.startswith('rtl/common/'):
                continue
            if fname in EXCEPTIONS:
                continue
            if enclosing(e, ('initial',)) is not None:
                continue
            kids = list(e)
            if tag in SHIFTS and len(kids) == 2 and kids[1].tag == 'const':
                continue
            if tag in POW2 and any(is_pow2_const(k) for k in kids):
                continue
            if expr_const(e):
                continue
            line = loc.split(',')[1]
            col = loc.split(',')[2]
            f = enclosing(e, ('func',))
            where = ' (function %s)' % f.attrib.get('name') if f is not None else ''
            found[(fname, int(line), int(col))] = sym + where


def main():
    found = {}
    tops = []
    if '--top' in sys.argv:
        tops = [(sys.argv[sys.argv.index('--top') + 1], [], 'one')]
    else:
        for f in sorted(glob.glob(os.path.join(ROOT, 'rtl', '**', '*.v'), recursive=True)):
            m = os.path.basename(f)[:-2]
            tops.append((m, [], m))
        tops.append(('atg_top', KC, 'atg_top_kc'))
        tops.append(('atg_top', KC + KCSU, 'atg_top_kcsu'))
        tops.append(('atg_top', KC + KCSU8, 'atg_top_kcsu8'))
    for top, args, tag in tops:
        root = run(top, args, tag)
        if root is not None:
            scan(root, found)
    if '--list' in sys.argv:
        for (fname, line, col), sym in sorted(found.items()):
            print('%s:%d:%d %s' % (fname, line, col, sym))
    per = {}
    for (fname, _, _) in found:
        per[fname] = per.get(fname, 0) + 1
    if '--files' in sys.argv:
        for fname in sorted(per):
            print('%5d %s' % (per[fname], fname))
    print('arith-lint: %d operators outside rtl/common' % len(found))
    sys.exit(1 if found else 0)


if __name__ == '__main__':
    main()
