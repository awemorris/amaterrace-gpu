#!/usr/bin/env python3
"""
generate_svgs.py

Generates 9 high-quality SVG architecture diagrams for GHCI 2.0 specification
and Amaterrace GPU (ATG1) documentation:
1. ghci_gpu_architecture.svg
2. ghci_uma_system.svg
3. ghci_discrete_system.svg
4. ghci_command_flow.svg
5. ghci_command_sequence.svg
6. atg_top_architecture.svg
7. atg_su_32lane.svg
8. atg_rx_rasterizer.svg
9. atg_rop_backend.svg
"""

import os
import sys

COMMON_STYLE = """<![CDATA[
    /* Fonts & Resets */
    text {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    }
    .title {
        font-size: 20px;
        font-weight: 700;
        fill: #0f172a;
    }
    .subtitle {
        font-size: 13px;
        font-weight: 500;
        fill: #475569;
    }
    .badge-text {
        font-size: 11px;
        font-weight: 600;
        fill: #ffffff;
    }
    .card-title {
        font-size: 14px;
        font-weight: 700;
        fill: #1e293b;
    }
    .card-subtitle {
        font-size: 11px;
        font-weight: 600;
        fill: #64748b;
    }
    .card-body {
        font-size: 11px;
        font-weight: 400;
        fill: #334155;
    }
    .card-bullet {
        font-size: 11px;
        font-weight: 400;
        fill: #475569;
    }
    .conn-label {
        font-size: 11px;
        font-weight: 600;
        fill: #334155;
    }
    .conn-sub {
        font-size: 9.5px;
        font-weight: 400;
        fill: #64748b;
    }
    .group-label {
        font-size: 12px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.8px;
    }
    .seq-actor {
        font-size: 13px;
        font-weight: 700;
        fill: #1e293b;
    }
    .seq-step {
        font-size: 11px;
        font-weight: 600;
        fill: #1e293b;
    }
    .seq-desc {
        font-size: 10px;
        font-weight: 400;
        fill: #475569;
    }
    .seq-num {
        font-size: 10.5px;
        font-weight: 700;
        fill: #ffffff;
    }
]]>"""

DEFS_COMMON = """
    <defs>
        <!-- Dropshadow Filters -->
        <filter id="shadow-sm" x="-4%" y="-4%" width="108%" height="108%" filterUnits="userSpaceOnUse">
            <feDropShadow dx="0" dy="1.5" stdDeviation="2" flood-color="#0f172a" flood-opacity="0.06"/>
        </filter>
        <filter id="shadow-md" x="-6%" y="-6%" width="112%" height="112%" filterUnits="userSpaceOnUse">
            <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#0f172a" flood-opacity="0.08"/>
        </filter>

        <!-- Arrow Markers -->
        <marker id="arrow" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#475569"/>
        </marker>
        <marker id="arrow-blue" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#2563eb"/>
        </marker>
        <marker id="arrow-purple" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#7c3aed"/>
        </marker>
        <marker id="arrow-emerald" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#059669"/>
        </marker>
        <marker id="arrow-amber" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#d97706"/>
        </marker>
        <marker id="arrow-rose" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#e11d48"/>
        </marker>

        <!-- Linear Gradients -->
        <linearGradient id="header-grad" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%" stop-color="#3b82f6"/>
            <stop offset="100%" stop-color="#8b5cf6"/>
        </linearGradient>
    </defs>
"""

def generate_ghci_gpu_architecture():
    """1. docs/svg/ghci_gpu_architecture.svg"""
    width, height = 1000, 720
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">GHCI 2.0 GPU Architecture</text>
        <text class="subtitle" x="0" y="40">Vulkan-Class Host Controller Interface • Slim MMIO • Autonomous MMU • In-Memory Pipeline State</text>
        <rect x="680" y="4" width="260" height="28" rx="14" fill="#3b82f6" opacity="0.1"/>
        <text x="810" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#1d4ed8">TO-BE SPECIFICATION (GHCI 2.0)</text>
    </g>

    <!-- Boundary: Host Interface (Left) -->
    <g transform="translate(30, 80)">
        <rect width="210" height="600" rx="10" fill="#ffffff" stroke="#93c5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 200 0 Q 210 0 210 10 L 210 38 L 0 38 Z" fill="#eff6ff"/>
        <text class="group-label" x="15" y="24" fill="#1d4ed8">Host CPU / Driver</text>

        <!-- Host Entities -->
        <g transform="translate(12, 50)">
            <rect width="186" height="70" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="20">User-Mode Driver</text>
            <text class="card-body" x="10" y="38">• In-Memory PSO Builder</text>
            <text class="card-body" x="10" y="54">• Descriptor Tables &amp; Shaders</text>
        </g>

        <g transform="translate(12, 130)">
            <rect width="186" height="70" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Kernel Driver (KMD)</text>
            <text class="card-body" x="10" y="38">• Doorbell (WPTR) Updates</text>
            <text class="card-body" x="10" y="54">• Interrupt Handler / Fences</text>
        </g>

        <!-- Slim MMIO Card -->
        <g transform="translate(12, 220)">
            <rect width="186" height="195" rx="8" fill="#f5f3ff" stroke="#c4b5fd" stroke-width="1.5"/>
            <rect x="0" y="0" width="186" height="28" rx="8" fill="#ede9fe"/>
            <text class="card-title" x="10" y="19" fill="#5b21b6">Slim MMIO Window</text>
            <text class="card-subtitle" x="10" y="44" fill="#6d28d9">19 Regs (76 Bytes Total)</text>
            <text class="card-bullet" x="10" y="64">• ID / CAP0, CAP1, CAP2</text>
            <text class="card-bullet" x="10" y="80">• RING_BASE_LO / HI, SIZE</text>
            <text class="card-bullet" x="10" y="96">• RING_WPTR, RING_RPTR</text>
            <text class="card-bullet" x="10" y="112">• FENCE_STATUS, FENCE_ACK</text>
            <text class="card-bullet" x="10" y="128">• IRQ_STATUS, IRQ_MASK</text>
            <text class="card-bullet" x="10" y="144">• RESET_REQ, RESET_STATUS</text>
            <rect x="8" y="156" width="170" height="28" rx="4" fill="#fef2f2" stroke="#fca5a5" stroke-width="1"/>
            <text x="93" y="174" text-anchor="middle" font-size="10.5" font-weight="700" fill="#dc2626">NO STATE REGISTERS</text>
        </g>

        <!-- Command Ring Buffer representation -->
        <g transform="translate(12, 435)">
            <rect width="186" height="150" rx="8" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Shared Ring Buffer</text>
            <text class="card-body" x="10" y="38">• CMD_BIND_PIPELINE</text>
            <text class="card-body" x="10" y="54">• CMD_BIND_DESCRIPTOR</text>
            <text class="card-body" x="10" y="70">• CMD_DRAW_INDIRECT</text>
            <text class="card-body" x="10" y="86">• CMD_DISPATCH</text>
            <text class="card-body" x="10" y="102">• CMD_BARRIER / FENCE</text>
            <text class="card-subtitle" x="10" y="132" fill="#0284c7">Zero-Copy DMA Region</text>
        </g>
    </g>

    <!-- GPU Core Container -->
    <g transform="translate(260, 80)">
        <rect width="710" height="600" rx="10" fill="#ffffff" stroke="#cbd5e1" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 700 0 Q 710 0 710 10 L 710 38 L 0 38 Z" fill="#f1f5f9"/>
        <text class="group-label" x="20" y="24" fill="#334155">GHCI 2.0 Conforming GPU Core (Amaterrace / ATG1)</text>

        <!-- Command Processor (CP) -->
        <g transform="translate(20, 50)">
            <rect width="670" height="100" rx="8" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1.5"/>
            <text class="card-title" x="16" y="22" fill="#6b21a8">Command Processor (CP)</text>
            <text class="card-subtitle" x="16" y="38" fill="#9333ea">Hardware Dispatcher &amp; Autonomous Address Translation</text>

            <!-- Sub modules in CP -->
            <g transform="translate(16, 46)">
                <rect width="145" height="42" rx="4" fill="#ffffff" stroke="#c084fc" stroke-width="1"/>
                <text class="card-title" x="72" y="18" text-anchor="middle" font-size="11.5">RV32IM Core</text>
                <text class="card-body" x="72" y="32" text-anchor="middle" font-size="9.5">Firmware / Scheduler</text>
            </g>
            <g transform="translate(173, 46)">
                <rect width="155" height="42" rx="4" fill="#ffffff" stroke="#c084fc" stroke-width="1"/>
                <text class="card-title" x="77" y="18" text-anchor="middle" font-size="11.5">Command Decoder</text>
                <text class="card-body" x="77" y="32" text-anchor="middle" font-size="9.5">Direct HW Dispatch</text>
            </g>
            <g transform="translate(340, 46)">
                <rect width="155" height="42" rx="4" fill="#ffffff" stroke="#c084fc" stroke-width="1"/>
                <text class="card-title" x="77" y="18" text-anchor="middle" font-size="11.5">HW Page Table Walker</text>
                <text class="card-body" x="77" y="32" text-anchor="middle" font-size="9.5">Autonomous 2-Level Walk</text>
            </g>
            <g transform="translate(507, 46)">
                <rect width="145" height="42" rx="4" fill="#ffffff" stroke="#c084fc" stroke-width="1"/>
                <text class="card-title" x="72" y="18" text-anchor="middle" font-size="11.5">Unified L1/L2 TLB</text>
                <text class="card-body" x="72" y="32" text-anchor="middle" font-size="9.5">Hardware Invalidation</text>
            </g>
        </g>

        <!-- 3D Pipeline Blocks & 2D BLT -->
        <g transform="translate(20, 168)">
            <!-- 2D Engine -->
            <g transform="translate(0, 0)">
                <rect width="115" height="175" rx="8" fill="#f0fdf4" stroke="#86efac" stroke-width="1.2"/>
                <text class="card-title" x="12" y="24" fill="#15803d">BLT (2D)</text>
                <text class="card-subtitle" x="12" y="40" fill="#16a34a">BitBLT &amp; DMA</text>
                <text class="card-body" x="12" y="65">• Fast Clear</text>
                <text class="card-body" x="12" y="83">• Buffer Copies</text>
                <text class="card-body" x="12" y="101">• Linear-Tiled</text>
                <text class="card-body" x="12" y="119">• DMA Transfer</text>
                <text class="card-body" x="12" y="150" font-weight="600" fill="#166534">Direct to L2C</text>
            </g>

            <!-- VF: Vertex Fetcher -->
            <g transform="translate(130, 0)">
                <rect width="120" height="175" rx="8" fill="#ecfeff" stroke="#67e8f9" stroke-width="1.2"/>
                <text class="card-title" x="12" y="24" fill="#0e7490">VF</text>
                <text class="card-subtitle" x="12" y="40" fill="#0891b2">Vertex Fetch</text>
                <text class="card-body" x="12" y="65">• In-Memory PSO</text>
                <text class="card-body" x="12" y="83">• Index Buffer</text>
                <text class="card-body" x="12" y="101">• Attr Unpack</text>
                <text class="card-body" x="12" y="119">• Instancing</text>
                <text class="card-body" x="12" y="150" font-weight="600" fill="#0e7490">Streams to SU</text>
            </g>

            <!-- SU: Shader Unit -->
            <g transform="translate(265, 0)">
                <rect width="140" height="175" rx="8" fill="#fffbeb" stroke="#fcd34d" stroke-width="1.2"/>
                <text class="card-title" x="12" y="24" fill="#b45309">SU (Shader)</text>
                <text class="card-subtitle" x="12" y="40" fill="#d97706">32-Lane SIMD</text>
                <text class="card-body" x="12" y="65">• GSI1 64-bit ISA</text>
                <text class="card-body" x="12" y="83">• Warp Scheduler</text>
                <text class="card-body" x="12" y="101">• DSP48E1 FMA</text>
                <text class="card-body" x="12" y="119">• LDS Scratchpad</text>
                <text class="card-body" x="12" y="137">• Vertex / Frag / CS</text>
            </g>

            <!-- RX: Rasterizer -->
            <g transform="translate(420, 0)">
                <rect width="125" height="175" rx="8" fill="#ecfeff" stroke="#67e8f9" stroke-width="1.2"/>
                <text class="card-title" x="12" y="24" fill="#0e7490">RX (Raster)</text>
                <text class="card-subtitle" x="12" y="40" fill="#0891b2">Hierarchical Scan</text>
                <text class="card-body" x="12" y="65">• Triangle Setup</text>
                <text class="card-body" x="12" y="83">• Coarse Scan</text>
                <text class="card-body" x="12" y="101">• Early Z-Cull</text>
                <text class="card-body" x="12" y="119">• Fine 2x2 Quads</text>
                <text class="card-body" x="12" y="137">• Barycentrics</text>
            </g>

            <!-- TU: Texture Unit -->
            <g transform="translate(560, 0)">
                <rect width="110" height="82" rx="6" fill="#f0f9ff" stroke="#7dd3fc" stroke-width="1.2"/>
                <text class="card-title" x="10" y="22" fill="#0369a1">TU (Texture)</text>
                <text class="card-body" x="10" y="40">• Bilinear/Tri</text>
                <text class="card-body" x="10" y="56">• Tex L1 Cache</text>
                <text class="card-body" x="10" y="72">• Descriptors</text>
            </g>

            <!-- ROP: Render Output -->
            <g transform="translate(560, 93)">
                <rect width="110" height="82" rx="6" fill="#fff1f2" stroke="#fda4af" stroke-width="1.2"/>
                <text class="card-title" x="10" y="22" fill="#be123c">ROP (Output)</text>
                <text class="card-body" x="10" y="40">• Tile Buffer</text>
                <text class="card-body" x="10" y="56">• Z / Stencil Test</text>
                <text class="card-body" x="10" y="72">• Dual Blend/Logic</text>
            </g>
        </g>

        <!-- Arrows between Pipeline Stages -->
        <path fill="none" d="M 215 100 L 215 168" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <path fill="none" d="M 390 100 L 390 168" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <path fill="none" d="M 250 255 L 265 255" stroke="#475569" stroke-width="1.8" marker-end="url(#arrow)"/>
        <path fill="none" d="M 405 230 L 420 230" stroke="#475569" stroke-width="1.8" marker-end="url(#arrow)"/>
        <path fill="none" d="M 420 270 L 405 270" stroke="#475569" stroke-width="1.8" marker-end="url(#arrow)"/>
        <path fill="none" d="M 405 285 L 560 285" stroke="#475569" stroke-width="1.8" stroke-dasharray="3,3" marker-end="url(#arrow)"/>
        <path fill="none" d="M 405 200 L 560 200" stroke="#475569" stroke-width="1.8" marker-end="url(#arrow)"/>
        <path fill="none" d="M 615 175 L 615 186" stroke="#475569" stroke-width="1.8"/>

        <!-- atg_rt Interconnect Router Bar -->
        <g transform="translate(20, 360)">
            <rect width="670" height="34" rx="6" fill="#f1f5f9" stroke="#94a3b8" stroke-width="1.2"/>
            <text class="card-title" x="335" y="22" text-anchor="middle" fill="#334155" letter-spacing="1">atg_rt MEMORY ROUTER INTERCONNECT TREE</text>
        </g>

        <!-- Pipeline connections to atg_rt -->
        <line x1="77" y1="343" x2="77" y2="360" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>
        <line x1="190" y1="343" x2="190" y2="360" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>
        <line x1="335" y1="343" x2="335" y2="360" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>
        <line x1="615" y1="343" x2="615" y2="360" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>

        <!-- Shared L2 Cache (LLC: Last Level Cache) -->
        <g transform="translate(20, 415)">
            <rect width="470" height="90" rx="8" fill="#ecfdf5" stroke="#6ee7b7" stroke-width="1.5"/>
            <text class="card-title" x="18" y="24" fill="#047857">Shared L2 Cache (LLC: Last Level Cache)</text>
            <text class="card-subtitle" x="18" y="42" fill="#059669">Unified Multi-Banked Cache • 512KB - 2MB • Write-Combining Buffer</text>
            <text class="card-body" x="18" y="66">• Caches VF, SU (D$), TU, and ROP Writebacks</text>
            <text class="card-body" x="18" y="80">• Enforces Memory Barriers &amp; Invalidation for Host/Shader Coherency</text>
        </g>

        <!-- Display Controller (DC) -->
        <g transform="translate(510, 415)">
            <rect width="180" height="90" rx="8" fill="#fdf4ff" stroke="#f0abfc" stroke-width="1.5"/>
            <text class="card-title" x="12" y="24" fill="#a21caf">DC (Display)</text>
            <text class="card-subtitle" x="12" y="42" fill="#c026d3">Independent 200 MHz</text>
            <text class="card-body" x="12" y="64">• High-Priority QoS Port</text>
            <text class="card-body" x="12" y="78">• Survives GPU Reset</text>
        </g>

        <!-- atg_rt to L2C and DC -->
        <line x1="255" y1="394" x2="255" y2="415" stroke="#059669" stroke-width="2" marker-end="url(#arrow-emerald)"/>
        <line x1="600" y1="394" x2="600" y2="415" stroke="#c026d3" stroke-width="2" marker-end="url(#arrow)"/>

        <!-- Memory Controller (MC) -->
        <g transform="translate(20, 525)">
            <rect width="670" height="55" rx="8" fill="#1e293b" stroke="#0f172a" stroke-width="1.5"/>
            <text class="card-title" x="20" y="24" fill="#f8fafc">Memory Controller (MC)</text>
            <text class="card-subtitle" x="20" y="42" fill="#94a3b8">AXI4 Coherent System Interface • Priority Arbiter for Display &amp; L2 Cache</text>
            <rect x="490" y="12" width="165" height="30" rx="4" fill="#334155"/>
            <text x="572" y="32" text-anchor="middle" font-size="11.5" font-weight="600" fill="#38bdf8">DRAM / Host UMA Bus</text>
        </g>

        <line x1="255" y1="505" x2="255" y2="525" stroke="#059669" stroke-width="2" marker-end="url(#arrow-emerald)"/>
        <line x1="600" y1="505" x2="600" y2="525" stroke="#c026d3" stroke-width="2" marker-end="url(#arrow)"/>
    </g>

    <!-- Cross connections from Host to GPU -->
    <!-- Doorbell write -->
    <path fill="none" d="M 210 240 L 260 240 L 260 110 L 280 110" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
    <text class="conn-label" x="235" y="180" fill="#7c3aed" text-anchor="middle" transform="rotate(-90 235 180)">WPTR Doorbell</text>

    <!-- Interrupt line -->
    <path fill="none" d="M 280 130 L 245 130 L 245 360 L 210 360" stroke="#dc2626" stroke-width="1.8" stroke-dasharray="4,3" marker-end="url(#arrow)"/>
    <text class="conn-label" x="235" y="290" fill="#dc2626" text-anchor="middle" transform="rotate(-90 235 290)">IRQ Line</text>
