#!/usr/bin/env python3
# ==============================================================================
# Amaterrace GPU (ATG1) Menuconfig TUI
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
# ==============================================================================
"""Terminal-based configuration utility for Amaterrace GPU.

Reads config.mk (or config.mk.template), presents an interactive curses TUI
to configure hardware options, and writes the result to config.mk.
Also supports non-interactive inspection and modification via CLI arguments.
"""

import argparse
import curses
import os
import re
import sys

CONFIG_TEMPLATE = "config.mk.template"
CONFIG_FILE = "config.mk"

SCHEMA = [
    {
        "title": "Board & Target Preset",
        "items": [
            {
                "key": "TARGET_PRESET",
                "label": "Target Board Preset",
                "type": "choice",
                "choices": ["kc705", "basys3", "arty_a7", "minimal_sim"],
                "default": "kc705",
                "help": "Target hardware board or simulation preset.",
            }
        ],
    },
    {
        "title": "1. Shader Unit (SU) Scaling & Capabilities",
        "items": [
            {
                "key": "CONFIG_SU_NPHYS",
                "label": "Physical SIMD Lanes (NPHYS)",
                "type": "choice",
                "choices": ["4", "8", "16", "32"],
                "default": "8",
                "help": "Number of physical SIMD execution lanes per SU (32/NPHYS cycles/inst).",
            },
            {
                "key": "CONFIG_SU_NWARPS",
                "label": "Concurrent Warp Slots",
                "type": "choice",
                "choices": ["2", "4", "8"],
                "default": "4",
                "help": "Maximum resident warps per SU.",
            },
            {
                "key": "CONFIG_SU_NREGS",
                "label": "GPRs per Thread",
                "type": "choice",
                "choices": ["32", "64"],
                "default": "32",
                "help": "Number of 32-bit general purpose registers per thread.",
            },
            {
                "key": "CONFIG_SU_ENABLE_FP16",
                "label": "Packed FP16x2 Arithmetic",
                "type": "bool",
                "default": "1",
                "help": "Enable packed FP16x2 arithmetic support (2x compute throughput).",
            },
            {
                "key": "CONFIG_SU_ENABLE_SUBGROUP",
                "label": "Subgroup Operations (shfl/vote/ballot)",
                "type": "bool",
                "default": "1",
                "help": "Enable intra-warp cross-thread communication instructions.",
            },
            {
                "key": "CONFIG_SU_ENABLE_SFU",
                "label": "Hardware SFU (Transcendental math)",
                "type": "bool",
                "default": "1",
                "help": "Hardware Special Function Unit for rcp, rsq, sin, cos.",
            },
            {
                "key": "CONFIG_SU_LDS_KB",
                "label": "Workgroup Local Data Share (KB)",
                "type": "choice",
                "choices": ["0", "1", "2", "4"],
                "default": "4",
                "help": "Shared scratchpad memory capacity in Kilobytes.",
            },
            {
                "key": "CONFIG_SU_ENABLE_SA",
                "label": "Systolic Tensor Accelerator",
                "type": "bool",
                "default": "0",
                "help": "Attach Systolic Tensor Accelerator (GEMM coprocessor) to SU.",
            },
            {
                "key": "CONFIG_SU_ENABLE_MESH",
                "label": "VK_EXT_mesh_shader Support",
                "type": "bool",
                "default": "0",
                "help": "Enable Task and Mesh Shader hardware capability (WS004).",
            },
        ],
    },
    {
        "title": "2. Rasterizer (RX) Configuration",
        "items": [
            {
                "key": "CONFIG_RX_ENABLE_MSAA",
                "label": "Multisample Anti-Aliasing (MSAA)",
                "type": "bool",
                "default": "1",
                "help": "Enable Multisample Anti-Aliasing rasterization support.",
            },
            {
                "key": "CONFIG_RX_MSAA_SAMPLES",
                "label": "Max MSAA Sample Count",
                "type": "choice",
                "choices": ["2", "4"],
                "default": "4",
                "help": "Maximum MSAA sample count when MSAA is enabled.",
            },
            {
                "key": "CONFIG_RX_ENABLE_EARLY_Z",
                "label": "Early-Z / Hi-Z Occlusion Culling",
                "type": "bool",
                "default": "1",
                "help": "Hierarchical Hi-Z occlusion culling RAM for early depth rejection.",
            },
            {
                "key": "CONFIG_RX_COARSE_SCAN",
                "label": "Two-Level Coarse Tile Scanning",
                "type": "bool",
                "default": "1",
                "help": "Coarse tile traversal before fine pixel scan.",
            },
        ],
    },
    {
        "title": "3. Texture Unit (TU) Configuration",
        "items": [
            {
                "key": "CONFIG_TU_ENABLE_BC",
                "label": "Block Compression (BC1-BC7) Decompressor",
                "type": "bool",
                "default": "0",
                "help": "Hardware decompression for desktop BC1-BC7 compressed textures.",
            },
            {
                "key": "CONFIG_TU_ENABLE_ETC2",
                "label": "ETC2 / EAC Texture Decompressor",
                "type": "bool",
                "default": "0",
                "help": "Hardware decompressor for mobile/Khronos standard ETC2/EAC formats (formats 147..156).",
            },
            {
                "key": "CONFIG_TU_ENABLE_ANISO",
                "label": "Anisotropic Filtering (up to 16x)",
                "type": "bool",
                "default": "0",
                "help": "Elliptical Weighted Average (EWA) anisotropic texture filtering up to 16x.",
            },
            {
                "key": "CONFIG_TU_ENABLE_SEAMLESS_CUBE",
                "label": "Seamless Cube Map Edge Filtering",
                "type": "bool",
                "default": "0",
                "help": "Hardware texel interpolation across cubemap face edges.",
            },
            {
                "key": "CONFIG_TU_ENABLE_FP_FILTER",
                "label": "Floating-Point Texture Filtering (FP16/FP32)",
                "type": "bool",
                "default": "0",
                "help": "Hardware floating-point texture filtering (reflected in DEVICE_CAPS[25]).",
            },
            {
                "key": "CONFIG_TU_ENABLE_ARRAY",
                "label": "Texture Array Layer Addressing (1D/2D Array)",
                "type": "bool",
                "default": "0",
                "help": "Hardware addressing and slice coordinate calculation for 1D/2D texture arrays.",
            },
            {
                "key": "CONFIG_TU_ENABLE_TRILINEAR",
                "label": "Trilinear / Mipmap Filtering",
                "type": "bool",
                "default": "1",
                "help": "Hardware mipmap filtering and trilinear interpolation.",
            },
            {
                "key": "CONFIG_TU_ENABLE_3D_CUBE",
                "label": "3D Volume & Cube Map Addressing",
                "type": "bool",
                "default": "0",
                "help": "Hardware addressing for 3D textures and Cube maps.",
            },
            {
                "key": "CONFIG_TU_L1_BANKS",
                "label": "Texture Cache L1 Bank Count",
                "type": "choice",
                "choices": ["1", "2", "4"],
                "default": "4",
                "help": "Number of parallel banks in Texture L1 cache.",
            },
            {
                "key": "CONFIG_TU_ENABLE_MSHR",
                "label": "Non-blocking MSHR Cache Pipeline",
                "type": "bool",
                "default": "1",
                "help": "Miss Status Holding Registers for non-blocking cache lookups.",
            },
        ],
    },
    {
        "title": "4. Render Output Backend (ROP) & Formats",
        "items": [
            {
                "key": "CONFIG_FMT_ENABLE_FP16",
                "label": "16-bit Float Formats (R16F, RGBA16F)",
                "type": "bool",
                "default": "0",
                "help": "Half-precision float color attachments, textures, and blending.",
            },
            {
                "key": "CONFIG_FMT_ENABLE_FP32",
                "label": "32-bit Float Formats (R32F, RGBA32F)",
                "type": "bool",
                "default": "0",
                "help": "Single-precision float color attachments and storage buffers.",
            },
            {
                "key": "CONFIG_FMT_ENABLE_SRGB",
                "label": "sRGB Hardware Conversion & Framebuffers",
                "type": "bool",
                "default": "1",
                "help": "Hardware sRGB to linear and linear to sRGB gamma conversion.",
            },
            {
                "key": "CONFIG_FMT_ENABLE_RGB565",
                "label": "16-bit Packed Color Formats (RGB565, RGBA4, ARGB1555)",
                "type": "bool",
                "default": "1",
                "help": "Support for 16-bit packed integer color formats.",
            },
            {
                "key": "CONFIG_FMT_ENABLE_DEPTH24_S8",
                "label": "24-bit Depth / 8-bit Stencil (D24_UNORM_S8_UINT)",
                "type": "bool",
                "default": "1",
                "help": "Standard 24-bit fixed depth with 8-bit stencil attachment.",
            },
            {
                "key": "CONFIG_FMT_ENABLE_DEPTH32F",
                "label": "32-bit Float Depth (D32_SFLOAT)",
                "type": "bool",
                "default": "0",
                "help": "High-precision 32-bit floating point depth attachment.",
            },
            {
                "key": "CONFIG_FMT_ENABLE_DEPTH16",
                "label": "16-bit Depth (D16_UNORM)",
                "type": "bool",
                "default": "1",
                "help": "Compact 16-bit depth attachment.",
            },
            {
                "key": "CONFIG_ROP_DUAL_SOURCE",
                "label": "Dual-Source Blending",
                "type": "bool",
                "default": "0",
                "help": "Vulkan Dual-Source Blending support (Src1Color / Src1Alpha).",
            },
            {
                "key": "CONFIG_ROP_ENABLE_LOGICOP",
                "label": "Bitwise LogicOp Operations",
                "type": "bool",
                "default": "0",
                "help": "Support 16 bitwise LogicOp blend modes.",
            },
            {
                "key": "CONFIG_ROP_FAST_CLEAR",
                "label": "Tile Fast Clear Metadata RAM",
                "type": "bool",
                "default": "1",
                "help": "Instant color/depth tile buffer fast clear tags.",
            },
            {
                "key": "CONFIG_ROP_MRT_COUNT",
                "label": "Simultaneous Multiple Render Targets",
                "type": "choice",
                "choices": ["1", "2", "4"],
                "default": "1",
                "help": "Maximum simultaneous color render targets.",
            },
        ],
    },
    {
        "title": "5. Command Processor (CP) & Memory Hierarchy",
        "items": [
            {
                "key": "CONFIG_GPU_VA_BITS",
                "label": "GPU Virtual Address Width (VA_BITS)",
                "type": "choice",
                "choices": ["30", "32", "36", "40"],
                "default": "32",
                "help": "Internal GPU virtual address representation width in bits (30..40, 1 GiB to 1 TiB). 32 bits = 4 GiB.",
            },
            {
                "key": "CONFIG_HOST_PA_BITS",
                "label": "Host Physical Address Width (PA_BITS)",
                "type": "choice",
                "choices": ["40", "44", "48"],
                "default": "40",
                "help": "Host physical address width for PCIe DMA in bits (40..48, 1 TiB to 256 TiB). 40 bits = 1 TiB.",
            },
            {
                "key": "CONFIG_CP_AUTONOMOUS_MMU",
                "label": "Hardware Page Table Walker",
                "type": "bool",
                "default": "1",
                "help": "Autonomous two-level MMU hardware page table walker.",
            },
            {
                "key": "CONFIG_CP_USE_RV32_CORE",
                "label": "RV32IM Microcode Core",
                "type": "bool",
                "default": "1",
                "help": "RV32IM microcode core (0: Lightweight hardwired FSM).",
            },
            {
                "key": "CONFIG_MC_L2_CACHE_KB",
                "label": "Shared L2 Cache Size (KB)",
                "type": "choice",
                "choices": ["0", "16", "32", "64", "128"],
                "default": "64",
                "help": "Last-Level Cache (L2) capacity in Kilobytes.",
            },
            {
                "key": "CONFIG_DC_ENABLE_CURSOR",
                "label": "Hardware Cursor Plane",
                "type": "bool",
                "default": "1",
                "help": "Dedicated hardware cursor plane in Display Controller.",
            },
        ],
    },
]


