# GHCI 1.0 Design Decisions Traceability Index

This document preserves the historical Q&A and architectural review tag index (`J*`, `K*`, `M*`, `N*`) previously embedded inline in `ghci.md`.

| Tag | Section(s) | Context Summary |
| :---: | :--- | :--- |
| **G34** | 3.3 CTRL and STATUS | Preserves host configuration (`IRQ_ENABLE`, `WDT_CYCLES`, `CP_HEAP_BASE/LIMIT`) across `CTRL.RESET` |
| **J01** | GHCI — GPU Host Controller Interface, 1.4 Status of this specification, 7.5 Legacy Class 2 Gpu-ops & Obsolete Pre-1.0 Protocols [DEPRECATED] | every conforming GPU. All decisions established in driver Q&A (J01-J27, K01-K19) |
| **J02** | 3.1 Canonical Register Map, 3.3 CTRL and STATUS, 3.4 IRQ_STATUS and IRQ_ENABLE ... | \| 0x010 \| STATUS \| RO \| Hardware execution status (section 3.3, J02) \| |
| **J03** | 3.1 Canonical Register Map, 3.5 FAULT_INFO, FAULT_ADDR and DIAG | \| 0x018 \| FAULT_INFO \| RO/W1C \| Fault classification, source unit, syndrome, and session ID (section |
| **J04** | 3.1 Canonical Register Map | ### 3.1 Canonical Register Map (0x000 - 0x0FC, J04) |
| **J05** | 3.1 Canonical Register Map, 6.1 Layout | \| 0x024 \| RING_BASE_LO \| RW \| Command ring 64-bit base host DMA address [31:0], 64-byte aligned (J05 |
| **J06** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor | #### 3.2.2 EXT_CAP_FEATURE (Capability Block Word 3, J06, K07, N19, N31) — Extended Feature & Addres |
| **J07** | 3.1 Canonical Register Map, 3.2.0 BOOT_CAPS (0x008) — Early Boot Capabilities, 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies | \| 0x058 \| SESSION_ACTIVE \| RO \| Active session identifier and session state bitmap (section 11.6, J0 |
| **J08** | 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies | #### 3.2.1 DEVICE_CAPS (Capability Block Word 2, J08, N18) — Architectural Capabilities & Topologies |
| **J12** | 3.1 Canonical Register Map | \| 0x050 \| CP_HEAP_BASE \| RW \| Dynamic page table allocation heap base [BASE, LIMIT) (section 11.2, J |
| **J13** | 3.4 IRQ_STATUS and IRQ_ENABLE, 7.2 Structured Command Opcodes | \| [0] \| IRQ_FENCE \| A `CMD_FENCE` packet completed and wrote 64-bit sequence value to memory (J13, K |
| **J14** | 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies | \| [3] \| CAP_INDIRECT_DRAW \| Firmware / hardware support \| 1 = Native MultiDrawIndirect and indirect  |
| **J18** | 7.2 Structured Command Opcodes, `CMD_COPY_IMAGE`, `CMD_BLIT` | \| `0x41` \| `CMD_COPY_IMAGE` \| 11 \| `CAP_BLT` \| 2D/3D image-to-image subresource slice transfer (J18, |
| **J24** | 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies, 12.8 Memory | \| [4] \| CAP_SECONDARY_RING \| Firmware / hardware support \| 1 = Secondary command buffer direct execu |
| **J25** | 3.1 Canonical Register Map | \| 0x05C \| TIMESTAMP_LO \| RO \| 64-bit GPU cycle timestamp [31:0] (section 14.3, J25) \| |
| **J27** | GHCI — GPU Host Controller Interface, 1.4 Status of this specification | every conforming GPU. All decisions established in driver Q&A (J01-J27, K01-K19) |
| **K01** | GHCI — GPU Host Controller Interface, 1.4 Status of this specification, 7.5 Legacy Class 2 Gpu-ops & Obsolete Pre-1.0 Protocols [DEPRECATED] | every conforming GPU. All decisions established in driver Q&A (J01-J27, K01-K19) |
| **K02** | Firmware Heap and Page Table Allocation | #### Firmware Heap and Page Table Allocation (`CP_HEAP_BASE`, `CP_HEAP_LIMIT`, K02, K08, N07, N09, N |
| **K03** | Session Fault Isolation vs Whole-Device Fault, 5.1 Hardware CP Micro-States | #### Session Fault Isolation vs Whole-Device Fault (K03, N05, N06) |
| **K04** | 3.5 FAULT_INFO, FAULT_ADDR and DIAG | ### 3.5 FAULT_INFO, FAULT_ADDR and DIAG (0x018, 0x01C/0x020, J03, K04, N05, N20) |
| **K06** | 3.2.3 Clocks, Timestamps and PCI Identification | #### 3.2.3 Clocks, Timestamps and PCI Identification (K06) |
| **K07** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor, 7.2 Structured Command Opcodes, `CMD_VM_MAP` ... | #### 3.2.2 EXT_CAP_FEATURE (Capability Block Word 3, J06, K07, N19, N31) — Extended Feature & Addres |
| **K08** | 5.2 Driver-Visible Lifecycle States, Firmware Heap and Page Table Allocation | - **Preserved Across Reset (K08, N08)**: All host RAM contents (command rings, fences, vertex/textur |
| **K09** | 3.4 IRQ_STATUS and IRQ_ENABLE, 7.2 Structured Command Opcodes, `CMD_FENCE` ... | \| [0] \| IRQ_FENCE \| A `CMD_FENCE` packet completed and wrote 64-bit sequence value to memory (J13, K |
| **K10** | 7.2 Structured Command Opcodes, `CMD_DRAW_INDIRECT` | \| `0x29` \| `CMD_DRAW_INDIRECT` \| 7 or 8 \| `CAP_INDIRECT_DRAW` \| MultiDrawIndirect (7 dw normal, 8 dw |
| **K11** | 8.2 Immutable Pipeline State Object (`GhciPipelineState`), Extended Pipeline State Object (`GhciPipelineStateExt`, 256 Bytes), 8.6 Vulkan Hardware Limits and Standard Architectural Constants | \| `0x40..0x7F` \| dw16-31 \| `attributes[16]` \| 16 × 4 B \| Packed vertex input attributes: 16 entries  |
| **K12** | 7.2 Structured Command Opcodes, `CMD_BEGIN_RENDER_PASS`, In-Memory Render Pass Descriptor | \| `0x2B` \| `CMD_BEGIN_RENDER_PASS` \| 10 \| Mandatory (Raster) \| Binds framebuffer via 192-byte `GhciR |
| **K16** | 6.0 Command Execution Lifecycle, 7.2 Structured Command Opcodes, `CMD_EXECUTE_COMMANDS` | > - Forbidden nesting: `CMD_EXECUTE_COMMANDS` (0x32) (nesting is strictly limited to 1 level, K16).  |
| **K17** | 7.2 Structured Command Opcodes, `CMD_BARRIER` | \| `0x31` \| `CMD_BARRIER` \| 4 \| Mandatory \| Pipeline stage barrier, cache flush/invalidation, drain ( |
| **K18** | 12.1 Overview | - Optional capabilities and ISA execution features are reported through `CMD_QUERY_CAPS` (K18, N16): |
| **K19** | GHCI — GPU Host Controller Interface, 1.4 Status of this specification, 6.1 Layout ... | every conforming GPU. All decisions established in driver Q&A (J01-J27, K01-K19) |
| **M01** | 3. Host control registers, 3.2 Hardware Capabilities and Architecture Sizes, 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies | > **MMIO Offsets & Capability Discovery in Page 0 MMIO (M01)**: |
| **M02** | 3.1 Canonical Register Map | \| 0x000 \| GHCI_MAGIC \| RO \| Magic identification: strictly `0x47484349` ("GHCI") (M02) \| |
| **M03** | 3.2.0 BOOT_CAPS (0x008) — Early Boot Capabilities, 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor | \| [11:8] \| VA_BITS_ENC \| Platform \| Supported GPU virtual address width offset encoding ($VA = 30 +  |
| **M04** | 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies | \| [0] \| CAP_UMA \| Board / Platform \| 1 = Unified Memory Architecture (Shared DRAM), 0 = Discrete VRA |
| **M05** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor | - `[19:16] MAX_MRT`: Maximum simultaneously bound color render targets (1..8) (M05, N31). |
| **M06** | 4.1 Extended Capability Register Window Map | - **EXTCAP Linked List vs Fixed Offsets (M06, N28)**: Drivers may discover capabilities by walking t |
| **M08** | 7.5 Legacy Class 2 Gpu-ops & Obsolete Pre-1.0 Protocols [DEPRECATED] | > **Complete Deprecation Notice (M08, J01, K01)**: |
| **M09** | 14. Bring-up and Diagnostics | back to verify 32-bit read/write bus timing (`WDT_CYCLES` resides at `0x048`) (M09). |
| **M10** | Driver-Visible Lifecycle States and Register Access Rules | #### Driver-Visible Lifecycle States and Register Access Rules (M10) |
| **M11** | 3.3 CTRL and STATUS, 3.4 IRQ_STATUS and IRQ_ENABLE, 9.2 Interrupts | - `[0] RESET`: 1 = Issue GPU software reset. Self-clearing; hardware resets core logic, pipeline blo |
| **M12** | 3.3 CTRL and STATUS | - `[4] TLB_FLUSH`: Diagnostic hook only. Under the driver transparency principle (§11.2), TLB invali |
| **M13** | Appendix A. Driver initialization (informative) | the diagnostic dump registers (`DIAG_CP_PC` at 0x074, `DIAG_CP_STATUS` at 0x078) (M13). |
| **M15** | 9.1 Fences | ### 9.1 Fences (M15, M18) |
| **M16** | Address Space Classification for Command Packets | #### Address Space Classification for Command Packets (M16, N07, N11, N12, N15) |
| **M18** | 9.1 Fences | ### 9.1 Fences (M15, M18) |
| **M19** | 9.2 Interrupts | ### 9.2 Interrupts (M11, M19, N21) |
| **M20** | 3.3 CTRL and STATUS | - `[2] FAULTED`: 1 = Global unrecoverable hardware or bus deadlock fault latched (M20). |
| **M22** | 3.5 FAULT_INFO, FAULT_ADDR and DIAG, 11.6 Session Protection & Virtual Memory Isolation | - `[15:8] SESSION_ID`: Client session identifier ($0..15$, up to 16 concurrent sessions, M22). |
| **M23** | 3.5 FAULT_INFO, FAULT_ADDR and DIAG | 64-bit GPU virtual address (for MMU faults) or physical bus address where the fault occurred. For Sh |
| **M26** | Appendix A. Driver initialization (informative) | Reset via `CTRL.RESET`, restore `RING_WPTR = 0` (existing host RAM allocations remain intact, M26), |
| **M27** | 7.2 Structured Command Opcodes, `CMD_SESSION_OPEN` (0x12) & `CMD_SESSION_CLOSE` (0x13) | \| `0x12` \| `CMD_SESSION_OPEN` \| 4 \| Mandatory \| Opens client session context ($0..15$) (M27) \| |
| **M29** | 11.6 Session Protection & Virtual Memory Isolation | ### 11.6 Session Protection & Virtual Memory Isolation (M29, M32, N10, N18) |
| **M31** | 6.0 Command Execution Lifecycle | The primary command ring is exclusively managed and written by the Kernel-Mode Driver (KMD) (M31). |
| **M32** | 11.6 Session Protection & Virtual Memory Isolation | ### 11.6 Session Protection & Virtual Memory Isolation (M29, M32, N10, N18) |
| **M37** | 7.2 Structured Command Opcodes | ### 7.2 Structured Command Opcodes (include/ghci_cmd.h, M37, M38, N32) |
| **M38** | 7.2 Structured Command Opcodes | ### 7.2 Structured Command Opcodes (include/ghci_cmd.h, M37, M38, N32) |
| **M39** | 7.2 Structured Command Opcodes, `CMD_DRAW_MESH_TASKS` | \| `0x2A` \| `CMD_DRAW_MESH_TASKS` \| 4 \| `CAP_MESH_SHADER` \| Dispatches task/mesh workgroups ($X, Y, Z |
| **M40** | `CMD_BEGIN_QUERY` (0x36) & `CMD_END_QUERY` (0x37) | #### `CMD_BEGIN_QUERY` (0x36) & `CMD_END_QUERY` (0x37) (M40, N17, N32) |
| **M41** | Extended Pipeline State Object (`GhciPipelineStateExt`, 256 Bytes) | **State Encodings (include/ghci_cmd.h, M41, N14):** |
| **M42** | Extended Pipeline State Object (`GhciPipelineStateExt`, 256 Bytes) | **Shader Stage Entry Points (M42):** |
| **M45** | 7.2 Structured Command Opcodes, `CMD_LOAD_CONST`, Push Constants & Constant Register Bank | \| `0x2D` \| `CMD_LOAD_CONST` \| 3+N \| `NUM_SU > 0` \| Loads $N$ dwords into constant bank $c[0..511]$ ( |
| **M46** | Descriptor Table Persistence & Dynamic Binding | #### Descriptor Table Persistence & Dynamic Binding (M46, N02) |
| **M47** | In-Memory Render Pass Descriptor | #### In-Memory Render Pass Descriptor (`GhciRenderPassDesc`, 192 Bytes, K12, M47, N03) |
| **M53** | 12.8 Memory | ### 12.8 Memory (M53) |
| **M54** | 7.2 Structured Command Opcodes, `CMD_DISP_SET`, `CMD_FLIP` | \| `0x50` \| `CMD_DISP_SET` \| 1+2N \| `CAP_DISP` \| Sets display controller registers (`flags[0]`: wait  |
| **M55** | 13.2 DISP2: a display controller that is a unit of the GPU | **Images & Scanout Address Space (M55).** |
| **M56** | 13.2 DISP2: a display controller that is a unit of the GPU | ### 13.2 DISP2: a display controller that is a unit of the GPU (Approved Architecture, M56) |
| **M58** | 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies, 15.2 PCIe binding | \| [1] \| CAP_IOMMU \| Platform \| 1 = System / Platform IOMMU translation active for GPU PCIe device (s |
| **N01** | 1.4 Status of this specification, 8.2 Immutable Pipeline State Object (`GhciPipelineState`), Extended Pipeline State Object (`GhciPipelineStateExt`, 256 Bytes) ... | \| Host control registers, extended capabilities, CP states, the ring, fences, interrupts, faults, qu |
| **N02** | 8.4 Descriptor Tables, Push Constants & Shader Resource Binding, Descriptor Table Persistence & Dynamic Binding, Push Constants & Constant Register Bank ... | - Inside each descriptor set table, descriptors are indexed using unified table-base + layout-offset |
| **N03** | 7.2 Structured Command Opcodes, `CMD_BEGIN_RENDER_PASS`, In-Memory Render Pass Descriptor | \| `0x2B` \| `CMD_BEGIN_RENDER_PASS` \| 10 \| Mandatory (Raster) \| Binds framebuffer via 192-byte `GhciR |
| **N04** | 6.0 Command Execution Lifecycle, 7.2 Structured Command Opcodes, `CMD_EXECUTE_COMMANDS` ... | > **Privilege Separation & Secondary Command Buffers (M31, N04)**: |
| **N05** | Session Fault Isolation vs Whole-Device Fault, 3.4 IRQ_STATUS and IRQ_ENABLE, 3.5 FAULT_INFO, FAULT_ADDR and DIAG ... | #### Session Fault Isolation vs Whole-Device Fault (K03, N05, N06) |
| **N06** | Session Fault Isolation vs Whole-Device Fault, 10. Faults, watchdog, quiesce and reset, 11.6 Session Protection & Virtual Memory Isolation | #### Session Fault Isolation vs Whole-Device Fault (K03, N05, N06) |
| **N07** | 5.2 Driver-Visible Lifecycle States, Address Space Classification for Command Packets, Firmware Heap and Page Table Allocation | 7. Re-map Session 0 kernel pages via `CMD_VM_MAP` (the CP table walker allocates/uses Session 0's ro |
| **N08** | 5.2 Driver-Visible Lifecycle States, `CMD_FENCE`, 10. Faults, watchdog, quiesce and reset | A reset (`CTRL.RESET = 1`, N08): |
| **N09** | Firmware Heap and Page Table Allocation | #### Firmware Heap and Page Table Allocation (`CP_HEAP_BASE`, `CP_HEAP_LIMIT`, K02, K08, N07, N09, N |
| **N10** | 4.1 Extended Capability Register Window Map, `CMD_SET_VIEWPORT` (0x24) & `CMD_SET_SCISSOR` (0x25), Firmware Heap and Page Table Allocation ... | **PROT (version 1, N10).** Session protection registers at the capability's register offset |
| **N11** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor, Address Space Classification for Command Packets, 7.2 Structured Command Opcodes ... | Decoded as: $\text{PA\_BITS} = 40 + ((\text{raw} >> 4) \ \& \ 0\text{xF})$. (Note: PA refers strictl |
| **N12** | Address Space Classification for Command Packets, `CMD_FENCE`, `CMD_WAIT_FENCE` ... | #### Address Space Classification for Command Packets (M16, N07, N11, N12, N15) |
| **N13** | 7.2 Structured Command Opcodes, `CMD_COPY_BUFFER`, `CMD_COPY_IMAGE` ... | \| `0x40` \| `CMD_COPY_BUFFER` \| 8 \| `CAP_BLT` \| 2D DMA buffer-to-buffer transfer (flags & burst align |
| **N14** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor, 7.2 Structured Command Opcodes, `CMD_BIND_VERTEX_BUFFERS` ... | - `[15] CAP_MRT_BLEND`: Independent per-target color blending supported (N14). |
| **N15** | Address Space Classification for Command Packets, 7.2 Structured Command Opcodes, `CMD_BARRIER` ... | #### Address Space Classification for Command Packets (M16, N07, N11, N12, N15) |
| **N16** | 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies, 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor, 11.5.1 Cache Hierarchy and Internal Buffer Configuration ... | **Capability Authority and Resolution (N16, N18)**: |
| **N17** | 7.2 Structured Command Opcodes, `CMD_DRAW_INDIRECT`, `CMD_DISPATCH_INDIRECT` ... | \| `0x29` \| `CMD_DRAW_INDIRECT` \| 7 or 8 \| `CAP_INDIRECT_DRAW` \| MultiDrawIndirect (7 dw normal, 8 dw |
| **N18** | 3.2 Hardware Capabilities and Architecture Sizes, 3.2.1 DEVICE_CAPS — Architectural Capabilities & Topologies, 11.6 Session Protection & Virtual Memory Isolation | GHCI provides structured hardware capability discovery through early boot flags in `BOOT_CAPS` (offs |
| **N19** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor | #### 3.2.2 EXT_CAP_FEATURE (Capability Block Word 3, J06, K07, N19, N31) — Extended Feature & Addres |
| **N20** | 3.4 IRQ_STATUS and IRQ_ENABLE, 3.5 FAULT_INFO, FAULT_ADDR and DIAG, 12.6 ISA faults | \| [1] \| IRQ_FAULT \| Hardware, translation, framing, or execution fault latched into `FAULT_INFO` (N0 |
| **N21** | 3.4 IRQ_STATUS and IRQ_ENABLE, 6.2 Writing commands & Ring Wrap Rules, 9.2 Interrupts ... | ### 3.4 IRQ_STATUS and IRQ_ENABLE (0x038, 0x03C, J02, N21) |
| **N22** | `CMD_BIND_PIPELINE` | #### `CMD_BIND_PIPELINE` (0x20, N22) |
| **N23** | 7.2 Structured Command Opcodes, `CMD_SET_DYNAMIC_STATE`, Texture Descriptor (`GhciTextureDescriptor`, 32 Bytes) ... | \| `0x26` \| `CMD_SET_DYNAMIC_STATE` \| 6 \| Mandatory (Raster) \| Dynamic pipeline state override by `st |
| **N24** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor, 8.2 Immutable Pipeline State Object (`GhciPipelineState`), 8.5.2 Texture Dimensions and Image Layouts ... | - `[27:20] CAP_LDS_SIZE_KB`: Local Data Share capacity in KiB per Shader Unit (8-bit value, 0..255)  |
| **N25** | Address Space Classification for Command Packets, 7.2 Structured Command Opcodes, `CMD_FLIP` ... | - `base` in `CMD_FLIP` (dword 2-3 lo/hi) and display controller `FB_BASE` / `FB_NEXT`: 32-bit GPU ph |
| **N26** | 3.1 Canonical Register Map, 3.4 IRQ_STATUS and IRQ_ENABLE, 10. Faults, watchdog, quiesce and reset | \| 0x048 \| WDT_CYCLES \| RW \| Watchdog timeout limit in core clock cycles (reset default: `0x10000000` |
| **N27** | 6.4 How the CP reads the ring | ### 6.4 How the CP reads the ring (N27) |
| **N28** | 1.3 Terms, 4.1 Extended Capability Register Window Map, `CMD_BARRIER` ... | \| Session \| A GPU context that the driver opens for a client; identified by the session ID (0..15) o |
| **N29** | 1.4 Status of this specification, 13.3 Handing over a boot framebuffer | \| Host control registers, extended capabilities, CP states, the ring, fences, interrupts, faults, qu |
| **N30** | 3.1 Canonical Register Map, 8.6 Vulkan Hardware Limits and Standard Architectural Constants | \| 0x048 \| WDT_CYCLES \| RW \| Watchdog timeout limit in core clock cycles (reset default: `0x10000000` |
| **N31** | 3.2.2 EXT_CAP_FEATURE — Extended Feature & Address Width Descriptor, 8.6 Vulkan Hardware Limits and Standard Architectural Constants, 11.5.1 Cache Hierarchy and Internal Buffer Configuration | #### 3.2.2 EXT_CAP_FEATURE (Capability Block Word 3, J06, K07, N19, N31) — Extended Feature & Addres |
| **N32** | 7.2 Structured Command Opcodes, `CMD_BARRIER`, `CMD_FENCE` ... | ### 7.2 Structured Command Opcodes (include/ghci_cmd.h, M37, M38, N32) |
| **N33** | 12.9 Texture instructions, 12.11 Multisampling | ### 12.9 Texture instructions (Approved Architecture, N16, N33) |
| **N34** | 12.9 Texture instructions | (fp32 for float/unorm/snorm formats, raw 32-bit uint/sint bit patterns for integer formats; N34). Th |
| **N37** | 12.10.3 Shader Stage Register & Export Conventions | #### 12.10.3 Shader Stage Register & Export Conventions (N37, N38..N43) |
| **N38** | 12.10.3 Shader Stage Register & Export Conventions | #### 12.10.3 Shader Stage Register & Export Conventions (N37, N38..N43) |
| **N39** | 12.10.3 Shader Stage Register & Export Conventions | ##### 1. Vertex Shader Input Conventions (N38, N39) |
| **N40** | 12.10.3 Shader Stage Register & Export Conventions | ##### 2. Vertex Shader Output / Export Interface (N40, N41, N42) |
| **N41** | 12.10.3 Shader Stage Register & Export Conventions | ##### 2. Vertex Shader Output / Export Interface (N40, N41, N42) |
| **N42** | 12.10.3 Shader Stage Register & Export Conventions | ##### 2. Vertex Shader Output / Export Interface (N40, N41, N42) |
| **N43** | 12.10.3 Shader Stage Register & Export Conventions, 12.12 Colour outputs and primitive inputs | #### 12.10.3 Shader Stage Register & Export Conventions (N37, N38..N43) |
| **N44** | Dual-Source Blending & State Encodings, 12.10.3 Shader Stage Register & Export Conventions | #### Dual-Source Blending & State Encodings (N14, N44) |
| **N45** | 12.12 Colour outputs and primitive inputs | ### 12.12 Colour outputs and primitive inputs (Approved Architecture, N28, N43, N45) |
| **N47** | In-Memory Render Pass Descriptor | **Attachment Memory Layout & Subresource Rules (N47, N79)**: |
| **N48** | Address Space Classification for Command Packets, 11.6 Session Protection & Virtual Memory Isolation | - **Root Table Allocation Timing (N07, N48)**: At power-on / hardware reset, `CP_HEAP_BASE` and `CP_ |
| **N49** | 11.6 Session Protection & Virtual Memory Isolation | 4. **`CMD_SESSION_CLOSE(session_id)` (0x13, N48, N49)**: |
| **N50** | 3.5 FAULT_INFO, FAULT_ADDR and DIAG, 12.6 ISA faults | **FAULT_INFO (0x018, J03, K04, N20, N50, N63, N73)**: |
| **N51** | `CMD_DRAW_INDIRECT` | - **Standard Indirect Draw (7 dwords, N51)**: |
| **N53** | 8.5.1 Comprehensive Vulkan Format Features Table | \| `A2B10G10R10_UNORM_PACK32`\| 64 \| 4 B \| Point + Linear \| Yes (Blend) \| No \| Yes \| No \| Mandatory (N |
| **N57** | `CMD_FLIP` | - `dword 1`: `display_id` (0 = primary display controller at `DISP2` MMIO `0x200`; `display_id = 1`  |
| **N58** | 12.11 Multisampling | **Sample locations (N58, N68).** The standard locations: with 1 sample (0.5, 0.5); |
| **N59** | `CMD_BIND_VERTEX_BUFFERS`, `CMD_BIND_DESCRIPTOR_TABLE` (0x23), `CMD_COPY_IMAGE` | - *Robust Buffer Access (N59)*: In compliance with Vulkan `robustBufferAccess = true`, vertex fetch  |
| **N61** | Texture Descriptor (`GhciTextureDescriptor`, 32 Bytes), Sampler Descriptor, 8.4 Descriptor Tables, Push Constants & Shader Resource Binding ... | \| `0x1C` \| `component_swizzle` \| uint32_t \| Component swizzle mappings (N61): `[2:0]` R swizzle, `[5 |
| **N62** | 8.4 Descriptor Tables, Push Constants & Shader Resource Binding, Push Constants & Constant Register Bank, 12.4 Instruction format ... | - **Decoupled Combined Image / Sampler Indexing (N61, N62, N65, N74)**: |
| **N63** | 3.5 FAULT_INFO, FAULT_ADDR and DIAG | **FAULT_INFO (0x018, J03, K04, N20, N50, N63, N73)**: |
| **N64** | 11.6 Session Protection & Virtual Memory Isolation | - **Driver CP_HEAP Sizing Formula (N48, N64)**: |
| **N65** | 8.4 Descriptor Tables, Push Constants & Shader Resource Binding | - **Decoupled Combined Image / Sampler Indexing (N61, N62, N65, N74)**: |
| **N66** | 12.3 Operands, 12.10.3 Shader Stage Register & Export Conventions | \| 120 \| `vtx_idx` (`gl_VertexIndex`, uint32, Vertex Shader only; reads 0 in other stages, N61, N66,  |
| **N67** | 8.5.1 Comprehensive Vulkan Format Features Table | \| `R16G16B16A16_SFLOAT` \| 97 \| 8 B \| Point + Linear \| Yes (Blend) \| No \| Yes \| Yes (*1) \| Mandatory  |
| **N68** | 12.11 Multisampling | **Sample locations (N58, N68).** The standard locations: with 1 sample (0.5, 0.5); |
| **N69** | 3.4 IRQ_STATUS and IRQ_ENABLE | \| [6] \| IRQ_HALTED \| Core execution halted following `CTRL.HALT` (section 5.2, N69) \| |
| **N70** | 7.2 Structured Command Opcodes, `CMD_DISP_SET` | \| `0x50` \| `CMD_DISP_SET` \| 1+2N \| `CAP_DISP` \| Sets display controller registers (`flags[0]`: wait  |
| **N71** | 8.6 Vulkan Hardware Limits and Standard Architectural Constants | \| `subPixelPrecisionBits` \| 4 \| 4 bits subpixel precision (1/16 pixel grid rasterization, N71) \| |
| **N72** | 8.5.1 Comprehensive Vulkan Format Features Table, 12.8 Memory, 12.10.2 Unified Resource Binding Architecture | \| `ETC2_R8G8B8_UNORM_BLOCK` \| 147 \| 8 B \| Point + Linear \| No \| No \| No \| No \| Optional (`CAP_ETC2`, |
| **N73** | 3.5 FAULT_INFO, FAULT_ADDR and DIAG, 11.6 Session Protection & Virtual Memory Isolation, 12.6 ISA faults | **FAULT_INFO (0x018, J03, K04, N20, N50, N63, N73)**: |
| **N74** | 8.4 Descriptor Tables, Push Constants & Shader Resource Binding, Push Constants & Constant Register Bank, 8.5 Supported Image Formats, Texture Compression & Dimensions ... | - **Decoupled Combined Image / Sampler Indexing (N61, N62, N65, N74)**: |
| **N75** | 8.5 Supported Image Formats, Texture Compression & Dimensions, 8.5.1 Comprehensive Vulkan Format Features Table | covering Vulkan 1.0 core mandatory requirements (with pipeline limits noted in §8.6 and N74/N75). |
| **N76** | 12.6 ISA faults, 12.8 Memory | - `kind 10` (`GHCI_FAULT_KIND_PERM_FAULT` / `GHCI_FAULT_KIND_MEMORY_FAULT`): Reported for VM page pe |
| **N77** | Push Constants & Constant Register Bank, 8.5.1 Comprehensive Vulkan Format Features Table, 12.1 Overview ... | - **Decoupled Image & Sampler Slot Mapping (N02, N61, N62, N74, N77)**: |
| **N79** | In-Memory Render Pass Descriptor, 12.11 Multisampling | **Attachment Memory Layout & Subresource Rules (N47, N79)**: |
| **N80** | 3.3 CTRL and STATUS, 10. Faults, watchdog, quiesce and reset | - `[0] RESET`: 1 = Issue GPU software reset. Self-clearing; hardware resets core logic, pipeline blo |
| **N81** | `CMD_BEGIN_QUERY` (0x36) & `CMD_END_QUERY` (0x37) | - *Hardware Counter Architecture & Session Atomicity (N81)*: |