</svg>
"""

def generate_ghci_uma_system():
    """2. docs/svg/ghci_uma_system.svg"""
    width, height = 1040, 720
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <defs>
        <!-- Dropshadow Filters -->
        <filter id="shadow-sm" x="-4%" y="-4%" width="108%" height="108%" filterUnits="userSpaceOnUse">
            <feDropShadow dx="0" dy="1.5" stdDeviation="2" flood-color="#0f172a" flood-opacity="0.06"/>
        </filter>
        <filter id="shadow-md" x="-6%" y="-6%" width="112%" height="112%" filterUnits="userSpaceOnUse">
            <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#0f172a" flood-opacity="0.08"/>
        </filter>

        <!-- Arrow Markers -->
        <marker id="arrow" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#475569"/>
        </marker>
        <marker id="arrow-blue" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#2563eb"/>
        </marker>
        <marker id="arrow-purple" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#7c3aed"/>
        </marker>
        <marker id="arrow-emerald" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#059669"/>
        </marker>
    </defs>

    <style><![CDATA[
        text {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
        }}
        .title {{
            font-size: 20px;
            font-weight: 700;
            fill: #0f172a;
        }}
        .subtitle {{
            font-size: 13px;
            font-weight: 500;
            fill: #475569;
        }}
        .group-label {{
            font-size: 12.5px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.8px;
        }}
        .card-title {{
            font-size: 12.5px;
            font-weight: 700;
            fill: #1e293b;
        }}
        .card-sub {{
            font-size: 10px;
            font-weight: 600;
            fill: #64748b;
        }}
        .card-body {{
            font-size: 10px;
            font-weight: 400;
            fill: #334155;
        }}
        .card-bullet {{
            font-size: 10px;
            font-weight: 400;
            fill: #475569;
        }}
        .conn-label {{
            font-size: 10.5px;
            font-weight: 600;
            fill: #334155;
        }}
    ]]></style>

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 22)">
        <text class="title" x="0" y="20">GHCI Unified Memory Architecture (UMA) System</text>
        <text class="subtitle" x="0" y="38">Zero-Copy In-Memory PSO &amp; Descriptors • Autonomous On-Chip GPU Command Processor • Platform Bus</text>
        <rect x="790" y="4" width="190" height="26" rx="13" fill="#059669" opacity="0.12"/>
        <text x="885" y="21" text-anchor="middle" font-size="11.5" font-weight="700" fill="#047857">UMA ZERO-COPY</text>
    </g>

    <!-- ============================================================== -->
    <!-- TOP LEFT: HOST CPU & OPERATING SYSTEM                          -->
    <!-- ============================================================== -->
    <g transform="translate(30, 72)">
        <rect width="430" height="280" rx="10" fill="#ffffff" stroke="#93c5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 420 0 Q 430 0 430 10 L 430 36 L 0 36 Z" fill="#eff6ff"/>
        <text class="group-label" x="16" y="24" fill="#1d4ed8">Host CPU Subsystem (No GPU Logic)</text>

        <!-- User Space -->
        <g transform="translate(16, 48)">
            <rect width="190" height="216" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <rect x="0" y="0" width="190" height="26" rx="6" fill="#e0f2fe"/>
            <text class="card-title" x="95" y="17" text-anchor="middle" fill="#0369a1">User Space (App / UMD)</text>
            <text class="card-body" x="12" y="44">• Vulkan 1.3 Application</text>
            <text class="card-body" x="12" y="64">• Amaterrace User-Mode</text>
            <text class="card-body" x="12" y="80">  Driver (UMD / Mesa)</text>
            <text class="card-body" x="12" y="102">• Builds GhciPipelineState</text>
            <text class="card-body" x="12" y="118">  (48B Immutable PSOs)</text>
            <text class="card-body" x="12" y="140">• Populates Descriptor Tables</text>
            <text class="card-body" x="12" y="162">• Writes Command Ring</text>
            <rect x="10" y="180" width="170" height="24" rx="4" fill="#dbeafe"/>
            <text x="95" y="196" text-anchor="middle" font-size="10" font-weight="700" fill="#1e40af">Zero-Copy Memory Alloc</text>
        </g>

        <!-- Kernel Space -->
        <g transform="translate(220, 48)">
            <rect width="194" height="216" rx="6" fill="#f0fdf4" stroke="#bbf7d0" stroke-width="1"/>
            <rect x="0" y="0" width="194" height="26" rx="6" fill="#dcfce7"/>
            <text class="card-title" x="97" y="17" text-anchor="middle" fill="#15803d">Kernel Space (KMD / OS)</text>
            <text class="card-body" x="12" y="44">• Amaterrace DRM / KMD</text>
            <text class="card-body" x="12" y="64">• Unified Virtual Memory</text>
            <text class="card-body" x="12" y="80">  (UVM) Manager</text>
            <text class="card-body" x="12" y="102">• Maps Unified Page Tables</text>
            <text class="card-body" x="12" y="124">• Writes Ring Doorbell</text>
            <text class="card-body" x="12" y="140">  (RING_WPTR register)</text>
            <text class="card-body" x="12" y="162">• Handles IRQ / Fences</text>
            <rect x="10" y="180" width="174" height="24" rx="4" fill="#bbf7d0"/>
            <text x="97" y="196" text-anchor="middle" font-size="10" font-weight="700" fill="#166534">76B Slim MMIO Only</text>
        </g>
    </g>

    <!-- ============================================================== -->
    <!-- TOP RIGHT: GPU SUBSYSTEM (CONTAINING CP AND PIPELINE)          -->
    <!-- ============================================================== -->
    <g transform="translate(485, 72)">
        <rect width="525" height="280" rx="10" fill="#ffffff" stroke="#c4b5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 515 0 Q 525 0 525 10 L 525 36 L 0 36 Z" fill="#f5f3ff"/>
        <text class="group-label" x="16" y="24" fill="#6d28d9">GPU Subsystem (On-Die Hardware ATG1)</text>

        <!-- Top Inner Block: Command Processor (CP) -->
        <g transform="translate(14, 46)">
            <rect width="497" height="106" rx="8" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1.2"/>
            <rect x="0" y="0" width="497" height="24" rx="8" fill="#f3e8ff"/>
            <text class="card-title" x="15" y="17" fill="#6b21a8">GPU Front-End: Command Processor (CP) — atg_cp</text>
            <text class="card-sub" x="480" y="16" text-anchor="end" fill="#7c3aed">Autonomous Hardware Controller</text>

            <g transform="translate(12, 32)">
                <!-- Sub 1: RV32IM Core -->
                <rect width="112" height="64" rx="4" fill="#ffffff" stroke="#e9d5ff" stroke-width="1"/>
                <text class="card-title" x="56" y="18" text-anchor="middle" font-size="10.5" fill="#581c87">RV32IM Core</text>
                <text class="card-desc" x="56" y="34" text-anchor="middle" font-size="8.5">• Microcode FW</text>
                <text class="card-desc" x="56" y="46" text-anchor="middle" font-size="8.5">• Ring Fetcher</text>
                <text class="card-desc" x="56" y="58" text-anchor="middle" font-size="8.5">• Preemption</text>
            </g>
            <g transform="translate(132, 32)">
                <!-- Sub 2: HW Page Table Walker -->
                <rect width="120" height="64" rx="4" fill="#ffffff" stroke="#e9d5ff" stroke-width="1"/>
                <text class="card-title" x="60" y="18" text-anchor="middle" font-size="10.5" fill="#581c87">Page Walker</text>
                <text class="card-desc" x="60" y="34" text-anchor="middle" font-size="8.5">• 2-Level Walk</text>
                <text class="card-desc" x="60" y="46" text-anchor="middle" font-size="8.5">• Traverses UMA</text>
                <text class="card-desc" x="60" y="58" text-anchor="middle" font-size="8.5">• Zero CPU Pin</text>
            </g>
            <g transform="translate(260, 32)">
                <!-- Sub 3: TLB Hierarchy -->
                <rect width="105" height="64" rx="4" fill="#ffffff" stroke="#e9d5ff" stroke-width="1"/>
                <text class="card-title" x="52" y="18" text-anchor="middle" font-size="10.5" fill="#581c87">L1/L2 TLBs</text>
                <text class="card-desc" x="52" y="34" text-anchor="middle" font-size="8.5">• Hardware TLB</text>
                <text class="card-desc" x="52" y="46" text-anchor="middle" font-size="8.5">• Auto-Refill</text>
                <text class="card-desc" x="52" y="58" text-anchor="middle" font-size="8.5">• Fast Invalidate</text>
            </g>
            <g transform="translate(373, 32)">
                <!-- Sub 4: Pipeline Dispatch -->
                <rect width="112" height="64" rx="4" fill="#ede9fe" stroke="#c084fc" stroke-width="1"/>
                <text class="card-title" x="56" y="18" text-anchor="middle" font-size="10.5" fill="#4c1d95">Dispatch Engine</text>
                <text class="card-desc" x="56" y="34" text-anchor="middle" font-size="8.5">• Configures VF/SU</text>
                <text class="card-desc" x="56" y="46" text-anchor="middle" font-size="8.5">• Multi-Queue Arb</text>
                <text class="card-desc" x="56" y="58" text-anchor="middle" font-size="8.5">• Zero-MMIO State</text>
            </g>
        </g>

        <!-- Downward Dispatch Arrows from CP to Execution Pipeline -->
        <path fill="none" d="M 70 152 L 70 168" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <path fill="none" d="M 230 152 L 230 168" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <path fill="none" d="M 390 152 L 390 168" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="flow-label" x="262" y="162" text-anchor="middle" fill="#6b21a8" font-size="9" font-weight="700">Internal Hardware Configuration &amp; Draw Dispatch Bus</text>

        <!-- Bottom Inner Block: GPU Execution Engines & Pipeline -->
        <g transform="translate(14, 172)">
            <rect width="497" height="96" rx="8" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1.2"/>
            <rect x="0" y="0" width="497" height="22" rx="8" fill="#f1f5f9"/>
            <text class="card-title" x="15" y="15" fill="#334155">GPU 3D, Compute &amp; 2D Execution Engines</text>

            <g transform="translate(8, 28)">
                <rect width="90" height="60" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
                <text class="card-title" x="45" y="16" text-anchor="middle" font-size="10">VF</text>
                <text class="card-body" x="45" y="32" text-anchor="middle" font-size="8.5">Vertex Fetch</text>
                <text class="card-body" x="45" y="46" text-anchor="middle" font-size="8.5">32-Entry PT-VC</text>
            </g>
            <g transform="translate(104, 28)">
                <rect width="96" height="60" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
                <text class="card-title" x="48" y="16" text-anchor="middle" font-size="10">SU (Warps)</text>
                <text class="card-body" x="48" y="32" text-anchor="middle" font-size="8.5">32-Thread SIMT</text>
                <text class="card-body" x="48" y="46" text-anchor="middle" font-size="8.5">Scalar PE Array</text>
            </g>
            <g transform="translate(206, 28)">
                <rect width="90" height="60" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
                <text class="card-title" x="45" y="16" text-anchor="middle" font-size="10">RX</text>
                <text class="card-body" x="45" y="32" text-anchor="middle" font-size="8.5">8×8 Tile Skip</text>
                <text class="card-body" x="45" y="46" text-anchor="middle" font-size="8.5">16-Sample MSAA</text>
            </g>
            <g transform="translate(302, 28)">
                <rect width="94" height="60" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
                <text class="card-title" x="47" y="16" text-anchor="middle" font-size="10">TU &amp; ROP</text>
                <text class="card-body" x="47" y="32" text-anchor="middle" font-size="8.5">MSHR Cache</text>
                <text class="card-body" x="47" y="46" text-anchor="middle" font-size="8.5">Tile SRAM Blend</text>
            </g>
            <g transform="translate(402, 28)">
                <rect width="88" height="60" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
                <text class="card-title" x="44" y="16" text-anchor="middle" font-size="10">BLT &amp; DC</text>
                <text class="card-body" x="44" y="32" text-anchor="middle" font-size="8.5">2.0 GB/s DMA</text>
                <text class="card-body" x="44" y="46" text-anchor="middle" font-size="8.5">200MHz Scanout</text>
            </g>
        </g>
    </g>

    <!-- ============================================================== -->
    <!-- CENTER BRIDGE: SYSTEM BUS & IOMMU                              -->
    <!-- ============================================================== -->
    <g transform="translate(30, 375)">
        <rect width="980" height="64" rx="8" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1.5"/>
        <text class="card-title" x="20" y="26" fill="#1e293b">Unified Platform Bus &amp; Hardware IOMMU (AXI4-Coherent)</text>
        <text class="card-subtitle" x="20" y="48" fill="#475569">48-bit Virtual Addressing • CPU maps shared ring &amp; PSOs • GPU CP traverses page tables autonomously without OS pinning</text>
        <rect x="745" y="17" width="215" height="30" rx="5" fill="#e2e8f0"/>
        <text x="852" y="37" text-anchor="middle" font-size="11" font-weight="700" fill="#334155">Zero Staging Copies</text>
    </g>

    <!-- Connections between Host, GPU, and Center Bus -->
    <!-- Host KMD Doorbell to GPU CP -->
    <path fill="none" d="M 330 352 L 330 365 L 560 365 L 560 180 L 515 180" stroke="#2563eb" stroke-width="1.8" stroke-dasharray="3,3" marker-end="url(#arrow-blue)"/>
    <text class="flow-label" x="445" y="361" text-anchor="middle" fill="#2563eb" font-size="9" font-weight="700">Slim MMIO Doorbell (WPTR Write)</text>

    <!-- GPU CP to Bus (Ring & Page Walk) -->
    <path fill="none" d="M 640 352 L 640 375" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
    <text class="flow-label" x="640" y="367" text-anchor="middle" fill="#7c3aed" font-size="8.5">CP Memory Port</text>

    <!-- GPU Execution Pipeline to Bus (Textures, Framebuffer) -->
    <path fill="none" d="M 850 352 L 850 375" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
    <text class="flow-label" x="850" y="367" text-anchor="middle" fill="#7c3aed" font-size="8.5">Shared L2C Port</text>

    <!-- Host App to Bus (Zero-Copy Ring & PSO Write) -->
    <path fill="none" d="M 130 352 L 130 375" stroke="#2563eb" stroke-width="2" marker-end="url(#arrow-blue)"/>
    <text class="flow-label" x="130" y="367" text-anchor="middle" fill="#2563eb" font-size="8.5">App Writes</text>

    <!-- ============================================================== -->
    <!-- BOTTOM: UNIFIED SYSTEM DRAM                                    -->
    <!-- ============================================================== -->
    <g transform="translate(30, 460)">
        <rect width="980" height="235" rx="10" fill="#ffffff" stroke="#6ee7b7" stroke-width="1.5" filter="url(#shadow-md)"/>
        <path d="M 0 10 Q 0 0 10 0 L 970 0 Q 980 0 980 10 L 980 36 L 0 36 Z" fill="#ecfdf5"/>
        <text class="group-label" x="20" y="24" fill="#047857">Shared Physical Memory (Unified System DRAM)</text>
        <text class="card-subtitle" x="420" y="24" fill="#059669">Single Physical Pool: Host CPU and GPU Engines read/write zero-copy data structures directly</text>

        <!-- Memory Buffer Cards -->
        <g transform="translate(20, 52)">
            <rect width="220" height="165" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="220" height="24" rx="6" fill="#e0f2fe"/>
            <text class="card-title" x="110" y="17" text-anchor="middle" fill="#0369a1">Command Ring Buffer</text>
            <text class="card-body" x="12" y="44">• Host app writes packets into DRAM</text>
            <text class="card-body" x="12" y="64">• GPU CP fetches via DMA/AXI master</text>
            <text class="card-body" x="12" y="84">• Lockless circular WPTR/RPTR</text>
            <text class="card-body" x="12" y="104">• BIND_PIPELINE, DRAW, DISPATCH</text>
            <rect x="10" y="128" width="200" height="24" rx="4" fill="#dbeafe"/>
            <text x="110" y="144" text-anchor="middle" font-size="10" font-weight="700" fill="#0284c7">Host: Write │ GPU CP: Read</text>
        </g>

        <g transform="translate(260, 52)">
            <rect width="220" height="165" rx="6" fill="#fdf4ff" stroke="#f0abfc" stroke-width="1.2"/>
            <rect x="0" y="0" width="220" height="24" rx="6" fill="#fae8ff"/>
            <text class="card-title" x="110" y="17" text-anchor="middle" fill="#a21caf">In-Memory PSO (48B)</text>
            <text class="card-body" x="12" y="44">• Immutable GhciPipelineState struct</text>
            <text class="card-body" x="12" y="64">• Shader GSI1 instruction pointers</text>
            <text class="card-body" x="12" y="84">• Raster, blend &amp; stencil states</text>
            <text class="card-body" x="12" y="104">• Created once, bound by pointer</text>
            <rect x="10" y="128" width="200" height="24" rx="4" fill="#f5d0fe"/>
            <text x="110" y="144" text-anchor="middle" font-size="10" font-weight="700" fill="#c026d3">Zero Register Configuration</text>
        </g>

        <g transform="translate(500, 52)">
            <rect width="220" height="165" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1.2"/>
            <rect x="0" y="0" width="220" height="24" rx="6" fill="#fef3c7"/>
            <text class="card-title" x="110" y="17" text-anchor="middle" fill="#b45309">Descriptor &amp; Page Tables</text>
            <text class="card-body" x="12" y="44">• Flat 64-bit GPU virtual address array</text>
            <text class="card-body" x="12" y="64">• OS 2-level page tables in DRAM</text>
            <text class="card-body" x="12" y="84">• Direct HW TU / VF descriptor fetch</text>
            <text class="card-body" x="12" y="104">• GPU CP walks page tables directly</text>
            <rect x="10" y="128" width="200" height="24" rx="4" fill="#fde68a"/>
            <text x="110" y="144" text-anchor="middle" font-size="10" font-weight="700" fill="#d97706">Hardware Page Walking</text>
        </g>

        <g transform="translate(740, 52)">
            <rect width="220" height="165" rx="6" fill="#ecfdf5" stroke="#a7f3d0" stroke-width="1.2"/>
            <rect x="0" y="0" width="220" height="24" rx="6" fill="#d1fae5"/>
            <text class="card-title" x="110" y="17" text-anchor="middle" fill="#047857">Buffers &amp; Framebuffers</text>
            <text class="card-body" x="12" y="44">• Vertex &amp; Index mesh attributes</text>
            <text class="card-body" x="12" y="64">• Textures, Mipmaps, Depth Buffers</text>
            <text class="card-body" x="12" y="84">• Color Render Targets / Framebuffers</text>
            <text class="card-body" x="12" y="104">• Direct Display Scanout (DC)</text>
            <rect x="10" y="128" width="200" height="24" rx="4" fill="#a7f3d0"/>
            <text x="110" y="144" text-anchor="middle" font-size="10" font-weight="700" fill="#059669">Zero-Copy DC Scanout</text>
        </g>
    </g>

    <!-- Connectors between Center Interconnect and Bottom DRAM -->
    <path fill="none" d="M 520 439 L 520 460" stroke="#059669" stroke-width="2.5" marker-end="url(#arrow-emerald)"/>
</svg>
"""

