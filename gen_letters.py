#!/usr/bin/env python3
"""
gen_letters.py - turn TrueType letters into morph data for morph.asm.

OVERVIEW
    morph.asm traces a letter's outline, then morphs it into the next
    letter of a message, and so on. This program does all the work
    that can be done in advance, on a PC, so the BBC Micro only does
    what has to happen live. In order:

    1. LETTERS. Each different letter of the message is read from a
       TrueType font, scaled so a capital H is CAP pixels tall, and
       turned into closed loops of quadratic Bezier segments (see
       morph.asm, header section 4):
         * straight edges become quadratics with the control point at
           the middle;
         * neighbouring quadratics are merged where one curve stays
           within MERGE_TOL pixels of the original (fewer segments =
           faster drawing);
         * long ones are split so no control-polygon leg exceeds
           LEGMAX pixels in x or y (keeps the 6502's numbers in range);
         * coordinates are rounded to half pixels and stored as bytes;
         * up to three loops per letter (outer edge, holes, dots).
       Each letter is stored once, however often it appears.

    2. PLANS. Each change of letter (H->e, e->l, ...) gets a small
       pairing plan, which the 6502 follows at the start of the morph
       to build two outlines with the same number of segments, point
       for point (morph.asm, header section 6):
         * Loops are paired outer with outer, the rest by nearest
           centre. A loop with no partner collapses to a point at its
           own centre, so it grows or shrinks in place.
         * A pair running opposite ways round is traversed backwards
           on one side, or the morph would turn it inside out.
         * The pair is matched by arc length (distance along the
           outline): the loop with fewer segments is split (at stored
           8-bit t values) at the same fractions of the way round as
           the other's segment joins, and the other's start point is
           rotated to the best fit, so the morph doesn't twist.

    3. STEPS. The animation as a list of steps: trace the first
       letter, then morph to each next letter, each followed by a
       pause (longer at the end of a word). A letter that follows
       itself ("ll") is traced again instead.

    4. PLACEMENT. The letters are centred on the 256 x 256 screen.
       Then the whole animation is run through morphmodel.py (an exact
       copy of the 6502's arithmetic) to find exactly which pixels
       each transition draws: the 6502 only clears that box.

    5. OUTPUT. Writes OUT.asm (the data block, assembled at &0E00),
       OUT_def.asm (constants) and OUT.json (everything, for testing).

TERMS
    Quadratic Bezier segment: a curve from P0 to P2 pulled towards a
        control point P1. Here a segment is a tuple (P0, P1, P2) of
        (x, y) pairs, in pixels, y up.
    Loop / contour: a closed chain of segments; each one's P2 is the
        next one's P0.
    Control polygon: the lines P0-P1-P2. The curve lies inside the
        triangle they make. A "leg" is P0-P1 or P1-P2.
    t: the curve's parameter, 0 at P0 to 1 at P2. Stored for the 6502
        as t * 256 in one byte.
    Arc length: the length of a curve, measured along it.
    Signed area: computed with the "shoelace formula"; positive for a
        loop that goes anticlockwise, negative for clockwise. Fonts
        go round outer edges one way and holes the other.
    Letter-local coordinates: x from the left of a letter box, y up
        from its bottom; XORG/YORG place that box on the screen.

Usage: gen_letters.py FONT.ttf OUT.asm OUT.json ["MESSAGE" [CAP_HEIGHT]]
"""
import json, math, os, sys
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.boundsPen import BoundsPen
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import morphmodel

# ------------------------------------------------------------ settings
FONT, OUT_ASM, OUT_JSON = sys.argv[1:4]
MESSAGE = sys.argv[4] if len(sys.argv) > 4 else "Hello Stardot from the BBC Micro"
CAP = float(sys.argv[5]) if len(sys.argv) > 5 else 80   # cap height in pixels
XC = 50               # letter-local x of each letter's centre
YB = 4                # letter-local y of the baseline
LEGMAX = 40           # max control-polygon leg per axis (keeps lines <= 80 px)
                      # and so the 6502's 8-bit bend estimate (at most
                      # 2 * LEGMAX) fits a signed byte
MERGE_TOL = 0.5       # max deviation (pixels) when merging neighbouring curves
SCREEN_CX = 128       # screen x of the letter centre (256-pixel screen)
ROWB = 256            # bytes per character row (32 columns)
HOLD, HOLD_SPACE, TRACE_FRAMES = 20, 45, 32   # frames: pause, pause at a
                                              # word's end, tracing
