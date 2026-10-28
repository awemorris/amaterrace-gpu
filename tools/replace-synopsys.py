#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Amaterrace GPU - Synopsys Directive Replacement Tool
Copyright (C) 2026 Awe Morris
SPDX-License-Identifier: Zlib

Safely converts synthesis directives (e.g. Vivado/standard comments) to
Synopsys Design Compiler pragmas/directives.

Safety mechanisms:
  - Default mode: Non-destructive, writes to an output directory (--out-dir).
  - In-place mode (--in-place): Requires clean git status unless --force is given.
"""

import sys
import os
import re
import argparse
import subprocess
import shutil

# Extensible rules table: (pattern, replacement, description)
REPLACEMENT_RULES = [
    # 1. Registers / SRL synthesis comments to Synopsys pragma
    (
        re.compile(r'/\*\s*synthesis\s+syn_ramstyle\s*=\s*"registers"\s*,\s*syn_srl_style\s*=\s*"registers"\s*\*/'),
        r'/* synopsys syn_ramstyle = "registers" syn_srl_style = "registers" */',
        'Registers/SRL comment -> Synopsys pragma'
    ),
    # 2. General syn_ramstyle comment
    (
        re.compile(r'/\*\s*synthesis\s+syn_ramstyle\s*=\s*"([^"]+)"\s*\*/'),
        r'/* synopsys syn_ramstyle = "\1" */',
        'Single syn_ramstyle comment -> Synopsys pragma'
    ),
    # 3. Add future rules here...
]

def check_git_clean(repo_root):
    """Returns True if git working tree has no uncommitted changes."""
    try:
        res = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True
        )
        return len(res.stdout.strip()) == 0
    except Exception as e:
        print(f"[WARN] Failed to check git status: {e}", file=sys.stderr)
        return False

def process_file_content(content):
    """Apply replacement rules to file content."""
    modified = False
    new_content = content
    for pattern, repl, desc in REPLACEMENT_RULES:
        if pattern.search(new_content):
            new_content = pattern.sub(repl, new_content)
            modified = True
    return new_content, modified

def main():
    parser = argparse.ArgumentParser(description="Replace synthesis directives with Synopsys syntax safely.")
    parser.add_argument("--repo-root", default=".", help="Root of repository (default: current dir)")
    parser.add_argument("--in-place", action="store_true", help="Modify files in place in the source tree")
    parser.add_argument("--out-dir", default="build/synopsys", help="Output directory for non-destructive mode")
    parser.add_argument("--force", action="store_true", help="Allow in-place replacement even if git status is dirty")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be modified without writing files")

    args = parser.parse_args()
    repo_root = os.path.abspath(args.repo_root)

    # Safety check for in-place mode
    if args.in_place and not args.dry_run:
        if not check_git_clean(repo_root) and not args.force:
            print("[ERROR] Git working tree has uncommitted changes!", file=sys.stderr)
            print("        Refusing to perform in-place replacement to avoid destroying uncommitted work.", file=sys.stderr)
            print("        Please commit or stash your changes first, or run without --in-place (writes to build/synopsys).", file=sys.stderr)
            sys.exit(1)

    target_dirs = ["rtl"]
    files_processed = 0
    files_modified = 0

    out_base = os.path.abspath(args.out_dir) if not args.in_place else repo_root

    for tdir in target_dirs:
        abs_tdir = os.path.join(repo_root, tdir)
        if not os.path.exists(abs_tdir):
            continue
        for root, _, files in os.walk(abs_tdir):
            for fname in files:
                if not fname.endswith(".v") and not fname.endswith(".vh"):
                    continue
                src_path = os.path.join(root, fname)
                rel_path = os.path.relpath(src_path, repo_root)

                with open(src_path, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read()

                new_content, modified = process_file_content(content)
                files_processed += 1

                if modified:
                    files_modified += 1
                    if args.dry_run:
                        print(f"[DRY-RUN] Would modify: {rel_path}")
                        continue

                    if args.in_place:
                        dest_path = src_path
                    else:
                        dest_path = os.path.join(out_base, rel_path)
                        os.makedirs(os.path.dirname(dest_path), exist_ok=True)

                    with open(dest_path, "w", encoding="utf-8") as f:
                        f.write(new_content)
                    print(f"[REPLACED] {rel_path} -> {os.path.relpath(dest_path, repo_root)}")
                else:
                    if not args.in_place and not args.dry_run:
                        # Copy original file to maintain complete tree in out-dir
                        dest_path = os.path.join(out_base, rel_path)
                        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
                        shutil.copy2(src_path, dest_path)

    print(f"\n[SUMMARY] Processed {files_processed} files. Modified {files_modified} files.")
    if not args.in_place and not args.dry_run:
        print(f"[INFO] Complete converted tree generated at: {os.path.relpath(out_base, repo_root)}")

if __name__ == "__main__":
    main()
