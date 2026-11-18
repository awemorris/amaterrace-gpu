import json

trans_path = '/home/awe/.gemini/antigravity-cli/brain/b65542c1-84e7-4efa-8e70-3c74e0f5df89/.system_generated/logs/transcript_full.jsonl'
file_path = '/home/awe/amaterrace-gpu/rtl/gpu/blt/atg_blt_2d.v'

with open(file_path, 'r') as f:
    content = f.read()

target_lines = [
    4418, 4422, 4426, 4432, 4436, 4440, 4448, 4450, 4452, 4456, 4466, 4470, 4472, 4476,
    4579, 4583, 4609, 4679, 4689, 4749, 4753, 4755, 4759, 4789, 4793, 4797
]

with open(trans_path) as f:
    for i, line in enumerate(f):
        if i not in target_lines:
            continue
        obj = json.loads(line)
        for c in obj.get('tool_calls', []):
            if c.get('name') == 'edit_file' and 'atg_blt_2d.v' in c.get('args', {}).get('Path', ''):
                args = c['args']
                target = args['Target']
                replacement = args['Replacement']
                count = content.count(target)
                if count != 1:
                    print(f"Warning at line {i}: target matches {count} times!")
                else:
                    content = content.replace(target, replacement, 1)
                    print(f"Line {i} applied cleanly.")

with open(file_path, 'w') as f:
    f.write(content)
print("Restoration finished. File length:", len(content))