# Easing: per-frame step sizes in units of (target - start) / 64.
# Ramps up, cruises, ramps down; the last frame lands exactly.
# (The 6502 precomputes 1, 2, 3 and 4 steps for every point, so the
# sizes must be 1-4, and they must add up to 64 to arrive.)
EASE = [1, 2, 2, 3] + [4] * 12 + [3, 2, 2, 1]
assert sum(EASE) == 64 and max(EASE) <= 4

font = TTFont(FONT)
gs = font.getGlyphSet()
cmap = font.getBestCmap()               # character -> glyph name
bp = BoundsPen(gs); gs[cmap[ord('H')]].draw(bp)
SCALE = CAP / bp.bounds[3]              # font units -> pixels: H is CAP tall


# ------------------------------------------------------------ geometry
def mid(a, b): return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
def dist(a, b): return math.hypot(a[0] - b[0], a[1] - b[1])
def line_quad(a, b): return (a, mid(a, b), b)   # a straight edge as a quadratic


def qpoint(q, t):
    """The point at t on quadratic q: (1-t)^2 P0 + 2t(1-t) P1 + t^2 P2."""
    a, b, c = q
    return tuple((1 - t) ** 2 * a[i] + 2 * (1 - t) * t * b[i] + t * t * c[i] for i in range(2))


def area(c):
    """Signed area of a loop's control polygon (shoelace formula):
    the sign says which way round it goes."""
    pts = [p for q in c for p in q[:2]]
    return sum(pts[i][0] * pts[i - 1][1] - pts[i - 1][0] * pts[i][1] for i in range(len(pts))) / 2


def leg(q):
    """The longest control-polygon leg, in x or y."""
    return max(abs(q[1][0] - q[0][0]), abs(q[1][1] - q[0][1]),
               abs(q[2][0] - q[1][0]), abs(q[2][1] - q[1][1]))


def split_at(q, t):
    """De Casteljau: split q at t into two quadratics that together are
    exactly the same curve. AB and BC are t of the way along each leg;
    M, t of the way from AB to BC, is on the curve."""
    a, b, c = q
    ab = (a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]))
    bc = (b[0] + t * (c[0] - b[0]), b[1] + t * (c[1] - b[1]))
    m = (ab[0] + t * (bc[0] - ab[0]), ab[1] + t * (bc[1] - ab[1]))
    return (a, ab, m), (m, bc, c)


def qlength(q, n=24):
    """Arc length of q, approximately: the length of n chords."""
    pts = [qpoint(q, i / n) for i in range(n + 1)]
    return sum(dist(a, b) for a, b in zip(pts, pts[1:]))


def t_at_length(q, frac):
    """The t at which a fraction frac of q's length has been covered.
    (t isn't proportional to distance along a curve, so it is found by
    walking along 64 chords.)"""
    n = 64
    pts = [qpoint(q, i / n) for i in range(n + 1)]
    seg = [dist(a, b) for a, b in zip(pts, pts[1:])]
    goal, acc = frac * sum(seg), 0.0
    for i, d in enumerate(seg):
        if acc + d >= goal:
            return (i + (goal - acc) / d) / n if d else i / n
        acc += d
    return 1.0


def merge_pair(qa, qb):
    """One quadratic replacing qa then qb, or None if it's not close enough.

    The new curve keeps qa's start and qb's end. Its control point is
    where the two end tangents meet: the line from qa's start towards
    its control point, and the line from qb's end back towards its
    control point. Then the new curve leaves and arrives in the same
    directions, so the outline stays smooth at the joins. If those
    lines are parallel (both pieces straight and in line), the control
    point goes in the middle. If they meet behind the start, no
    quadratic fits.

    It is accepted only if every sampled point of the old pair is
    within MERGE_TOL of the new curve AND every sampled point of the
    new curve is within MERGE_TOL of the old pair (the distance both
    ways, so neither can bulge away from the other)."""
    p0, p2 = qa[0], qb[2]
    ta = (qa[1][0] - qa[0][0], qa[1][1] - qa[0][1])     # start tangent
    tb = (qb[2][0] - qb[1][0], qb[2][1] - qb[1][1])     # end tangent
    den = ta[0] * tb[1] - ta[1] * tb[0]                 # cross product
    if abs(den) < 1e-9:
        c = mid(p0, p2)
    else:
        # p0 + s ta lies on the end tangent line: solve for s
        s = ((p2[0] - p0[0]) * tb[1] - (p2[1] - p0[1]) * tb[0]) / den
        if s <= 0:
            return None
        c = (p0[0] + s * ta[0], p0[1] + s * ta[1])
    m = (p0, c, p2)
    curve = [qpoint(m, i / 64) for i in range(65)]
    for q in (qa, qb):
        for i in range(17):
            if min(dist(qpoint(q, i / 16), r) for r in curve) > MERGE_TOL:
                return None
    for i in range(0, 65, 4):
        if min(dist(curve[i], qpoint(q, j / 32)) for q in (qa, qb) for j in range(33)) > MERGE_TOL:
            return None
    return m


