#!/usr/bin/env python3
"""
parse-synth-result.py: Extract timing and resource utilization metrics from Vivado reports.
"""
import sys
import re
from pathlib import Path

def parse_report(report_dir):
    p = Path(report_dir)
    timing_file = p / "timing_summary.rpt"
    util_file = p / "utilization.rpt"

    wns = "N/A"
    levels = 0
    lut = 0
    ff = 0
    bram = 0
    dsp = 0

    if timing_file.exists():
        content = timing_file.read_text(encoding="utf-8", errors="ignore")
        # Match Slack: Slack (MET) : 1.729ns or Slack (VIOLATED) : -1.234ns
        m = re.search(r"Slack\s*\([A-Za-z]+\)\s*:\s*([+-]?\d+\.\d+)ns", content)
        if m:
            wns = float(m.group(1))

        # Match logic levels: Logic Levels:           7  (CARRY4=2 ...)
        m_levels = re.search(r"Logic Levels:\s*(\d+)", content)
        if m_levels:
            levels = int(m_levels.group(1))

    if util_file.exists():
        content = util_file.read_text(encoding="utf-8", errors="ignore")
        # Match Slice LUTs
        m_lut = re.search(r"\|\s*Slice LUTs\s*\*?\s*\|\s*(\d+)\s*\|", content)
        if m_lut:
            lut = int(m_lut.group(1))
        
        # Match Slice Registers
        m_ff = re.search(r"\|\s*Slice Registers\s*\|\s*(\d+)\s*\|", content)
        if m_ff:
            ff = int(m_ff.group(1))

        # Match Block RAM Tile
        m_bram = re.search(r"\|\s*Block RAM Tile\s*\|\s*([\d\.]+)\s*\|", content)
        if m_bram:
            bram = float(m_bram.group(1))
            if bram.is_integer():
                bram = int(bram)

        # Match DSPs
        m_dsp = re.search(r"\|\s*DSPs\s*\|\s*(\d+)\s*\|", content)
        if m_dsp:
            dsp = int(m_dsp.group(1))

    return {
        "wns": wns,
        "levels": levels,
        "lut": lut,
        "ff": ff,
        "bram": bram,
        "dsp": dsp,
        "pass": (wns != "N/A" and float(wns) >= 0.0)
    }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: parse-synth-result.py <report_dir>")
        sys.exit(1)
    res = parse_report(sys.argv[1])
    print(res)
