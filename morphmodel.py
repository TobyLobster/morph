"""
morphmodel.py - an exact Python model of morph.asm's integer arithmetic.

WHAT THIS IS FOR
    morph.asm draws each frame with 16-bit fixed point arithmetic,
    shifts that round in particular ways, and Bresenham lines. This
    module does exactly the same sums, in the same order, with the
    same rounding, and lists the pixels every frame lights. That has
    two uses:

    * gen_letters.py runs the whole animation through it to find out
      where on the screen each transition draws, so the 6502 only
      clears that area, and to check nothing falls off the screen;
    * the tests run the real 6502 code in a simulator and compare its
      screen with this model's pixels, byte for byte, every frame.
      So any difference between the two is a bug in one of them.

    It is not written for speed, and it doesn't model the screen
    memory layout: it just returns sets of (x, y) pixels.

NUMBERS
    Coordinates are 16-bit "8.8 fixed point" values (see morph.asm,
    header section 3): the high byte is whole pixels, the low byte
    256ths of a pixel. Python integers have no size limit, so values
    are masked with & 0xFFFF wherever the 6502 would wrap round, and
    s16() reads a 16-bit value as signed (two's complement), as the
    6502's sign bit does. Python's >> on a negative number is an
    arithmetic shift (rounds toward minus infinity), the same as the
    6502's ASR16 macro.

WHICH FUNCTION MODELS WHICH ROUTINE
    raw            toraw            half pixels -> 8.8 with +0.5
    lerp           lerp, mul        de Casteljau splitting
    build_spec     buildspec        one side of one loop of a plan
    build          buildplan        source and target outlines
    straight_flags flagstraight     always-straight segments
    ease_steps     makesteps        the four easing step sizes
    line           line + loops     Bresenham, start pixel excluded
    drawloop       drawloop         flattening curves into lines
    frame_pixels   drawframe        the loops one frame draws
    frames         doframe          the whole animation, frame by frame
"""

MASK = 0xFFFF       # 16 bits: the 6502's two-byte numbers wrap at 65536


def raw(h):
    """Half pixels -> 8.8 fixed point, plus 0.5 so the high byte rounds.

    h half pixels is h/2 pixels = h/2 * 256 = h * 128 in 8.8. Adding 128
    (half a pixel) means that taking the high byte later rounds to the
    nearest pixel rather than always rounding down."""
    return (h + 1) * 128


def s16(v):
    """Read v as a signed 16-bit (two's complement) number."""
    v &= MASK
    return v - 0x10000 if v & 0x8000 else v


def lerp(u, v, t):
    """u + (v - u) * t / 256, truncated toward u, as the 6502 does it.

    "lerp" is linear interpolation: the point a fraction t/256 of the
    way from u to v. The 6502 multiplies the size of the difference by
    t and drops the low byte (dividing by 256, rounding down), then
    adds it to u or takes it from u. So the result is rounded toward
    u, not toward minus infinity; this copies that."""
    d = s16(v - u)
    m = (abs(d) * t) >> 8
    return (u - m if d < 0 else u + m) & MASK


# --------------------------------------------------------------- building
#
# A letter is a list of loops. Each loop is a dict with
#     n: number of segments,
#     x, y: 2n half-pixel coordinates, two points per segment: its start
#           point P0 (even index) and its control point P1 (odd index).
# A segment's end point P2 is the next segment's start point.
#
# A plan (made by gen_letters.py) lists "slots": one per pair of loops
# that morph into each other. Each slot has n (segments, the same on
# both sides), flags (bit 7: drawn in the source letter, bit 6: in the
# target), and a "spec" for each side saying how to build it from the
# letter: which loop, from which segment ("rot"), which way round
# ("rev"), and where to split segments ("splits"), or "collapsed" to a
# single point.