def simplify(c):
    """Merge neighbouring segments of loop c (including the last with
    the first) while any pair can be merged; keep at least three."""
    c = list(c)
    while len(c) > 3:
        for i in range(len(c)):
            m = merge_pair(c[i], c[(i + 1) % len(c)])
            if m:
                if i + 1 < len(c): c[i:i + 2] = [m]
                else: c[i] = m; del c[0]        # the pair wrapped round
                break
        else:
            return c                            # nothing more to merge
    return c


def leg_limit(c):
    """Halve the segment with the longest leg until no leg is over
    LEGMAX. Halving a segment halves its legs and doesn't change the
    curve."""
    c = list(c)
    while True:
        i = max(range(len(c)), key=lambda j: leg(c[j]))
        if leg(c[i]) <= LEGMAX:
            return c
        a, b = split_at(c[i], 0.5); c[i:i + 1] = [a, b]


# ------------------------------------------------------------ letters
def glyph(ch):
    """Contours of ch: lists of quads in local pixels, quantised to half pixels.

    The font's drawing instructions are recorded with a "pen":
        moveTo     start a new loop
        lineTo     a straight edge
        qCurveTo   one or more quadratics. TrueType saves space by
                   listing several control points in a row: between
                   two of them there is an on-curve point that isn't
                   stored, exactly halfway between them.
        closePath  end the loop (with a straight edge back to the start
                   if it isn't there already)
    The letter is centred on x = XC, its baseline at y = YB.

    Returns, for each loop (largest first, so the outer edge comes
    first), a list of half-pixel points: each segment's start point
    and control point, which is how the 6502 stores them."""
    pen = DecomposingRecordingPen(gs)       # (decomposing: accented
    gs[cmap[ord(ch)]].draw(pen)             # letters built from parts)
    b = BoundsPen(gs); gs[cmap[ord(ch)]].draw(b)
    cx = (b.bounds[0] + b.bounds[2]) / 2
    P = lambda p: ((p[0] - cx) * SCALE + XC, p[1] * SCALE + YB)
    conts, cur, start = [], None, None
    for op, args in pen.value:
        if op == 'moveTo':
            cur = start = P(args[0]); conts.append([])
        elif op == 'lineTo':
            n = P(args[0]); conts[-1].append(line_quad(cur, n)); cur = n
        elif op == 'qCurveTo':
            pts = [P(a) for a in args]
            offs, end = pts[:-1], pts[-1]               # control points, end
            for i, c in enumerate(offs):
                e = end if i == len(offs) - 1 else mid(c, offs[i + 1])  # implied point
                conts[-1].append((cur, c, e)); cur = e
        elif op == 'closePath':
            if dist(cur, start) > 1e-6:
                conts[-1].append(line_quad(cur, start))
            cur = start
    # drop segments of no length, then merge and split
    conts = [[q for q in c if dist(q[0], q[2]) > 1e-6 or dist(q[0], q[1]) > 1e-6] for c in conts]
    conts = [leg_limit(simplify(c)) for c in conts]
    conts.sort(key=lambda c: -abs(area(c)))
    assert len(conts) <= 3, ch
    out = []
    for c in conts:                     # quantise: points p0, ctrl per segment
        pts = [tuple(round(v * 2) for v in p) for q in c for p in q[:2]]
        assert all(0 <= v <= 254 for p in pts for v in p), (ch, pts)    # fits a byte
        out.append(pts)
    return out


def quads(pts):
    """Half-pixel point list -> float quads in pixels."""
    n = len(pts) // 2
    f = lambda p: (p[0] / 2, p[1] / 2)
    return [(f(pts[2 * j]), f(pts[2 * j + 1]), f(pts[2 * ((j + 1) % n)])) for j in range(n)]