def load_config(root_dir="."):
    """Loads configuration values from config.mk or config.mk.template."""
    cfg = {}
    # 1. Populate defaults
    for sec in SCHEMA:
        for it in sec["items"]:
            cfg[it["key"]] = str(it["default"])

    # 2. Try loading config.mk or config.mk.template
    target = os.path.join(root_dir, CONFIG_FILE)
    if not os.path.exists(target):
        target = os.path.join(root_dir, CONFIG_TEMPLATE)

    if os.path.exists(target):
        with open(target, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                m = re.match(r"^([A-Za-z0-9_]+)\s*\??=\s*([^#]+)", line)
                if m:
                    k, v = m.group(1).strip(), m.group(2).strip()
                    cfg[k] = v
    return cfg


def save_config(cfg, root_dir="."):
    """Saves configuration values to config.mk, preserving template layout and comments."""
    template_path = os.path.join(root_dir, CONFIG_TEMPLATE)
    target_path = os.path.join(root_dir, CONFIG_FILE)

    if os.path.exists(template_path):
        with open(template_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    elif os.path.exists(target_path):
        with open(target_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    else:
        lines = []

    written_keys = set()
    new_lines = []
    for line in lines:
        m = re.match(r"^([A-Za-z0-9_]+)(\s*\??=\s*)([^#\n]*)(.*)$", line)
        if m:
            k, eq, val, comment = m.group(1), m.group(2), m.group(3), m.group(4)
            if k in cfg:
                written_keys.add(k)
                new_line = f"{k:<24} ?= {cfg[k]}"
                if comment.strip():
                    new_line = f"{new_line:<36} {comment.strip()}\n"
                else:
                    new_line = f"{new_line}\n"
                new_lines.append(new_line)
                continue
        new_lines.append(line)

    # Any extra keys not in template
    for k, v in cfg.items():
        if k not in written_keys:
            new_lines.append(f"{k:<24} ?= {v}\n")

    with open(target_path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)


class MenuApp:
    def __init__(self, stdscr, cfg, root_dir="."):
        self.stdscr = stdscr
        self.cfg = cfg
        self.root_dir = root_dir
        self.modified = False
        self.status_msg = ""

        # Flatten list of entries: headers and items
        self.entries = []
        for sec in SCHEMA:
            self.entries.append({"type": "header", "title": sec["title"]})
            for it in sec["items"]:
                self.entries.append({"type": "item", "item": it})

        # Find first selectable item index
        self.cursor = 0
        for i, ent in enumerate(self.entries):
            if ent["type"] == "item":
                self.cursor = i
                break

        self.scroll_offset = 0

    def toggle_or_next(self, ent, forward=True):
        if ent["type"] != "item":
            return
        it = ent["item"]
        k = it["key"]
        curr = self.cfg.get(k, str(it["default"]))

        if it["type"] == "bool":
            new_val = "0" if curr == "1" else "1"
            self.cfg[k] = new_val
            self.modified = True
            self.status_msg = f"Changed {k} = {new_val}"
        elif it["type"] == "choice":
            choices = it["choices"]
            idx = choices.index(curr) if curr in choices else 0
            if forward:
                idx = (idx + 1) % len(choices)
            else:
                idx = (idx - 1 + len(choices)) % len(choices)
            self.cfg[k] = choices[idx]
            self.modified = True
            self.status_msg = f"Changed {k} = {choices[idx]}"

    def run(self):
        curses.curs_set(0)
        self.stdscr.keypad(True)
        # Use terminal colors if available
        if curses.has_colors():
            curses.start_color()
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)   # Header / Bar
            curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)   # Highlight
            curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLACK) # Section Header
            curses.init_pair(4, curses.COLOR_GREEN, curses.COLOR_BLACK)  # Enabled
            curses.init_pair(5, curses.COLOR_RED, curses.COLOR_BLACK)    # Disabled
            curses.init_pair(6, curses.COLOR_CYAN, curses.COLOR_BLACK)   # Values

        while True:
            self.draw()
            try:
                ch = self.stdscr.getch()
            except KeyboardInterrupt:
                break

            if ch in (ord('q'), ord('Q'), 27):  # 'q' or ESC
                if self.modified:
                    # Confirm exit without save
                    if self.confirm_dialog("Configuration modified. Exit without saving? (y/n)"):
                        break
                else:
                    break
            elif ch in (ord('s'), ord('S')):
                save_config(self.cfg, self.root_dir)
                self.modified = False
                self.status_msg = f"Configuration saved successfully to {CONFIG_FILE}!"
            elif ch in (ord('r'), ord('R')):
                if self.confirm_dialog("Reset all settings to defaults? (y/n)"):
                    for sec in SCHEMA:
                        for it in sec["items"]:
                            self.cfg[it["key"]] = str(it["default"])
                    self.modified = True
                    self.status_msg = "All settings reset to defaults."
            elif ch in (curses.KEY_UP, ord('k')):
                self.move_cursor(-1)
            elif ch in (curses.KEY_DOWN, ord('j')):
                self.move_cursor(1)
            elif ch in (curses.KEY_LEFT, ord('h')):
                ent = self.entries[self.cursor]
                self.toggle_or_next(ent, forward=False)
            elif ch in (curses.KEY_RIGHT, ord('l')):
                ent = self.entries[self.cursor]
                self.toggle_or_next(ent, forward=True)
            elif ch in (ord(' '), 10, 13, curses.KEY_ENTER):
                ent = self.entries[self.cursor]
                self.toggle_or_next(ent, forward=True)

    def move_cursor(self, delta):
        n = len(self.entries)
        idx = self.cursor
        while True:
            idx += delta
            if idx < 0 or idx >= n:
                return  # Reached boundary
            if self.entries[idx]["type"] == "item":
                self.cursor = idx
                return

    def confirm_dialog(self, message):
        h, w = self.stdscr.getmaxyx()
        box_w = min(len(message) + 6, w - 4)
        box_h = 5
        start_y = (h - box_h) // 2
        start_x = (w - box_w) // 2
        win = curses.newwin(box_h, box_w, start_y, start_x)
        win.box()
        win.addstr(1, 2, message[:box_w - 4], curses.A_BOLD)
        win.addstr(3, (box_w - 18) // 2, "[Y]es      [N]o")
        win.refresh()
        while True:
            ch = win.getch()
            if ch in (ord('y'), ord('Y')):
                return True
            elif ch in (ord('n'), ord('N'), 27, ord('q'), ord('Q')):
                return False

    def draw(self):
        self.stdscr.erase()
        h, w = self.stdscr.getmaxyx()

        # Top Title Bar
        title = " Amaterrace GPU (ATG1) Menuconfig "
        mod_indicator = " [*MODIFIED*]" if self.modified else ""
        header_text = f"{title}{mod_indicator}"
        header_bar = header_text + " " * max(0, w - len(header_text))
        try:
            self.stdscr.addstr(0, 0, header_bar[:w], curses.color_pair(1) | curses.A_BOLD)
        except curses.error:
            pass

        # Viewport layout
        # Lines 2 to h - 6 for the menu list
        menu_top = 2
        menu_bottom = h - 6
        menu_height = max(1, menu_bottom - menu_top + 1)

        # Adjust scroll offset so cursor is visible
        if self.cursor < self.scroll_offset:
            self.scroll_offset = self.cursor
        elif self.cursor >= self.scroll_offset + menu_height:
            self.scroll_offset = self.cursor - menu_height + 1

        # Draw menu items
        for line_idx in range(menu_height):
            entry_idx = self.scroll_offset + line_idx
            if entry_idx >= len(self.entries):
                break

            ent = self.entries[entry_idx]
            y = menu_top + line_idx

            if ent["type"] == "header":
                header_line = f"  -- {ent['title']} --"
                try:
                    self.stdscr.addstr(y, 0, header_line[:w], curses.color_pair(3) | curses.A_BOLD)
                except curses.error:
                    pass
            elif ent["type"] == "item":
                it = ent["item"]
                k = it["key"]
                val = self.cfg.get(k, str(it["default"]))
                is_selected = (entry_idx == self.cursor)

                if it["type"] == "bool":
                    val_str = "[*] Enabled " if val == "1" else "[ ] Disabled"
                    val_color = curses.color_pair(4) if val == "1" else curses.color_pair(5)
                else:
                    val_str = f"<{val:>4}>"
                    val_color = curses.color_pair(6) | curses.A_BOLD

                label_col_w = min(42, max(20, w - 30))
                label_fmt = it["label"][:label_col_w]
                item_line = f"    {label_fmt:<{label_col_w}} "

                try:
                    if is_selected:
                        self.stdscr.addstr(y, 0, "> " + item_line[2:], curses.color_pair(2) | curses.A_BOLD)
                        self.stdscr.addstr(y, len(item_line), val_str, curses.color_pair(2) | curses.A_BOLD)
                    else:
                        self.stdscr.addstr(y, 0, item_line)
                        self.stdscr.addstr(y, len(item_line), val_str, val_color)
                except curses.error:
                    pass

        # Divider and Item Help Text
        help_y = h - 5
        try:
            self.stdscr.addstr(help_y - 1, 0, "-" * w)
        except curses.error:
            pass

        selected_ent = self.entries[self.cursor]
        if selected_ent["type"] == "item":
            it = selected_ent["item"]
            help_text = f"[{it['key']}] {it['help']}"
            try:
                self.stdscr.addstr(help_y, 2, help_text[:w - 4], curses.A_DIM)
            except curses.error:
                pass

        # Status Message
        if self.status_msg:
            try:
                self.stdscr.addstr(h - 3, 2, self.status_msg[:w - 4], curses.color_pair(4) | curses.A_BOLD)
            except curses.error:
                pass

        # Bottom Key Command Bar
        bottom_bar = " [Up/Down]: Move  [Space/Enter]: Toggle/Change  [S]: Save  [R]: Reset  [Q]: Quit "
        bottom_fill = bottom_bar + " " * max(0, w - len(bottom_bar))
        try:
            self.stdscr.addstr(h - 1, 0, bottom_fill[:w], curses.color_pair(1))
        except curses.error:
            pass

        self.stdscr.refresh()


PRESETS = {
    "minimal": {
        "TARGET_PRESET": "minimal_sim",
        "CONFIG_SU_NPHYS": "4",
        "CONFIG_SU_NWARPS": "2",
        "CONFIG_SU_NREGS": "32",
        "CONFIG_SU_ENABLE_FP16": "0",
        "CONFIG_SU_ENABLE_SUBGROUP": "0",
        "CONFIG_SU_ENABLE_SFU": "0",
        "CONFIG_SU_LDS_KB": "0",
        "CONFIG_SU_ENABLE_SA": "0",
        "CONFIG_SU_ENABLE_MESH": "0",
        "CONFIG_RX_ENABLE_MSAA": "0",
        "CONFIG_RX_MSAA_SAMPLES": "1",
        "CONFIG_RX_ENABLE_EARLY_Z": "0",
        "CONFIG_RX_COARSE_SCAN": "0",
        "CONFIG_TU_ENABLE_BC": "0",
        "CONFIG_TU_ENABLE_TRILINEAR": "0",
        "CONFIG_TU_ENABLE_3D_CUBE": "0",
        "CONFIG_TU_ENABLE_MSHR": "0",
        "CONFIG_ROP_DUAL_SOURCE": "0",
        "CONFIG_ROP_ENABLE_LOGICOP": "0",
        "CONFIG_ROP_MRT_COUNT": "1",
        "CONFIG_ROP_FAST_CLEAR": "0",
        "CONFIG_CP_AUTONOMOUS_MMU": "0",
        "CONFIG_CP_USE_RV32_CORE": "0",
        "CONFIG_MC_L2_CACHE_KB": "16",
        "CONFIG_DC_ENABLE_CURSOR": "0",
    },
    "balanced": {
        "TARGET_PRESET": "kc705",
        "CONFIG_SU_NPHYS": "8",
        "CONFIG_SU_NWARPS": "4",
        "CONFIG_SU_NREGS": "32",
        "CONFIG_SU_ENABLE_FP16": "1",
        "CONFIG_SU_ENABLE_SUBGROUP": "1",
        "CONFIG_SU_ENABLE_SFU": "1",
        "CONFIG_SU_LDS_KB": "4",
        "CONFIG_SU_ENABLE_SA": "0",
        "CONFIG_SU_ENABLE_MESH": "0",
        "CONFIG_RX_ENABLE_MSAA": "1",
        "CONFIG_RX_MSAA_SAMPLES": "4",
        "CONFIG_RX_ENABLE_EARLY_Z": "1",
        "CONFIG_RX_COARSE_SCAN": "1",
        "CONFIG_TU_ENABLE_BC": "0",
        "CONFIG_TU_ENABLE_TRILINEAR": "1",
        "CONFIG_TU_ENABLE_3D_CUBE": "1",
        "CONFIG_TU_ENABLE_MSHR": "1",
        "CONFIG_ROP_DUAL_SOURCE": "1",
        "CONFIG_ROP_ENABLE_LOGICOP": "1",
        "CONFIG_ROP_MRT_COUNT": "1",
        "CONFIG_ROP_FAST_CLEAR": "1",
        "CONFIG_CP_AUTONOMOUS_MMU": "1",
        "CONFIG_CP_USE_RV32_CORE": "1",
        "CONFIG_MC_L2_CACHE_KB": "64",
        "CONFIG_DC_ENABLE_CURSOR": "1",
    },
    "high-perf": {
        "TARGET_PRESET": "kc705",
        "CONFIG_SU_NPHYS": "16",
        "CONFIG_SU_NWARPS": "8",
        "CONFIG_SU_NREGS": "64",
        "CONFIG_SU_ENABLE_FP16": "1",
        "CONFIG_SU_ENABLE_SUBGROUP": "1",
        "CONFIG_SU_ENABLE_SFU": "1",
        "CONFIG_SU_LDS_KB": "4",
        "CONFIG_SU_ENABLE_SA": "1",
        "CONFIG_SU_ENABLE_MESH": "1",
        "CONFIG_RX_ENABLE_MSAA": "1",
        "CONFIG_RX_MSAA_SAMPLES": "4",
        "CONFIG_RX_ENABLE_EARLY_Z": "1",
        "CONFIG_RX_COARSE_SCAN": "1",
        "CONFIG_TU_ENABLE_BC": "1",
        "CONFIG_TU_ENABLE_TRILINEAR": "1",
        "CONFIG_TU_ENABLE_3D_CUBE": "1",
        "CONFIG_TU_ENABLE_MSHR": "1",
        "CONFIG_ROP_DUAL_SOURCE": "1",
        "CONFIG_ROP_ENABLE_LOGICOP": "1",
        "CONFIG_ROP_MRT_COUNT": "4",
        "CONFIG_ROP_FAST_CLEAR": "1",
        "CONFIG_CP_AUTONOMOUS_MMU": "1",
        "CONFIG_CP_USE_RV32_CORE": "1",
        "CONFIG_MC_L2_CACHE_KB": "128",
        "CONFIG_DC_ENABLE_CURSOR": "1",
    }
}


def main():
    parser = argparse.ArgumentParser(description="Amaterrace GPU Build Configuration Tool (menuconfig)")
    parser.add_argument("--preset", choices=["minimal", "balanced", "high-perf"], help="Apply standard build preset")
    parser.add_argument("--show", action="store_true", help="Print current configuration and exit")
    parser.add_argument("--set", metavar="KEY=VALUE", action="append", help="Set a configuration parameter")
    parser.add_argument("--root", default=".", help="Project root directory containing config files")
    args = parser.parse_args()

    cfg = load_config(args.root)

    if args.preset:
        preset_cfg = PRESETS[args.preset]
        cfg.update(preset_cfg)
        save_config(cfg, args.root)
        print(f"Applied preset '{args.preset}' and saved to {os.path.join(args.root, CONFIG_FILE)}.")
        return

    if args.set:
        for item in args.set:
            if "=" not in item:
                print(f"Error: Invalid argument format: '{item}'. Use KEY=VALUE.")
                sys.exit(1)
            k, v = item.split("=", 1)
            cfg[k.strip()] = v.strip()
        save_config(cfg, args.root)
        print(f"Updated configuration saved to {os.path.join(args.root, CONFIG_FILE)}.")
        return

    if args.show or not sys.stdin.isatty():
        print("=" * 60)
        print(" Amaterrace GPU (ATG1) Configuration")
        print("=" * 60)
        for sec in SCHEMA:
            print(f"\n[{sec['title']}]")
            for it in sec["items"]:
                k = it["key"]
                v = cfg.get(k, str(it["default"]))
                type_str = "(bool)  " if it["type"] == "bool" else "(choice)"
                print(f"  {k:<28} = {v:<8} {type_str} # {it['label']}")
        print("=" * 60)
        return

    # Interactive Curses Mode
    curses.wrapper(lambda stdscr: MenuApp(stdscr, cfg, args.root).run())


if __name__ == "__main__":
    main()
