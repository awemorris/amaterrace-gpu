Amaterrace GPU
==============

`Amaterrace GPU` is an RTL GPU implementation.

- GHCI ... A standard HCI for Vulkan-compatible GPUs that this project proposes.
- DC ... Display Controller Block
- CP ... Command Processor Block
- BLT ... Blitter Block
- VF ... Vertex Fetcher Block
- RX ... Rasterizer Block
- SU ... Shader Unit Block
- TU ... Texture Unit Block
- ROP ... Buffer Writer Block
- MC ... Memory Controller Block

Overall Architecture:
```
CPU -- (AXI4) -- Command Processor

Fill/Copy:
CP --> BLT --> MC

Primitive:
CP --> VF --> SU --> RX --> SU --> ROP --> MC
                            |
                            +--> TU
```

Shader Architecture:
- Warp: 32-lane scalar with 16-bit packed
- Register File: xxx
```

Synthesis goal is 200MHz on KC705 board.