def centre_half(pts):
    """A loop's centre (the average of its points), in half pixels."""
    return (round(sum(p[0] for p in pts) / len(pts)), round(sum(p[1] for p in pts) / len(pts)))


# ------------------------------------------------------------ pairing
def fractions(c):
    """For each segment of loop c, how far round the loop (as a
    fraction of its whole length) it starts; also each segment's
    length, and the total."""
    lens = [qlength(q) for q in c]
    tot, acc, out = sum(lens), 0.0, []
    for l in lens:
        out.append(acc / tot); acc += l
    return out, lens, tot


def match_into(short, target):
    """Split 'short' so its joins line up with the target fractions.
    Returns (split contour, cuts) with cuts = [(segment, t relative to the
    remaining piece), ...] in order.

    'target' lists where the longer loop's segment joins are, as
    fractions of the way round. The short loop has fewer joins.

    First each short join is matched to a different target join, in
    order, so that the total mismatch (the sum of the differences in
    fraction) is smallest. This is a small dynamic programming problem:
        cost[j][k] = the least total mismatch for short joins 0..j,
                     with join j matched to target join k
                   = |F[j] - target[k]| + the least cost[j-1][k'] over k' < k
    and 'back' remembers which k' gave it, to trace the best matching
    back from the end. Join 0 is always matched to join 0 (both loops
    start together).

    Every target join left unmatched needs a new join (a split) on the
    short loop. It goes at the same relative position between the
    matched joins either side of it: e.g. a target join halfway
    between two matched ones is placed halfway between their partners.

    Each new join is then turned into a split of the short segment it
    falls in: the t that is that far along the segment (by length),
    rounded to 8 bits (1-255) as the 6502 will use it."""
    F, lens, tot = fractions(short)
    m, n = len(F), len(target)
    INF = float('inf')
    cost = [[INF] * n for _ in range(m)]
    back = [[-1] * n for _ in range(m)]
    cost[0][0] = 0.0
    for j in range(1, m):
        best, bk = INF, -1                  # best cost[j-1][k'] for k' < k
        for k in range(1, n):
            if cost[j - 1][k - 1] < best:
                best, bk = cost[j - 1][k - 1], k - 1
            if best < INF:
                cost[j][k] = best + abs(F[j] - target[k]); back[j][k] = bk
    k = min(range(n), key=lambda k: cost[m - 1][k])
    match = [0] * m
    for j in range(m - 1, -1, -1):          # trace the best matching back
        match[j] = k; k = back[j][k]
    # (target fraction, short fraction) pairs that are joined, plus the end
    anchors = [(target[match[j]], F[j]) for j in range(m)] + [(1.0, 1.0)]
    new, matched = [], set(match)
    for k in range(n):
        if k in matched: continue
        T = target[k]
        for (ta, fa), (tb, fb) in zip(anchors, anchors[1:]):
            if ta < T < tb:                 # in proportion between anchors
                new.append(fa + (T - ta) / (tb - ta) * (fb - fa)); break
    out, cuts = [], []
    for i, q in enumerate(short):
        f0, f1 = F[i], F[i] + lens[i] / tot     # this segment's span
        rest, start = q, f0
        for f in sorted(f for f in new if f0 < f < f1):
            # t on what is left of the segment after any earlier cut
            t = t_at_length(rest, (f - start) / (f1 - start))
            t8 = min(255, max(1, round(t * 256)))
            a, b = split_at(rest, t8 / 256)
            out.append(a); cuts.append((i, t8)); rest, start = b, f
        out.append(rest)
    return out, cuts


def pair_loops(A, B):
    """Specs (rot, cuts) for loops A and B (float quads) with equal counts.

    The loop with more segments (L) keeps its segments but may start
    from any of them (rotation). The other (Sh) starts where it does
    but is split to match. Every rotation is tried; the one where
    paired points are closest (least sum of squared distances) wins,
    so the shape moves as little as possible and doesn't spin.
    Returns ((A's spec, B's spec), segment count)."""
    swap = len(A) < len(B)
    L, Sh = (B, A) if swap else (A, B)
    Fl, _, _ = fractions(L)
    best = None
    for r in range(len(L)):
        rot = L[r:] + L[:r]
        T = [(f - Fl[r]) % 1.0 for f in Fl[r:] + Fl[:r]]   # joins from the new start
        s2, cuts = match_into(Sh, T)
        if len(s2) != len(rot):
            continue
        pl = [p for q in rot for p in q[:2]]; ps = [p for q in s2 for p in q[:2]]
        score = sum(dist(a, b) ** 2 for a, b in zip(pl, ps))
        if best is None or score < best[0]:
            best = (score, r, cuts)
    _, r, cuts = best
    long_spec, short_spec = (r, []), (0, cuts)
    n = len(L)
    return ((short_spec, long_spec) if swap else (long_spec, short_spec)), n


