#!/usr/bin/env python3
"""
Generate 2D Die Floorplan SVGs for Amaterrace GPU (N = 1, 2, 4, 8, 16, 32, 64, 128 SUs)
for user architectural review prior to implementing atg_su_fabric_n{1..128}.v.

Outputs:
  docs/svg/floorplan/floorplan_n{1,2,4,8,16,32,64,128}.svg
  docs/svg/floorplan/floorplan_overview_all.svg
"""

import os
import xml.etree.ElementTree as ET

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "svg", "floorplan")

HEADER_DEFS = """    <defs>
        <filter id="shadow" x="-5%" y="-5%" width="110%" height="110%">
            <feDropShadow dx="0" dy="2" stdDeviation="2.5" flood-color="#0f172a" flood-opacity="0.08"/>
        </filter>
        <marker id="arr-sky" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#0284c7"/>
        </marker>
        <marker id="arr-vio" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#7c3aed"/>
        </marker>
        <marker id="arr-em" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#059669"/>
        </marker>
        <marker id="arr-slate" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#475569"/>
        </marker>
    </defs>
    <style><![CDATA[
        text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; }
        .t-title { font-size: 18px; font-weight: 700; fill: #0f172a; }
        .t-sub { font-size: 11.5px; font-weight: 500; fill: #475569; }
        .t-sec { font-size: 11px; font-weight: 700; letter-spacing: 0.6px; fill: #334155; }
        .t-su { font-size: 10.5px; font-weight: 700; fill: #0c4a6e; }
        .t-susub { font-size: 8px; font-weight: 600; fill: #0369a1; }
        .t-rt { font-size: 9px; font-weight: 700; fill: #4c1d95; }
        .t-rep { font-size: 8px; font-weight: 700; fill: #92400e; }
        .t-box { font-size: 10px; font-weight: 700; fill: #1e293b; }
        .t-boxsub { font-size: 8.5px; font-weight: 500; fill: #475569; }
    ]]></style>"""


