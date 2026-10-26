#!/usr/bin/env python3
"""Runs GSI1 compute programs on the Amaterrace GPU's bitstream 4
("compute", WS288 p008: CP + BLT + MC + one SU, NPHYS 8) on the real ZYBO
with nothing but fpgareg: no GPU driver.  For each program of
amaterrace-gpu sim/tb/su (vadd: c = a + b over 2 workgroups; reduce: the
fp32 tree reduction in LDS with barriers) it writes the code and the data
image into the GPU's memory through the debug port (DBG_ADDR/DATA), sets
CS_BASE, WG_SIZE and the DISPATCH group counts in STATE, kicks DISPATCH
(KICK bit 2), waits for STATUS to be idle, reads the output window back
through the debug port and compares it with tools/gsi1model.py's memory
image (the same model as the simulation testbench sim/tb/atg_su_tb.v).

The programs address the data at 0x8000-0xBFFF; on the board every movi of
an address in that range is moved by --base (the GPU's memory is physical),
which the model's image is compared against word for word.  The data image
changes with --seed (default: the time) so that no run finds an earlier
result in place.

  plan/ws288/tests/ghci-su-board.py [--bit FILE.bit] [--host HOST]
      [--base 0x1C000000] [--seed N] [--gpu ~/amaterrace-gpu] [--prog vadd,reduce]

The login is root/root (sshpass); the host's board lock
/tmp/zedbsd-zybo-board.lock is held for the run.  Prints one PASS or FAIL
line per check and exits 1 on any FAIL.  Each fpgareg is a process on the
board (about 10 ms); a program takes about a minute.

Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
"""

import argparse
import fcntl
import os
import random
import re
import struct
import subprocess
import sys
import time

SSH_OPTIONS = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
               "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10"]
