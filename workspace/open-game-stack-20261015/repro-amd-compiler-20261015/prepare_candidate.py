"""Offline replay of the narrowly qualified generated-MSL experiment, NOT a runtime pass.

Refuses every other source revision. A general native conversion rule must prove
address-only def/use and preserve ABI before being enabled for other shaders.
"""
import difflib
import hashlib
from pathlib import Path
import re

root = Path(__file__).resolve().parent
source = root / 'input/shader-fs-25f807389203fa9a.metal'
raw = source.read_bytes()
assert hashlib.sha256(raw).hexdigest() == '44ed154b9dbf13a19f14218f5954537d6b8c68e7b87348bdf3854791d5d1e628'
before = raw.decode()
after = before
for index in range(5):
    old = f'uint2 _m{index};'
    assert after.count(old) == 1
    after = after.replace(old, f'const device uchar* _m{index};')
for name in ('78', '80', '82', '85'):
    old = f'uint2 _{name};'
    assert after.count(old) == 1
    after = after.replace(old, f'const device uchar* _{name};')
after, count = re.subn(r'as_type<ulong>\((_78|_80|_82|_85)\)', r'\1', after)
assert count == 41
assert before.count('is_null_texture(') == after.count('is_null_texture(') == 4
assert before.count('.sample(') == after.count('.sample(') == 4
assert before.count('if (') == after.count('if (')
target = root / 'variants/typed-root-pointers.metal'
if target.exists():
    assert target.read_text() == after, 'Never silently replace a different qualified candidate'
else:
    target.write_text(after)
patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                   fromfile='original-generated.metal', tofile='typed-root-pointers.metal'))
(root / 'generated-msl-typed-root-pointers.patch').write_text(patch)
print(hashlib.sha256(after.encode()).hexdigest(), target)