def generate_ghci_discrete_system():
    """3. docs/svg/ghci_discrete_system.svg"""
    width, height = 980, 640
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">GHCI Discrete System Architecture (PCIe Binding)</text>
        <text class="subtitle" x="0" y="40">BAR0 Slim MMIO • PCIe IOMMU • Bus Master DMA • Dedicated High-Bandwidth VRAM</text>
        <rect x="730" y="4" width="220" height="28" rx="14" fill="#2563eb" opacity="0.12"/>
        <text x="840" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#1d4ed8">DISCRETE PCIe MODEL</text>
    </g>

    <!-- Host Side (Left) -->
    <g transform="translate(30, 80)">
        <rect width="360" height="520" rx="10" fill="#ffffff" stroke="#93c5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 350 0 Q 360 0 360 10 L 360 36 L 0 36 Z" fill="#eff6ff"/>
        <text class="group-label" x="16" y="24" fill="#1d4ed8">Host Subsystem (Motherboard)</text>

        <!-- Host CPU & Driver -->
        <g transform="translate(16, 50)">
            <rect width="328" height="110" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="12" y="22">Host CPU &amp; Kernel Driver</text>
            <text class="card-body" x="12" y="42">• Maps BAR0 MMIO window for Slim MMIO (76B)</text>
            <text class="card-body" x="12" y="60">• Writes Doorbell (`RING_WPTR`) to trigger CP</text>
            <text class="card-body" x="12" y="78">• Receives MSI / MSI-X or INTx Interrupts</text>
            <text class="card-body" x="12" y="96">• Manages VRAM page migrations / staging buffers</text>
        </g>

        <!-- Host Physical DRAM -->
        <g transform="translate(16, 175)">
            <rect width="328" height="155" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="12" y="22">Host Physical DRAM</text>
            <text class="card-body" x="12" y="42">• Command Ring Buffer (Host memory)</text>
            <text class="card-body" x="12" y="60">• Staging Upload Buffers (Textures, Meshes)</text>
            <text class="card-body" x="12" y="78">• Host-cached Descriptors &amp; Shaders</text>
            <text class="card-body" x="12" y="96">• Readback buffers for fence status / query</text>
            <rect x="10" y="115" width="308" height="26" rx="4" fill="#e2e8f0"/>
            <text x="164" y="132" text-anchor="middle" font-size="10.5" font-weight="600" fill="#334155">Directly readable by GPU via PCIe Bus Master</text>
        </g>

        <!-- Root Complex & PCIe IOMMU -->
        <g transform="translate(16, 345)">
            <rect width="328" height="145" rx="6" fill="#f0fdf4" stroke="#86efac" stroke-width="1"/>
            <text class="card-title" x="12" y="22" fill="#15803d">PCIe Root Complex &amp; IOMMU</text>
            <text class="card-body" x="12" y="42">• Translates GPU Bus Master DMA requests</text>
            <text class="card-body" x="12" y="60">• Provides hardware isolation &amp; memory protection</text>
            <text class="card-body" x="12" y="78">• Manages BAR apertures (BAR0: MMIO, BAR1: VRAM)</text>
            <text class="card-subtitle" x="12" y="112" fill="#166534">PCIe Gen3 / Gen4 x8 / x16 Interface</text>
        </g>
    </g>

    <!-- Center Bus (PCIe) -->
    <g transform="translate(415, 80)">
        <rect width="130" height="520" rx="8" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1.2"/>
        <text class="group-label" x="65" y="24" text-anchor="middle" fill="#475569">PCIe Bus</text>

        <!-- PCIe Channels -->
        <g transform="translate(12, 50)">
            <rect width="106" height="65" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
            <text class="conn-label" x="53" y="24" text-anchor="middle">BAR0 MMIO</text>
            <text class="conn-sub" x="53" y="40" text-anchor="middle">Host -> GPU</text>
            <text class="conn-sub" x="53" y="54" text-anchor="middle">76B Regs</text>
        </g>

        <g transform="translate(12, 130)">
            <rect width="106" height="75" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
            <text class="conn-label" x="53" y="24" text-anchor="middle">Bus Master DMA</text>
            <text class="conn-sub" x="53" y="40" text-anchor="middle">GPU -> Host</text>
            <text class="conn-sub" x="53" y="54" text-anchor="middle">Ring &amp; Data Fetch</text>
            <text class="conn-sub" x="53" y="68" text-anchor="middle">(High Bandwidth)</text>
        </g>

        <g transform="translate(12, 220)">
            <rect width="106" height="65" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
            <text class="conn-label" x="53" y="24" text-anchor="middle">BAR1 Aperture</text>
            <text class="conn-sub" x="53" y="40" text-anchor="middle">Host -> VRAM</text>
            <text class="conn-sub" x="53" y="54" text-anchor="middle">(Resizable BAR)</text>
        </g>

        <g transform="translate(12, 300)">
            <rect width="106" height="65" rx="4" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
            <text class="conn-label" x="53" y="24" text-anchor="middle">MSI-X / IRQ</text>
            <text class="conn-sub" x="53" y="40" text-anchor="middle">GPU -> Host</text>
            <text class="conn-sub" x="53" y="54" text-anchor="middle">Fence Wakeup</text>
        </g>

        <!-- Bidirectional Flow Arrows -->
        <path fill="none" d="M 65 390 L 65 470" stroke="#64748b" stroke-width="2" marker-end="url(#arrow)"/>
        <text class="conn-sub" x="65" y="495" text-anchor="middle" font-weight="700">PCIe Link</text>
    </g>

    <!-- Discrete GPU Card (Right) -->
    <g transform="translate(570, 80)">
        <rect width="380" height="520" rx="10" fill="#ffffff" stroke="#c4b5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 370 0 Q 380 0 380 10 L 380 36 L 0 36 Z" fill="#f5f3ff"/>
        <text class="group-label" x="16" y="24" fill="#6d28d9">Discrete GPU Card (Amaterrace Hardware)</text>

        <!-- PCIe Endpoint & DMA Engine -->
        <g transform="translate(16, 50)">
            <rect width="348" height="68" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="12" y="20">PCIe Endpoint &amp; DMA Controller</text>
            <text class="card-body" x="12" y="38">• BAR0 MMIO Window &amp; Doorbell register latch</text>
            <text class="card-body" x="12" y="54">• Asynchronous DMA Engine: Host DRAM &lt;--&gt; Local VRAM</text>
        </g>

        <!-- Command Processor & MMU -->
        <g transform="translate(16, 128)">
            <rect width="348" height="95" rx="6" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#6b21a8">Command Processor (CP)</text>
            <text class="card-body" x="12" y="38">• Autonomous Ring DMA Engine (Fetches from Host)</text>
            <text class="card-body" x="12" y="54">• GPU Page Table Walker: Handles Local VRAM &amp; Host Pages</text>
            <text class="card-body" x="12" y="70">• Dispatches commands to 3D Pipeline &amp; BLT Engine</text>
            <text class="card-subtitle" x="12" y="86" fill="#7c3aed">Decoupled execution from Host PCIe Latency</text>
        </g>

        <!-- GPU Core Pipeline -->
        <g transform="translate(16, 233)">
            <rect width="348" height="75" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#b45309">GPU Pipeline Core</text>
            <text class="card-body" x="12" y="38">• VF, SU (32-Lane), RX, TU, ROP, BLT</text>
            <text class="card-body" x="12" y="56">• High clock frequency graphics compute</text>
        </g>

        <!-- Shared L2 Cache -->
        <g transform="translate(16, 318)">
            <rect width="348" height="55" rx="6" fill="#ecfdf5" stroke="#a7f3d0" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#047857">Shared L2 Cache (LLC)</text>
            <text class="card-body" x="12" y="38">• 512KB - 2MB On-Chip Cache for high hit rate</text>
        </g>

        <!-- Local Dedicated VRAM -->
        <g transform="translate(16, 385)">
            <rect width="348" height="115" rx="8" fill="#1e293b" stroke="#0f172a" stroke-width="1.5"/>
            <text class="card-title" x="14" y="24" fill="#f8fafc">Local Dedicated VRAM (GDDR / DDR)</text>
            <text class="card-subtitle" x="14" y="42" fill="#38bdf8">High Bandwidth Dedicated Physical Memory (2GB - 16GB)</text>
            <text class="card-body" x="14" y="65" fill="#e2e8f0">• Render Targets, Depth/Stencil, G-Buffers</text>
            <text class="card-body" x="14" y="82" fill="#e2e8f0">• Textures, Geometry Buffers, Pipeline States</text>
            <text class="card-body" x="14" y="99" fill="#94a3b8">• Display Scanout (DC reads without crossing PCIe)</text>
        </g>
    </g>
