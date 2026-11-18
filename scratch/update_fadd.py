with open('rtl/gpu/rx/atg_rx_fadd.v') as f:
    content = f.read()

# Replace module name
content = content.replace('module atg_rx_fadd', 'module atg_rop_fadd')
content = content.replace('atg_rx_fadd: optimized fp32 adder / subtractor', 'atg_rop_fadd: optimized fp32 adder / subtractor')

with open('rtl/gpu/rop/atg_rop_fadd.v', 'w') as f:
    f.write(content)

print("Updated rtl/gpu/rop/atg_rop_fadd.v successfully!")