def build_spec(letter, spec, n):
    """2n points (x, y) in 8.8 for one side of one contour slot.

    Walk round the loop, from segment 'rot', forwards or backwards,
    copying each segment's start and control point. Where 'splits'
    says, cut the segment with de Casteljau's construction and copy
    the pieces instead (several cuts in one segment each cut what is
    left of it). The result has exactly n segments."""
    if spec['collapsed']:
        # A loop with no partner in the other letter: all its points
        # are one point (the partner's centre), so it grows from or
        # shrinks to nothing.
        p = (raw(spec['cx']), raw(spec['cy']))
        return [p] * (2 * n)
    C = letter[spec['c']]
    m = C['n']
    pt = lambda i: (raw(C['x'][i]), raw(C['y'][i]))
    out, g, rev = [], spec['rot'], spec['rev']
    splits = spec['splits']                 # [(segment number j, t), ...]
    si = 0
    for j in range(m):
        if not rev:
            # forwards: segment g runs from point 2g, pulled by 2g+1,
            # to the next segment's start
            i0, ic, i2 = 2 * g, 2 * g + 1, 2 * ((g + 1) % m)
        else:
            # backwards: the same segment with start and end swapped
            i0, ic, i2 = 2 * ((g + 1) % m), 2 * g + 1, 2 * g
        qa, qb, qc = pt(i0), pt(ic), pt(i2)
        while si < len(splits) and splits[si][0] == j:
            # de Casteljau at t/256: AB on the first leg, BC on the
            # second, M between them is on the curve. The first piece
            # is (qa, AB, M); the rest (M, BC, qc) may be split again.
            t = splits[si][1]; si += 1
            ab = tuple(lerp(qa[k], qb[k], t) for k in range(2))
            bc = tuple(lerp(qb[k], qc[k], t) for k in range(2))
            mm = tuple(lerp(ab[k], bc[k], t) for k in range(2))
            out += [qa, ab]
            qa, qb = mm, bc
        out += [qa, qb]
        g = (g - 1) % m if rev else (g + 1) % m
    assert len(out) == 2 * n, (len(out), n)
    return out


def build(plan, letters):
    """Source and target point lists for a plan (slots concatenated).

    Point i of the source morphs into point i of the target. The loops
    follow one another in the lists, as in the 6502's arrays."""
    S, T = [], []
    for s in plan['slots']:
        S += build_spec(letters[plan['src']], s['src'], s['n'])
        T += build_spec(letters[plan['dst']], s['dst'], s['n'])
    return S, T


def straight_flags(plan, S, T):
    """1 for each segment (by start point index) whose bend
    P0 + P2 - 2 P1 is within -256..255 (under a pixel) in both outlines:
    those are drawn as one straight piece without testing the bend.

    Why this is safe: every point moves in a straight line from S to T,
    and the bend is a sum of points, so the bend also moves in a
    straight line between its S and T values. It can't get bigger than
    the larger of the two. The test looks at the high byte of the
    16-bit bend: 0 or 0xFF means -256..255."""
    flags = [0] * len(S)
    cs = 0
    for s in plan['slots']:
        ce = cs + 2 * s['n']                # this loop's points: cs..ce-1
        for i0 in range(cs, ce, 2):
            i2 = i0 + 2 if i0 + 2 < ce else cs      # end point, wrapping
            ok = 1
            for P in (S, T):
                for k in range(2):
                    a = (P[i0][k] + P[i2][k] - 2 * P[i0 + 1][k]) & MASK
                    if (a >> 8) not in (0, 0xFF):
                        ok = 0
            flags[i0] = ok
        cs = ce
    return flags


def ease_steps(S, T):
    """The four per-frame step sizes: k * ((T - S) / 64 rounded toward
    zero), k = 1..4. Rounding toward zero means no point ever passes its
    target, so everything drawn stays within the start and end shapes.

    For a negative difference, adding 63 before the shift turns the
    shift's rounding down into rounding toward zero."""
    def d128(d):
        d = s16(d)
        return ((d + 63) >> 6 if d < 0 else d >> 6) & MASK
    steps = []
    for (sx, sy), (tx, ty) in zip(S, T):
        d1 = tuple(d128(t - s) for s, t in ((sx, tx), (sy, ty)))
        d2 = tuple((v << 1) & MASK for v in d1)
        d3 = tuple((a + b) & MASK for a, b in zip(d2, d1))
        d4 = tuple((v << 1) & MASK for v in d2)
        steps.append((d1, d2, d3, d4))
    return steps