def spec(c, rev=False, rot=0, cuts=()):
    """Build one side from loop c of the letter (see morph.asm's buildplan)."""
    return dict(collapsed=False, c=c, rev=rev, rot=rot, splits=list(cuts))


def collapsed(p):
    """One side that is a single point p (half pixels)."""
    return dict(collapsed=True, cx=p[0], cy=p[1])


def make_plan(a, b):
    """The pairing plan for morphing letter a into letter b."""
    LA, LB = letters[a], letters[b]
    # loop pairing: outer with outer, others by nearest centre
    # (loop 0 is the largest, so the outer edge, in each letter)
    pairs, ra, rb = [(0, 0)], list(range(1, len(LA))), list(range(1, len(LB)))
    cands = sorted((dist(centre_half(LA[i]), centre_half(LB[j])), i, j) for i in ra for j in rb)
    for _, i, j in cands:
        if i in ra and j in rb:
            pairs.append((i, j)); ra.remove(i); rb.remove(j)
    pairs += [(i, None) for i in ra] + [(None, j) for j in rb]    # no partner
    slots = []
    for i, j in pairs:
        if i is not None and j is not None:
            A, B = quads(LA[i]), quads(LB[j])
            rev = (area(A) > 0) != (area(B) > 0)    # opposite ways round?
            nB = len(B)
            if rev:
                # B read backwards: segments in reverse order, each
                # with its start and end swapped
                B = [(q[2], q[1], q[0]) for q in (B[(-k) % nB] for k in range(nB))]
            (sa, sb), n = pair_loops(A, B)
            # the rotation counted in the reversed list -> the segment
            # the 6502 starts from when walking backwards
            rotb = (-sb[0]) % nB if rev else sb[0]
            slots.append(dict(n=n, flags=0xC0, src=spec(i, False, sa[0], sa[1]),
                              dst=spec(j, rev, rotb, sb[1])))
        elif i is not None:
            # a loop of a with no partner: shrinks to its own centre
            slots.append(dict(n=len(LA[i]) // 2, flags=0x80, src=spec(i),
                              dst=collapsed(centre_half(LA[i]))))
        else:
            # a loop of b with no partner: grows from its own centre
            slots.append(dict(n=len(LB[j]) // 2, flags=0x40, src=collapsed(centre_half(LB[j])),
                              dst=spec(j)))
    return dict(name=a + b, src=index[a], dst=index[b], slots=slots)