LOCK = "/tmp/zedbsd-zybo-board.lock"
CTRL, STATUS, IRQ_STATUS = 0x030, 0x034, 0x038
AP_BASE, AP_LIMIT, FAULT_INFO, FAULT_ADDR = 0x060, 0x064, 0x06C, 0x068
DBG_ADDR, DBG_DATA, KICK, STATE = 0x0A0, 0x0A4, 0xF00, 0x1000
DATA, DWORDS = 0x8000, 4096
# Per program: lanes, workgroups, the output window (word offsets in the image).
PROGS = {"vadd": (128, 2, range(0x1000 // 4, 0x1000 // 4 + 256)),
         "reduce": (128, 1, range(0x1000 // 4, 0x1000 // 4 + 2))}


def board_script(base, code, image, out_words, lanes, groups):
    lines = [
        "r() { fpgareg read $1; }",
        "w() { fpgareg write $1 $2 >/dev/null; }",
        "dw() { w 0xa0 $1; w 0xa4 $2; }",
        "dr() { w 0xa0 $1; s=$(r 0xa8); echo \"D $1 $(r 0xa4) $s\"; }",
        "st() { w $((0x1000 + $1 * 4)) $2; }",
        f"w {CTRL:#x} 2",
        f"w {IRQ_STATUS:#x} 0x7f",
        f"w {AP_BASE:#x} {base:#x}",
        f"w {AP_LIMIT:#x} {base + 0x4000000:#x}",
    ]
    for i, v in enumerate(code):
        lines.append(f"dw {base + 0x1000 + 4 * i:#x} {v:#x}")
    for i, v in enumerate(image):
        lines.append(f"dw {base + DATA + 4 * i:#x} {v:#x}")
    lines += [
        f"st 0x194 {base + 0x1000:#x}",
        f"st 0x199 {0x010100 | lanes:#x}",
        f"st 0x1e9 {groups}", "st 0x1ea 1", "st 0x1eb 1",
        f"w {KICK:#x} 4",
        # STATUS.SU_BUSY (bit 6) clear: wait up to about 10 s.
        "n=0; while [ $(( $(r 0x34) & 0x40 )) -ne 0 ] && [ $n -lt 500 ]; do n=$((n+1)); done",
        "echo \"S $n $(r 0x34) $(r 0x6c) $(r 0x68)\"",
    ]
    for k in out_words:
        lines.append(f"dr {base + DATA + 4 * k:#x}")
    return "\n".join(lines) + "\necho END\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit")
    ap.add_argument("--host", default="10.0.30.2")
    ap.add_argument("--base", default="0x1C000000")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--gpu", default=os.path.expanduser("~/amaterrace-gpu"))
    ap.add_argument("--prog", default="vadd,reduce")
    args = ap.parse_args()
    base = int(args.base, 0)
    seed = (args.seed if args.seed is not None else int(time.time())) & 0xFFFFFFFF
    print(f"seed {seed}")
    sys.path.insert(0, os.path.join(args.gpu, "tools"))
    import gsi1asm as A  # noqa: E402
    import gsi1model as M  # noqa: E402

    env = dict(os.environ, SSHPASS="root")
    ssh = ["sshpass", "-e", "ssh"] + SSH_OPTIONS + [f"root@{args.host}"]
    lock = open(LOCK, "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    fails = 0

    def check(name, ok, detail=""):
        nonlocal fails
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else " " + detail))
        fails += 0 if ok else 1

    if args.bit:
        subprocess.run(["timeout", "120", "sshpass", "-e", "scp"] + SSH_OPTIONS +
                       [args.bit, f"root@{args.host}:/tmp/ghci-su.bit"], env=env, check=True)
        load = subprocess.run(["timeout", "60"] + ssh +
                              ["fpgaload /tmp/ghci-su.bit; fpgaload --status"],
                              env=env, capture_output=True, text=True)
        check("fpgaload", load.returncode == 0, load.stderr.strip())
    rnd = random.Random(seed)
    for name in args.prog.split(","):
        lanes, groups, out = PROGS[name]
        src = open(os.path.join(args.gpu, "sim/tb/su", name + ".s")).read()
        # The data image: random floats in [-100, 100) from word 256 on.
        image = [rnd.getrandbits(32) for _ in range(256)] + [
            struct.unpack("<I", struct.pack("<f", rnd.uniform(-100, 100)))[0]
            for _ in range(DWORDS - 256)]
        mem = {DATA // 4 + i: v for i, v in enumerate(image)}
        m = M.Machine(A.encode(src), lanes, 32, mem, groups, False)
        m.run()
        want = [m.mem.get(DATA // 4 + k, 0) for k in out]

        def move(mt):
            v = int(mt.group(2), 0)
            return mt.group(1) + (hex(v + base) if DATA <= v < DATA + 4 * DWORDS else mt.group(2))
        bsrc = re.sub(r"(movi\s+r\d+,\s*)(0x[0-9A-Fa-f]+|\d+)", move, src)
        words = A.encode(bsrc)
        code = []
        for w in words:
            code += [w & 0xFFFFFFFF, w >> 32]
        script = board_script(base, code, image, out, lanes, groups)
        run = subprocess.run(["timeout", "900"] + ssh + ["sh -s"], input=script, env=env,
                             capture_output=True, text=True)
        got = {}
        status = None
        for ln in run.stdout.splitlines():
            p = ln.split()
            if p and p[0] == "D":
                got[(int(p[1], 0) - base - DATA) // 4] = int(p[2], 0)
            elif p and p[0] == "S":
                status = p[1:]
        check(f"{name}: dispatch idle", status is not None and int(status[1], 0) & 0x240 == 0,
              f"status {status} {run.stderr.strip()[:200]}")
        bad = [k for i, k in enumerate(out) if got.get(k) != want[i]]
        check(f"{name}: {len(out)} words equal the model", not bad,
              f"{len(bad)} differ, first word {bad[0] if bad else 0}: "
              f"{got.get(bad[0]) if bad else 0} want {want[out.index(bad[0])] if bad else 0}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