# --------------------------------------------------------------- drawing
def line(a, b, out):
    """Bresenham from a to b, start pixel excluded.

    The standard integer form: err = dx + dy (dy negative). Each pixel,
    step in x if 2 err >= dy and in y if 2 err <= dx. The 6502 splits
    this into eight loops, one per direction ("octant"), but makes the
    same choices pixel for pixel."""
    if a == b:
        return
    x0, y0 = a; x1, y1 = b
    dx, sx = abs(x1 - x0), (1 if x1 >= x0 else -1)
    dy, sy = -abs(y1 - y0), (1 if y1 >= y0 else -1)
    err = dx + dy
    while (x0, y0) != (x1, y1):
        e2 = 2 * err
        if e2 >= dy: err += dy; x0 += sx
        if e2 <= dx: err += dx; y0 += sy
        out.add((x0, y0))


def drawloop(P, cs, ce, qleft, out, flags):
    """Draw qleft segments of the closed loop P[cs:ce] (8.8 points).

    Each curved segment is drawn as N straight lines, N chosen from its
    bend (see morph.asm, header section 7): the furthest a line strays
    from the curve is bend / (4 N^2) pixels.
        bend under 3 px     1 line
        3 - 8               2 lines: via the midpoint
        9 - 32              4 lines: via the quarter points
        33 and up           8 or 16 lines: forward differencing
    The bend is measured from the high bytes (whole pixels) in 8 bits,
    as the 6502 does, wrapping and all."""
    X = [p[0] for p in P]; Y = [p[1] for p in P]
    cur = (X[cs] >> 8, Y[cs] >> 8)          # the high byte: pixel
    out.add(cur)
    i0 = cs
    def go(p):                              # line on from the last point
        nonlocal cur
        line(cur, p, out); cur = p
    avg = lambda u, v: (u + v) >> 1         # 17-bit sum, halved: no overflow
    for _ in range(qleft):
        i2 = i0 + 2 if i0 + 2 < ce else cs
        if flags[i0]:                       # always straight: one line
            go((X[i2] >> 8, Y[i2] >> 8))
            i0 = i2
            continue
        ms = []
        for V in (X, Y):
            # (P0 - P1) + (P2 - P1) in whole pixels, as a signed byte,
            # then its size
            h0, h1, h2 = V[i0] >> 8, V[i0 + 1] >> 8, V[i2] >> 8
            d = ((h0 - h1) + (h2 - h1)) & 0xFF
            ms.append(256 - d if d & 0x80 else d)
        m = max(ms)
        if 3 <= m < 9:                                   # 2 pieces: midpoint
            # B(1/2) = ((P0 + P2)/2 + P1)/2, high byte only
            go(tuple(((avg(V[i0], V[i2]) + V[i0 + 1]) >> 9) & 0xFF for V in (X, Y)))
        elif 9 <= m < 33:                                # 4 pieces: de Casteljau
            # halve at t = 1/2: L1, R1 on the legs, M on the curve; then
            # the quarter and three-quarter points are the midpoints of
            # the halves (P0, L1, M) and (M, R1, P2)
            q1, mh, q3 = [], [], []
            for V in (X, Y):
                a, b, c = V[i0], V[i0 + 1], V[i2]
                l1, r1 = avg(a, b), avg(b, c); mm = avg(l1, r1)
                q1.append(((avg(a, mm) + l1) >> 9) & 0xFF)
                mh.append(mm >> 8)
                q3.append(((avg(mm, c) + r1) >> 9) & 0xFF)
            go(tuple(q1)); go(tuple(mh)); go(tuple(q3))
        elif m >= 33:                                    # 8 or 16: forward differences
            # B(t) = P0 + 2t b + t^2 a, with b = P1 - P0, a = P0 - 2P1 + P2.
            # At t = i/N (N = 2^k) the second difference is the constant
            # 2a/N^2 = a >> (2k-1), and the first difference starts at
            # 2b/N + a/N^2 = (b >> (k-1)) + (that >> 1). Each point is then
            # pos += d1; d1 += d2.
            k = 3 if m < 129 else 4
            d2, d1, pos = [], [], []
            for V in (X, Y):
                a = s16(V[i0] + V[i2] - 2 * V[i0 + 1])
                b = s16(V[i0 + 1] - V[i0]) >> (k - 1)
                t2 = a >> (2 * k - 1)
                d2.append(t2); d1.append(s16(b + (t2 >> 1))); pos.append(V[i0])
            for _ in range((1 << k) - 1):
                for j in range(2):
                    pos[j] = (pos[j] + d1[j]) & MASK
                    d1[j] = s16(d1[j] + d2[j])
                go(((pos[0] >> 8) & 0xFF, (pos[1] >> 8) & 0xFF))
        go((X[i2] >> 8, Y[i2] >> 8))        # the last piece: exactly to P2
        i0 = i2