def trace_plan(a):
    """A 'plan' for tracing letter a: each loop paired with itself."""
    L = letters[a]
    return dict(name=a, src=index[a], dst=index[a],
                slots=[dict(n=len(pts) // 2, flags=0xC0, src=spec(c), dst=spec(c)) for c, pts in enumerate(L)])


# ------------------------------------------------------------ the message
seq = [ch for ch in MESSAGE if ch != ' ']               # letters in order
names = sorted(set(seq))                                # each letter once
index = {ch: i for i, ch in enumerate(names)}
letters = {ch: glyph(ch) for ch in names}
# positions in seq of letters that end a word: pause longer after them
before_space = {len(MESSAGE[:i].replace(' ', '')) - 1 for i, ch in enumerate(MESSAGE) if ch == ' '}
hold_for = lambda i: HOLD_SPACE if (i % len(seq)) in before_space else HOLD

# Plans are shared: "ro" appears twice in the message but is stored once.
plans, plan_index = [], {}
def get_plan(key, maker):
    if key not in plan_index:
        plan_index[key] = len(plans); plans.append(maker())
    return plan_index[key]

# Steps: (kind 0 = trace / 1 = morph, plan number, pause in frames).
# Step 0 traces the first letter; then one morph per letter, the last
# going back to the first letter. After the last step the 6502 goes
# back to step 1 (loop_start), so the trace is only seen once.
steps = [(0, get_plan(('t', seq[0]), lambda: trace_plan(seq[0])), hold_for(0))]
loop_start = 1
for i in range(len(seq)):
    a, b = seq[i], seq[(i + 1) % len(seq)]
    if a != b:
        steps.append((1, get_plan((a, b), lambda: make_plan(a, b)), hold_for(i + 1)))
    else:                                   # repeated letter: trace it again
        steps.append((0, get_plan(('t', b), lambda: trace_plan(b)), hold_for(i + 1)))

# letter data in the model's form
mletters = [[dict(n=len(pts) // 2, x=[p[0] for p in pts], y=[p[1] for p in pts]) for pts in letters[ch]]
            for ch in names]

# ------------------------------------------------------------ screen placement
# Every outline the 6502 will build, exactly as it builds them. A curve
# never goes outside its control points, so their highest and lowest
# rows bound everything drawn (give or take the rounding).
built = [morphmodel.build(p, mletters) for p in plans]
rows = [v[1] >> 8 for S, T in built for v in S + T]
ymin, ymax = min(rows), max(rows)
cells = (ymax - ymin + 8) // 8                  # character rows needed
YORG = 128 - (ymin + ymax) // 2                 # centred vertically...
while (255 - (YORG + ymin + cells * 8 - 1)) % 8:
    YORG += 1                                   # ...nudged so the area
TOPROW = 255 - (YORG + ymin + cells * 8 - 1)    # starts on a cell row
XORG = SCREEN_CX - XC                           # centred across
NPMAX = max(len(S) for S, T in built)

# Clear boxes: the exact extent of every frame each plan draws, from the
# model (one full cycle of the animation).
# The x range is rounded out to whole character cells: with 256-byte
# rows those pixel numbers are also the byte offsets to clear (see
# morph.asm, drawframe). 'skip' is the number of empty character rows
# at the top of the letter area, which the clear routine jumps over.
D = dict(XORG=XORG, YORG=YORG, TRACEF=TRACE_FRAMES, ease=EASE, steps=steps,
         loop_start=loop_start, plans=plans, letters=mletters)
ext = {}
nheld = 0
for label, pix in morphmodel.frames(D):
    name = label.split()[1]
    if pix:
        xs = [x for x, y in pix]; ys = [y for x, y in pix]
        e = ext.get(name, (255, 0, 255, 0))
        ext[name] = (min(e[0], min(xs)), max(e[1], max(xs)), min(e[2], min(ys)), max(e[3], max(ys)))
    if label.startswith('hold'):
        nheld += 1
        if nheld == len(steps):                 # every step seen once
            break
for p in plans:
    x0, x1, y0, y1 = ext[p['name']]
    # everything drawn is on the screen and inside the letter area
    assert x1 < 256 and y0 >= 255 - (TOPROW + cells * 8 - 1) and y1 <= 255 - TOPROW, p['name']
    p['clear'] = ((x0 // 8) * 8, (x1 // 8) * 8 + 7)
    assert p['clear'][1] - p['clear'][0] < 128, p['name']   # clear loop counts with BPL
    p['skip'] = (255 - y1) // 8 - TOPROW // 8
assert NPMAX <= 64, NPMAX                       # the 6502's arrays hold 64 points

# ------------------------------------------------------------ output
def spec_bytes(s):
    """A spec as the 6502 reads it (see morph.asm, buildplan)."""
    if s['collapsed']:
        return [0x80, s['cx'], s['cy']]
    out = [(0x40 if s['rev'] else 0) | s['c'], s['rot'], len(s['splits'])]
    for j, t in s['splits']:
        out += [j, t]
    return out

D = []
w = D.append
w(f"\\ Generated by gen_letters.py from {FONT.split('/')[-1]}: \"{MESSAGE}\"")
w("\\")
w("\\ The data block for morph.asm, assembled to run at &0E00. Layout:")
w("\\   steptab  3 bytes per step: kind (0 trace, 1 morph), plan, pause frames")
w("\\   easetab  steps to move on each morph frame, 1-4 (x (target - start) / 64)")
w("\\   planlo/planhi, letlo/lethi  addresses of each plan and letter")
w("\\   planN    loops, clear x range (first, last pixel column = byte")
w("\\            offset), empty character rows at the top, source letter,")
w("\\            target letter; then per loop: segments, flags (bit 7 drawn")
w("\\            in the source, bit 6 in the target), source spec, target spec.")
w("\\            A spec is &80, x, y (a point, in half pixels), or")
w("\\            flags (bit 6 backwards, bits 0-2 the letter's loop),")
w("\\            first segment, number of splits, then (segment, t * 256)")
w("\\            for each split.")
w("\\   letN     loops; per loop: segments n, then 2n x and 2n y bytes in")
w("\\            half pixels (start point and control point of each segment,")
w("\\            x = 0 at the left of the letter box, y = 0 at the bottom)")
w(".steptab                \\ kind (0 trace, 1 morph), plan, hold frames")
for k, pi, h in steps:
    w(f"    EQUB {k}, {pi}, {h}            \\ {plans[pi]['name']}")
w(".easetab                \\ step size per morph frame (x (target - start) / 64)")
w("    EQUB " + ", ".join(map(str, EASE)))
w(".planlo")
w("    EQUB " + ", ".join(f"LO(plan{i})" for i in range(len(plans))))
w(".planhi")
w("    EQUB " + ", ".join(f"HI(plan{i})" for i in range(len(plans))))
w(".letlo")
w("    EQUB " + ", ".join(f"LO(let{i})" for i in range(len(names))))
w(".lethi")
w("    EQUB " + ", ".join(f"HI(let{i})" for i in range(len(names))))
for i, p in enumerate(plans):
    w(f".plan{i}                  \\ {p['name']}")
    w(f"    EQUB {len(p['slots'])}, {p['clear'][0]}, {p['clear'][1]}, {p['skip']}, {p['src']}, {p['dst']}"
      "   \\ loops, clear x range, empty rows, letters")
    for s in p['slots']:
        w(f"    EQUB {s['n']}, &{s['flags']:02X}   \\ segments, which sides exist")
        w("    EQUB " + ", ".join(map(str, spec_bytes(s['src']))) + "   \\ source")
        w("    EQUB " + ", ".join(map(str, spec_bytes(s['dst']))) + "   \\ target")
for i, ch in enumerate(names):
    w(f".let{i}                   \\ '{ch}'")
    w(f"    EQUB {len(letters[ch])}")
    for pts in letters[ch]:
        w(f"    EQUB {len(pts) // 2}")
        w("    EQUB " + ", ".join(str(p[0]) for p in pts))
        w("    EQUB " + ", ".join(str(p[1]) for p in pts))
open(OUT_ASM, 'w').write("\n".join(D) + "\n")

C = [f"\\ Generated by gen_letters.py: \"{MESSAGE}\", cap height {CAP} px",
     f"XORG = {XORG}            \\ screen x of letter-local x = 0",
     f"YORG = {YORG}            \\ screen y of letter-local y = 0 (y up)",
     f"TOPCELL = {TOPROW // 8}         \\ first character row of the letter area",
     f"NCELLS = {cells}           \\ character rows in the letter area",
     f"NPMAX = {NPMAX}           \\ most points in any outline",
     f"MORPHF = {len(EASE)}           \\ frames per morph",
     f"TRACEF = {TRACE_FRAMES}           \\ frames to trace an outline",
     f"NSTEPS = {len(steps)}",
     f"LOOPSTEP = {loop_start}         \\ step to go back to after the last"]
open(OUT_ASM.replace('.asm', '_def.asm'), 'w').write("\n".join(C) + "\n")

json.dump(dict(XORG=XORG, YORG=YORG, TOPCELL=TOPROW // 8, NCELLS=cells, TRACEF=TRACE_FRAMES, ROWB=ROWB,
               ease=EASE, steps=steps, loop_start=loop_start, plans=plans, letters=mletters,
               names=names, message=MESSAGE), open(OUT_JSON, 'w'))

# sizes, for interest (the 6502 has room for &B00 bytes of data)
lsize = sum(1 + sum(1 + len(p) * 2 for p in letters[ch]) for ch in names)
psize = sum(6 + sum(2 + len(spec_bytes(s['src'])) + len(spec_bytes(s['dst'])) for s in p['slots']) for p in plans)
print(f"\"{MESSAGE}\": {len(seq)} letters ({len(names)} different), {len(plans)} plans, {len(steps)} steps")
print(f"data: letters {lsize} B, plans {psize} B, steps {3 * len(steps)} B, NPMAX {NPMAX}")
print(f"XORG {XORG}, YORG {YORG}, rows {ymin}..{ymax}, {cells} cells from cell row {TOPROW // 8}")
