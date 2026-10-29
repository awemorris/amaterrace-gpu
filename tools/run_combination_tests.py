#!/usr/bin/env python3
"""
run_combination_tests.py: Automated runner for docs/combination.md OOC matrix tests.
"""
import sys
import os
import subprocess
import json
import re
from pathlib import Path

# Add tools to sys.path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import parse_synth_result

MODULE_TESTS = {
    "fmt": [
        {"id": "FMT-F-MAX",  "mod": "atg_fmt_cvt", "extra": "", "cat": "FULL", "size": "MAX", "desc": "全形式有効 7段パイプライン"},
        {"id": "FMT-B-MIN",  "mod": "atg_fmt_cvt", "extra": "CFG_FMT_BARE=1", "cat": "BARE", "size": "MIN", "desc": "RGBA8 UINT/UNORM のみ"},
        {"id": "FMT-I-FP16", "mod": "atg_fmt_cvt", "extra": "CFG_FMT_FP16_ONLY=1", "cat": "ISO-FP16", "size": "MIN", "desc": "FP16 相互変換のみ単独有効"},
        {"id": "FMT-I-SRGB", "mod": "atg_fmt_cvt", "extra": "CFG_FMT_SRGB_ONLY=1", "cat": "ISO-sRGB", "size": "MIN", "desc": "sRGB テーブルのみ単独有効"},
        {"id": "FMT-I-SNRM", "mod": "atg_fmt_cvt", "extra": "CFG_FMT_SNORM_ONLY=1", "cat": "ISO-SNORM", "size": "MIN", "desc": "SNORM のみ単独有効"},
        {"id": "FMT-I-DEP",  "mod": "atg_fmt_cvt", "extra": "CFG_FMT_DEPTH_ONLY=1", "cat": "ISO-Depth", "size": "MIN", "desc": "D24S8 / D32F のみ単独有効"},
        {"id": "FMT-P-FS",   "mod": "atg_fmt_cvt", "extra": "CFG_FMT_FP16_SRGB=1", "cat": "PAIR-FP16+sRGB", "size": "MIN", "desc": "FP16 + sRGB 有効"},
        {"id": "FMT-P-PD",   "mod": "atg_fmt_cvt", "extra": "CFG_FMT_PACKED_DEPTH=1", "cat": "PAIR-Pack+Depth", "size": "MIN", "desc": "Packed + Depth 有効"},
        {"id": "FMT-P-SS",   "mod": "atg_fmt_cvt", "extra": "CFG_FMT_FP32_SNORM=1", "cat": "PAIR-FP32+SNORM", "size": "MIN", "desc": "FP32 + SNORM 有効"},
        {"id": "FMT-T-FSP",  "mod": "atg_fmt_cvt", "extra": "CFG_FMT_FP16_SRGB_PACKED=1", "cat": "TRIO-FP16+sRGB+Pk", "size": "MIN", "desc": "FP16 + sRGB + Packed"},
        {"id": "FMT-T-SPD",  "mod": "atg_fmt_cvt", "extra": "CFG_FMT_SRGB_PACKED_DEPTH=1", "cat": "TRIO-sRGB+Pk+Dep", "size": "MIN", "desc": "sRGB + Packed + Depth"},
        {"id": "FMT-Q-FPSD", "mod": "atg_fmt_cvt", "extra": "CFG_FMT_FP16_SRGB_PACKED_DEPTH=1", "cat": "QUAD-All4", "size": "MIN", "desc": "FP16 + sRGB + Packed + Depth"},
        {"id": "FMT-S-HALF", "mod": "atg_fmt_cvt", "extra": "CFG_FMT_STAGE_5=1", "cat": "FULL", "size": "HALF", "desc": "全形式有効 5段パイプライン"},
        {"id": "FMT-S-QTR",  "mod": "atg_fmt_cvt", "extra": "CFG_FMT_STAGE_3=1", "cat": "FULL", "size": "QUARTER", "desc": "全形式有効 3段パイプライン"},
    ],
    "vf": [
        {"id": "VF-F-MAX",  "mod": "atg_vf_conv", "extra": "", "cat": "FULL", "size": "MAX", "desc": "VkFormat=1, Cache=8 lines"},
        {"id": "VF-B-MIN",  "mod": "atg_vf_conv", "extra": "CFG_VF_BARE=1", "cat": "BARE", "size": "MIN", "desc": "標準Floatのみ, Cache=1 line"},
        {"id": "VF-I-VK",   "mod": "atg_vf_conv", "extra": "CFG_VF_VKFMT=1", "cat": "ISO-VkFormat", "size": "MIN", "desc": "VkFormat 単独有効"},
        {"id": "VF-I-INST", "mod": "atg_vf_conv", "extra": "CFG_VF_INST=1", "cat": "ISO-Inst", "size": "MIN", "desc": "インスタンシング単独有効"},
        {"id": "VF-I-OOB",  "mod": "atg_vf_conv", "extra": "CFG_VF_OOB=1", "cat": "ISO-OOB", "size": "MIN", "desc": "OOB判定単独有効"},
        {"id": "VF-P-VI",   "mod": "atg_vf_conv", "extra": "CFG_VF_VKFMT=1 CFG_VF_INST=1", "cat": "PAIR-VkFmt+Inst", "size": "MIN", "desc": "VkFormat + Instancing 有効"},
        {"id": "VF-P-VO",   "mod": "atg_vf_conv", "extra": "CFG_VF_VKFMT=1 CFG_VF_OOB=1", "cat": "PAIR-VkFmt+OOB", "size": "MIN", "desc": "VkFormat + OOB 有効"},
        {"id": "VF-P-IB",   "mod": "atg_vf_conv", "extra": "CFG_VF_INST=1 CFG_VF_IB=1", "cat": "PAIR-Inst+IBCache", "size": "MIN", "desc": "Instancing + IB Cache 有効"},
        {"id": "VF-T-VIO",  "mod": "atg_vf_conv", "extra": "CFG_VF_VKFMT=1 CFG_VF_INST=1 CFG_VF_OOB=1", "cat": "TRIO-Vk+Inst+OOB", "size": "MIN", "desc": "VkFormat + Inst + OOB"},
        {"id": "VF-T-VIB",  "mod": "atg_vf_conv", "extra": "CFG_VF_VKFMT=1 CFG_VF_INST=1 CFG_VF_IB=1", "cat": "TRIO-Vk+Inst+IB", "size": "MIN", "desc": "VkFormat + Inst + IB Cache"},
        {"id": "VF-Q-ALL",  "mod": "atg_vf_conv", "extra": "CFG_VF_ALL=1", "cat": "QUAD-All4", "size": "MIN", "desc": "VkFormat + Inst + OOB + IBCache"},
        {"id": "VF-S-HALF", "mod": "atg_vf_conv", "extra": "CFG_VF_HALF=1", "cat": "FULL", "size": "HALF", "desc": "全機能有効, Cache=4 lines"},
        {"id": "VF-S-QTR",  "mod": "atg_vf_conv", "extra": "CFG_VF_QTR=1", "cat": "FULL", "size": "QUARTER", "desc": "全機能有効, Cache=2 lines"},
    ],
    "blt": [
        {"id": "BLT-F-MAX",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=64 LINE_SHIFT=6", "cat": "FULL", "size": "MAX", "desc": "全機能有効, FIFO=64"},
        {"id": "BLT-B-MIN",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=16 LINE_SHIFT=4", "cat": "BARE", "size": "MIN", "desc": "Direct Copy のみ, FIFO=16"},
        {"id": "BLT-I-ROP",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_ROP_ONLY=1", "cat": "ISO-ROP3", "size": "MIN", "desc": "ROP3 単独有効"},
        {"id": "BLT-I-SCL",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_SCL_ONLY=1", "cat": "ISO-Scaling", "size": "MIN", "desc": "Scaling 単独有効"},
        {"id": "BLT-I-FMT",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_FMT_ONLY=1", "cat": "ISO-FmtCvt", "size": "MIN", "desc": "FmtCvt 単独有効"},
        {"id": "BLT-P-RS",   "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_RS=1", "cat": "PAIR-ROP3+Scl", "size": "MIN", "desc": "ROP3 + Scaling 有効"},
        {"id": "BLT-P-SF",   "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_SF=1", "cat": "PAIR-Scl+Fmt", "size": "MIN", "desc": "Scaling + FmtCvt 有効"},
        {"id": "BLT-P-FC",   "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_FC=1", "cat": "PAIR-Fmt+Clip", "size": "MIN", "desc": "FmtCvt + Clip 有効"},
        {"id": "BLT-T-RSF",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_RSF=1", "cat": "TRIO-ROP+Scl+Fmt", "size": "MIN", "desc": "ROP3 + Scaling + FmtCvt"},
        {"id": "BLT-T-SFC",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5 CFG_BLT_SFC=1", "cat": "TRIO-Scl+Fmt+Clp", "size": "MIN", "desc": "Scaling + FmtCvt + Clip"},
        {"id": "BLT-Q-ALL",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5", "cat": "QUAD-All4", "size": "MIN", "desc": "4機能全有効 (FIFO=32)"},
        {"id": "BLT-S-HALF", "mod": "atg_blt_2d", "extra": "LINE_BYTES=32 LINE_SHIFT=5", "cat": "FULL", "size": "HALF", "desc": "全機能有効, FIFO=32"},
        {"id": "BLT-S-QTR",  "mod": "atg_blt_2d", "extra": "LINE_BYTES=16 LINE_SHIFT=4", "cat": "FULL", "size": "QUARTER", "desc": "全機能有効, FIFO=16"},
    ],
    "dc": [
        {"id": "DC-F-MAX",  "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=11", "cat": "FULL", "size": "MAX", "desc": "Cursor=1, FIFO=2048"},
        {"id": "DC-B-MIN",  "mod": "atg_dc", "extra": "HAS_CURSOR=0 FIFO_LOG2=7",  "cat": "BARE", "size": "MIN", "desc": "Direct Out, FIFO=128"},
        {"id": "DC-I-CUR",  "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=7",  "cat": "ISO-Cursor", "size": "MIN", "desc": "Cursor 単独有効"},
        {"id": "DC-I-PL2",  "mod": "atg_dc", "extra": "HAS_CURSOR=0 FIFO_LOG2=7 CFG_DC_PLANE2=1", "cat": "ISO-Plane2", "size": "MIN", "desc": "Plane2 単独有効"},
        {"id": "DC-I-TMD",  "mod": "atg_dc", "extra": "HAS_CURSOR=0 FIFO_LOG2=7 CFG_DC_TMDS=1",   "cat": "ISO-TMDS", "size": "MIN", "desc": "TMDS 単独有効"},
        {"id": "DC-P-CP",   "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=7 CFG_DC_PLANE2=1", "cat": "PAIR-Cur+Plane2", "size": "MIN", "desc": "Cursor + Plane2 有効"},
        {"id": "DC-P-PT",   "mod": "atg_dc", "extra": "HAS_CURSOR=0 FIFO_LOG2=7 CFG_DC_PLANE2=1 CFG_DC_TMDS=1", "cat": "PAIR-Pl2+TMDS", "size": "MIN", "desc": "Plane2 + TMDS 有効"},
        {"id": "DC-P-CG",   "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=7 CFG_DC_GAMMA=1",  "cat": "PAIR-Cur+Gamma", "size": "MIN", "desc": "Cursor + Gamma 有効"},
        {"id": "DC-T-CPT",  "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=7 CFG_DC_PLANE2=1 CFG_DC_TMDS=1", "cat": "TRIO-Cur+Pl2+TMD", "size": "MIN", "desc": "Cursor + Plane2 + TMDS"},
        {"id": "DC-T-CPG",  "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=7 CFG_DC_PLANE2=1 CFG_DC_GAMMA=1", "cat": "TRIO-Cur+Pl2+Gam", "size": "MIN", "desc": "Cursor + Plane2 + Gamma"},
        {"id": "DC-Q-ALL",  "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=7 CFG_DC_PLANE2=1 CFG_DC_TMDS=1 CFG_DC_GAMMA=1", "cat": "QUAD-All4", "size": "MIN", "desc": "4機能全有効 (最小FIFO)"},
        {"id": "DC-S-HALF", "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=10", "cat": "FULL", "size": "HALF", "desc": "全機能有効, FIFO=1024"},
        {"id": "DC-S-QTR",  "mod": "atg_dc", "extra": "HAS_CURSOR=1 FIFO_LOG2=9",  "cat": "FULL", "size": "QUARTER", "desc": "全機能有効, FIFO=512"},
    ],
    "mc": [
        {"id": "MC-F-MAX",  "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=1 L2_WAYS=16 L2_SET_W=8", "cat": "FULL", "size": "MAX", "desc": "L2=128KB 16-way, Prot=1"},
        {"id": "MC-B-MIN",  "mod": "atg_mc", "extra": "HAS_PROT=0 HAS_L2=0", "cat": "BARE", "size": "MIN", "desc": "ベースラインのみ (L2/Prot無効)"},
        {"id": "MC-I-PROT", "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=0", "cat": "ISO-Prot", "size": "MIN", "desc": "Prot 単独有効"},
        {"id": "MC-I-COAL", "mod": "atg_mc", "extra": "HAS_PROT=0 HAS_L2=0 CFG_MC_COAL=1", "cat": "ISO-Coalesce", "size": "MIN", "desc": "Coalesce 単独有効"},
        {"id": "MC-I-PREF", "mod": "atg_mc", "extra": "HAS_PROT=0 HAS_L2=0 CFG_MC_PREF=1", "cat": "ISO-Prefetch", "size": "MIN", "desc": "Prefetch 単独有効"},
        {"id": "MC-I-PRIO", "mod": "atg_mc", "extra": "HAS_PROT=0 HAS_L2=0 CFG_MC_PRIO=1", "cat": "ISO-Priority", "size": "MIN", "desc": "Priority 単独有効"},
        {"id": "MC-P-PC",   "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=0 CFG_MC_COAL=1", "cat": "PAIR-Prot+Coalesce", "size": "MIN", "desc": "Prot + Coalesce 有効"},
        {"id": "MC-P-CP",   "mod": "atg_mc", "extra": "HAS_PROT=0 HAS_L2=0 CFG_MC_COAL=1 CFG_MC_PREF=1", "cat": "PAIR-Coalesce+Prefetch", "size": "MIN", "desc": "Coalesce + Prefetch 有効"},
        {"id": "MC-P-PP",   "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=0 CFG_MC_PRIO=1", "cat": "PAIR-Prot+Priority", "size": "MIN", "desc": "Prot + Priority 有効"},
        {"id": "MC-T-PCP",  "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=0 CFG_MC_COAL=1 CFG_MC_PREF=1", "cat": "TRIO-Prot+Coalesce+Prefetch", "size": "MIN", "desc": "Prot + Coalesce + Prefetch"},
        {"id": "MC-T-CPP",  "mod": "atg_mc", "extra": "HAS_PROT=0 HAS_L2=0 CFG_MC_COAL=1 CFG_MC_PREF=1 CFG_MC_PRIO=1", "cat": "TRIO-Coalesce+Prefetch+Priority", "size": "MIN", "desc": "Coalesce + Prefetch + Priority"},
        {"id": "MC-Q-ALL",  "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=0 CFG_MC_COAL=1 CFG_MC_PREF=1 CFG_MC_PRIO=1", "cat": "QUAD-All4", "size": "MIN", "desc": "4機能全有効 (L2無効)"},
        {"id": "MC-S-HALF", "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=1 L2_WAYS=8 L2_SET_W=7", "cat": "FULL", "size": "HALF", "desc": "全機能有効, L2=32KB 8-way"},
        {"id": "MC-S-QTR",  "mod": "atg_mc", "extra": "HAS_PROT=1 HAS_L2=1 L2_WAYS=4 L2_SET_W=6", "cat": "FULL", "size": "QUARTER", "desc": "全機能有効, L2=16KB 4-way"},
    ],
    "cp": [
        {"id": "CP-F-MAX",  "mod": "atg_cp", "extra": "HAS_CPU=1 HAS_DISP=1 DISP_PLANES=2", "cat": "FULL", "size": "MAX", "desc": "全機能有効, RV32=1, AutoMMU=1"},
        {"id": "CP-B-MIN",  "mod": "atg_cp", "extra": "HAS_CPU=0 HAS_DISP=0 DISP_PLANES=1", "cat": "BARE", "size": "MIN", "desc": "HWステートマシンのみ"},
        {"id": "CP-I-MMU",  "mod": "atg_cp", "extra": "CFG_CP_AUTONOMOUS_MMU=1 HAS_CPU=0 HAS_DISP=0", "cat": "ISO-AutoMMU", "size": "MIN", "desc": "AutoMMU 単独有効"},
        {"id": "CP-I-RV32", "mod": "atg_cp", "extra": "CFG_CP_USE_RV32_CORE=1 HAS_CPU=1 HAS_DISP=0",  "cat": "ISO-RV32", "size": "MIN", "desc": "RV32 単独有効"},
        {"id": "CP-I-IND",  "mod": "atg_cp", "extra": "HAS_CPU=0 HAS_DISP=0 CFG_CP_INDIRECT=1",      "cat": "ISO-Indirect", "size": "MIN", "desc": "Indirect 単独有効"},
        {"id": "CP-P-MR",   "mod": "atg_cp", "extra": "CFG_CP_AUTONOMOUS_MMU=1 CFG_CP_USE_RV32_CORE=1 HAS_CPU=1 HAS_DISP=0", "cat": "PAIR-MMU+RV32", "size": "MIN", "desc": "AutoMMU + RV32 有効"},
        {"id": "CP-P-RI",   "mod": "atg_cp", "extra": "CFG_CP_USE_RV32_CORE=1 HAS_CPU=1 CFG_CP_INDIRECT=1 HAS_DISP=0",       "cat": "PAIR-RV32+Ind", "size": "MIN", "desc": "RV32 + Indirect 有効"},
        {"id": "CP-P-IS",   "mod": "atg_cp", "extra": "HAS_CPU=0 HAS_DISP=0 CFG_CP_INDIRECT=1 CFG_CP_STATE_BC=1",            "cat": "PAIR-Ind+State", "size": "MIN", "desc": "Indirect + StateBC 有効"},
        {"id": "CP-T-MRI",  "mod": "atg_cp", "extra": "CFG_CP_AUTONOMOUS_MMU=1 CFG_CP_USE_RV32_CORE=1 HAS_CPU=1 CFG_CP_INDIRECT=1", "cat": "TRIO-MMU+RV+Ind", "size": "MIN", "desc": "AutoMMU + RV32 + Indirect"},
        {"id": "CP-T-RIS",  "mod": "atg_cp", "extra": "CFG_CP_USE_RV32_CORE=1 HAS_CPU=1 CFG_CP_INDIRECT=1 CFG_CP_STATE_BC=1",       "cat": "TRIO-RV+Ind+St", "size": "MIN", "desc": "RV32 + Indirect + StateBC"},
        {"id": "CP-Q-ALL",  "mod": "atg_cp", "extra": "CFG_CP_AUTONOMOUS_MMU=1 CFG_CP_USE_RV32_CORE=1 HAS_CPU=1 HAS_DISP=1",        "cat": "QUAD-All4", "size": "MIN", "desc": "4機能全有効 (最小メモリ)"},
        {"id": "CP-S-HALF", "mod": "atg_cp", "extra": "HAS_CPU=1 HAS_DISP=1 DISP_PLANES=2", "cat": "FULL", "size": "HALF", "desc": "バランス型メモリフットプリント"},
        {"id": "CP-S-QTR",  "mod": "atg_cp", "extra": "HAS_CPU=1 HAS_DISP=1 DISP_PLANES=1", "cat": "FULL", "size": "QUARTER", "desc": "軽量 RV32 構成"},
    ],
    "mmu": [
        {"id": "MMU-F-MAX",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=5 MAX_SESSIONS=16", "cat": "FULL", "size": "MAX", "desc": "5 clients, 16 sessions"},
        {"id": "MMU-B-MIN",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=1 MAX_SESSIONS=2",  "cat": "BARE", "size": "MIN", "desc": "1 client, 2 sessions"},
        {"id": "MMU-I-L1",   "mod": "atg_mmu", "extra": "NUM_CLIENTS=1 MAX_SESSIONS=2 CFG_MMU_L1_ONLY=1", "cat": "ISO-L1TLB", "size": "MIN", "desc": "L1 TLB 単独有効"},
        {"id": "MMU-I-L2",   "mod": "atg_mmu", "extra": "NUM_CLIENTS=2 MAX_SESSIONS=4 CFG_MMU_L2_ONLY=1", "cat": "ISO-L2TLB", "size": "MIN", "desc": "L2 TLB 単独有効"},
        {"id": "MMU-I-PTW",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=2 MAX_SESSIONS=4 CFG_MMU_PTW_ONLY=1", "cat": "ISO-PTWalker", "size": "MIN", "desc": "Page Table Walker 単独"},
        {"id": "MMU-I-TRP",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=2 MAX_SESSIONS=4 CFG_MMU_TRP_ONLY=1", "cat": "ISO-Trap", "size": "MIN", "desc": "Trap 単独有効"},
        {"id": "MMU-P-12",   "mod": "atg_mmu", "extra": "NUM_CLIENTS=2 MAX_SESSIONS=4 CFG_MMU_L1_L2=1",   "cat": "PAIR-L1+L2", "size": "MIN", "desc": "L1 + L2 有効"},
        {"id": "MMU-P-2W",   "mod": "atg_mmu", "extra": "NUM_CLIENTS=2 MAX_SESSIONS=4 CFG_MMU_L2_PTW=1",  "cat": "PAIR-L2+Walker", "size": "MIN", "desc": "L2 + Walker 有効"},
        {"id": "MMU-P-WT",   "mod": "atg_mmu", "extra": "NUM_CLIENTS=2 MAX_SESSIONS=4 CFG_MMU_PTW_TRP=1", "cat": "PAIR-Walker+Trap", "size": "MIN", "desc": "Walker + Trap 有効"},
        {"id": "MMU-T-12W",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=3 MAX_SESSIONS=8 CFG_MMU_12W=1",     "cat": "TRIO-L1+L2+Walker", "size": "MIN", "desc": "L1 + L2 + Walker"},
        {"id": "MMU-T-2WT",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=3 MAX_SESSIONS=8 CFG_MMU_2WT=1",     "cat": "TRIO-L2+Walker+Trap", "size": "MIN", "desc": "L2 + Walker + Trap"},
        {"id": "MMU-Q-ALL",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=5 MAX_SESSIONS=16", "cat": "QUAD-All4", "size": "MIN", "desc": "4機能全有効 (最小メモリ)"},
        {"id": "MMU-S-HALF", "mod": "atg_mmu", "extra": "NUM_CLIENTS=4 MAX_SESSIONS=8",  "cat": "FULL", "size": "HALF", "desc": "4 clients, 8 sessions"},
        {"id": "MMU-S-QTR",  "mod": "atg_mmu", "extra": "NUM_CLIENTS=2 MAX_SESSIONS=4",  "cat": "FULL", "size": "QUARTER", "desc": "2 clients, 4 sessions"},
    ],
    "tu": [
        {"id": "TU-F-MAX",  "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=16 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_BC=1 CFG_ENABLE_3D_CUBE=1 CFG_ENABLE_TRILINEAR=1", "cat": "FULL", "size": "MAX", "desc": "全機能有効, L1=16KB, 4 banks"},
        {"id": "TU-B-MIN",  "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=0 CFG_ENABLE_BC=0 CFG_ENABLE_3D_CUBE=0 CFG_ENABLE_TRILINEAR=0", "cat": "BARE", "size": "MIN", "desc": "2D ポイントサンプリングのみ, L1=2KB"},
        {"id": "TU-I-BC",   "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=0 CFG_ENABLE_BC=1 CFG_ENABLE_3D_CUBE=0", "cat": "ISO-BC", "size": "MIN", "desc": "BC 展開単独有効"},
        {"id": "TU-I-ANIS", "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=0 CFG_ENABLE_ANISO=1 CFG_ENABLE_BC=0", "cat": "ISO-Aniso", "size": "MIN", "desc": "異方性フィルタ単独有効"},
        {"id": "TU-I-CUBE", "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=0 CFG_ENABLE_3D_CUBE=1 CFG_ENABLE_BC=0", "cat": "ISO-Cube", "size": "MIN", "desc": "キューブマップ単独有効"},
        {"id": "TU-I-FPF",  "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_BC=0 CFG_ENABLE_3D_CUBE=0", "cat": "ISO-FPFilt", "size": "MIN", "desc": "FP フィルタ単独有効"},
        {"id": "TU-P-BA",   "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=0 CFG_ENABLE_BC=1 CFG_ENABLE_ANISO=1", "cat": "PAIR-BC+Aniso", "size": "MIN", "desc": "BC 展開 + 異方性フィルタ有効"},
        {"id": "TU-P-CF",   "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_3D_CUBE=1", "cat": "PAIR-Cube+FPFilt", "size": "MIN", "desc": "Cube + FP フィルタ有効"},
        {"id": "TU-P-BM",   "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=0 CFG_ENABLE_BC=1 CFG_ENABLE_MSHR=1", "cat": "PAIR-BC+MSHR", "size": "MIN", "desc": "BC 展開 + MSHR 有効"},
        {"id": "TU-T-BAF",  "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_BC=1 CFG_ENABLE_ANISO=1", "cat": "TRIO-BC+Anis+FP", "size": "MIN", "desc": "BC + Aniso + FP フィルタ"},
        {"id": "TU-T-CAF",  "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_3D_CUBE=1 CFG_ENABLE_ANISO=1", "cat": "TRIO-Cube+Anis+FP", "size": "MIN", "desc": "Cube + Aniso + FP フィルタ"},
        {"id": "TU-Q-BACF", "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=2 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_BC=1 CFG_ENABLE_ANISO=1 CFG_ENABLE_3D_CUBE=1", "cat": "QUAD-All4", "size": "MIN", "desc": "BC + Aniso + Cube + FP フィルタ"},
        {"id": "TU-S-HALF", "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=8 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_BC=1 CFG_ENABLE_3D_CUBE=1", "cat": "FULL", "size": "HALF", "desc": "全機能有効, L1=8KB, 4 banks"},
        {"id": "TU-S-QTR",  "mod": "atg_tu", "extra": "CFG_TU_L1_CACHE_KB=4 CFG_TU_ENABLE_FFILT=1 CFG_ENABLE_BC=1 CFG_ENABLE_3D_CUBE=1", "cat": "FULL", "size": "QUARTER", "desc": "全機能有効, L1=4KB, 4 banks"},
    ]
}

def run_single(tc):
    test_id = tc["id"]
    mod = tc["mod"]
    extra = tc["extra"]
    print(f"\n=========================================================")
    print(f"  RUNNING TEST: {test_id} (Module: {mod})")
    print(f"  EXTRA: {extra}")
    print(f"=========================================================")
    cmd = ["tools/synth-module.sh", mod, "5.000"]
    if extra:
        cmd.append(extra)
    res = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)
    if res.returncode != 0:
        print(f"ERROR: Return code {res.returncode}")
        print(res.stderr)
        return None

    clean_def = re.sub(r"[^a-zA-Z0-9_]", "_", extra) if extra else ""
    out_name = f"{mod}_{clean_def}" if clean_def else mod
    out_dir = ROOT / "build" / "synth_module" / out_name

    metrics = parse_synth_result.parse_report(out_dir)
    metrics["id"] = test_id
    metrics["mod"] = mod
    metrics["cat"] = tc["cat"]
    metrics["size"] = tc["size"]
    metrics["desc"] = tc["desc"]
    print(f"--> [RESULT] {test_id}: WNS={metrics['wns']} ns, Levels={metrics['levels']}, LUT={metrics['lut']}, FF={metrics['ff']}, BRAM={metrics['bram']}, DSP={metrics['dsp']}, Pass={metrics['pass']}")
    return metrics

def main():
    target_mod = sys.argv[1] if len(sys.argv) > 1 else None
    all_results = {}
    db_file = ROOT / "build" / "combination_results.json"
    if db_file.exists():
        try:
            with open(db_file, "r") as f:
                all_results = json.load(f)
        except Exception:
            all_results = {}

    mods = [target_mod] if target_mod in MODULE_TESTS else list(MODULE_TESTS.keys())

    for m in mods:
        print(f"\n#########################################################")
        print(f"  Processing Module: {m}")
        print(f"#########################################################")
        for tc in MODULE_TESTS[m]:
            test_id = tc["id"]
            if test_id in all_results and all_results[test_id].get("pass", False):
                print(f"Skipping already passed test: {test_id} (WNS: {all_results[test_id]['wns']} ns)")
                continue
            r = run_single(tc)
            if r:
                all_results[test_id] = r
                with open(db_file, "w") as f:
                    json.dump(all_results, f, indent=2)

    # Format Markdown Table
    print("\n\n=== GENERATING MARKDOWN TABLES ===")
    for m in mods:
        print(f"\n### ({m.upper()}) `{m}` 組み合わせ OOC 測定結果")
        print("| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |")
        print("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |")
        for tc in MODULE_TESTS[m]:
            tid = tc["id"]
            if tid in all_results:
                res = all_results[tid]
                wns_val = res['wns']
                wns_str = f"**+{wns_val:.3f}**" if (isinstance(wns_val, float) and wns_val >= 0) else f"**{wns_val}**"
                judge = "**PASS**" if res['pass'] else "**FAIL**"
                lut_str = f"{res['lut']:,}"
                ff_str = f"{res['ff']:,}"
                print(f"| `{tid}` | `{tc['mod']}` | `{tc['cat']}` | `{tc['size']}` | {wns_str} | {res['levels']} | {lut_str} | {ff_str} | {res['bram']} | {res['dsp']} | {judge} |")

if __name__ == "__main__":
    main()