</svg>
"""

def generate_ghci_command_flow():
    """4. docs/svg/ghci_command_flow.svg"""
    width, height = 1000, 680
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">GHCI 2.0 Command Flow &amp; In-Memory Architecture</text>
        <text class="subtitle" x="0" y="40">Zero-State-Register Model • Pointer-Based Pipeline State Objects (PSO) • Autonomous GPU Dispatch</text>
        <rect x="730" y="4" width="220" height="28" rx="14" fill="#7c3aed" opacity="0.12"/>
        <text x="840" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#6d28d9">GHCI 2.0 IN-MEMORY PSO</text>
    </g>

    <!-- Stage 1: Host Application & UMD (Top Left) -->
    <g transform="translate(30, 80)">
        <rect width="280" height="250" rx="10" fill="#ffffff" stroke="#93c5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 270 0 Q 280 0 280 10 L 280 34 L 0 34 Z" fill="#eff6ff"/>
        <text class="group-label" x="14" y="22" fill="#1d4ed8">1. Host Driver (UMD &amp; App)</text>

        <g transform="translate(12, 45)">
            <rect width="256" height="55" rx="5" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="18">Pipeline State Compiler</text>
            <text class="card-body" x="10" y="34">• Compiles Shaders to GSI1 64-bit</text>
            <text class="card-body" x="10" y="48">• Validates &amp; bakes `GhciPipelineState`</text>
        </g>

        <g transform="translate(12, 110)">
            <rect width="256" height="55" rx="5" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="18">Descriptor Table Builder</text>
            <text class="card-body" x="10" y="34">• Allocates 64-bit GPU VA descriptor arrays</text>
            <text class="card-body" x="10" y="48">• Writes texture &amp; buffer pointers</text>
        </g>

        <g transform="translate(12, 175)">
            <rect width="256" height="62" rx="5" fill="#f0fdf4" stroke="#86efac" stroke-width="1"/>
            <text class="card-title" x="10" y="18" fill="#15803d">Command Ring Recorder</text>
            <text class="card-body" x="10" y="34">• Records 64-bit command packets</text>
            <text class="card-body" x="10" y="48">• Rings Doorbell (`WPTR`) via KMD</text>
        </g>
    </g>

    <!-- Stage 2: In-Memory Data Structures (Center) -->
    <g transform="translate(340, 80)">
        <rect width="320" height="420" rx="10" fill="#ffffff" stroke="#cbd5e1" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 310 0 Q 320 0 320 10 L 320 34 L 0 34 Z" fill="#f8fafc"/>
        <text class="group-label" x="14" y="22" fill="#334155">2. Shared Memory Structures (Zero-Copy)</text>

        <!-- Command Ring -->
        <g transform="translate(14, 45)">
            <rect width="292" height="110" rx="6" fill="#f0f9ff" stroke="#7dd3fc" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#0369a1">Command Ring Buffer (Ring 0)</text>
            <text class="card-bullet" x="10" y="40" font-family="monospace">CMD_BIND_PIPELINE(pso_gpu_va)</text>
            <text class="card-bullet" x="10" y="58" font-family="monospace">CMD_BIND_DESCRIPTOR(table_va)</text>
            <text class="card-bullet" x="10" y="76" font-family="monospace">CMD_DRAW_INDIRECT(args_va)</text>
            <text class="card-bullet" x="10" y="94" font-family="monospace">CMD_BARRIER(flags) / FENCE</text>
        </g>

        <!-- In-Memory PSO -->
        <g transform="translate(14, 168)">
            <rect width="292" height="120" rx="6" fill="#fdf4ff" stroke="#f0abfc" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#a21caf">In-Memory PSO (GhciPipelineState)</text>
            <text class="card-body" x="10" y="38">• vs_code_va, fs_code_va, cs_code_va</text>
            <text class="card-body" x="10" y="54">• raster_state (cull, topology, scissor)</text>
            <text class="card-body" x="10" y="70">• blend_state (alpha blend, dual-source)</text>
            <text class="card-body" x="10" y="86">• depth_stencil (compare, mask)</text>
            <text class="card-subtitle" x="10" y="106" fill="#c026d3">Immutable Pointer Target (48 Bytes)</text>
        </g>

        <!-- Descriptor Table -->
        <g transform="translate(14, 300)">
            <rect width="292" height="105" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#b45309">Descriptor Tables &amp; Buffers</text>
            <text class="card-body" x="10" y="38">• Slot 0: Texture 2D Buffer Descriptor</text>
            <text class="card-body" x="10" y="54">• Slot 1: Sampler Filter &amp; Wrap Mode</text>
            <text class="card-body" x="10" y="70">• Slot 2: Storage Buffer (UAV / SSBO)</text>
            <text class="card-subtitle" x="10" y="92" fill="#d97706">Indexed directly by Shader Unit (SU)</text>
        </g>
    </g>

    <!-- Stage 3: GPU Command Processor & Dispatch (Right) -->
    <g transform="translate(690, 80)">
        <rect width="280" height="570" rx="10" fill="#ffffff" stroke="#c4b5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 270 0 Q 280 0 280 10 L 280 34 L 0 34 Z" fill="#f5f3ff"/>
        <text class="group-label" x="14" y="22" fill="#6d28d9">3. GPU Hardware Execution</text>

        <!-- CP Fetch & Decode -->
        <g transform="translate(12, 45)">
            <rect width="256" height="120" rx="6" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#6b21a8">Command Processor (CP)</text>
            <text class="card-body" x="10" y="38">• Fetches commands using `RING_RPTR`</text>
            <text class="card-body" x="10" y="54">• Autonomous Address Translation</text>
            <text class="card-body" x="10" y="70">• Reads In-Memory PSO directly</text>
            <text class="card-body" x="10" y="86">• Resolves Indirect Draw Arguments</text>
            <text class="card-subtitle" x="10" y="106" fill="#7c3aed">Zero Host CPU Register Overhead</text>
        </g>

        <!-- Direct Dispatch to Units -->
        <g transform="translate(12, 178)">
            <rect width="256" height="375" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="12" y="22">Hardware Pipeline Units</text>

            <g transform="translate(10, 36)">
                <rect width="236" height="50" rx="4" fill="#ecfeff" stroke="#a5f3fc" stroke-width="1"/>
                <text class="card-title" x="8" y="18" font-size="12" fill="#0891b2">VF (Vertex Fetcher)</text>
                <text class="card-body" x="8" y="34" font-size="10.5">Fetches vertices via PSO attribute layout</text>
            </g>

            <g transform="translate(10, 96)">
                <rect width="236" height="50" rx="4" fill="#fffbeb" stroke="#fde68a" stroke-width="1"/>
                <text class="card-title" x="8" y="18" font-size="12" fill="#b45309">SU (Shader Unit 32-Lane)</text>
                <text class="card-body" x="8" y="34" font-size="10.5">Executes VS / FS / CS with GSI1 64-bit</text>
            </g>

            <g transform="translate(10, 156)">
                <rect width="236" height="50" rx="4" fill="#ecfeff" stroke="#a5f3fc" stroke-width="1"/>
                <text class="card-title" x="8" y="18" font-size="12" fill="#0891b2">RX (Rasterizer)</text>
                <text class="card-body" x="8" y="34" font-size="10.5">Hierarchical Scan, Early Z, Quads</text>
            </g>

            <g transform="translate(10, 216)">
                <rect width="236" height="50" rx="4" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
                <text class="card-title" x="8" y="18" font-size="12" fill="#0369a1">TU (Texture Unit)</text>
                <text class="card-body" x="8" y="34" font-size="10.5">Direct Descriptor &amp; Filter Lookup</text>
            </g>

            <g transform="translate(10, 276)">
                <rect width="236" height="50" rx="4" fill="#fff1f2" stroke="#fecdd3" stroke-width="1"/>
                <text class="card-title" x="8" y="18" font-size="12" fill="#be123c">ROP &amp; Shared L2 Cache</text>
                <text class="card-body" x="8" y="34" font-size="10.5">Blend, Stencil, Depth, Coherent Write</text>
            </g>

            <g transform="translate(10, 335)">
                <rect width="236" height="30" rx="4" fill="#f0fdf4" stroke="#86efac" stroke-width="1"/>
                <text x="118" y="20" text-anchor="middle" font-size="11" font-weight="700" fill="#15803d">Fence / IRQ Completion</text>
            </g>
        </g>
    </g>

    <!-- Bottom Left: Slim MMIO Interaction -->
    <g transform="translate(30, 350)">
        <rect width="280" height="300" rx="10" fill="#ffffff" stroke="#e2e8f0" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 270 0 Q 280 0 280 10 L 280 34 L 0 34 Z" fill="#f8fafc"/>
        <text class="group-label" x="14" y="22" fill="#475569">Kernel Doorbell &amp; IRQ Flow</text>

        <g transform="translate(14, 45)">
            <text class="card-title" x="0" y="16">1. Ring Advance</text>
            <text class="card-body" x="0" y="34">Host writes new offset to `RING_WPTR`.</text>
            <text class="card-body" x="0" y="50">Single 32-bit MMIO write.</text>

            <text class="card-title" x="0" y="80">2. Autonomous Processing</text>
            <text class="card-body" x="0" y="98">CP runs independently without</text>
            <text class="card-body" x="0" y="114">host CPU intervention.</text>

            <text class="card-title" x="0" y="144">3. Fences &amp; Interrupts</text>
            <text class="card-body" x="0" y="162">`CMD_FENCE` writes sequence ID</text>
            <text class="card-body" x="0" y="178">to DRAM and raises IRQ line.</text>

            <text class="card-title" x="0" y="208">4. Host IRQ Handler</text>
            <text class="card-body" x="0" y="226">Reads `FENCE_STATUS`, clears bit,</text>
            <text class="card-body" x="0" y="242">and unblocks waiting thread.</text>
        </g>
    </g>

    <!-- Flow Arrows connecting stages -->
    <path fill="none" d="M 310 135 L 340 135" stroke="#2563eb" stroke-width="2" marker-end="url(#arrow-blue)"/>
    <path fill="none" d="M 310 200 L 340 200" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
    <path fill="none" d="M 660 100 L 690 100" stroke="#7c3aed" stroke-width="2.5" marker-end="url(#arrow-purple)"/>
    <path fill="none" d="M 660 220 L 685 220 L 685 130 L 690 130" stroke="#7c3aed" stroke-width="2" stroke-dasharray="3,3" marker-end="url(#arrow-purple)"/>
    <path fill="none" d="M 310 400 L 340 400 L 340 480 L 690 480" stroke="#059669" stroke-width="1.8" stroke-dasharray="4,3" marker-end="url(#arrow-emerald)"/>
</svg>
"""

def generate_ghci_command_sequence():
    """5. docs/svg/ghci_command_sequence.svg"""
    width, height = 1000, 720
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">GHCI Command Execution Swimlane Sequence</text>
        <text class="subtitle" x="0" y="40">End-to-End Execution Trace: In-Memory PSO Binding, Draw Indirect, Texture Fetch, Blend &amp; Fence</text>
        <rect x="730" y="4" width="220" height="28" rx="14" fill="#059669" opacity="0.12"/>
        <text x="840" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#047857">EXECUTION SEQUENCE</text>
    </g>

    <!-- Swimlane Columns -->
    <!-- Column 1: Host Driver -->
    <g transform="translate(40, 80)">
        <rect width="130" height="40" rx="6" fill="#eff6ff" stroke="#93c5fd" stroke-width="1.2"/>
        <text class="seq-actor" x="65" y="25" text-anchor="middle">Host Driver</text>
        <line x1="65" y1="40" x2="65" y2="600" stroke="#cbd5e1" stroke-width="1.5" stroke-dasharray="4,4"/>
    </g>

    <!-- Column 2: Shared DRAM (Ring & PSO) -->
    <g transform="translate(200, 80)">
        <rect width="140" height="40" rx="6" fill="#f0f9ff" stroke="#7dd3fc" stroke-width="1.2"/>
        <text class="seq-actor" x="70" y="25" text-anchor="middle">Shared DRAM</text>
        <line x1="70" y1="40" x2="70" y2="600" stroke="#cbd5e1" stroke-width="1.5" stroke-dasharray="4,4"/>
    </g>

    <!-- Column 3: CP Firmware & HW Walker -->
    <g transform="translate(370, 80)">
        <rect width="140" height="40" rx="6" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1.2"/>
        <text class="seq-actor" x="70" y="25" text-anchor="middle">CP (RV32IM)</text>
        <line x1="70" y1="40" x2="70" y2="600" stroke="#cbd5e1" stroke-width="1.5" stroke-dasharray="4,4"/>
    </g>

    <!-- Column 4: Geometry & Compute (VF->SU) -->
    <g transform="translate(540, 80)">
        <rect width="130" height="40" rx="6" fill="#ecfeff" stroke="#67e8f9" stroke-width="1.2"/>
        <text class="seq-actor" x="65" y="25" text-anchor="middle">VF / SU (32-Lane)</text>
        <line x1="65" y1="40" x2="65" y2="600" stroke="#cbd5e1" stroke-width="1.5" stroke-dasharray="4,4"/>
    </g>

    <!-- Column 5: Raster & Output (RX->TU->ROP) -->
    <g transform="translate(700, 80)">
        <rect width="130" height="40" rx="6" fill="#fff1f2" stroke="#fda4af" stroke-width="1.2"/>
        <text class="seq-actor" x="65" y="25" text-anchor="middle">RX / TU / ROP</text>
        <line x1="65" y1="40" x2="65" y2="600" stroke="#cbd5e1" stroke-width="1.5" stroke-dasharray="4,4"/>
    </g>

    <!-- Column 6: Shared L2C & Fence Unit -->
    <g transform="translate(850, 80)">
        <rect width="120" height="40" rx="6" fill="#ecfdf5" stroke="#86efac" stroke-width="1.2"/>
        <text class="seq-actor" x="60" y="25" text-anchor="middle">L2C / Fence</text>
        <line x1="60" y1="40" x2="60" y2="600" stroke="#cbd5e1" stroke-width="1.5" stroke-dasharray="4,4"/>
    </g>

    <!-- Sequence Steps -->

    <!-- Step 1: Host builds PSO in Shared DRAM -->
    <g transform="translate(0, 145)">
        <circle cx="105" cy="0" r="10" fill="#2563eb"/>
        <text class="seq-num" x="105" y="4" text-anchor="middle">1</text>
        <line x1="105" y1="0" x2="265" y2="0" stroke="#2563eb" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="seq-step" x="185" y="-8" text-anchor="middle">Build Immutable PSO &amp; Descriptors</text>
        <text class="seq-desc" x="185" y="16" text-anchor="middle">GhciPipelineState struct (48B) written to DRAM</text>
    </g>

    <!-- Step 2: Host writes Commands into Ring & hits Doorbell -->
    <g transform="translate(0, 210)">
        <circle cx="105" cy="0" r="10" fill="#2563eb"/>
        <text class="seq-num" x="105" y="4" text-anchor="middle">2</text>
        <line x1="105" y1="0" x2="265" y2="0" stroke="#2563eb" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="seq-step" x="185" y="-8" text-anchor="middle">Write CMD_BIND_PIPELINE + CMD_DRAW</text>

        <!-- Doorbell directly to CP -->
        <path fill="none" d="M 105 10 L 105 25 L 435 25" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="seq-step" x="270" y="38" text-anchor="middle" fill="#7c3aed">MMIO Write: RING_WPTR (Doorbell)</text>
    </g>

    <!-- Step 3: CP fetches command packet from DRAM -->
    <g transform="translate(0, 285)">
        <circle cx="440" cy="0" r="10" fill="#7c3aed"/>
        <text class="seq-num" x="440" y="4" text-anchor="middle">3</text>
        <line x1="440" y1="0" x2="275" y2="0" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="seq-step" x="355" y="-8" text-anchor="middle">Fetch Command Packet</text>
        <text class="seq-desc" x="355" y="16" text-anchor="middle">DMA Ring fetch via WPTR/RPTR</text>
    </g>

    <!-- Step 4: CP autonomous address translation & PSO read -->
    <g transform="translate(0, 345)">
        <circle cx="440" cy="0" r="10" fill="#7c3aed"/>
        <text class="seq-num" x="440" y="4" text-anchor="middle">4</text>
        <line x1="440" y1="0" x2="275" y2="0" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="seq-step" x="355" y="-8" text-anchor="middle">Autonomous Page Walk / TLB Hit</text>
        <text class="seq-desc" x="355" y="16" text-anchor="middle">Resolves PSO pointer &amp; configures HW pipeline</text>
    </g>

    <!-- Step 5: CP dispatches Draw to VF & SU -->
    <g transform="translate(0, 405)">
        <circle cx="440" cy="0" r="10" fill="#7c3aed"/>
        <text class="seq-num" x="440" y="4" text-anchor="middle">5</text>
        <line x1="440" y1="0" x2="600" y2="0" stroke="#0891b2" stroke-width="2" marker-end="url(#arrow)"/>
        <text class="seq-step" x="520" y="-8" text-anchor="middle">Dispatch Draw &amp; Pipeline State</text>
        <text class="seq-desc" x="520" y="16" text-anchor="middle">VF fetches attributes; SU runs Vertex Shader</text>
    </g>

    <!-- Step 6: SU outputs primitives to RX (Rasterizer) -->
    <g transform="translate(0, 465)">
        <circle cx="605" cy="0" r="10" fill="#0891b2"/>
        <text class="seq-num" x="605" y="4" text-anchor="middle">6</text>
        <line x1="605" y1="0" x2="760" y2="0" stroke="#0891b2" stroke-width="2" marker-end="url(#arrow)"/>
        <text class="seq-step" x="685" y="-8" text-anchor="middle">Rasterization &amp; Early Z</text>
        <text class="seq-desc" x="685" y="16" text-anchor="middle">Triangle setup, bounding box scan, 2x2 quads</text>
    </g>

    <!-- Step 7: RX & SU fragment shading + TU sampling + ROP blending -->
    <g transform="translate(0, 525)">
        <circle cx="765" cy="0" r="10" fill="#e11d48"/>
        <text class="seq-num" x="765" y="4" text-anchor="middle">7</text>
        <line x1="765" y1="0" x2="905" y2="0" stroke="#e11d48" stroke-width="2" marker-end="url(#arrow-rose)"/>
        <text class="seq-step" x="835" y="-8" text-anchor="middle">Tile Buffer &amp; L2C Flush</text>
        <text class="seq-desc" x="835" y="16" text-anchor="middle">Dual-source blend, depth test, write to LLC</text>
    </g>

    <!-- Step 8: Fence completion & Host IRQ -->
    <g transform="translate(0, 585)">
        <circle cx="910" cy="0" r="10" fill="#059669"/>
        <text class="seq-num" x="910" y="4" text-anchor="middle">8</text>
        <!-- Writeback to DRAM -->
        <line x1="910" y1="0" x2="275" y2="0" stroke="#059669" stroke-width="2" marker-end="url(#arrow-emerald)"/>
        <text class="seq-step" x="590" y="-8" text-anchor="middle" fill="#047857">Write Fence Counter to DRAM &amp; Assert IRQ Line</text>

        <!-- IRQ back to Host -->
        <path fill="none" d="M 270 12 L 105 12" stroke="#dc2626" stroke-width="2" stroke-dasharray="3,3" marker-end="url(#arrow)"/>
        <text class="seq-desc" x="185" y="28" text-anchor="middle" fill="#dc2626">Host ISR unblocks synchronization primitive</text>
    </g>
