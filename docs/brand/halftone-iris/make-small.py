"""AppIcon-small.svg: the halftone iris at half the density, for small sizes.

The full icon's dots sit on a 32-unit grid; at 64 px and under they blur
into a grey ring. Here the same pattern — every dot's radius read off the
full icon's radial profile, ring and pupil — is laid on a 48-unit grid with
dots half as large again, so it stays a halftone eye where the full one
cannot. Run from this folder: python3 make-small.py
"""
import math, re

source = open("AppIcon.svg").read()
dots = [(float(x), float(y), float(r)) for x, y, r in
        re.findall(r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"', source)]
profile_points = sorted((math.hypot(x - 512, y - 512), r) for x, y, r in dots)
nearest = profile_points[0][0]  # the pupil's own dots, the closest to the centre

def radius_at(d):
    # Inside the pupil's dots the pupil only grows: hold their radius to the centre.
    d = max(d, nearest)
    weights = [math.exp(-((d - pd) / 10) ** 2) for pd, _ in profile_points]
    total = sum(weights)
    return 0 if total < 0.05 else sum(w * r for w, (_, r) in zip(weights, profile_points)) / total

STEP, BOLD = 48, 1.12
small = []
n = int(360 / STEP) + 1
for i in range(-n, n + 1):
    for j in range(-n, n + 1):
        x, y = 512 + i * STEP, 512 + j * STEP
        r = radius_at(math.hypot(x - 512, y - 512)) * STEP / 32 * BOLD
        if r >= 1.6 * STEP / 32:
            small.append(f'<circle cx="{x}" cy="{y}" r="{r:.1f}"/>')

out = re.sub(r'<metadata>.*?</metadata>', '', source, flags=re.S)
out = out.replace(' xmlns:c2pa="http://c2pa.org/manifest"', '')
out = re.sub(r'<circle[^>]*>(</circle>)?', '', out)
out = out.replace('</svg>', f'<g fill="#0A0A0A">{"".join(small)}</g></svg>')
open("AppIcon-small.svg", "w").write(out)
print(f"{len(small)} dots")
