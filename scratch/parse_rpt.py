import re
from collections import defaultdict

with open("build/asic_lint/atg_tu/asic_lint.rpt") as f:
    text = f.read()

modules = defaultdict(lambda: defaultdict(int))

# Rule 1
r1 = text[text.find("[RULE 1]"):text.find("[RULE 2]")]
for m in re.finditer(r"VIOLATION \(([^)]+)\):.*?Path: (\S+) --> (\S+)", r1, re.DOTALL):
    kind = m.group(1)
    sp = m.group(2)
    mod = sp.split("/")[0] if "/" in sp else "top"
    modules[mod]["Rule1_" + kind] += 1

for d in re.findall(r"VIOLATION \(DSP Internal Latency\): (\S+)", r1):
    mod = d.split("/")[0] if "/" in d else "top"
    modules[mod]["Rule1_DSP_LAT"] += 1

# Rule 2
r2 = text[text.find("[RULE 2]"):text.find("[RULE 3]")]
for net, fo in re.findall(r"Net \x27([^\x27]+)\x27 has fanout (\d+)", r2):
    if int(fo) > 24:
        mod = net.split("/")[0] if "/" in net else "top"
        modules[mod]["Rule2_Fanout"] += 1

# Rule 3
r3 = text[text.find("[RULE 3]"):text.find("[RULE 4]")]
for m in re.finditer(r"VIOLATION \(Feedthrough\)", r3):
    modules["top"]["Rule3_Feedthrough"] += 1

# Rule 4
r4 = text[text.find("[RULE 4]"):text.find("[RULE 5]")]
for mem in re.findall(r"Memory \x27([^\x27]+)\x27", r4):
    mod = mem.split("/")[0] if "/" in mem else "top"
    modules[mod]["Rule4_RAM"] += 1

hdr = "Submodule".ljust(20) + " | " + "Total".ljust(6) + " | Details"
print(hdr)
print("-" * 75)
for mod in sorted(modules.keys(), key=lambda m: sum(modules[m].values()), reverse=True):
    tot = sum(modules[mod].values())
    det = ", ".join(f"{k}: {v}" for k, v in sorted(modules[mod].items()))
    print(f"{mod:<20} | {tot:<6} | {det}")