def frame_pixels(plan, P, lims, show_mask, xorg, yorg, flags):
    """Pixels of one frame: slots whose flags match show_mask, lims[s] segments each.

    show_mask is 0x80 while tracing (the source letter's loops), 0xC0
    while morphing (all of them) and 0x40 when holding the finished
    target (so a loop that shrank to a point doesn't leave a dot).
    The result is in screen pixels: x across, y UP from the bottom."""
    out, cs = set(), 0
    for s, lim in zip(plan['slots'], lims):
        ce = cs + 2 * s['n']
        if s['flags'] & show_mask:
            drawloop(P, cs, ce, lim, out, flags)
        cs = ce
    return {(xorg + x, yorg + y) for x, y in out}


def frames(D):
    """Yield (label, pixels) for every frame the program draws, in order, forever.

    D is the JSON written by gen_letters.py. The labels are
        "trace H 5"   frame 5 of tracing H
        "morph He 12" frame 12 of the H -> e morph
        "hold He"     the finished shape, drawn once more at the start
                      of the pause (into the second screen)
    Frames during a pause, when nothing is drawn, are not listed.
    Like the 6502, after the last step it goes back to step loop_start
    (the morph from the first letter), not to the opening trace."""
    letters, plans, steps, ease = D['letters'], D['plans'], D['steps'], D['ease']
    xo, yo, TRACEF = D['XORG'], D['YORG'], D['TRACEF']
    si = 0
    while True:
        kind, pi, hold = steps[si]          # kind: 0 trace, 1 morph
        plan = plans[pi]
        S, T = build(plan, letters)
        fl = straight_flags(plan, S, T)
        name = plan['name']
        ns = [s['n'] for s in plan['slots']]
        if kind == 0:
            # tracing: frame f draws n * f / TRACEF segments of each loop
            for f in range(1, TRACEF + 1):
                yield f"trace {name} {f}", frame_pixels(plan, S, [n * f // TRACEF for n in ns], 0x80, xo, yo, fl)
            yield f"hold {name}", frame_pixels(plan, S, ns, 0x80, xo, yo, fl)
        else:
            # morphing: each frame adds k steps (k from the easing table)
            st = ease_steps(S, T)
            P = list(S)
            for f, k in enumerate(ease):
                if f == len(ease) - 1:
                    P = list(T)                                  # last frame: exactly the target
                else:
                    P = [tuple((p[j] + st[i][k - 1][j]) & MASK for j in range(2)) for i, p in enumerate(P)]
                yield f"morph {name} {f + 1}", frame_pixels(plan, P, ns, 0xC0, xo, yo, fl)
            yield f"hold {name}", frame_pixels(plan, T, ns, 0x40, xo, yo, fl)
        si += 1
        if si == len(steps):
            si = D['loop_start']
