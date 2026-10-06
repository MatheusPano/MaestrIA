"""Gera os arquivos de marca da MaestrIA: ícone do app (D) e marca/logotipo (B).

uso: python build.py <Geist.ttf> <saida>
"""
import subprocess, sys, pathlib
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

FONT, OUT = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
(OUT / 'branding').mkdir(parents=True, exist_ok=True)
(OUT / 'png').mkdir(parents=True, exist_ok=True)

ACCENT = '<stop offset="0" stop-color="#7AA2F7"/><stop offset="1" stop-color="#C3A6FF"/>'
GLOW = '<stop offset="0" stop-color="#C3A6FF" stop-opacity=".55"/><stop offset="1" stop-color="#C3A6FF" stop-opacity="0"/>'

# O M regente, no espaço de 1024 do ícone.
M_REGENTE = '''<path d="M290 730 V 380 Q 290 330 324 368 L 500 572" fill="none" stroke="url(#ac)" stroke-width="82" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M471 545 L 733 245 L 757 266 L 529 599 Q 500 630 471 600 Q 445 572 471 545 Z" fill="url(#ac)"/>'''

def tip(color, glow):
    g = '<circle cx="752" cy="268" r="110" fill="url(#glow)"/>\n' if glow else ''
    return g + f'<circle cx="752" cy="268" r="40" fill="{color}"/>'

def defs(extra=''):
    return f'''<defs>
<linearGradient id="ac" gradientUnits="userSpaceOnUse" x1="260" y1="780" x2="780" y2="250">{ACCENT}</linearGradient>
<radialGradient id="glow" cx=".5" cy=".5" r=".5">{GLOW}</radialGradient>{extra}
</defs>'''

def svg(view, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}">\n{body}\n</svg>\n'

# --- Ícone do app (D): o M aponta o painel aceso -------------------------------

PANES = '''<g fill="#2C313A" opacity=".8">
<rect x="236" y="236" width="258" height="258" rx="58"/>
<rect x="236" y="530" width="258" height="258" rx="58"/>
<rect x="530" y="530" width="258" height="258" rx="58"/>
</g>
<rect x="530" y="236" width="258" height="258" rx="58" fill="url(#ac)" opacity=".28"/>
<rect x="531.5" y="237.5" width="255" height="255" rx="56.5" fill="none" stroke="url(#ac)" stroke-width="3" opacity=".7"/>'''

BG_DEFS = '''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#20242C"/><stop offset="1" stop-color="#0D0F13"/></linearGradient>
<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".5" stop-color="#fff" stop-opacity=".03"/><stop offset="1" stop-color="#fff" stop-opacity=".06"/></linearGradient>
<filter id="shadow" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".3"/></filter>'''

def app_icon(shadow):
    sh = ' filter="url(#shadow)"' if shadow else ''
    return defs(BG_DEFS) + f'''
<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#bg)"{sh}/>
<rect x="101.5" y="101.5" width="821" height="821" rx="184.5" fill="none" stroke="url(#rim)" stroke-width="3"/>
{PANES}
{M_REGENTE}
{tip('#fff', True)}'''

# macOS: o quadrado de 824 com margem e sombra, como o gabarito da Apple pede.
(OUT / 'branding/app-icon.svg').write_text(svg('0 0 1024 1024', app_icon(True)))
# Windows: sem a margem do macOS, o desenho ocupa o quadro todo.
(OUT / 'branding/app-icon-windows.svg').write_text(svg('100 100 824 824', app_icon(False)))

# --- Marca (B) ------------------------------------------------------------------

MARK_VIEW = (210, 130, 690, 690)

def mark_body(tip_color, glow):
    return f'{M_REGENTE}\n{tip(tip_color, glow)}'

(OUT / 'branding/mark.svg').write_text(svg(' '.join(map(str, MARK_VIEW)), defs() + '\n' + mark_body('#FFFFFF', True)))
(OUT / 'branding/mark-light.svg').write_text(svg(' '.join(map(str, MARK_VIEW)), defs() + '\n' + mark_body('#3D6FE0', False)))