def render_spine(x, y, w, n_trunks, n_su):
    cx = x + w / 2
    s = []
    s.append(f'    <!-- SPINE & MC ROOT -->')
    s.append(f'    <rect x="{x}" y="{y}" width="{w}" height="165" rx="8" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1.5" filter="url(#shadow)"/>')
    s.append(f'    <text class="t-sec" x="{x+14}" y="{y+18}">SPINE &amp; ROOT NOC (SOUTH DIE EDGE) — {n_trunks} SU TRUNK(S) TO ATG_MMU + FIXED-FUNC SUBTREE + DC ROOT</text>')

    # MMU Bar
    n_t = 8 if isinstance(n_trunks, str) else n_trunks
    mmu_w = min(w - 304, max(500, n_t * 85))
    mmu_x = cx - mmu_w / 2
    s.append(f'    <rect x="{mmu_x}" y="{y+26}" width="{mmu_w}" height="32" rx="6" fill="#ecfdf5" stroke="#10b981" stroke-width="1.5"/>')
    s.append(f'    <text x="{cx}" y="{y+40}" text-anchor="middle" font-size="9.2" font-weight="700" fill="#065f46">Spine MMU Boundary: {n_trunks}x SU Trunks + VF/TU/ROP/BLT -&gt; atg_mmu (L1+L2 TLB+Walker)</text>')
    s.append(f'    <text x="{cx}" y="{y+52}" text-anchor="middle" font-size="8.3" fill="#047857">UNIT_ADDR_W (VA 30..40b inside SU Fabric)  ==&gt;  MC_ADDR_W (PA 40..48b after MMU)</text>')

    # Shared PT (Option I) & Graphics Spine on Left
    s.append(f'    <rect x="{x+14}" y="{y+26}" width="136" height="58" rx="6" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.2"/>')
    s.append(f'    <text x="{x+82}" y="{y+41}" text-anchor="middle" font-size="9.5" font-weight="700" fill="#1d4ed8">Fixed-Func Subtree</text>')
    s.append(f'    <text x="{x+82}" y="{y+53}" text-anchor="middle" font-size="7.8" fill="#1e40af">VF, TU, ROP, BLT -&gt; Root</text>')
    s.append(f'    <text x="{x+82}" y="{y+65}" text-anchor="middle" font-size="7.8" fill="#1e40af">RX (Spine) -&gt; PT / ROP</text>')
    s.append(f'    <text x="{x+82}" y="{y+77}" text-anchor="middle" font-size="7.5" fill="#2563eb">(0 in compute-only)</text>')

    s.append(f'    <rect x="{x+14}" y="{y+92}" width="136" height="62" rx="6" fill="#f5f3ff" stroke="#8b5cf6" stroke-width="1.2"/>')
    s.append(f'    <text x="{x+82}" y="{y+107}" text-anchor="middle" font-size="9.2" font-weight="700" fill="#5b21b6">Shared Spine PT (Opt I)</text>')
    s.append(f'    <text x="{x+82}" y="{y+119}" text-anchor="middle" font-size="7.6" fill="#6d28d9">atg_su_pt + warp_dist</text>')
    s.append(f'    <text x="{x+82}" y="{y+131}" text-anchor="middle" font-size="7.6" fill="#6d28d9">pt_exp_rt + tx_rt + ex_rt</text>')
    s.append(f'    <text x="{x+82}" y="{y+143}" text-anchor="middle" font-size="7.5" fill="#7c3aed">atom_rt -&gt; mc_atom ({n_su} SUs)</text>')

    # Reserved SA Node on Right
    rx_box = x + w - 150
    s.append(f'    <rect x="{rx_box}" y="{y+26}" width="136" height="58" rx="6" fill="#fefce8" stroke="#ca8a04" stroke-width="1.3" stroke-dasharray="4,2"/>')
    s.append(f'    <text x="{rx_box+68}" y="{y+43}" text-anchor="middle" font-size="9.5" font-weight="700" fill="#854d0e">Reserved SA Slot</text>')
    s.append(f'    <text x="{rx_box+68}" y="{y+56}" text-anchor="middle" font-size="8" fill="#a16207">Future Systolic GEMM</text>')
    s.append(f'    <text x="{rx_box+68}" y="{y+68}" text-anchor="middle" font-size="8" fill="#a16207">Independent NoC Node</text>')
    s.append(f'    <text x="{rx_box+68}" y="{y+79}" text-anchor="middle" font-size="7.5" fill="#b45309">(Stub when HAS_SA=0)</text>')

    # CP + DC near Root on Right
    s.append(f'    <rect x="{rx_box}" y="{y+92}" width="136" height="62" rx="6" fill="#fff1f2" stroke="#e11d48" stroke-width="1.3"/>')
    s.append(f'    <text x="{rx_box+68}" y="{y+108}" text-anchor="middle" font-size="9.5" font-weight="700" fill="#9f1239">Root Priority Nodes</text>')
    s.append(f'    <text x="{rx_box+68}" y="{y+121}" text-anchor="middle" font-size="8" fill="#be123c">CP + RV32 FW (PRIO=1)</text>')
    s.append(f'    <text x="{rx_box+68}" y="{y+133}" text-anchor="middle" font-size="8" fill="#be123c">DC Scanout (s_* direct)</text>')
    s.append(f'    <text x="{rx_box+68}" y="{y+145}" text-anchor="middle" font-size="7.5" fill="#9f1239">Walker 0xFE -&gt; L2/AXI</text>')

    # Root atg_rt + atg_mc
    s.append(f'    <rect x="{cx-150}" y="{y+66}" width="300" height="32" rx="6" fill="#ede9fe" stroke="#7c3aed" stroke-width="1.5"/>')
    s.append(f'    <text x="{cx}" y="{y+85}" text-anchor="middle" font-size="10" font-weight="700" fill="#4c1d95">Root Fat-Tree Arbiter (CP + Fixed + SU Trunks + SA)</text>')

    s.append(f'    <rect x="{cx-180}" y="{y+108}" width="360" height="46" rx="6" fill="#1e293b" stroke="#0f172a" stroke-width="1.5"/>')
    s.append(f'    <text x="{cx}" y="{y+127}" text-anchor="middle" font-size="10.5" font-weight="700" fill="#f8fafc">atg_mc (L2 Cache + Session PROT + Aperture)</text>')
    s.append(f'    <text x="{cx}" y="{y+143}" text-anchor="middle" font-size="8.5" fill="#94a3b8">External AXI4 Master (m_awaddr / m_araddr [PA_BITS]) — 0/1 ID Local/Host</text>')

    # Connecting arrows inside Spine
    s.append(f'    <line x1="{cx}" y1="{y+58}" x2="{cx}" y2="{y+66}" stroke="#059669" stroke-width="1.8" marker-end="url(#arr-em)"/>')
    s.append(f'    <line x1="{cx}" y1="{y+98}" x2="{cx}" y2="{y+108}" stroke="#7c3aed" stroke-width="2" marker-end="url(#arr-vio)"/>')
    s.append(f'    <line x1="{x+150}" y1="{y+55}" x2="{mmu_x}" y2="{y+44}" stroke="#0284c7" stroke-width="1.4" marker-end="url(#arr-sky)"/>')
    s.append(f'    <line x1="{rx_box}" y1="{y+55}" x2="{mmu_x+mmu_w}" y2="{y+44}" stroke="#ca8a04" stroke-width="1.3" stroke-dasharray="3,2"/>')
    s.append(f'    <line x1="{rx_box}" y1="{y+122}" x2="{cx+150}" y2="{y+84}" stroke="#e11d48" stroke-width="1.5" marker-end="url(#arr-vio)"/>')
    return "\n".join(s)


def su_tile(x, y, w, h, idx):
    return (
        f'    <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="5" fill="#e0f2fe" stroke="#0284c7" stroke-width="1.3" filter="url(#shadow)"/>\n'
        f'    <text class="t-su" x="{x+w/2}" y="{y+h*0.44}" text-anchor="middle">SU {idx}</text>\n'
        f'    <text class="t-susub" x="{x+w/2}" y="{y+h*0.76}" text-anchor="middle">rt2(D$+I$)</text>'
    )


