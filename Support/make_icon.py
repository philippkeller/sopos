import sys, cairosvg
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen

font_path, out, variant, weight = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
font = instantiateVariableFont(TTFont(font_path), {"wght": weight})
gs, cmap = font.getGlyphSet(), font.getBestCmap()
cap = font["OS/2"].sCapHeight

def glyph(ch):
    name = cmap[ord(ch)]
    pen = SVGPathPen(gs); gs[name].draw(pen)
    b = BoundsPen(gs); gs[name].draw(b)
    return pen.getCommands(), b.bounds

# Portishead "P" (path from Wikimedia Portishead.svg), bounds x 224.87..578.79, y 154.71..884.05
P = "M 379.24501,272.24557 L 379.24501,522.23067 C 380.9991,522.23103 383.48433,522.37722 386.7007,522.66924 C 389.91669,522.96198 392.25573,523.10817 393.71783,523.10781 C 405.41282,523.10817 413.38018,521.06151 417.61991,516.96783 C 421.85919,512.87487 423.97895,505.27299 423.97918,494.16217 L 423.97918,474.4265 L 423.97918,311.7169 C 423.97895,293.58992 421.93229,282.47948 417.8392,278.38555 C 413.74565,274.29284 405.41282,272.24618 392.84069,272.24557 L 379.24501,272.24557 z M 224.86824,884.05121 L 224.86824,154.70872 L 400.73495,154.70872 C 477.33829,154.70945 526.16574,163.40775 547.21745,180.80365 C 568.26845,198.20096 578.79413,239.79201 578.79452,305.57692 L 578.79452,488.02218 C 578.79413,554.39282 568.19536,596.27625 546.99816,613.67259 C 525.80026,631.06946 477.33829,639.76777 401.61209,639.76752 L 379.24501,639.76752 L 379.24501,884.05121 L 224.86824,884.05121 z"
px0, py0, px1, py1 = 224.86824, 154.70872, 578.79452, 884.05121

SIZE, CAP_PX, GAP = 1024, 150, 46
s = CAP_PX / cap
pieces = []  # (width_px, svg_fn(x, baseline))

def letter(ch):
    d, (x0, y0, x1, y1) = glyph(ch)
    w = (x1 - x0) * s
    return w, lambda x, base: f'<path transform="translate({x - x0*s:.2f},{base:.2f}) scale({s:.5f},{-s:.5f})" d="{d}" fill="#fff"/>'

def portishead_p():
    if variant == "bare":
        h = CAP_PX * 1.12; k = h / (py1 - py0); w = (px1 - px0) * k
        def draw(x, base):
            top = base - CAP_PX/2 - h/2
            return f'<path transform="translate({x - px0*k:.2f},{top - py0*k:.2f}) scale({k:.5f})" d="{P}" fill="#fff"/>'
        return w, draw
    # boxed: the full Portishead tile (white frame, black inside, white P)
    h = CAP_PX * 1.75; k = h / 1040; w = 800 * k
    def draw(x, base):
        top = base - CAP_PX/2 - h/2
        return (f'<g transform="translate({x:.2f},{top:.2f}) scale({k:.5f})">'
                f'<rect x="31" y="28" width="742" height="983" fill="#fff" stroke="#fff" stroke-width="39"/>'
                f'<rect x="68" y="61.5" width="668" height="916" fill="#000"/>'
                f'<path d="{P}" fill="#fff"/></g>')
    return w, draw

pieces = [letter("S"), letter("O"), portishead_p(), letter("O"), letter("S")]
total = sum(w for w, _ in pieces) + GAP * (len(pieces) - 1)
x, base = (SIZE - total) / 2, SIZE / 2 + CAP_PX / 2
body = []
for w, draw in pieces:
    body.append(draw(x, base)); x += w + GAP
svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}"><rect width="100%" height="100%" fill="#000"/>{"".join(body)}</svg>'
cairosvg.svg2png(bytestring=svg.encode(), write_to=out, output_width=SIZE, output_height=SIZE)
print(out, round(total))
