"""Writes the menu-bar template icons (wax seal) as SVG: design/MenuBarSeal*.svg.

Single black shape with the mark knocked out (even-odd), so macOS can tint it.
"""
import math, os

HERE = os.path.dirname(os.path.abspath(__file__))
CX, CY, R = 18, 15, 12.2

def seal():
    pts = []
    for i in range(0, 360, 3):
        a = math.radians(i)
        r = R + 1.1 * math.sin(12 * a)
        pts.append((CX + r * math.cos(a), CY + r * math.sin(a)))
    return pts

def thick_polyline(points, w):
    """Outline of a polyline stroked with width w (mitred joins, flat ends)."""
    h = w / 2
    def normal(p, q):
        dx, dy = q[0] - p[0], q[1] - p[1]
        l = math.hypot(dx, dy)
        return (-dy / l * h, dx / l * h)
    left, right = [], []
    for i, p in enumerate(points):
        ns = []
        if i > 0: ns.append(normal(points[i - 1], p))
        if i < len(points) - 1: ns.append(normal(p, points[i + 1]))
        nx, ny = sum(n[0] for n in ns) / len(ns), sum(n[1] for n in ns) / len(ns)
        k = h * h / (nx * nx + ny * ny)  # mitre length correction
        nx, ny = nx * k, ny * k
        left.append((p[0] + nx, p[1] + ny)); right.append((p[0] - nx, p[1] - ny))
    return left + right[::-1]

def circle(cx, cy, r, n=24):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]

def path(*polys):
    return " ".join("M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in p) + " Z" for p in polys)

tails = [[(13.0, 24.5), (10.0, 34.5), (13.4, 32.6), (15.6, 35.4), (17.4, 26.5)],
         [(23.0, 24.5), (26.0, 34.5), (22.6, 32.6), (20.4, 35.4), (18.6, 26.5)]]
check = thick_polyline([(12.6, 15.2), (16.4, 19.0), (23.4, 11.4)], 3.4)
bang = [[(16.3, 7.6), (19.7, 7.6), (19.2, 17.0), (16.8, 17.0)], circle(18, 20.6, 1.9)]

def svg(marks):
    d = path(seal(), *marks)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="108" height="108" viewBox="0 0 36 36">'
            f'<path d="{d}" fill="#000" fill-rule="evenodd"/>'
            f'<path d="{path(*tails)}" fill="#000"/></svg>')

for name, marks in (("MenuBarSeal", [check]), ("MenuBarSealWarning", bang)):
    with open(os.path.join(HERE, f"{name}.svg"), "w") as f:
        f.write(svg(marks))