</svg>
"""

def generate_atg_top_architecture():
    """6. docs/svg/atg_top_architecture.svg"""
    width, height = 1040, 740
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">Amaterrace GPU (ATG1) SoC Top-Level Architecture</text>
        <text class="subtitle" x="0" y="40">Complete Internal Interconnect • Shared L2 Cache (LLC) • Independent 200 MHz Display Controller</text>
        <rect x="740" y="4" width="260" height="28" rx="14" fill="#1e293b" opacity="0.08"/>
        <text x="870" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#0f172a">AMATERRACE HARDWARE TO-BE</text>
    </g>

    <!-- Top: Host Bus Interface -->
    <g transform="translate(30, 78)">
        <rect width="980" height="50" rx="8" fill="#eff6ff" stroke="#93c5fd" stroke-width="1.5"/>
        <text class="card-title" x="20" y="22" fill="#1d4ed8">Host System Interconnect (AXI4-Lite Slim MMIO + AXI4-Full Coherent Memory)</text>
        <text class="card-subtitle" x="20" y="38" fill="#2563eb">Doorbell Write, Fences, Hardware Invalidation, and High-Throughput System Memory Access</text>
    </g>

    <!-- Command Processor (CP) -->
    <g transform="translate(30, 142)">
        <rect width="980" height="95" rx="8" fill="#faf5ff" stroke="#c4b5fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <text class="card-title" x="20" y="22" fill="#5b21b6">Command Processor (CP) — atg_cp</text>
        <text class="card-subtitle" x="20" y="38" fill="#7c3aed">RV32IM RISC-V Microcontroller • Hardware Page Table Walker • Unified L1/L2 TLB</text>

        <!-- Sub components -->
        <g transform="translate(20, 48)">
            <rect width="180" height="36" rx="4" fill="#ffffff" stroke="#d8b4fe" stroke-width="1"/>
            <text class="card-title" x="90" y="17" text-anchor="middle" font-size="11">RV32IM Core</text>
            <text class="card-body" x="90" y="30" text-anchor="middle" font-size="9.5">Ring Dispatch &amp; Sync</text>
        </g>
        <g transform="translate(215, 48)">
            <rect width="230" height="36" rx="4" fill="#ffffff" stroke="#d8b4fe" stroke-width="1"/>
            <text class="card-title" x="115" y="17" text-anchor="middle" font-size="11">HW Page Table Walker</text>
            <text class="card-body" x="115" y="30" text-anchor="middle" font-size="9.5">Autonomous 2-Level Walk (Host/GPU)</text>
        </g>
        <g transform="translate(460, 48)">
            <rect width="230" height="36" rx="4" fill="#ffffff" stroke="#d8b4fe" stroke-width="1"/>
            <text class="card-title" x="115" y="17" text-anchor="middle" font-size="11">Unified L1/L2 TLB</text>
            <text class="card-body" x="115" y="30" text-anchor="middle" font-size="9.5">Transparent Invalidation on Barrier</text>
        </g>
        <g transform="translate(705, 48)">
            <rect width="255" height="36" rx="4" fill="#ffffff" stroke="#d8b4fe" stroke-width="1"/>
            <text class="card-title" x="127" y="17" text-anchor="middle" font-size="11">Pipeline Dispatch Engine</text>
            <text class="card-body" x="127" y="30" text-anchor="middle" font-size="9.5">Direct Config to VF/SU/RX/ROP</text>
        </g>
    </g>

    <!-- Graphics & Compute Core (Middle Row) -->
    <g transform="translate(30, 252)">
        <rect width="980" height="200" rx="10" fill="#ffffff" stroke="#cbd5e1" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 970 0 Q 980 0 980 10 L 980 34 L 0 34 Z" fill="#f8fafc"/>
        <text class="group-label" x="20" y="22" fill="#334155">Graphics &amp; Compute Pipeline Engines</text>

        <!-- BLT: 2D Engine -->
        <g transform="translate(20, 46)">
            <rect width="130" height="140" rx="6" fill="#f0fdf4" stroke="#86efac" stroke-width="1.2"/>
            <text class="card-title" x="12" y="22" fill="#15803d">BLT (2D)</text>
            <text class="card-subtitle" x="12" y="38" fill="#16a34a">BitBLT Engine</text>
            <text class="card-body" x="12" y="60">• Fast Solid Fill</text>
            <text class="card-body" x="12" y="78">• Blit / Copy</text>
            <text class="card-body" x="12" y="96">• Format Swizzle</text>
            <text class="card-body" x="12" y="114">• DMA Transfers</text>
        </g>

        <!-- VF: Vertex Fetcher -->
        <g transform="translate(165, 46)">
            <rect width="135" height="140" rx="6" fill="#ecfeff" stroke="#67e8f9" stroke-width="1.2"/>
            <text class="card-title" x="12" y="22" fill="#0891b2">VF</text>
            <text class="card-subtitle" x="12" y="38" fill="#0e7490">Vertex Fetcher</text>
            <text class="card-body" x="12" y="60">• In-Memory PSO</text>
            <text class="card-body" x="12" y="78">• Index Unpack</text>
            <text class="card-body" x="12" y="96">• Attr Decoders</text>
            <text class="card-body" x="12" y="114">• Instancing</text>
        </g>

        <!-- SU: 32-Lane Shader Unit -->
        <g transform="translate(315, 46)">
            <rect width="180" height="140" rx="6" fill="#fffbeb" stroke="#fcd34d" stroke-width="1.2"/>
            <text class="card-title" x="12" y="22" fill="#b45309">SU (Shader Unit)</text>
            <text class="card-subtitle" x="12" y="38" fill="#d97706">32-Lane Full SIMD</text>
            <text class="card-body" x="12" y="60">• 4 Quads (32 SIMD Lanes)</text>
            <text class="card-body" x="12" y="78">• DSP48E1 FP32 FMA Cascade</text>
            <text class="card-body" x="12" y="96">• Local Data Share (LDS)</text>
            <text class="card-body" x="12" y="114">• Warp Scheduler (Scoreboard)</text>
        </g>

        <!-- RX: Rasterizer -->
        <g transform="translate(510, 46)">
            <rect width="150" height="140" rx="6" fill="#ecfeff" stroke="#67e8f9" stroke-width="1.2"/>
            <text class="card-title" x="12" y="22" fill="#0891b2">RX (Rasterizer)</text>
            <text class="card-subtitle" x="12" y="38" fill="#0e7490">Two-Level Scan</text>
            <text class="card-body" x="12" y="60">• Triangle Setup</text>
            <text class="card-body" x="12" y="78">• Coarse / Fine Scan</text>
            <text class="card-body" x="12" y="96">• Hierarchical Z-Cull</text>
            <text class="card-body" x="12" y="114">• Barycentrics &amp; Quads</text>
        </g>

        <!-- TU: Texture Unit -->
        <g transform="translate(675, 46)">
            <rect width="135" height="140" rx="6" fill="#f0f9ff" stroke="#7dd3fc" stroke-width="1.2"/>
            <text class="card-title" x="12" y="22" fill="#0369a1">TU (Sampler)</text>
            <text class="card-subtitle" x="12" y="38" fill="#0284c7">Texture Engine</text>
            <text class="card-body" x="12" y="60">• Bilinear / Trilinear</text>
            <text class="card-body" x="12" y="78">• Texture L1 Cache</text>
            <text class="card-body" x="12" y="96">• Descriptors Table</text>
            <text class="card-body" x="12" y="114">• Format Decompress</text>
        </g>

        <!-- ROP: Render Output -->
        <g transform="translate(825, 46)">
            <rect width="135" height="140" rx="6" fill="#fff1f2" stroke="#fda4af" stroke-width="1.2"/>
            <text class="card-title" x="12" y="22" fill="#be123c">ROP (Output)</text>
            <text class="card-subtitle" x="12" y="38" fill="#e11d48">Pixel Backend</text>
            <text class="card-body" x="12" y="60">• Tile Buffer</text>
            <text class="card-body" x="12" y="78">• Stencil / Depth Test</text>
            <text class="card-body" x="12" y="96">• Dual-Source Blend</text>
            <text class="card-body" x="12" y="114">• Logic Operations</text>
        </g>
    </g>

    <!-- atg_rt Interconnect Router Tree -->
    <g transform="translate(30, 467)">
        <rect width="980" height="34" rx="6" fill="#f1f5f9" stroke="#94a3b8" stroke-width="1.2"/>
        <text class="card-title" x="490" y="22" text-anchor="middle" fill="#334155" letter-spacing="1">atg_rt MEMORY ROUTER TREE (DISTRIBUTED AXI4/NOC SWITCH)</text>
    </g>

    <!-- Routing Lines down to atg_rt -->
    <line x1="115" y1="438" x2="115" y2="467" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>
    <line x1="232" y1="438" x2="232" y2="467" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>
    <line x1="405" y1="438" x2="405" y2="467" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>
    <line x1="742" y1="438" x2="742" y2="467" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>
    <line x1="892" y1="438" x2="892" y2="467" stroke="#475569" stroke-width="1.5" marker-end="url(#arrow)"/>

    <!-- Bottom Row: Shared L2C, Display Controller, MC -->
    <g transform="translate(30, 515)">
        <!-- Shared L2 Cache -->
        <g transform="translate(0, 0)">
            <rect width="680" height="110" rx="8" fill="#ecfdf5" stroke="#6ee7b7" stroke-width="1.5" filter="url(#shadow-sm)"/>
            <text class="card-title" x="20" y="24" fill="#047857">Shared L2 Cache (LLC: Last Level Cache)</text>
            <text class="card-subtitle" x="20" y="42" fill="#059669">512KB - 2MB Shared SRAM • Multi-Banked • Low-Latency On-Chip Storage</text>
            <text class="card-body" x="20" y="66">• Caches all client traffic: VF attributes, SU instruction &amp; data, TU textures, ROP tile writeback</text>
            <text class="card-body" x="20" y="84">• Integrates Write-Combining and Coherency Barrier invalidation engine</text>
        </g>

        <!-- Display Controller (DC) -->
        <g transform="translate(705, 0)">
            <rect width="275" height="110" rx="8" fill="#fdf4ff" stroke="#f0abfc" stroke-width="1.5" filter="url(#shadow-sm)"/>
            <text class="card-title" x="14" y="24" fill="#a21caf">Display Controller (DC) — atg_dc</text>
            <text class="card-subtitle" x="14" y="42" fill="#c026d3">Independent 200 MHz Pixel Clock</text>
            <text class="card-body" x="14" y="66">• High-Priority QoS Port directly into MC</text>
            <text class="card-body" x="14" y="84">• Never starved during heavy 3D rendering</text>
            <text class="card-body" x="14" y="100">• Survives GPU Quiesce and Reset</text>
        </g>
    </g>

    <!-- Memory Controller (MC) Bottom Bar -->
    <g transform="translate(30, 642)">
        <rect width="980" height="65" rx="8" fill="#1e293b" stroke="#0f172a" stroke-width="1.5"/>
        <text class="card-title" x="24" y="26" fill="#f8fafc">Memory Controller (MC) — atg_mc</text>
        <text class="card-subtitle" x="24" y="46" fill="#94a3b8">Multi-Port High-Bandwidth DRAM Interface (DDR3 / DDR4 / LPDDR4 / AXI4 Coherent UMA)</text>
        <rect x="740" y="16" width="220" height="34" rx="6" fill="#334155"/>
        <text x="850" y="38" text-anchor="middle" font-size="12" font-weight="700" fill="#38bdf8">Physical DRAM Memory</text>
    </g>

    <!-- Connections to MC -->
    <line x1="340" y1="625" x2="340" y2="642" stroke="#059669" stroke-width="2.5" marker-end="url(#arrow-emerald)"/>
    <line x1="842" y1="625" x2="842" y2="642" stroke="#c026d3" stroke-width="2.5" marker-end="url(#arrow)"/>
</svg>
"""

def generate_atg_su_32lane():
    """7. docs/svg/atg_su_32lane.svg"""
    width, height = 1020, 720
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">Amaterrace Shader Unit (SU) — 32-Lane SIMD Architecture</text>
        <text class="subtitle" x="0" y="40">4 Quads (32 SIMD Lanes) • GSI1 64-bit ISA • Full-Width DSP48E1 FP32 FMA Cascade • LDS Scratchpad</text>
        <rect x="750" y="4" width="240" height="28" rx="14" fill="#d97706" opacity="0.12"/>
        <text x="870" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#b45309">32-LANE FULL IMPLEMENTATION</text>
    </g>

    <!-- Top Frontend: Instruction & Warp Management -->
    <g transform="translate(30, 80)">
        <rect width="960" height="120" rx="10" fill="#ffffff" stroke="#fcd34d" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 950 0 Q 960 0 960 10 L 960 32 L 0 32 Z" fill="#fffbeb"/>
        <text class="group-label" x="18" y="21" fill="#b45309">Frontend &amp; Warp Scheduling (GSI1 64-bit ISA)</text>

        <!-- Sub components -->
        <g transform="translate(18, 44)">
            <rect width="210" height="62" rx="6" fill="#fef3c7" stroke="#fde68a" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#92400e">Instruction Cache (I$)</text>
            <text class="card-body" x="12" y="38">• 16KB Multi-Way L1 I$</text>
            <text class="card-body" x="12" y="52">• 64-bit Instruction Pre-fetch</text>
        </g>

        <g transform="translate(244, 44)">
            <rect width="230" height="62" rx="6" fill="#fef3c7" stroke="#fde68a" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#92400e">Warp Scheduler &amp; Scoreboard</text>
            <text class="card-body" x="12" y="38">• 8 - 16 Warps in flight</text>
            <text class="card-body" x="12" y="52">• Zero-Cycle Context Switch</text>
        </g>

        <g transform="translate(490, 44)">
            <rect width="230" height="62" rx="6" fill="#fef3c7" stroke="#fde68a" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#92400e">Branch &amp; Divergence Stack</text>
            <text class="card-body" x="12" y="38">• Per-Lane Execution Mask (32-bit)</text>
            <text class="card-body" x="12" y="52">• Hardware Re-convergence IP</text>
        </g>

        <g transform="translate(736, 44)">
            <rect width="206" height="62" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#0369a1">Texture Fetch FIFO</text>
            <text class="card-body" x="12" y="38">• Non-blocking Sample Requests</text>
            <text class="card-body" x="12" y="52">• Direct link to TU Engine</text>
        </g>
    </g>

    <!-- Middle: 32-Lane SIMD Execution Array (4 Quads) -->
    <g transform="translate(30, 215)">
        <rect width="960" height="340" rx="10" fill="#ffffff" stroke="#cbd5e1" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 950 0 Q 960 0 960 10 L 960 32 L 0 32 Z" fill="#f8fafc"/>
        <text class="group-label" x="18" y="21" fill="#334155">32 SIMD Lanes Execution Array (4 Quads × 8 Lanes)</text>

        <!-- Quad 0 -->
        <g transform="translate(18, 44)">
            <rect width="220" height="280" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1.2"/>
            <text class="card-title" x="14" y="22" fill="#b45309">QUAD 0 (Lanes 0 - 7)</text>
            <text class="card-subtitle" x="14" y="38" fill="#d97706">8 SIMD Compute Units</text>

            <g transform="translate(10, 48)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Register File (GPR)</text>
                <text class="card-body" x="10" y="34" font-size="10">32 Regs/Lane × Warps</text>
            </g>
            <g transform="translate(10, 104)">
                <rect width="200" height="54" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">FP32 FMA / am_mul</text>
                <text class="card-body" x="10" y="32" font-size="10">DSP48E1 24×17 Cascade</text>
                <text class="card-body" x="10" y="46" font-size="10">1 Cycle Throughput</text>
            </g>
            <g transform="translate(10, 166)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Integer ALU &amp; Bitwise</text>
                <text class="card-body" x="10" y="34" font-size="10">Add, Sub, Shift, Logic, Cmp</text>
            </g>
            <g transform="translate(10, 222)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Special Function (SFU)</text>
                <text class="card-body" x="10" y="34" font-size="10">Rcp, Rsqrt, Sin, Cos</text>
            </g>
        </g>

        <!-- Quad 1 -->
        <g transform="translate(254, 44)">
            <rect width="220" height="280" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1.2"/>
            <text class="card-title" x="14" y="22" fill="#b45309">QUAD 1 (Lanes 8 - 15)</text>
            <text class="card-subtitle" x="14" y="38" fill="#d97706">8 SIMD Compute Units</text>

            <g transform="translate(10, 48)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Register File (GPR)</text>
                <text class="card-body" x="10" y="34" font-size="10">32 Regs/Lane × Warps</text>
            </g>
            <g transform="translate(10, 104)">
                <rect width="200" height="54" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">FP32 FMA / am_mul</text>
                <text class="card-body" x="10" y="32" font-size="10">DSP48E1 24×17 Cascade</text>
                <text class="card-body" x="10" y="46" font-size="10">1 Cycle Throughput</text>
            </g>
            <g transform="translate(10, 166)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Integer ALU &amp; Bitwise</text>
                <text class="card-body" x="10" y="34" font-size="10">Add, Sub, Shift, Logic, Cmp</text>
            </g>
            <g transform="translate(10, 222)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Special Function (SFU)</text>
                <text class="card-body" x="10" y="34" font-size="10">Rcp, Rsqrt, Sin, Cos</text>
            </g>
        </g>

        <!-- Quad 2 -->
        <g transform="translate(490, 44)">
            <rect width="220" height="280" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1.2"/>
            <text class="card-title" x="14" y="22" fill="#b45309">QUAD 2 (Lanes 16 - 23)</text>
            <text class="card-subtitle" x="14" y="38" fill="#d97706">8 SIMD Compute Units</text>

            <g transform="translate(10, 48)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Register File (GPR)</text>
                <text class="card-body" x="10" y="34" font-size="10">32 Regs/Lane × Warps</text>
            </g>
            <g transform="translate(10, 104)">
                <rect width="200" height="54" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">FP32 FMA / am_mul</text>
                <text class="card-body" x="10" y="32" font-size="10">DSP48E1 24×17 Cascade</text>
                <text class="card-body" x="10" y="46" font-size="10">1 Cycle Throughput</text>
            </g>
            <g transform="translate(10, 166)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Integer ALU &amp; Bitwise</text>
                <text class="card-body" x="10" y="34" font-size="10">Add, Sub, Shift, Logic, Cmp</text>
            </g>
            <g transform="translate(10, 222)">
                <rect width="200" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Special Function (SFU)</text>
                <text class="card-body" x="10" y="34" font-size="10">Rcp, Rsqrt, Sin, Cos</text>
            </g>
        </g>

        <!-- Quad 3 -->
        <g transform="translate(726, 44)">
            <rect width="216" height="280" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1.2"/>
            <text class="card-title" x="14" y="22" fill="#b45309">QUAD 3 (Lanes 24 - 31)</text>
            <text class="card-subtitle" x="14" y="38" fill="#d97706">8 SIMD Compute Units</text>

            <g transform="translate(10, 48)">
                <rect width="196" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Register File (GPR)</text>
                <text class="card-body" x="10" y="34" font-size="10">32 Regs/Lane × Warps</text>
            </g>
            <g transform="translate(10, 104)">
                <rect width="196" height="54" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">FP32 FMA / am_mul</text>
                <text class="card-body" x="10" y="32" font-size="10">DSP48E1 24×17 Cascade</text>
                <text class="card-body" x="10" y="46" font-size="10">1 Cycle Throughput</text>
            </g>
            <g transform="translate(10, 166)">
                <rect width="196" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Integer ALU &amp; Bitwise</text>
                <text class="card-body" x="10" y="34" font-size="10">Add, Sub, Shift, Logic, Cmp</text>
            </g>
            <g transform="translate(10, 222)">
                <rect width="196" height="48" rx="4" fill="#ffffff" stroke="#fcd34d" stroke-width="1"/>
                <text class="card-title" x="10" y="18" font-size="11.5">Special Function (SFU)</text>
                <text class="card-body" x="10" y="34" font-size="10">Rcp, Rsqrt, Sin, Cos</text>
            </g>
        </g>
    </g>

    <!-- Bottom: LDS, Data Cache & Memory Subsystem -->
    <g transform="translate(30, 570)">
        <rect width="960" height="120" rx="10" fill="#ffffff" stroke="#6ee7b7" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 950 0 Q 960 0 960 10 L 960 32 L 0 32 Z" fill="#ecfdf5"/>
        <text class="group-label" x="18" y="21" fill="#047857">Memory &amp; Local Storage (LDS / Data Cache / L2C)</text>

        <g transform="translate(18, 44)">
            <rect width="290" height="62" rx="6" fill="#f0fdf4" stroke="#a7f3d0" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#065f46">Local Data Share (LDS / Scratchpad)</text>
            <text class="card-body" x="12" y="38">• 32KB Multi-Banked High-Speed SRAM</text>
            <text class="card-body" x="12" y="52">• Zero bank-conflict cross-lane data sharing</text>
        </g>

        <g transform="translate(322, 44)">
            <rect width="300" height="62" rx="6" fill="#f0fdf4" stroke="#a7f3d0" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#065f46">L1 Data Cache &amp; Load/Store Unit (LSU)</text>
            <text class="card-body" x="12" y="38">• 32-Lane Memory Access Coalescing Engine</text>
            <text class="card-body" x="12" y="52">• Coalesces contiguous 32-bit accesses into burst</text>
        </g>

        <g transform="translate(636, 44)">
            <rect width="306" height="62" rx="6" fill="#f0fdf4" stroke="#a7f3d0" stroke-width="1"/>
            <text class="card-title" x="12" y="20" fill="#065f46">Shared L2 Cache (LLC) Interface</text>
            <text class="card-body" x="12" y="38">• Unified AXI4-Coherent Client Port</text>
            <text class="card-body" x="12" y="52">• Hardware-enforced cache invalidation on barrier</text>
        </g>
    </g>