def rt_badge(cx, cy, label, bg="#ede9fe", bd="#7c3aed", w=54, h=20):
    return (
        f'    <rect x="{cx-w/2}" y="{cy-h/2}" width="{w}" height="{h}" rx="5" fill="{bg}" stroke="{bd}" stroke-width="1.4"/>\n'
        f'    <text class="t-rt" x="{cx}" y="{cy+3.5}" text-anchor="middle">{label}</text>'
    )


def rep_badge(cx, cy, label, w=48, h=16):
    return (
        f'    <rect x="{cx-w/2}" y="{cy-h/2}" width="{w}" height="{h}" rx="4" fill="#fef3c7" stroke="#d97706" stroke-width="1.2"/>\n'
        f'    <text class="t-rep" x="{cx}" y="{cy+3}" text-anchor="middle">{label}</text>'
    )


def gen_n1():
    W, H = 880, 440
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 1 SU (1x1 Tile, atg_su_fabric_n1)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">1x1 Grid | 1 Spine Trunk | ASIC: Unified Fat-Tree (0 rep hops) | FPGA minimal: Crossbar mode (atg_mc_tree)</text>')

    lines.append(f'    <rect x="24" y="64" width="832" height="175" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    lines.append(su_tile(160, 95, 160, 74, 0))
    lines.append(f'    <line x1="240" y1="169" x2="240" y2="212" stroke="#059669" stroke-width="2"/>')
    lines.append(f'    <line x1="240" y1="212" x2="440" y2="212" stroke="#059669" stroke-width="2"/>')
    lines.append(f'    <line x1="440" y1="212" x2="440" y2="276" stroke="#059669" stroke-width="2" marker-end="url(#arr-em)"/>')
    lines.append(f'    <text x="340" y="205" text-anchor="middle" font-size="9" font-weight="600" fill="#047857">Direct Trunk 0 (0 rep hops)</text>')

    # FPGA inset box
    lines.append(f'    <rect x="490" y="88" width="320" height="90" rx="6" fill="#fff7ed" stroke="#ea580c" stroke-width="1.2" stroke-dasharray="4,2"/>')
    lines.append(f'    <text x="650" y="108" text-anchor="middle" font-size="10" font-weight="700" fill="#9a3412">Target Platform Switch (menuconfig #1)</text>')
    lines.append(f'    <text x="650" y="126" text-anchor="middle" font-size="9" fill="#c2410c">• ASIC (compute/gfx-*-su1): USE_NOC_FABRIC = 1</text>')
    lines.append(f'    <text x="650" y="141" text-anchor="middle" font-size="9" fill="#c2410c">  SU0 local rt2 -&gt; Unified Fat-Tree Root</text>')
    lines.append(f'    <text x="650" y="158" text-anchor="middle" font-size="9" fill="#c2410c">• FPGA (*-fpga-test-minimal): USE_NOC_FABRIC = 0</text>')
    lines.append(f'    <text x="650" y="172" text-anchor="middle" font-size="9" fill="#c2410c">  Flat 2-cyc Crossbar (atg_mc_tree)</text>')

    lines.append(render_spine(24, 252, 832, 1, 1))
    lines.append('</svg>')
    return "\n".join(lines)


def gen_n2():
    W, H = 880, 450
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 2 SUs (2x1 West/East, atg_su_fabric_n2)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">2x1 Symmetric | 1x atg_rt2 + rep_h(1) optional | 1 Trunk (ASIC Fat-Tree) | FPGA supports Crossbar (NSU=1,2)</text>')

    lines.append(f'    <rect x="24" y="64" width="832" height="185" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    lines.append(su_tile(180, 88, 140, 64, 0))
    lines.append(su_tile(560, 88, 140, 64, 1))
    lines.append(rep_badge(365, 120, "rep_h(1)"))
    lines.append(rep_badge(515, 120, "rep_h(1)"))
    lines.append(f'    <line x1="320" y1="120" x2="341" y2="120" stroke="#0284c7" stroke-width="1.8"/>')
    lines.append(f'    <line x1="389" y1="120" x2="413" y2="120" stroke="#0284c7" stroke-width="1.8"/>')
    lines.append(f'    <line x1="560" y1="120" x2="539" y2="120" stroke="#0284c7" stroke-width="1.8"/>')
    lines.append(f'    <line x1="491" y1="120" x2="467" y2="120" stroke="#0284c7" stroke-width="1.8"/>')
    lines.append(rt_badge(440, 120, "rt2_top"))
    lines.append(f'    <line x1="440" y1="130" x2="440" y2="286" stroke="#059669" stroke-width="2" marker-end="url(#arr-em)"/>')
    lines.append(f'    <text x="490" y="212" font-size="9" font-weight="600" fill="#047857">Trunk 0 (RW: rt2=1b + local rt2=1b)</text>')

    lines.append(render_spine(24, 262, 832, 1, 2))
    lines.append('</svg>')
    return "\n".join(lines)


def gen_n4():
    W, H = 880, 500
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 4 SUs (2x2 Quad, atg_su_fabric_n4)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">1 Quad (4 SUs) -&gt; Single 1-hop atg_rt4 | North row rep_v(1) | Spine rep_s(1) | 1 Unified Trunk to MMU</text>')

    lines.append(f'    <rect x="24" y="64" width="832" height="235" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    # 2x2 Quad box
    lines.append(f'    <rect x="255" y="76" width="370" height="210" rx="8" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1.2" stroke-dasharray="4,2"/>')
    lines.append(f'    <text x="266" y="91" font-size="9" font-weight="700" fill="#6b21a8">QUAD 0 (2x2)</text>')

    lines.append(su_tile(275, 98, 120, 52, 0))
    lines.append(su_tile(485, 98, 120, 52, 1))
    lines.append(su_tile(275, 210, 120, 52, 2))
    lines.append(su_tile(485, 210, 120, 52, 3))

    lines.append(rep_badge(335, 165, "rep_v(1)"))
    lines.append(rep_badge(545, 165, "rep_v(1)"))

    lines.append(f'    <line x1="335" y1="150" x2="335" y2="180" stroke="#7c3aed" stroke-width="1.5"/>')
    lines.append(f'    <line x1="335" y1="180" x2="412" y2="180" stroke="#7c3aed" stroke-width="1.5"/>')
    lines.append(f'    <line x1="545" y1="150" x2="545" y2="180" stroke="#7c3aed" stroke-width="1.5"/>')
    lines.append(f'    <line x1="545" y1="180" x2="468" y2="180" stroke="#7c3aed" stroke-width="1.5"/>')
    lines.append(f'    <line x1="395" y1="236" x2="440" y2="190" stroke="#7c3aed" stroke-width="1.5"/>')
    lines.append(f'    <line x1="485" y1="236" x2="440" y2="190" stroke="#7c3aed" stroke-width="1.5"/>')

    lines.append(rt_badge(440, 180, "rt4_q0"))
    lines.append(rep_badge(440, 272, "rep_s(1)"))
    lines.append(f'    <line x1="440" y1="190" x2="440" y2="264" stroke="#059669" stroke-width="2"/>')
    lines.append(f'    <line x1="440" y1="280" x2="440" y2="336" stroke="#059669" stroke-width="2" marker-end="url(#arr-em)"/>')

    lines.append(render_spine(24, 312, 832, 1, 4))
    lines.append('</svg>')
    return "\n".join(lines)


def gen_n8():
    W, H = 880, 510
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 8 SUs (4x2: West + East Quads, atg_su_fabric_n8)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">2 Quads (West 2x2 + East 2x2) -&gt; 2x atg_rt4 + horizontal rep_h(1) per Quad -&gt; 2 Parallel Trunks to MMU</text>')

    lines.append(f'    <rect x="24" y="64" width="832" height="245" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    for qi, (qx, base_idx, side) in enumerate([(54, 0, "WEST QUAD 0"), (496, 4, "EAST QUAD 1")]):
        lines.append(f'    <rect x="{qx}" y="76" width="330" height="195" rx="8" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1.2" stroke-dasharray="4,2"/>')
        lines.append(f'    <text x="{qx+10}" y="91" font-size="9" font-weight="700" fill="#6b21a8">{side}</text>')
        lines.append(su_tile(qx+18, 98, 108, 48, base_idx+0))
        lines.append(su_tile(qx+204, 98, 108, 48, base_idx+1))
        lines.append(su_tile(qx+18, 204, 108, 48, base_idx+2))
        lines.append(su_tile(qx+204, 204, 108, 48, base_idx+3))
        rcx, rcy = qx + 165, 174
        lines.append(f'    <line x1="{qx+72}" y1="146" x2="{rcx}" y2="{rcy}" stroke="#7c3aed" stroke-width="1.3"/>')
        lines.append(f'    <line x1="{qx+258}" y1="146" x2="{rcx}" y2="{rcy}" stroke="#7c3aed" stroke-width="1.3"/>')
        lines.append(f'    <line x1="{qx+72}" y1="204" x2="{rcx}" y2="{rcy}" stroke="#7c3aed" stroke-width="1.3"/>')
        lines.append(f'    <line x1="{qx+258}" y1="204" x2="{rcx}" y2="{rcy}" stroke="#7c3aed" stroke-width="1.3"/>')
        lines.append(rt_badge(rcx, rcy, f"rt4_q{qi}"))
        tx = 360 if qi == 0 else 520
        rx_rep = (rcx + tx) / 2
        lines.append(f'    <line x1="{rcx}" y1="{rcy+10}" x2="{rcx}" y2="282" stroke="#059669" stroke-width="1.8"/>')
        lines.append(f'    <line x1="{rcx}" y1="282" x2="{tx}" y2="282" stroke="#059669" stroke-width="1.8"/>')
        lines.append(rep_badge(rx_rep, 282, "rep_h(1)"))
        lines.append(f'    <line x1="{tx}" y1="282" x2="{tx}" y2="346" stroke="#059669" stroke-width="2" marker-end="url(#arr-em)"/>')

    lines.append(f'    <text x="440" y="295" text-anchor="middle" font-size="9" font-weight="700" fill="#047857">Trunk 0 (W) | Trunk 1 (E)</text>')
    lines.append(render_spine(24, 322, 832, 2, 8))
    lines.append('</svg>')
    return "\n".join(lines)


def gen_n16():
    W, H = 880, 620
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 16 SUs (4x4, 4 Quads, atg_su_fabric_n16)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">4 Quads (NW, NE, SW, SE) | NW/NE vertical rep_v(2), SW/SE vertical rep_v(1) | 4 Parallel Trunks into Spine MMU</text>')

    lines.append(f'    <rect x="24" y="64" width="832" height="355" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    quads = [
        (48, 78, "Q0 (NW)", 0, "rep_v(2)", 340),
        (468, 78, "Q1 (NE)", 4, "rep_v(2)", 540),
        (48, 232, "Q2 (SW)", 8, "rep_v(1)", 390),
        (468, 232, "Q3 (SE)", 12, "rep_v(1)", 490),
    ]
    for qi, (qx, qy, name, base, replab, tx) in enumerate(quads):
        lines.append(f'    <rect x="{qx}" y="{qy}" width="360" height="140" rx="8" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1.2" stroke-dasharray="4,2"/>')
        lines.append(f'    <text x="{qx+10}" y="{qy+14}" font-size="9" font-weight="700" fill="#6b21a8">{name}</text>')
        lines.append(su_tile(qx+14, qy+20, 96, 40, base+0))
        lines.append(su_tile(qx+250, qy+20, 96, 40, base+1))
        lines.append(su_tile(qx+14, qy+86, 96, 40, base+2))
        lines.append(su_tile(qx+250, qy+86, 96, 40, base+3))
        rcx, rcy = qx + 180, qy + 72
        for sx, sy in [(qx+110, qy+40), (qx+250, qy+40), (qx+110, qy+106), (qx+250, qy+106)]:
            lines.append(f'    <line x1="{sx}" y1="{sy}" x2="{rcx}" y2="{rcy}" stroke="#7c3aed" stroke-width="1.2"/>')
        lines.append(rt_badge(rcx, rcy, f"rt4_q{qi}"))
        # Trunk routing to Spine
        if qi < 2:
            lines.append(f'    <line x1="{rcx}" y1="{rcy+10}" x2="{rcx}" y2="390" stroke="#059669" stroke-width="1.6"/>')
            lines.append(rep_badge(rcx, 224, replab))
            lines.append(f'    <line x1="{rcx}" y1="390" x2="{tx}" y2="390" stroke="#059669" stroke-width="1.6"/>')
            lines.append(f'    <line x1="{tx}" y1="390" x2="{tx}" y2="455" stroke="#059669" stroke-width="1.8" marker-end="url(#arr-em)"/>')
        else:
            lines.append(f'    <line x1="{rcx}" y1="{rcy+10}" x2="{rcx}" y2="404" stroke="#059669" stroke-width="1.6"/>')
            lines.append(rep_badge(rcx, 380, replab))
            lines.append(f'    <line x1="{rcx}" y1="404" x2="{tx}" y2="404" stroke="#059669" stroke-width="1.6"/>')
            lines.append(f'    <line x1="{tx}" y1="404" x2="{tx}" y2="455" stroke="#059669" stroke-width="1.8" marker-end="url(#arr-em)"/>')

    lines.append(render_spine(24, 432, 832, 4, 16))
    lines.append('</svg>')
    return "\n".join(lines)


def quad_block(x, y, w, h, q_label, su_range, rt_label):
    return (
        f'    <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="#e0f2fe" stroke="#0284c7" stroke-width="1.3" filter="url(#shadow)"/>\n'
        f'    <text x="{x+w/2}" y="{y+16}" text-anchor="middle" font-size="9.5" font-weight="700" fill="#0c4a6e">{q_label}</text>\n'
        f'    <text x="{x+w/2}" y="{y+29}" text-anchor="middle" font-size="8.5" font-weight="600" fill="#0369a1">{su_range}</text>\n'
        f'    <rect x="{x+w/2-26}" y="{y+h-22}" width="52" height="16" rx="4" fill="#ede9fe" stroke="#7c3aed" stroke-width="1.1"/>\n'
        f'    <text x="{x+w/2}" y="{y+h-11}" text-anchor="middle" font-size="8" font-weight="700" fill="#4c1d95">{rt_label}</text>'
    )


def gen_n32():
    W, H = 980, 560
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 32 SUs (8x4: 8 Quads, atg_su_fabric_n32)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">West 4x4 + East 4x4 (Each cell = 2x2 Quad w/ atg_rt4) | Outer cols rep_h(2), Inner rep_h(1) -&gt; 4 Trunks to Spine MMU</text>')

    lines.append(f'    <rect x="24" y="64" width="932" height="295" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    cols_x = [48, 214, 620, 786]
    rows_y = [84, 186]
    names = [
        ("W_NW (Q0)", "SU 0..3", "W_NE (Q1)", "SU 4..7", "E_NW (Q4)", "SU 16..19", "E_NE (Q5)", "SU 20..23"),
        ("W_SW (Q2)", "SU 8..11", "W_SE (Q3)", "SU 12..15", "E_SW (Q6)", "SU 24..27", "E_SE (Q7)", "SU 28..31"),
    ]
    for ri, ry in enumerate(rows_y):
        for ci, cx_box in enumerate(cols_x):
            ql = names[ri][ci*2]
            sr = names[ri][ci*2+1]
            qidx = ri*2 + (ci if ci < 2 else ci+2)
            lines.append(quad_block(cx_box, ry, 146, 70, ql, sr, f"rt4_q{qidx}"))

    # Pairwise horizontal combiners into 4 Trunks (W_N, W_S, E_N, E_S)
    # Outer cols get rep_h(2), inner get rep_h(1); North row gets rep_v(2), South gets rep_v(1)
    pairs = [
        (48+146, 119, 214, 420, 174, "rep_h(2)", "rep_h(1)", "rep_v(2)", "rt2_wn", 400),
        (620+146, 119, 786, 560, 174, "rep_h(1)", "rep_h(2)", "rep_v(2)", "rt2_en", 580),
        (48+146, 221, 214, 420, 276, "rep_h(2)", "rep_h(1)", "rep_v(1)", "rt2_ws", 445),
        (620+146, 221, 786, 560, 276, "rep_h(1)", "rep_h(2)", "rep_v(1)", "rt2_es", 535),
    ]
    for c_idx, (x0_r, y_m, x1_l, rx, ry, rep_l, rep_r, rep_v, rtlab, tx) in enumerate(pairs):
        cx0 = x0_r - 73
        cx1 = x1_l + 73
        lines.append(f'    <line x1="{cx0}" y1="{y_m+35}" x2="{cx0}" y2="{ry}" stroke="#7c3aed" stroke-width="1.5"/>')
        lines.append(f'    <line x1="{cx0}" y1="{ry}" x2="{rx}" y2="{ry}" stroke="#7c3aed" stroke-width="1.5"/>')
        lines.append(f'    <line x1="{cx1}" y1="{y_m+35}" x2="{cx1}" y2="{ry}" stroke="#7c3aed" stroke-width="1.5"/>')
        lines.append(f'    <line x1="{cx1}" y1="{ry}" x2="{rx}" y2="{ry}" stroke="#7c3aed" stroke-width="1.5"/>')
        lines.append(rep_badge((cx0+rx)/2 if rx > cx1 else (cx0+rx)/2, ry, rep_l))
        lines.append(rep_badge((cx1+rx)/2, ry, rep_r))
        lines.append(rt_badge(rx, ry, rtlab, w=58))
        drop_y = 328 if "n" in rtlab else 340
        lines.append(f'    <line x1="{rx}" y1="{ry+10}" x2="{rx}" y2="{drop_y}" stroke="#059669" stroke-width="1.7"/>')
        lines.append(rep_badge(rx, (ry+drop_y)/2, rep_v))
        lines.append(f'    <line x1="{rx}" y1="{drop_y}" x2="{tx}" y2="{drop_y}" stroke="#059669" stroke-width="1.7"/>')
        lines.append(f'    <line x1="{tx}" y1="{drop_y}" x2="{tx}" y2="395" stroke="#059669" stroke-width="1.8" marker-end="url(#arr-em)"/>')

    lines.append(render_spine(24, 372, 932, 4, 32))
    lines.append('</svg>')
    return "\n".join(lines)


def q16_block(x, y, w, h, label, su_range, qi_start):
    s = []
    s.append(f'    <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="#f0f9ff" stroke="#0ea5e9" stroke-width="1.4" filter="url(#shadow)"/>')
    s.append(f'    <text x="{x+10}" y="{y+16}" font-size="9.5" font-weight="700" fill="#0369a1">{label} ({su_range})</text>')
    bw, bh = (w - 36) / 2, (h - 52) / 2
    for r in range(2):
        for c in range(2):
            bx = x + 10 + c * (bw + 16)
            by = y + 24 + r * (bh + 18)
            q = qi_start + r*2 + c
            s.append(f'    <rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="4" fill="#e0f2fe" stroke="#0284c7" stroke-width="1.1"/>')
            s.append(f'    <text x="{bx+bw/2}" y="{by+bh*0.45}" text-anchor="middle" font-size="8.5" font-weight="700" fill="#0c4a6e">Q{q} (4 SU)</text>')
            s.append(f'    <text x="{bx+bw/2}" y="{by+bh*0.80}" text-anchor="middle" font-size="7.5" fill="#4c1d95">rt4_q{q}</text>')
    rcx, rcy = x + w/2, y + h/2 + 6
    s.append(rt_badge(rcx, rcy, "rt4_q16", w=54, h=18))
    return "\n".join(s)


def gen_n64():
    W, H = 960, 650
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 64 SUs (8x8: 4x 16-SU Quadrants, atg_su_fabric_n64)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">4 Quadrants (NW, NE, SW, SE = 16 Quads) | Outer rep_h(2), North trunks rep_v(3), South rep_v(1) -> 4 Trunks to Spine MMU</text>')

    lines.append(f'    <rect x="24" y="64" width="912" height="385" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    quadrants = [
        ("NW 4x4", "SU 0..15", 48, 80, 0, "rep_v(3)+rep_h(2)", 340, 412),
        ("NE 4x4", "SU 16..31", 522, 80, 4, "rep_v(3)+rep_h(2)", 620, 412),
        ("SW 4x4", "SU 32..47", 48, 250, 8, "rep_v(1)+rep_h(2)", 420, 424),
        ("SE 4x4", "SU 48..63", 522, 250, 12, "rep_v(1)+rep_h(2)", 540, 424),
    ]
    for lbl, sr, qx, qy, qs, rlab, tx, ty in quadrants:
        lines.append(q16_block(qx, qy, 390, 148, lbl, sr, qs))
        cxq = qx + 195
        cyq = qy + 148
        lines.append(f'    <line x1="{cxq}" y1="{cyq}" x2="{cxq}" y2="{ty}" stroke="#059669" stroke-width="1.8"/>')
        lines.append(f'    <line x1="{cxq}" y1="{ty}" x2="{tx}" y2="{ty}" stroke="#059669" stroke-width="1.8"/>')
        lines.append(f'    <line x1="{tx}" y1="{ty}" x2="{tx}" y2="485" stroke="#059669" stroke-width="2" marker-end="url(#arr-em)"/>')
        lines.append(rep_badge((cxq+tx)/2 if qy > 200 else cxq, ty if qy > 200 else 236, rlab, w=96))

    lines.append(render_spine(24, 462, 912, 4, 64))
    lines.append('</svg>')
    return "\n".join(lines)


def gen_n128():
    W, H = 1040, 680
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU 2D Floorplan — N = 128 SUs (16x8: 8x 16-SU Quadrants, atg_su_fabric_n128)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">16x8 Grid (32 Quads) | Manhattan-balanced atg_rep (1..6 hops) | 8 Parallel Trunks -&gt; 8 MMU Bridges -&gt; Root Fat-Tree (2x rt4 + rt2)</text>')

    lines.append(f'    <rect x="24" y="64" width="992" height="415" rx="8" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.2"/>')
    # West 8x8 and East 8x8 enclosing boundaries
    lines.append(f'    <rect x="36" y="72" width="474" height="332" rx="8" fill="#f8fafc" stroke="#94a3b8" stroke-width="1.2" stroke-dasharray="5,3"/>')
    lines.append(f'    <text x="48" y="88" font-size="10" font-weight="700" fill="#334155">WEST 8x8 BANK (SU 0..63)</text>')
    lines.append(f'    <rect x="530" y="72" width="474" height="332" rx="8" fill="#f8fafc" stroke="#94a3b8" stroke-width="1.2" stroke-dasharray="5,3"/>')
    lines.append(f'    <text x="542" y="88" font-size="10" font-weight="700" fill="#334155">EAST 8x8 BANK (SU 64..127)</text>')

    q16s = [
        ("W_NW", "SU 0..15",   44,  96, 0,  "v3+h3 (6)", 315, 424),
        ("W_NE", "SU 16..31",  282, 96, 4,  "v3+h1 (4)", 385, 440),
        ("W_SW", "SU 32..47",  44,  250, 8, "v1+h3 (4)", 450, 456),
        ("W_SE", "SU 48..63",  282, 250, 12,"v1+h1 (2)", 495, 468),
        ("E_NW", "SU 64..79",  538, 96, 16, "v3+h1 (4)", 655, 440),
        ("E_NE", "SU 80..95",  776, 96, 20, "v3+h3 (6)", 725, 424),
        ("E_SW", "SU 96..111", 538, 250, 24,"v1+h1 (2)", 545, 468),
        ("E_SE", "SU 112..127",776, 250, 28,"v1+h3 (4)", 590, 456),
    ]
    for lbl, sr, qx, qy, qs, rlab, tx, ty in q16s:
        lines.append(q16_block(qx, qy, 218, 138, lbl, sr, qs))
        cxq = qx + 109 + (-10 if qy < 200 else 10)
        cyq = qy + 138
        lines.append(f'    <line x1="{cxq}" y1="{cyq}" x2="{cxq}" y2="{ty}" stroke="#059669" stroke-width="1.5"/>')
        lines.append(f'    <line x1="{cxq}" y1="{ty}" x2="{tx}" y2="{ty}" stroke="#059669" stroke-width="1.5"/>')
        lines.append(f'    <line x1="{tx}" y1="{ty}" x2="{tx}" y2="514" stroke="#059669" stroke-width="1.6" marker-end="url(#arr-em)"/>')
        lines.append(rep_badge(cxq, 397 if qy > 200 else 242, rlab, w=58, h=14))

    lines.append(render_spine(24, 492, 992, 8, 128))
    lines.append('</svg>')
    return "\n".join(lines)


def gen_overview():
    W, H = 1040, 560
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">', HEADER_DEFS]
    lines.append(f'    <rect width="{W}" height="{H}" fill="#f8fafc" rx="10"/>')
    lines.append(f'    <text class="t-title" x="24" y="30">Amaterrace GPU Explicit 2D Floorplan Family (N = 1 .. 128 SUs)</text>')
    lines.append(f'    <text class="t-sub" x="24" y="48">Each N has an explicit 2D physical module atg_su_fabric_n&lt;N&gt;.v with fixed repeater stages and shared Spine interface</text>')

    specs = [
        (1,   "1x1",  "SU0 local rt2",             "0 rep",       "1 trunk",  "floorplan_n1.svg"),
        (2,   "2x1",  "rt2_top",                   "0/1 rep_h",   "1 trunk",  "floorplan_n2.svg"),
        (4,   "2x2",  "1x rt4_quad",               "1 rep_v, 1 rep_s", "1 trunk", "floorplan_n4.svg"),
        (8,   "4x2",  "2x rt4_quad",               "1 rep_h",     "2 trunks", "floorplan_n8.svg"),
        (16,  "4x4",  "4x rt4_quad",               "1-2 rep_v",   "4 trunks", "floorplan_n16.svg"),
        (32,  "8x4",  "8x rt4 + 4x rt2",           "1-2h, 1-2v",  "4 trunks", "floorplan_n32.svg"),
        (64,  "8x8",  "16x rt4 + 4x rt4_q16",      "2h, 1-3v",    "4 trunks", "floorplan_n64.svg"),
        (128, "16x8", "32x rt4 + 8x rt4_q16",      "1-3h, 1-3v",  "8 trunks", "floorplan_n128.svg"),
    ]
    cw, ch = 232, 130
    for idx, (n, dim, tree, rep, trk, fname) in enumerate(specs):
        col = idx % 4
        row = idx // 4
        x = 24 + col * (cw + 20)
        y = 70 + row * (ch + 18)
        lines.append(f'    <rect x="{x}" y="{y}" width="{cw}" height="{ch}" rx="8" fill="#ffffff" stroke="#cbd5e1" stroke-width="1.4" filter="url(#shadow)"/>')
        lines.append(f'    <rect x="{x}" y="{y}" width="{cw}" height="28" rx="8" fill="#0f172a"/>')
        lines.append(f'    <text x="{x+12}" y="{y+18}" font-size="11.5" font-weight="700" fill="#f8fafc">N = {n} ({dim})</text>')
        lines.append(f'    <text x="{x+cw-10}" y="{y+18}" text-anchor="end" font-size="9.5" font-weight="600" fill="#34d399">{trk}</text>')
        lines.append(f'    <text x="{x+12}" y="{y+48}" font-size="9.5" font-weight="600" fill="#4c1d95">Routers: {tree}</text>')
        lines.append(f'    <text x="{x+12}" y="{y+66}" font-size="9.5" font-weight="600" fill="#92400e">Repeaters: {rep}</text>')
        lines.append(f'    <text x="{x+12}" y="{y+84}" font-size="9" fill="#475569">Tile: SU + local rt2(D$+I$)</text>')
        plat = "FPGA Xbar + ASIC NoC" if n <= 2 else "ASIC Fat-Tree NoC Only"
        pcol = "#c2410c" if n <= 2 else "#0369a1"
        lines.append(f'    <text x="{x+12}" y="{y+102}" font-size="9" font-weight="700" fill="{pcol}">{plat}</text>')
        lines.append(f'    <text x="{x+12}" y="{y+118}" font-size="8" fill="#64748b">File: {fname}</text>')

    lines.append(render_spine(24, 370, 992, "1..8", "N"))
    lines.append('</svg>')
    return "\n".join(lines)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    outputs = {
        "floorplan_n1.svg": gen_n1(),
        "floorplan_n2.svg": gen_n2(),
        "floorplan_n4.svg": gen_n4(),
        "floorplan_n8.svg": gen_n8(),
        "floorplan_n16.svg": gen_n16(),
        "floorplan_n32.svg": gen_n32(),
        "floorplan_n64.svg": gen_n64(),
        "floorplan_n128.svg": gen_n128(),
        "floorplan_overview_all.svg": gen_overview(),
    }
    for fname, content in outputs.items():
        path = os.path.join(OUT_DIR, fname)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        # Validate XML well-formedness
        ET.fromstring(content)
        print(f"Generated & validated: {path}")


if __name__ == "__main__":
    main()
