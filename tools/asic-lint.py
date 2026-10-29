#!/usr/bin/env python3
# asic-lint.py: Frontend Linter for ASIC 5nm 1.5 GHz High-Frequency Design Rules
#
# Usage:
#   tools/asic-lint.py --top <module_name> [--period <ns>] [--defines "DEF1 DEF2"]
#   tools/asic-lint.py --all [--period <ns>]
#   tools/asic-lint.py --check-ast [--top <module_name>]
#
# Rules checked (docs/style.md: High-Frequency ASIC Scaling):
#   Rule 1: Primitive & Logic Level Budget
#   Rule 2: Fanout Limitation & Tree Buffering
#   Rule 3: Flop-to-Flop Boundary Rule (Feedthrough)
#   Rule 4: Clean Single-Cycle Memory Pipeline
#   Rule 5: Backpressure Decoupling (Skid Buffer)

import argparse
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Terminal ANSI colors
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

CORE_MODULES = [
    "atg_fmt_cvt",
    "atg_vf_conv",
    "atg_mc",
    "atg_dc",
    "atg_cp",
    "atg_mmu",
    "atg_tu",
    "atg_su",
    "atg_rop",
    "atg_rx",
    "atg_blt_2d",
]


def run_ast_check(top=None):
    """Fast pre-synth AST / static regex check on RTL sources."""
    print(f"{CYAN}{BOLD}==> Running Static RTL Pre-Checks (Rule 3 & 4 AST Heuristics)...{RESET}")
    violations = 0

    rtl_files = sorted(glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True))
    if top:
        target_file = None
        for f in rtl_files:
            if os.path.basename(f) == f"{top}.v":
                target_file = f
                break
        rtl_files = [target_file] if target_file else []
        if not rtl_files:
            print(f"Error: Module file {top}.v not found under rtl/")
            return 1

    for fpath in rtl_files:
        rel = os.path.relpath(fpath, ROOT)
        if "bsp" in rel or "library" in rel:
            continue

        with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()

        # Check for potential memory indexing with complex expressions (Rule 4)
        for idx, line in enumerate(lines, 1):
            m = re.search(r'\b[a-zA-Z0-9_]+\s*\[([^\]]+)\]', line)
            if m:
                sub = m.group(1).strip()
                if any(op in sub for op in ["+", "-", "*", "/", "<<", ">>"]):
                    if "reg [" not in line and "wire [" not in line and "localparam" not in line and "parameter" not in line:
                        if "mem" in line or "ram" in line or "table" in line or "rom" in line:
                            print(f"{YELLOW}[AST WARNING]{RESET} {rel}:{idx}: Complex expression in array index '{sub}'")

    print(f"{GREEN}[AST Check Complete]{RESET}")
    return 0


def run_vivado_lint(top, period="4.000", defines="", out_dir=""):
    """Runs Vivado OOC ASIC structural linter."""
    print(f"\n{CYAN}{BOLD}================================================================================")
    print(f"  Running ASIC 5nm 1.5 GHz Linter on Module: {top}")
    print(f"  Surrogate Target: Kintex-7 -2 @ {period} ns (250 MHz)")
    print(f"================================================================================{RESET}")

    cmd = [
        os.path.join(ROOT, "tools", "asic-lint.sh"),
        top,
        period,
        defines
    ]

    env = dict(os.environ)
    env["VIVADO_THREADS"] = "2"
    env["VIVADO_MAX_THREADS"] = "2"

    proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    output = proc.stdout
    passed = proc.returncode == 0 and "OVERALL VERDICT: PASSED" in output

    # Print summary highlights
    in_summary = False
    for line in output.splitlines():
        if "[TIMING SUMMARY]" in line or "[RULE " in line or "ASIC 5nm 1.5 GHz COMPLIANCE SUMMARY" in line:
            in_summary = True
        if in_summary:
            if "VIOLATION" in line or "[FAIL]" in line or "FAILED" in line:
                print(f"{RED}{BOLD}{line}{RESET}")
            elif "[PASS]" in line or "PASSED" in line:
                print(f"{GREEN}{BOLD}{line}{RESET}")
            elif "WARNING" in line:
                print(f"{YELLOW}{line}{RESET}")
            else:
                print(line)

    rpt_path = os.path.join(ROOT, "build", "asic_lint", top, "asic_lint.rpt")
    print(f"\nDetailed report saved to: {BOLD}{rpt_path}{RESET}")

    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description="ASIC 5nm 1.5 GHz Architecture & Style Linter")
    parser.add_argument("--top", help="Top module to lint (e.g. atg_fmt_cvt, atg_mc)")
    parser.add_argument("--period", default="4.000", help="Clock period target in ns (default: 4.000 ns = 250 MHz)")
    parser.add_argument("--defines", default="", help="Extra Verilog defines (space separated)")
    parser.add_argument("--all", action="store_true", help="Lint all core GPU modules")
    parser.add_argument("--check-ast", action="store_true", help="Run fast static AST RTL checks only")

    args = parser.parse_args()

    if args.check_ast:
        sys.exit(run_ast_check(args.top))

    if args.all:
        failures = []
        for mod in CORE_MODULES:
            rc = run_vivado_lint(mod, args.period, args.defines)
            if rc != 0:
                failures.append(mod)
        print(f"\n{BOLD}=== ALL MODULES LINT SUMMARY ==={RESET}")
        if failures:
            print(f"{RED}FAILED modules: {', '.join(failures)}{RESET}")
            sys.exit(1)
        else:
            print(f"{GREEN}ALL modules PASSED ASIC 5nm 1.5 GHz linting!{RESET}")
            sys.exit(0)

    if not args.top:
        parser.print_help()
        sys.exit(1)

    sys.exit(run_vivado_lint(args.top, args.period, args.defines))


if __name__ == "__main__":
    main()