</svg>
"""

def generate_atg_rx_rasterizer():
    """8. docs/svg/atg_rx_rasterizer.svg"""
    width, height = 980, 640
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">Amaterrace Rasterizer Unit (RX) Internal Pipeline</text>
        <text class="subtitle" x="0" y="40">Triangle Setup • Two-Level Hierarchical Scan • Early Z-Cull • Perspective Barycentric Interpolation</text>
        <rect x="740" y="4" width="210" height="28" rx="14" fill="#0891b2" opacity="0.12"/>
        <text x="845" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#0e7490">RX RASTERIZER PIPELINE</text>
    </g>

    <!-- Pipeline Stages Horizontal Flow -->

    <!-- Stage 1: Triangle Setup & Bounding Box (Left) -->
    <g transform="translate(30, 80)">
        <rect width="210" height="520" rx="10" fill="#ffffff" stroke="#67e8f9" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 200 0 Q 210 0 210 10 L 210 36 L 0 36 Z" fill="#ecfeff"/>
        <text class="group-label" x="14" y="24" fill="#0e7490">1. Primitive Setup</text>

        <g transform="translate(12, 50)">
            <rect width="186" height="75" rx="6" fill="#f0fdf4" stroke="#86efac" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#15803d">Vertex Ingestion</text>
            <text class="card-body" x="10" y="38">• Streams from Vertex Shader</text>
            <text class="card-body" x="10" y="54">• Assembles Triangles &amp; Strips</text>
            <text class="card-body" x="10" y="70">• Clip &amp; Viewport Transform</text>
        </g>

        <g transform="translate(12, 140)">
            <rect width="186" height="135" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#0369a1">Triangle Setup Engine</text>
            <text class="card-body" x="10" y="40">• Edge Equations:</text>
            <text class="card-bullet" x="16" y="56">E0: A0·x + B0·y + C0</text>
            <text class="card-bullet" x="16" y="72">E1: A1·x + B1·y + C1</text>
            <text class="card-bullet" x="16" y="88">E2: A2·x + B2·y + C2</text>
            <text class="card-body" x="10" y="108">• Area computation (2×Area)</text>
            <text class="card-body" x="10" y="124">• Back-face culling test</text>
        </g>

        <g transform="translate(12, 290)">
            <rect width="186" height="110" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Bounding Box</text>
            <text class="card-body" x="10" y="38">• Computes [Xmin, Xmax]</text>
            <text class="card-body" x="10" y="54">• Computes [Ymin, Ymax]</text>
            <text class="card-body" x="10" y="70">• Clamps to Scissor Rect</text>
            <text class="card-body" x="10" y="94" font-weight="600" fill="#0891b2">Generates Tile Stream</text>
        </g>
    </g>

    <!-- Stage 2: Coarse Rasterizer & Early Z-Cull (Center-Left) -->
    <g transform="translate(265, 80)">
        <rect width="210" height="520" rx="10" fill="#ffffff" stroke="#67e8f9" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 200 0 Q 210 0 210 10 L 210 36 L 0 36 Z" fill="#ecfeff"/>
        <text class="group-label" x="14" y="24" fill="#0e7490">2. Coarse Scan &amp; Z</text>

        <g transform="translate(12, 50)">
            <rect width="186" height="110" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#0369a1">Coarse Tile Walker</text>
            <text class="card-body" x="10" y="38">• Walks 8×8 or 16×16 tiles</text>
            <text class="card-body" x="10" y="54">• Tests corner equations</text>
            <text class="card-body" x="10" y="70">• Fast-rejects exterior tiles</text>
            <text class="card-body" x="10" y="94" font-weight="600" fill="#0284c7">Fast-accepts interior tiles</text>
        </g>

        <g transform="translate(12, 175)">
            <rect width="186" height="165" rx="6" fill="#fef2f2" stroke="#fca5a5" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#b91c1c">Early Z-Cull Engine</text>
            <text class="card-body" x="10" y="38">• Hierarchical Z (Hi-Z) RAM</text>
            <text class="card-body" x="10" y="54">• Compares nearest tile Z</text>
            <text class="card-body" x="10" y="70">  against coarse depth buffer</text>
            <text class="card-body" x="10" y="92" font-weight="700" fill="#dc2626">• Discards 50-80%</text>
            <text class="card-body" x="10" y="108" font-weight="700" fill="#dc2626">  of occluded fragments</text>
            <text class="card-body" x="10" y="128">• Bypasses downstream</text>
            <text class="card-body" x="10" y="144">  fragment shading load</text>
        </g>

        <g transform="translate(12, 355)">
            <rect width="186" height="75" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Tile Active Mask</text>
            <text class="card-body" x="10" y="38">• Compresses active tiles</text>
            <text class="card-body" x="10" y="54">• Dispatches to Fine Scan</text>
        </g>
    </g>

    <!-- Stage 3: Fine Rasterizer & Quad Generation (Center-Right) -->
    <g transform="translate(500, 80)">
        <rect width="210" height="520" rx="10" fill="#ffffff" stroke="#67e8f9" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 200 0 Q 210 0 210 10 L 210 36 L 0 36 Z" fill="#ecfeff"/>
        <text class="group-label" x="14" y="24" fill="#0e7490">3. Fine Scan (2×2)</text>

        <g transform="translate(12, 50)">
            <rect width="186" height="110" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#0369a1">Quad Generator</text>
            <text class="card-body" x="10" y="38">• Evaluates sub-tile 2×2 pixels</text>
            <text class="card-body" x="10" y="54">• 4 sample points evaluated</text>
            <text class="card-body" x="10" y="70">  in parallel</text>
            <text class="card-body" x="10" y="94" font-weight="600" fill="#0284c7">Generates 4-bit Pixel Mask</text>
        </g>

        <g transform="translate(12, 175)">
            <rect width="186" height="135" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#b45309">Barycentric Unit</text>
            <text class="card-body" x="10" y="38">• Fixed-point interpolation:</text>
            <text class="card-bullet" x="16" y="54">λ0 = E0(x, y) / Area</text>
            <text class="card-bullet" x="16" y="70">λ1 = E1(x, y) / Area</text>
            <text class="card-bullet" x="16" y="86">λ2 = 1.0 - λ0 - λ1</text>
            <text class="card-body" x="10" y="108">• Perspective-correct (1/W)</text>
            <text class="card-body" x="10" y="124">• Sub-pixel precision (1/16th)</text>
        </g>

        <g transform="translate(12, 325)">
            <rect width="186" height="105" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Attribute Interpolator</text>
            <text class="card-body" x="10" y="38">• Interpolates UV (Texture)</text>
            <text class="card-body" x="10" y="54">• Interpolates Normals &amp; Colors</text>
            <text class="card-body" x="10" y="70">• Interpolates Depth Z</text>
        </g>
    </g>

    <!-- Stage 4: Fragment Output & Dispatch (Right) -->
    <g transform="translate(735, 80)">
        <rect width="215" height="520" rx="10" fill="#ffffff" stroke="#67e8f9" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 205 0 Q 215 0 215 10 L 215 36 L 0 36 Z" fill="#ecfeff"/>
        <text class="group-label" x="14" y="24" fill="#0e7490">4. Quad Output</text>

        <g transform="translate(12, 50)">
            <rect width="191" height="120" rx="6" fill="#faf5ff" stroke="#d8b4fe" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#6b21a8">Fragment Quad Pack</text>
            <text class="card-body" x="10" y="38">• 2×2 Pixel Fragment Pack</text>
            <text class="card-body" x="10" y="54">• Active lane coverage mask</text>
            <text class="card-body" x="10" y="70">• Screen coordinates (X, Y)</text>
            <text class="card-body" x="10" y="86">• Depth &amp; Stencil values</text>
            <text class="card-body" x="10" y="102">• Interpolated varying attrs</text>
        </g>

        <g transform="translate(12, 185)">
            <rect width="191" height="145" rx="6" fill="#fffbeb" stroke="#fcd34d" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#b45309">Dispatch to SU / Warp</text>
            <text class="card-body" x="10" y="38">• Groups quads into 32-lane</text>
            <text class="card-body" x="10" y="54">  warps (8 quads = 32 pixels)</text>
            <text class="card-body" x="10" y="74">• Dispatches to Fragment</text>
            <text class="card-body" x="10" y="90">  Shader Warp Queue</text>
            <rect x="8" y="110" width="175" height="24" rx="4" fill="#fef3c7"/>
            <text x="95" y="126" text-anchor="middle" font-size="10.5" font-weight="700" fill="#92400e">Direct to SU Engine</text>
        </g>

        <g transform="translate(12, 345)">
            <rect width="191" height="110" rx="6" fill="#fff1f2" stroke="#fda4af" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#be123c">Early Z Bypass to ROP</text>
            <text class="card-body" x="10" y="38">• Feeds pre-calculated Z</text>
            <text class="card-body" x="10" y="54">  to ROP Tile Buffer for</text>
            <text class="card-body" x="10" y="70">  early depth buffer updates</text>
            <text class="card-body" x="10" y="92" font-weight="600" fill="#e11d48">Synchronized Depth Pass</text>
        </g>
    </g>

    <!-- Connectors between stages -->
    <path fill="none" d="M 240 200 L 265 200" stroke="#0891b2" stroke-width="2.5" marker-end="url(#arrow)"/>
    <path fill="none" d="M 475 200 L 500 200" stroke="#0891b2" stroke-width="2.5" marker-end="url(#arrow)"/>
    <path fill="none" d="M 710 200 L 735 200" stroke="#0891b2" stroke-width="2.5" marker-end="url(#arrow)"/>
</svg>
"""

def generate_atg_rop_backend():
    """9. docs/svg/atg_rop_backend.svg"""
    width, height = 980, 640
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <style>{COMMON_STYLE}</style>
    {DEFS_COMMON}

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 24)">
        <text class="title" x="0" y="20">Amaterrace Render Output Unit (ROP) Architecture</text>
        <text class="subtitle" x="0" y="40">On-Chip Tile Buffer • Stencil &amp; Depth Test • Dual-Source Alpha Blending • Shared L2 Cache Writeback</text>
        <rect x="730" y="4" width="220" height="28" rx="14" fill="#e11d48" opacity="0.12"/>
        <text x="840" y="23" text-anchor="middle" font-size="12" font-weight="700" fill="#be123c">ROP RENDER BACKEND</text>
    </g>

    <!-- Stage 1: Fragment Input FIFO & Tile Buffer (Left) -->
    <g transform="translate(30, 80)">
        <rect width="210" height="520" rx="10" fill="#ffffff" stroke="#fda4af" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 200 0 Q 210 0 210 10 L 210 36 L 0 36 Z" fill="#fff1f2"/>
        <text class="group-label" x="14" y="24" fill="#be123c">1. Fragment Ingestion</text>

        <g transform="translate(12, 50)">
            <rect width="186" height="110" rx="6" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#0369a1">Fragment Input FIFO</text>
            <text class="card-body" x="10" y="38">• Shaded pixel color (RGBA)</text>
            <text class="card-body" x="10" y="54">• Dual-source color 1 (RGBA1)</text>
            <text class="card-body" x="10" y="70">• Interpolated depth (Z)</text>
            <text class="card-body" x="10" y="86">• Coverage mask &amp; Stencil ref</text>
        </g>

        <!-- Tile Buffer -->
        <g transform="translate(12, 175)">
            <rect width="186" height="180" rx="6" fill="#fff1f2" stroke="#fca5a5" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#be123c">On-Chip Tile Buffer</text>
            <text class="card-subtitle" x="10" y="36" fill="#e11d48">Fast Multi-Banked SRAM</text>
            <text class="card-body" x="10" y="58">• Holds active tile depth,</text>
            <text class="card-body" x="10" y="74">  stencil, and color buffers</text>
            <text class="card-body" x="10" y="94">• Single-cycle read-modify-</text>
            <text class="card-body" x="10" y="110">  write operations</text>
            <text class="card-body" x="10" y="130">• Eliminates DRAM read traffic</text>
            <text class="card-body" x="10" y="146">  during heavy blend/depth</text>
            <text class="card-subtitle" x="10" y="166" fill="#be123c">8×8 / 16×16 Tile Size</text>
        </g>

        <g transform="translate(12, 370)">
            <rect width="186" height="75" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Tile State Tracker</text>
            <text class="card-body" x="10" y="38">• Tracks dirty lines &amp; tags</text>
            <text class="card-body" x="10" y="54">• Triggers auto writeback</text>
        </g>
    </g>

    <!-- Stage 2: Stencil & Depth Test Units (Center-Left) -->
    <g transform="translate(265, 80)">
        <rect width="210" height="520" rx="10" fill="#ffffff" stroke="#fda4af" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 200 0 Q 210 0 210 10 L 210 36 L 0 36 Z" fill="#fff1f2"/>
        <text class="group-label" x="14" y="24" fill="#be123c">2. Stencil &amp; Depth</text>

        <!-- Stencil Test Unit -->
        <g transform="translate(12, 50)">
            <rect width="186" height="155" rx="6" fill="#fdf4ff" stroke="#f0abfc" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#a21caf">Stencil Test Unit</text>
            <text class="card-body" x="10" y="38">• Front / Back Stencil state</text>
            <text class="card-body" x="10" y="54">• Compare functions (NEVER,</text>
            <text class="card-body" x="10" y="70">  LESS, EQUAL, ALWAYS, etc.)</text>
            <text class="card-body" x="10" y="90">• Ops: KEEP, ZERO, REPLACE,</text>
            <text class="card-body" x="10" y="106">  INCR, DECR, INVERT</text>
            <text class="card-body" x="10" y="126">• Stencil write mask support</text>
            <text class="card-subtitle" x="10" y="146" fill="#c026d3">Per-Pixel Pass/Fail Flag</text>
        </g>

        <!-- Depth Test Unit -->
        <g transform="translate(12, 220)">
            <rect width="186" height="155" rx="6" fill="#f0fdf4" stroke="#86efac" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#15803d">Depth Test Unit</text>
            <text class="card-body" x="10" y="38">• Standard 24-bit / 32-bit</text>
            <text class="card-body" x="10" y="54">  fixed / float depth test</text>
            <text class="card-body" x="10" y="74">• Compare funcs (LESS, LEQUAL,</text>
            <text class="card-body" x="10" y="90">  GREATER, EQUAL, etc.)</text>
            <text class="card-body" x="10" y="110">• Depth write enable mask</text>
            <text class="card-body" x="10" y="126">• Updates Tile Buffer depth</text>
            <text class="card-subtitle" x="10" y="146" fill="#16a34a">Late Z Reject Gate</text>
        </g>
    </g>

    <!-- Stage 3: Color Blending & Logic Op (Center-Right) -->
    <g transform="translate(500, 80)">
        <rect width="210" height="520" rx="10" fill="#ffffff" stroke="#fda4af" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 200 0 Q 210 0 210 10 L 210 36 L 0 36 Z" fill="#fff1f2"/>
        <text class="group-label" x="14" y="24" fill="#be123c">3. Color Blend &amp; Logic</text>

        <!-- Color Blender -->
        <g transform="translate(12, 50)">
            <rect width="186" height="175" rx="6" fill="#fffbeb" stroke="#fde68a" stroke-width="1.2"/>
            <text class="card-title" x="10" y="20" fill="#b45309">Color Blender Engine</text>
            <text class="card-body" x="10" y="38">• Blend Factors: ZERO, ONE,</text>
            <text class="card-body" x="10" y="54">  SRC_ALPHA, ONE_MINUS_SRC,</text>
            <text class="card-body" x="10" y="70">  DST_ALPHA, CONST_COLOR</text>
            <text class="card-body" x="10" y="90">• Equations: ADD, SUBTRACT,</text>
            <text class="card-body" x="10" y="106">  REVERSE_SUB, MIN, MAX</text>
            <text class="card-body" x="10" y="126" font-weight="700" fill="#d97706">• Dual-Source Blending:</text>
            <text class="card-body" x="10" y="142">  Src0, Src1, Dst alpha blending</text>
            <text class="card-subtitle" x="10" y="164" fill="#b45309">Vulkan 1.3 Conforming</text>
        </g>

        <!-- Logic Operations -->
        <g transform="translate(12, 240)">
            <rect width="186" height="135" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Logic Operation Unit</text>
            <text class="card-body" x="10" y="38">• Vulkan LogicOp modes:</text>
            <text class="card-body" x="10" y="54">  CLEAR, AND, AND_REVERSE,</text>
            <text class="card-body" x="10" y="70">  COPY, AND_INVERTED, NOOP,</text>
            <text class="card-body" x="10" y="86">  XOR, OR, NOR, EQUIV, INVERT</text>
            <text class="card-body" x="10" y="102">• Bitwise ROP2/ROP3 modes</text>
            <text class="card-subtitle" x="10" y="124" fill="#475569">Bypasses Blend if Active</text>
        </g>
    </g>

    <!-- Stage 4: Writeback & L2 Cache Interface (Right) -->
    <g transform="translate(735, 80)">
        <rect width="215" height="520" rx="10" fill="#ffffff" stroke="#fda4af" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 10 Q 0 0 10 0 L 205 0 Q 215 0 215 10 L 215 36 L 0 36 Z" fill="#fff1f2"/>
        <text class="group-label" x="14" y="24" fill="#be123c">4. Memory Writeback</text>

        <!-- Write Combiner -->
        <g transform="translate(12, 50)">
            <rect width="191" height="110" rx="6" fill="#f0fdf4" stroke="#86efac" stroke-width="1"/>
            <text class="card-title" x="10" y="20" fill="#15803d">Write Combiner</text>
            <text class="card-body" x="10" y="38">• Merges active tile pixels</text>
            <text class="card-body" x="10" y="54">• Coalesces writes into</text>
            <text class="card-body" x="10" y="70">  64-byte / 128-byte bursts</text>
            <text class="card-body" x="10" y="94" font-weight="600" fill="#166534">Minimizes Bus Overhead</text>
        </g>

        <!-- Color Compression -->
        <g transform="translate(12, 175)">
            <rect width="191" height="110" rx="6" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1"/>
            <text class="card-title" x="10" y="20">Tile Compression (Lossless)</text>
            <text class="card-body" x="10" y="38">• Fast clear flag optimization</text>
            <text class="card-body" x="10" y="54">• 2:1 / 4:1 Tile delta compression</text>
            <text class="card-body" x="10" y="70">• Reduces memory bandwidth</text>
            <text class="card-subtitle" x="10" y="94" fill="#475569">Bandwidth Saver</text>
        </g>

        <!-- Shared L2C Writeback -->
        <g transform="translate(12, 300)">
            <rect width="191" height="145" rx="6" fill="#ecfdf5" stroke="#6ee7b7" stroke-width="1.5"/>
            <text class="card-title" x="10" y="22" fill="#047857">Shared L2 Cache Flush</text>
            <text class="card-body" x="10" y="42">• Writes directly into Shared</text>
            <text class="card-body" x="10" y="58">  L2 Cache (LLC)</text>
            <text class="card-body" x="10" y="78">• Coherent writeback prevents</text>
            <text class="card-body" x="10" y="94">  DRAM page-churn</text>
            <text class="card-body" x="10" y="112">• Readily available for DC</text>
            <text class="card-body" x="10" y="128">  scanout or texture sampling</text>
        </g>
    </g>

    <!-- Connectors between stages -->
    <path fill="none" d="M 240 200 L 265 200" stroke="#be123c" stroke-width="2.5" marker-end="url(#arrow-rose)"/>
    <path fill="none" d="M 475 200 L 500 200" stroke="#be123c" stroke-width="2.5" marker-end="url(#arrow-rose)"/>
    <path fill="none" d="M 710 200 L 735 200" stroke="#be123c" stroke-width="2.5" marker-end="url(#arrow-rose)"/>