# --- Logotipo: marca + "MaestrIA" em Geist, convertido em curvas -----------------

def instance(weight):
    f = TTFont(FONT)
    return instantiateVariableFont(f, {'wght': weight}), hb.Font(hb.Face(hb.Blob.from_file_path(str(FONT))))

def outline(text, weight, x0, baseline, size, tracking):
    """Desenha `text` como paths, com a forma e o kerning da Geist no peso pedido."""
    tt, hbfont = instance(weight)
    hbfont.set_variations({'wght': weight})
    buf = hb.Buffer(); buf.add_str(text); buf.guess_segment_properties()
    hb.shape(hbfont, buf, {'kern': True, 'liga': True})
    upem = tt['head'].unitsPerEm
    scale = size / upem
    gs = tt.getGlyphSet()
    order = tt.getGlyphOrder()
    paths, x = [], x0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        name = order[info.codepoint]
        pen = SVGPathPen(gs)
        gx = x + pos.x_offset * scale
        gs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, gx, baseline)))
        paths.append(pen.getCommands())
        x += pos.x_advance * scale + tracking * size
    return ' '.join(p for p in paths if p), x - tracking * size

# O M da marca vai de 330 a 771. O texto tem 62% dessa altura em maiúsculas e
# fica centrado no M: do tamanho inteiro, ele pesa mais que o traço da marca.
M_TOP, M_BOTTOM = 330, 771
CAP = 710 / 1000
CAP_H = (M_BOTTOM - M_TOP) * 0.62
BASELINE = (M_TOP + M_BOTTOM) / 2 + CAP_H / 2
TEXT_TOP = BASELINE - CAP_H
SIZE = CAP_H / CAP
TRACK = -0.02
X0 = 850

def lockup(fg, ia_from, ia_to, tip_color, glow):
    d1, x1 = outline('Maestr', 500, X0, BASELINE, SIZE, TRACK)
    d2, x2 = outline('IA', 600, x1 + TRACK * SIZE, BASELINE, SIZE, TRACK)
    extra = f'\n<linearGradient id="ia" gradientUnits="userSpaceOnUse" x1="{x1:.0f}" y1="{BASELINE:.0f}" x2="{x2:.0f}" y2="{TEXT_TOP:.0f}"><stop offset="0" stop-color="{ia_from}"/><stop offset="1" stop-color="{ia_to}"/></linearGradient>'
    body = defs(extra) + f'\n{mark_body(tip_color, glow)}\n<path d="{d1}" fill="{fg}"/>\n<path d="{d2}" fill="url(#ia)"/>'
    x, y, w, h = MARK_VIEW
    return svg(f'{x} {y} {x2 + 60 - x:.0f} {h}', body)

(OUT / 'branding/logo.svg').write_text(lockup('#E6E8EB', '#7AA2F7', '#B08CFF', '#FFFFFF', True))
(OUT / 'branding/logo-light.svg').write_text(lockup('#1A1D23', '#3D6FE0', '#8257D8', '#3D6FE0', False))

# --- Exportações ----------------------------------------------------------------

def png(src, dst, w, h=None):
    subprocess.run(['resvg', '-w', str(w), '-h', str(h or w), str(src), str(dst)], check=True)

b = OUT / 'branding'
for s in (16, 32, 64, 128, 256, 512, 1024):
    png(b / 'app-icon.svg', OUT / f'png/app_icon_{s}.png', s)
ico_sizes = (16, 24, 32, 48, 64, 128, 256)
for s in ico_sizes:
    png(b / 'app-icon-windows.svg', OUT / f'png/win_{s}.png', s)
subprocess.run(['magick', *[str(OUT / f'png/win_{s}.png') for s in ico_sizes], str(OUT / 'png/app_icon.ico')], check=True)

png(b / 'app-icon.svg', b / 'app-icon.png', 1024)
png(b / 'mark.svg', b / 'mark.png', 512)
png(b / 'mark-light.svg', b / 'mark-light.png', 512)
for name in ('logo', 'logo-light'):
    subprocess.run(['resvg', '-h', '256', str(b / f'{name}.svg'), str(b / f'{name}.png')], check=True)
print('ok')