</svg>
"""

def generate_atg_data_paths():
    width, height = 1040, 770
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}">
    <defs>
        <!-- Dropshadow Filters -->
        <filter id="shadow-sm" x="-4%" y="-4%" width="108%" height="108%" filterUnits="userSpaceOnUse">
            <feDropShadow dx="0" dy="1.5" stdDeviation="2" flood-color="#0f172a" flood-opacity="0.06"/>
        </filter>
        <filter id="shadow-md" x="-6%" y="-6%" width="112%" height="112%" filterUnits="userSpaceOnUse">
            <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#0f172a" flood-opacity="0.08"/>
        </filter>

        <!-- Arrow Markers -->
        <marker id="arrow-blue" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#0284c7"/>
        </marker>
        <marker id="arrow-emerald" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#059669"/>
        </marker>
        <marker id="arrow-purple" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#7c3aed"/>
        </marker>
        <marker id="arrow-amber" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#d97706"/>
        </marker>
        <marker id="arrow-rose" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M 0 1.5 L 8 5 L 0 8.5 z" fill="#e11d48"/>
        </marker>
    </defs>

    <style><![CDATA[
        text {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
        }}
        .title {{
            font-size: 20px;
            font-weight: 700;
            fill: #0f172a;
        }}
        .subtitle {{
            font-size: 13px;
            font-weight: 500;
            fill: #475569;
        }}
        .sec-title {{
            font-size: 12px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }}
        .card-title {{
            font-size: 12px;
            font-weight: 700;
            fill: #1e293b;
        }}
        .card-sub {{
            font-size: 9.5px;
            font-weight: 600;
            fill: #64748b;
        }}
        .card-desc {{
            font-size: 9px;
            font-weight: 400;
            fill: #475569;
        }}
        .flow-label {{
            font-size: 9px;
            font-weight: 600;
            fill: #334155;
        }}
        .highlight-text {{
            font-size: 9.5px;
            font-weight: 700;
        }}
    ]]></style>

    <!-- Background Canvas -->
    <rect width="{width}" height="{height}" fill="#f8fafc" rx="12"/>
    <rect x="1" y="1" width="{width-2}" height="{height-2}" fill="none" stroke="#e2e8f0" stroke-width="1.5" rx="11"/>

    <!-- Header Block -->
    <g transform="translate(30, 22)">
        <text class="title" x="0" y="20">Amaterrace GPU Execution Data Paths</text>
        <text class="subtitle" x="0" y="38">Hardware Streaming Dataflow: 3D Graphics, 2D Blit, Systolic Matrix Acceleration, and Display Scanout</text>
        <rect x="760" y="4" width="220" height="26" rx="13" fill="#1e293b" opacity="0.08"/>
        <text x="870" y="21" text-anchor="middle" font-size="11" font-weight="700" fill="#0f172a">EXECUTION DATAPATHS</text>
    </g>

    <!-- ============================================================== -->
    <!-- 1. 3D GRAPHICS PIPELINE                                        -->
    <!-- ============================================================== -->
    <g transform="translate(25, 72)">
        <rect width="990" height="255" rx="8" fill="#f0f9ff" stroke="#bae6fd" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <!-- Section Header Banner -->
        <path d="M 0 8 Q 0 0 8 0 L 982 0 Q 990 0 990 8 L 990 28 L 0 28 Z" fill="#0284c7"/>
        <text class="sec-title" x="15" y="19" fill="#ffffff">1. 3D Graphics Pipeline (Geometry → Setup &amp; Raster → Fragment &amp; Texture → Tile Blend &amp; Cache Writeback)</text>

        <!-- Block 1: CP -->
        <g transform="translate(15, 42)">
            <rect width="95" height="110" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="95" height="22" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="47" y="15" text-anchor="middle" fill="#0369a1">CP</text>
            <text class="card-sub" x="47" y="36" text-anchor="middle">Command Dispatch</text>
            <text class="card-desc" x="47" y="52" text-anchor="middle">• Ring Fetcher</text>
            <text class="card-desc" x="47" y="66" text-anchor="middle">• Immutable PSO</text>
            <text class="card-desc" x="47" y="80" text-anchor="middle">• Draw Packet</text>
            <text class="card-desc" x="47" y="94" text-anchor="middle">• HW Page Walk</text>
        </g>

        <!-- Arrow CP -> VF -->
        <path d="M 110 97 L 133 97" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="122" y="90" text-anchor="middle">Draw</text>

        <!-- Block 2: VF -->
        <g transform="translate(135, 42)">
            <rect width="110" height="110" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="110" height="22" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="55" y="15" text-anchor="middle" fill="#0369a1">VF</text>
            <text class="card-sub" x="55" y="36" text-anchor="middle">Vertex Fetch &amp; PT-VC</text>
            <text class="card-desc" x="55" y="52" text-anchor="middle">• 4-Stream DMA</text>
            <text class="card-desc" x="55" y="66" text-anchor="middle">• 32-Entry PT-VC</text>
            <text class="card-desc" x="55" y="80" text-anchor="middle" fill="#0284c7" font-weight="700">78% Shader Bypass</text>
            <text class="card-desc" x="55" y="94" text-anchor="middle">• Primitive Asm</text>
        </g>

        <!-- Arrow VF -> SU (VS) -->
        <path d="M 245 97 L 268 97" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="256" y="90" text-anchor="middle">Attribs</text>

        <!-- Block 3: SU (Vertex Shader) -->
        <g transform="translate(270, 42)">
            <rect width="115" height="110" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="115" height="22" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="57" y="15" text-anchor="middle" fill="#0369a1">SU (Vertex Shader)</text>
            <text class="card-sub" x="57" y="36" text-anchor="middle">32-Thread SIMT Warp</text>
            <text class="card-desc" x="57" y="52" text-anchor="middle">• Scalar PE Array</text>
            <text class="card-desc" x="57" y="66" text-anchor="middle">• True 6-Stage Pipe</text>
            <text class="card-desc" x="57" y="80" text-anchor="middle">• DSP48E1 am_mul</text>
            <text class="card-desc" x="57" y="94" text-anchor="middle">• Clip / Position</text>
        </g>

        <!-- Arrow SU (VS) -> RX -->
        <path d="M 385 97 L 408 97" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="396" y="90" text-anchor="middle">Clip Pos</text>

        <!-- Block 4: RX -->
        <g transform="translate(410, 42)">
            <rect width="135" height="110" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="135" height="22" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="67" y="15" text-anchor="middle" fill="#0369a1">RX (Rasterizer)</text>
            <text class="card-sub" x="67" y="36" text-anchor="middle">Setup &amp; Coarse Raster</text>
            <text class="card-desc" x="67" y="52" text-anchor="middle">• 1-cyc Setup Pipeline</text>
            <text class="card-desc" x="67" y="66" text-anchor="middle" fill="#0284c7" font-weight="700">8×8 Tile Skip (1 cyc)</text>
            <text class="card-desc" x="67" y="80" text-anchor="middle">• 16-Sample MSAA 4x</text>
            <text class="card-desc" x="67" y="94" text-anchor="middle">• Fast DDA Plane Eval</text>
        </g>

        <!-- Arrow RX -> SU (FS) -->
        <path d="M 545 97 L 568 97" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="556" y="90" text-anchor="middle">Quads</text>

        <!-- Block 5: SU (Fragment Shader) -->
        <g transform="translate(570, 42)">
            <rect width="125" height="110" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="125" height="22" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="62" y="15" text-anchor="middle" fill="#0369a1">SU (Fragment Shader)</text>
            <text class="card-sub" x="62" y="36" text-anchor="middle">Pixel Warps &amp; Math</text>
            <text class="card-desc" x="62" y="52" text-anchor="middle">• 32-Pixel Warps</text>
            <text class="card-desc" x="62" y="66" text-anchor="middle">• Packed FP16×2 Math</text>
            <text class="card-desc" x="62" y="80" text-anchor="middle">• 32 KiB Multi-Bank LDS</text>
            <text class="card-desc" x="62" y="94" text-anchor="middle">• Scoreboard Schedule</text>
        </g>

        <!-- Arrow SU (FS) -> ROP -->
        <path d="M 695 97 L 718 97" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="706" y="90" text-anchor="middle">Color/Z</text>

        <!-- Block 6: ROP -->
        <g transform="translate(720, 42)">
            <rect width="120" height="110" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="120" height="22" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="60" y="15" text-anchor="middle" fill="#0369a1">ROP</text>
            <text class="card-sub" x="60" y="36" text-anchor="middle">Blend &amp; Tile Cache</text>
            <text class="card-desc" x="60" y="52" text-anchor="middle">• On-Chip Tile Buffer</text>
            <text class="card-desc" x="60" y="66" text-anchor="middle">• Hazard Pixel Lock</text>
            <text class="card-desc" x="60" y="80" text-anchor="middle">• Dual-Source Blend</text>
            <text class="card-desc" x="60" y="94" text-anchor="middle">• Lossless Tile Pack</text>
        </g>

        <!-- Arrow ROP -> MC/L2C -->
        <path d="M 840 97 L 863 97" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="851" y="90" text-anchor="middle">Tile WB</text>

        <!-- Block 7: MC Flat Crossbar & Shared L2 LLC -->
        <g transform="translate(865, 42)">
            <rect width="110" height="110" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="110" height="22" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="55" y="15" text-anchor="middle" fill="#0369a1">MC &amp; L2 LLC</text>
            <text class="card-sub" x="55" y="36" text-anchor="middle">Crossbar &amp; Cache</text>
            <text class="card-desc" x="55" y="52" text-anchor="middle">• 2-cyc Flat Xbar</text>
            <text class="card-desc" x="55" y="66" text-anchor="middle">• DWRR Arbiter</text>
            <text class="card-desc" x="55" y="80" text-anchor="middle">• 256KB-2MB LLC</text>
            <text class="card-desc" x="55" y="94" text-anchor="middle">• AXI4 Host DRAM</text>
        </g>

        <!-- Branch: Texture Unit (TU) -->
        <g transform="translate(570, 168)">
            <rect width="270" height="74" rx="6" fill="#ffffff" stroke="#93c5fd" stroke-width="1.2"/>
            <rect x="0" y="0" width="270" height="20" rx="6" fill="#eff6ff"/>
            <text class="card-title" x="135" y="14" text-anchor="middle" fill="#0369a1">TU (Texture Unit) — atg_tu</text>
            <text class="card-desc" x="135" y="34" text-anchor="middle">• 4-Entry MSHR (Hit-Under-Miss: Non-blocking texture access)</text>
            <text class="card-desc" x="135" y="48" text-anchor="middle">• 4-Bank Interleaved L1 Texture Cache (1-cyc quad texel fetch)</text>
            <text class="card-desc" x="135" y="62" text-anchor="middle">• 2D/3D/Cube Bilinear &amp; Trilinear Filter • Format Decompression</text>
        </g>

        <!-- Bidirectional link SU(FS) <-> TU -->
        <path d="M 625 152 L 625 166" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <path d="M 640 166 L 640 152" fill="none" stroke="#0284c7" stroke-width="2" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="655" y="162" font-size="8.5">Sample / Texels</text>

        <!-- TU fetch link to MC & L2C -->
        <path d="M 840 205 L 920 205 L 920 154" fill="none" stroke="#0284c7" stroke-width="1.8" stroke-dasharray="4,3" marker-end="url(#arrow-blue)"/>
        <text class="flow-label" x="880" y="198" text-anchor="middle" font-size="8.5">MSHR Refill</text>
    </g>

    <!-- ============================================================== -->
    <!-- 2. 2D BLIT & STREAMING COPY PIPELINE                           -->
    <!-- ============================================================== -->
    <g transform="translate(25, 337)">
        <rect width="990" height="130" rx="8" fill="#f0fdf4" stroke="#bbf7d0" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 8 Q 0 0 8 0 L 982 0 Q 990 0 990 8 L 990 26 L 0 26 Z" fill="#059669"/>
        <text class="sec-title" x="15" y="18" fill="#ffffff">2. 2D Blitter &amp; Fast Memory Copy Pipeline (Fill / Copy / Format Convert / MSAA 4x Resolve)</text>

        <!-- Block 1: CP -->
        <g transform="translate(15, 36)">
            <rect width="140" height="82" rx="6" fill="#ffffff" stroke="#86efac" stroke-width="1.2"/>
            <rect x="0" y="0" width="140" height="20" rx="6" fill="#f0fdf4"/>
            <text class="card-title" x="70" y="14" text-anchor="middle" fill="#047857">CP (Command Ring)</text>
            <text class="card-desc" x="70" y="35" text-anchor="middle">• Dedicated Copy Queue</text>
            <text class="card-desc" x="70" y="50" text-anchor="middle">• Async Compute / Copy Ring</text>
            <text class="card-desc" x="70" y="65" text-anchor="middle">• Zero-MMIO DMA Trigger</text>
        </g>

        <!-- Arrow CP -> BLT -->
        <path d="M 155 77 L 193 77" fill="none" stroke="#059669" stroke-width="2" marker-end="url(#arrow-emerald)"/>
        <text class="flow-label" x="174" y="70" text-anchor="middle">Blit Cmd</text>

        <!-- Block 2: BLT Engine -->
        <g transform="translate(195, 36)">
            <rect width="395" height="82" rx="6" fill="#ffffff" stroke="#86efac" stroke-width="1.2"/>
            <rect x="0" y="0" width="395" height="20" rx="6" fill="#f0fdf4"/>
            <text class="card-title" x="197" y="14" text-anchor="middle" fill="#047857">BLT (Streaming 2D Blitter &amp; Resolve Engine) — atg_blt</text>
            <text class="card-desc" x="197" y="35" text-anchor="middle">• 1 KiB Dual Ping-Pong DMA Buffers (Sustained 2.0+ GB/s Streaming Throughput)</text>
            <text class="card-desc" x="197" y="50" text-anchor="middle">• 1-Cycle Parallel MSAA 4x Resolve (4-Sample Downsample Box Average without Stall)</text>
            <text class="card-desc" x="197" y="65" text-anchor="middle">• Fast Color Fill, Alpha-Over Blending, and Linear ↔ Tiled Texture Layout Transposition</text>
        </g>

        <!-- Arrow BLT -> MC Xbar -->
        <path d="M 590 77 L 628 77" fill="none" stroke="#059669" stroke-width="2" marker-end="url(#arrow-emerald)"/>
        <text class="flow-label" x="609" y="70" text-anchor="middle">Burst DMA</text>

        <!-- Block 3: MC Flat Crossbar -->
        <g transform="translate(630, 36)">
            <rect width="165" height="82" rx="6" fill="#ffffff" stroke="#86efac" stroke-width="1.2"/>
            <rect x="0" y="0" width="165" height="20" rx="6" fill="#f0fdf4"/>
            <text class="card-title" x="82" y="14" text-anchor="middle" fill="#047857">MC Flat Crossbar</text>
            <text class="card-desc" x="82" y="35" text-anchor="middle">• Level 0 DWRR Fair Schedule</text>
            <text class="card-desc" x="82" y="50" text-anchor="middle">• Registered Skid Buffer (1 cyc)</text>
            <text class="card-desc" x="82" y="65" text-anchor="middle">• Multi-Flit Packet Atomic Lock</text>
        </g>

        <!-- Arrow MC Xbar -> L2C/MC -->
        <path d="M 795 77 L 833 77" fill="none" stroke="#059669" stroke-width="2" marker-end="url(#arrow-emerald)"/>
        <text class="flow-label" x="814" y="70" text-anchor="middle">Writeback</text>

        <!-- Block 4: Shared L2C & MC -->
        <g transform="translate(835, 36)">
            <rect width="140" height="82" rx="6" fill="#ffffff" stroke="#86efac" stroke-width="1.2"/>
            <rect x="0" y="0" width="140" height="20" rx="6" fill="#f0fdf4"/>
            <text class="card-title" x="70" y="14" text-anchor="middle" fill="#047857">Shared L2C &amp; MC</text>
            <text class="card-desc" x="70" y="35" text-anchor="middle">• Write-Combining Buffers</text>
            <text class="card-desc" x="70" y="50" text-anchor="middle">• Coherent Flush / Invalidate</text>
            <text class="card-desc" x="70" y="65" text-anchor="middle">• AXI4-Full Master</text>
        </g>
    </g>

    <!-- ============================================================== -->
    <!-- 3. SYSTOLIC MATRIX & LLM ACCELERATOR PIPELINE                  -->
    <!-- ============================================================== -->
    <g transform="translate(25, 477)">
        <rect width="990" height="130" rx="8" fill="#faf5ff" stroke="#e9d5ff" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 8 Q 0 0 8 0 L 982 0 Q 990 0 990 8 L 990 26 L 0 26 Z" fill="#7c3aed"/>
        <text class="sec-title" x="15" y="18" fill="#ffffff">3. Systolic Matrix Multiplication &amp; LLM Accelerator Pipeline (Scalable to 100 TOPS)</text>

        <!-- Block 1: CP -->
        <g transform="translate(15, 36)">
            <rect width="135" height="82" rx="6" fill="#ffffff" stroke="#c084fc" stroke-width="1.2"/>
            <rect x="0" y="0" width="135" height="20" rx="6" fill="#faf5ff"/>
            <text class="card-title" x="67" y="14" text-anchor="middle" fill="#6b21a8">CP (Tensor Dispatch)</text>
            <text class="card-desc" x="67" y="35" text-anchor="middle">• Compute Queue</text>
            <text class="card-desc" x="67" y="50" text-anchor="middle">• Tensor Descriptor Parse</text>
            <text class="card-desc" x="67" y="65" text-anchor="middle">• Matrix Shape / Strides</text>
        </g>

        <!-- Arrow CP -> VF/DMA -->
        <path d="M 150 77 L 183 77" fill="none" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="flow-label" x="166" y="70" text-anchor="middle">Shape</text>

        <!-- Block 2: VF/DMA -->
        <g transform="translate(185, 36)">
            <rect width="130" height="82" rx="6" fill="#ffffff" stroke="#c084fc" stroke-width="1.2"/>
            <rect x="0" y="0" width="130" height="20" rx="6" fill="#faf5ff"/>
            <text class="card-title" x="65" y="14" text-anchor="middle" fill="#6b21a8">VF / Stream DMA</text>
            <text class="card-desc" x="65" y="35" text-anchor="middle">• High-Bandwidth Fetch</text>
            <text class="card-desc" x="65" y="50" text-anchor="middle">• FP16 / BF16 / INT8</text>
            <text class="card-desc" x="65" y="65" text-anchor="middle">• Weight Matrix Stream</text>
        </g>

        <!-- Arrow VF -> SU Scheduler -->
        <path d="M 315 77 L 348 77" fill="none" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="flow-label" x="331" y="70" text-anchor="middle">Weights</text>

        <!-- Block 3: SU Scheduler -->
        <g transform="translate(350, 36)">
            <rect width="145" height="82" rx="6" fill="#ffffff" stroke="#c084fc" stroke-width="1.2"/>
            <rect x="0" y="0" width="145" height="20" rx="6" fill="#faf5ff"/>
            <text class="card-title" x="72" y="14" text-anchor="middle" fill="#6b21a8">SU (Warp Scheduler)</text>
            <text class="card-desc" x="72" y="35" text-anchor="middle">• 32 KiB Multi-Bank LDS</text>
            <text class="card-desc" x="72" y="50" text-anchor="middle">• Activation Staging</text>
            <text class="card-desc" x="72" y="65" text-anchor="middle">• Systolic Feed Orchestrator</text>
        </g>

        <!-- Arrow SU -> SA -->
        <path d="M 495 77 L 528 77" fill="none" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="flow-label" x="511" y="70" text-anchor="middle">A Stream</text>

        <!-- Block 4: SA (Systolic Array) -->
        <g transform="translate(530, 36)">
            <rect width="190" height="82" rx="6" fill="#ffffff" stroke="#c084fc" stroke-width="1.2"/>
            <rect x="0" y="0" width="190" height="20" rx="6" fill="#faf5ff"/>
            <text class="card-title" x="95" y="14" text-anchor="middle" fill="#6b21a8">SA (32×32 Systolic Array)</text>
            <text class="card-desc" x="95" y="35" text-anchor="middle">• 1,024 MAC Processing Elements</text>
            <text class="card-desc" x="95" y="50" text-anchor="middle" fill="#7c3aed" font-weight="700">0.8 TOPS / SU @ 200 MHz</text>
            <text class="card-desc" x="95" y="65" text-anchor="middle">• Scalable to 100 TOPS Multi-Core</text>
        </g>

        <!-- Arrow SA -> SU Norm -->
        <path d="M 720 77 L 753 77" fill="none" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="flow-label" x="736" y="70" text-anchor="middle">Partial Sums</text>

        <!-- Block 5: SU Norm/Act -->
        <g transform="translate(755, 36)">
            <rect width="115" height="82" rx="6" fill="#ffffff" stroke="#c084fc" stroke-width="1.2"/>
            <rect x="0" y="0" width="115" height="20" rx="6" fill="#faf5ff"/>
            <text class="card-title" x="57" y="14" text-anchor="middle" fill="#6b21a8">SU (Post-Process)</text>
            <text class="card-desc" x="57" y="35" text-anchor="middle">• LayerNorm / RMSNorm</text>
            <text class="card-desc" x="57" y="50" text-anchor="middle">• SiLU / GELU / ReLU</text>
            <text class="card-desc" x="57" y="65" text-anchor="middle">• Quantize / Output</text>
        </g>

        <!-- Arrow SU Norm -> L2C -->
        <path d="M 870 77 L 903 77" fill="none" stroke="#7c3aed" stroke-width="2" marker-end="url(#arrow-purple)"/>
        <text class="flow-label" x="886" y="70" text-anchor="middle">Results</text>

        <!-- Block 6: L2C & MC -->
        <g transform="translate(905, 36)">
            <rect width="70" height="82" rx="6" fill="#ffffff" stroke="#c084fc" stroke-width="1.2"/>
            <rect x="0" y="0" width="70" height="20" rx="6" fill="#faf5ff"/>
            <text class="card-title" x="35" y="14" text-anchor="middle" fill="#6b21a8">L2C / MC</text>
            <text class="card-desc" x="35" y="42" text-anchor="middle">• LLC</text>
            <text class="card-desc" x="35" y="58" text-anchor="middle">• DRAM</text>
        </g>
    </g>

    <!-- ============================================================== -->
    <!-- 4. DISPLAY CONTROLLER SCANOUT & PREEMPTION PATH                -->
    <!-- ============================================================== -->
    <g transform="translate(25, 617)">
        <rect width="990" height="135" rx="8" fill="#fffbeb" stroke="#fde68a" stroke-width="1.5" filter="url(#shadow-sm)"/>
        <path d="M 0 8 Q 0 0 8 0 L 982 0 Q 990 0 990 8 L 990 26 L 0 26 Z" fill="#d97706"/>
        <text class="sec-title" x="15" y="18" fill="#ffffff">4. Display Controller (DC) Scanout &amp; Multi-Level Watermark Preemption Path (Tear-Free 1080p@60Hz)</text>

        <!-- Block 1: Host / Local DRAM Framebuffer -->
        <g transform="translate(15, 36)">
            <rect width="140" height="86" rx="6" fill="#ffffff" stroke="#fcd34d" stroke-width="1.2"/>
            <rect x="0" y="0" width="140" height="20" rx="6" fill="#fffbeb"/>
            <text class="card-title" x="70" y="14" text-anchor="middle" fill="#b45309">DRAM Framebuffer</text>
            <text class="card-desc" x="70" y="35" text-anchor="middle">• 1920×1080 @ 60 Hz</text>
            <text class="card-desc" x="70" y="50" text-anchor="middle">• 148.5 MHz Dot Clock</text>
            <text class="card-desc" x="70" y="65" text-anchor="middle">• Zero-Copy Shared Pool</text>
            <text class="card-desc" x="70" y="78" text-anchor="middle">• Linear Scanout Buffer</text>
        </g>

        <!-- Arrow DRAM -> MC Crossbar -->
        <path d="M 155 79 L 198 79" fill="none" stroke="#d97706" stroke-width="2" marker-end="url(#arrow-amber)"/>
        <text class="flow-label" x="176" y="72" text-anchor="middle">Scanout</text>

        <!-- Block 2: MC Flat Crossbar (Level 1 Strict Priority) -->
        <g transform="translate(200, 36)">
            <rect width="180" height="86" rx="6" fill="#ffffff" stroke="#fcd34d" stroke-width="1.2"/>
            <rect x="0" y="0" width="180" height="20" rx="6" fill="#fffbeb"/>
            <text class="card-title" x="90" y="14" text-anchor="middle" fill="#b45309">MC Flat Crossbar Arbiter</text>
            <text class="card-desc" x="90" y="35" text-anchor="middle">• Level 1 Strict Priority Channel</text>
            <text class="card-desc" x="90" y="50" text-anchor="middle">• Instant DC Grant on Valid</text>
            <text class="card-desc" x="90" y="65" text-anchor="middle">• Zero-Bubble Panic Preempt</text>
            <text class="card-desc" x="90" y="78" text-anchor="middle" fill="#d97706" font-weight="700">2-Cycle Roundtrip Latency</text>
        </g>

        <!-- Arrow MC Crossbar -> BRAM AFIFO -->
        <path d="M 380 79 L 418 79" fill="none" stroke="#d97706" stroke-width="2" marker-end="url(#arrow-amber)"/>
        <text class="flow-label" x="399" y="72" text-anchor="middle">DMA Read</text>

        <!-- Block 3: 2048-Word BRAM AFIFO -->
        <g transform="translate(420, 36)">
            <rect width="210" height="86" rx="6" fill="#ffffff" stroke="#fcd34d" stroke-width="1.2"/>
            <rect x="0" y="0" width="210" height="20" rx="6" fill="#fffbeb"/>
            <text class="card-title" x="105" y="14" text-anchor="middle" fill="#b45309">2048-Word BRAM AFIFO</text>
            <text class="card-desc" x="105" y="35" text-anchor="middle">• am_afifo_bram (Dual-Clock CDC)</text>
            <text class="card-desc" x="105" y="50" text-anchor="middle">• gclk (200 MHz) ↔ pclk (200 MHz)</text>
            <text class="card-desc" x="105" y="65" text-anchor="middle" fill="#b45309" font-weight="700">Urgent (&lt;40%) / Panic (&lt;20%) WMs</text>
            <text class="card-desc" x="105" y="78" text-anchor="middle">• 32-Line Continuous Burst Prefetch</text>
        </g>

        <!-- Arrow AFIFO -> DC -->
        <path d="M 630 79 L 668 79" fill="none" stroke="#d97706" stroke-width="2" marker-end="url(#arrow-amber)"/>
        <text class="flow-label" x="649" y="72" text-anchor="middle">pclk Data</text>

        <!-- Block 4: DC (Display Controller) -->
        <g transform="translate(670, 36)">
            <rect width="165" height="86" rx="6" fill="#ffffff" stroke="#fcd34d" stroke-width="1.2"/>
            <rect x="0" y="0" width="165" height="20" rx="6" fill="#fffbeb"/>
            <text class="card-title" x="82" y="14" text-anchor="middle" fill="#b45309">DC (Display Controller)</text>
            <text class="card-desc" x="82" y="35" text-anchor="middle">• Independent 200 MHz Domain</text>
            <text class="card-desc" x="82" y="50" text-anchor="middle">• Hardware Cursor &amp; Color LUT</text>
            <text class="card-desc" x="82" y="65" text-anchor="middle">• YCbCr / RGB Conversion</text>
            <text class="card-desc" x="82" y="78" text-anchor="middle">• Survives Full 3D Core Reset</text>
        </g>

        <!-- Arrow DC -> Output -->
        <path d="M 835 79 L 873 79" fill="none" stroke="#d97706" stroke-width="2" marker-end="url(#arrow-amber)"/>
        <text class="flow-label" x="854" y="72" text-anchor="middle">TMDS</text>

        <!-- Block 5: HDMI / DVI Output -->
        <g transform="translate(875, 36)">
            <rect width="100" height="86" rx="6" fill="#ffffff" stroke="#fcd34d" stroke-width="1.2"/>
            <rect x="0" y="0" width="100" height="20" rx="6" fill="#fffbeb"/>
            <text class="card-title" x="50" y="14" text-anchor="middle" fill="#b45309">HDMI / DVI</text>
            <text class="card-desc" x="50" y="42" text-anchor="middle">• 1080p @ 60Hz</text>
            <text class="card-desc" x="50" y="58" text-anchor="middle">• Tear-Free Scan</text>
            <text class="card-desc" x="50" y="74" text-anchor="middle">• Zero Jitter</text>
        </g>

        <!-- Preemption Feedback Loop: Urgent / Panic from AFIFO back to MC Crossbar -->
        <path d="M 525 122 L 525 130 L 290 130 L 290 122" fill="none" stroke="#e11d48" stroke-width="1.8" stroke-dasharray="3,3" marker-end="url(#arrow-rose)"/>
        <text class="flow-label" x="407" y="127" text-anchor="middle" fill="#e11d48" font-size="8.5" font-weight="700">dc_urgent (&lt;40%) / dc_panic (&lt;20%) Preemption Feedback (Throttles 3D Traffic)</text>
    </g>
</svg>
"""



def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = script_dir

    generators = [
        ("ghci_gpu_architecture.svg", generate_ghci_gpu_architecture),
        ("ghci_uma_system.svg", generate_ghci_uma_system),
        ("ghci_discrete_system.svg", generate_ghci_discrete_system),
        ("ghci_command_flow.svg", generate_ghci_command_flow),
        ("ghci_command_sequence.svg", generate_ghci_command_sequence),
        ("atg_top_architecture.svg", generate_atg_top_architecture),
        ("atg_data_paths.svg", generate_atg_data_paths),
        ("atg_su_32lane.svg", generate_atg_su_32lane),
        ("atg_rx_rasterizer.svg", generate_atg_rx_rasterizer),
        ("atg_rop_backend.svg", generate_atg_rop_backend),
    ]

    print(f"Generating 10 SVG architecture diagrams in {output_dir}...")
    for filename, gen_func in generators:
        filepath = os.path.join(output_dir, filename)
        content = gen_func()
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  ✓ Created {filename} ({len(content)} bytes)")

    print("All SVGs generated successfully.")

if __name__ == "__main__":
    main()
