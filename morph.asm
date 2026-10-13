\ ******************************************************************
\ morph.asm - morphing letter outlines for the BBC Micro (MODE 4)
\             BeebAsm format. Letter data comes from gen_letters.py.
\
\ The first letter's outline is drawn ("traced") a little more each
\ frame. Then the letter turns smoothly into the next one ("morphs"),
\ pauses, turns into the next, and so on through the whole message,
\ forever. Every frame is drawn from scratch at 50 frames a second.
\
\ This header explains the ideas. Each routine below has its own notes
\ on how it does its part.
\
\ ==================================================================
\ CONTENTS OF THIS HEADER
\   1. Words used in this file
\   2. The screen
\   3. How numbers are held: fixed point
\   4. Quadratic Bezier curves
\   5. What is worked out in advance (Python) and what is live (6502)
\   6. Morphing one outline into another
\   7. Drawing a curve: splitting it into straight pieces
\   8. Drawing a straight line: Bresenham's method
\   9. One frame: clear, draw, show
\  10. Speed tricks used
\  11. Memory map, and how to build
\ ==================================================================
\
\ ------------------------------------------------------------------
\ 1. WORDS USED IN THIS FILE
\ ------------------------------------------------------------------
\ Outline / loop / contour
\     A letter is drawn as its outline: one or more closed loops.
\     "B" has three: the outside edge and the two holes. "i" has two:
\     the stem and the dot. A loop is a chain of curved segments that
\     ends where it began. (Fonts call a loop a "contour".)
\ Segment
\     One curved piece of a loop: a quadratic Bezier curve (section 4).
\ Control point
\     One of the points that define a curve. A quadratic has three:
\     it starts at P0, ends at P2, and is pulled towards P1 between.
\ Morph
\     Changing one shape smoothly into another by moving every
\     control point, a little each frame, from where it is in the
\     first shape to where it is in the second.
\ Plan (pairing plan)
\     A short recipe, made by the Python program, saying how to line
\     two letters' loops up point for point so they can be morphed.
\ Slot
\     One loop of a morph: a loop of the first letter paired with a
\     loop of the second, both built with the same number of
\     segments.
\ Fixed point, 8.8
\     A way of holding fractions in whole-number arithmetic (section 3).
\ Pixel, character cell, character row
\     See section 2.
\ Zero page
\     Memory &00-&FF. The 6502 reaches it with shorter, faster
\     instructions, so the busiest variables live there.
\ Two's complement
\     How the 6502 holds negative numbers: -1 is &FF (or &FFFF in
\     16 bits), -2 is &FE, and so on. Adding works the same for
\     negative and positive numbers. The top bit is set for negatives.
\ Arithmetic shift right
\     Halving a two's complement number by shifting it right while
\     keeping its sign bit (so -6 becomes -3, not a large positive).
\ Carry
\     The 6502's carry flag: the 9th bit of an addition, or "no
\     borrow" after a subtraction. ROR/ROL shift it in and out of a
\     byte, which is how 16-bit and 17-bit values are handled here.
\ Unrolling
\     Writing a loop's body out several times in a row, so the loop's
\     own counting and branching happens less often.
\ Self-modifying code
\     A routine that rewrites some of its own instructions' operands
\     before running them. It's used here so the screen clear runs
\     with fixed addresses rather than slower indirect ones.
\ Vertical sync (vsync)
\     The moment, 50 times a second, when the TV's beam has finished
\     a picture and returns to the top. Changing which screen is shown
\     at that moment avoids showing half of one picture and half of
\     the next ("tearing").
\ CRTC
\     The 6845 Cathode Ray Tube Controller chip. It reads screen
\     memory and makes the video signal. Its registers set the screen
\     size and where in memory the screen starts.
\ VIA
\     The 6522 Versatile Interface Adapter. The "system VIA" at &FE40
\     has a flag that is set at each vertical sync.
\ Cycle
\     One tick of the 2 MHz 6502 clock: 0.5 microseconds. A 50 Hz
\     frame is 20 ms = 40,000 cycles.
\
\ ------------------------------------------------------------------
\ 2. THE SCREEN
\ ------------------------------------------------------------------
\ MODE 4 is 1 bit per pixel, 2 colours. It normally shows 40 columns
\ of character cells (320 pixels) and 32 rows (256 pixels). Here the
\ CRTC is told to show only 32 columns (as Elite does), so the screen
\ is 256 x 256 pixels and each character row is exactly 256 bytes.
\
\ Screen memory is arranged in character cells of 8 x 8 pixels. Each
\ cell is 8 bytes, one per line of pixels, top to bottom. Each byte
\ holds 8 pixels side by side, the leftmost in bit 7. Cells run left
\ to right along a character row:
\
\        cell 0       cell 1                cell 31
\      +--------+   +--------+            +--------+
\      | byte 0 |   | byte 8 |            | byte248|   pixel line 0
\      | byte 1 |   | byte 9 |    ...     | byte249|   pixel line 1
\      |  ...   |   |  ...   |            |  ...   |
\      | byte 7 |   | byte15 |            | byte255|   pixel line 7
\      +--------+   +--------+            +--------+
\      the next character row starts 256 bytes further on
\
\ So for the pixel at x (0-255) on line r (0 = top):
\     address = screen start + (r DIV 8) * 256 + (x AND &F8) + (r AND 7)
\     bit     = &80 >> (x AND 7)
\
\ With 256-byte rows:
\   * moving one pixel left or right only ever changes the low byte
\     of the address (by 8, at a cell edge);
\   * moving to the line above or below inside a cell is +/-1 (kept in
\     the Y register);
\   * crossing into the character row above or below is just +/-1 on
\     the address's HIGH byte. With 320-byte rows this needed a
\     16-bit add of 320.
\   * the byte offset of pixel x's cell within its row is x AND &F8.
\     So a range of pixel columns, rounded out to whole cells, is also
\     the range of byte offsets to clear in every row (used in 9).
\
\ Letter-local coordinates: the letters are designed in a box with
\ x = 0 at the left and y = 0 at the bottom, y going UP (as in fonts).
\ XORG and YORG (from gen_letters.py) place that box on the screen:
\     screen x = XORG + x,   screen line from the top = 255 - (YORG + y)
\
\ ------------------------------------------------------------------
\ 3. HOW NUMBERS ARE HELD: FIXED POINT
\ ------------------------------------------------------------------
\ Positions need fractions of a pixel, or smooth motion would be
\ impossible: a point moving 1/64 of 20 pixels per frame moves less
\ than one pixel. The 6502 has no fractions, so each coordinate is a
\ 16-bit number counting 1/256ths of a pixel: "8.8 fixed point".
\ The high byte is the whole pixels and the low byte the fraction:
\     &3A80 = &3A + &80/256 = 58.5 pixels
\ Adding and subtracting work exactly as for whole numbers.
\
\ The letter data holds each coordinate in one byte, in HALF pixels
\ (so 0-254 covers 0-127 pixels, with half-pixel precision). When it
\ is loaded, a half-pixel value h becomes
\     (h + 1) * 128  =  h/2 pixels + 0.5 pixel
\ The extra half pixel is a deliberate offset: when the drawing code
\ takes just the high byte (throwing the fraction away), it gets the
\ position ROUNDED to the nearest pixel instead of always rounded
\ down. Everything is offset by the same half pixel, so shapes are
\ unchanged.
\
\ ------------------------------------------------------------------
\ 4. QUADRATIC BEZIER CURVES
\ ------------------------------------------------------------------
\ TrueType fonts build letters from straight lines and quadratic
\ Bezier curves. A quadratic Bezier with control points P0, P1, P2
\ is the path, for t from 0 to 1:
\
\     B(t) = (1-t)^2 P0 + 2t(1-t) P1 + t^2 P2
\
\ It starts at P0 heading towards P1, and ends at P2 arriving from
\ the direction of P1. It never strays outside the triangle P0 P1 P2.
\ A straight line is a quadratic with P1 halfway between P0 and P2.
\
\ Rearranged, with b = P1 - P0 and a = P0 - 2 P1 + P2:
\
\     B(t) = P0 + 2t b + t^2 a
\
\ "a" is the BEND: how far the curve bows away from the straight
\ chord P0-P2. If a = 0 the curve is a straight line. The point of
\ greatest bow, at t = 1/2, is a/4 away from the middle of the chord.
\
\ A useful fact (de Casteljau's construction): find the point that is
\ a fraction t of the way along each leg of the triangle, then t of
\ the way between those two:
\
\     AB = P0 + t (P1 - P0)       BC = P1 + t (P2 - P1)
\     M  = AB + t (BC - AB)       is exactly B(t), on the curve
\
\ and the curve splits there into two smaller quadratics, (P0, AB, M)
\ and (M, BC, P2), which together are exactly the original curve.
\ This is used for both splitting segments (section 6) and drawing
\ them (section 7). With t = 1/2 everything is just averages.
\
\ Why quadratics rather than cubics (as in PostScript)? They need one
\ less control point per segment (less data, less to move per frame),
\ the fonts already use them, and the drawing maths is simpler.
\
\ ------------------------------------------------------------------
\ 5. WHAT IS WORKED OUT IN ADVANCE, AND WHAT IS LIVE
\ ------------------------------------------------------------------
\ gen_letters.py (on a PC) does the slow, clever parts once:
\   * reads each letter from the TrueType font and scales it;
\   * turns straight edges into quadratics, merges neighbouring
\     curves where one curve would do (fewer segments = faster), and
\     splits long ones so the numbers stay in range (no control-point
\     leg longer than 40 pixels in x or y);
\   * stores each different letter ONCE, as bytes (half pixels);
\   * for each change of letter (H->e, e->l, ...) works out a pairing
\     plan: which loop morphs into which, where to split segments so
\     both outlines have equal numbers of segments, which way round
\     to go and where to start, so the morph doesn't twist;
\   * places the letters on screen, and works out exactly which
\     screen area each transition draws in (so only that is cleared);
\   * writes letters.asm (the data), letters_def.asm (constants) and
\     letters.json (for testing).
\ morphmodel.py is an exact Python copy of this program's arithmetic.
\ gen_letters.py uses it to measure the drawing, and the tests check
\ every frame this program draws against it, byte for byte.
\
\ The 6502 does, at the start of each transition (during a pause):
\   * builds both outlines from the letter data and plan, including
\     the curve splitting, with 16-bit fixed point arithmetic;
\   * works out the per-frame movement of every control point;
\   * marks which segments stay straight throughout.
\ and every frame:
\   * moves every control point one step;
\   * turns every curve into short straight lines and draws them;
\   * clears the area drawn two frames earlier, and swaps screens.
\
\ Building at run time rather than storing ready-made outlines for
\ every transition keeps the data small: each letter is stored once,
\ and a plan is only a few bytes.
\
\ ------------------------------------------------------------------
\ 6. MORPHING ONE OUTLINE INTO ANOTHER
\ ------------------------------------------------------------------
\ To morph shape S into shape T, both need the same number of
\ control points, with each point of S paired with a sensible point
\ of T. Then every frame each point moves a little along the
\ straight line from its S position to its T position. The plan
\ arranges the pairing (gen_letters.py explains how it chooses):
\
\   * Loops are paired up: outside edge with outside edge, holes with
\     the nearest holes. A loop with no partner (o has a hole, S does
\     not) is paired with a single point at its centre: "collapsed".
\     Then the hole shrinks away to nothing, or grows out of nothing.
\   * Both loops of a pair must go round the same way (clockwise or
\     anticlockwise), or the morph would turn the loop inside out. If
\     they don't, one is read backwards ("reversed").
\   * The loop with fewer segments has some segments split in two (or
\     more) at chosen t values with de Casteljau's construction, so
\     both have the same count. A split doesn't change the shape at
\     all, it only adds points. The split points are chosen at the
\     same fractions of the way round as the other loop's joins.
\   * The other loop may start at a different segment ("rotation"),
\     chosen so paired points are as close as possible; otherwise the
\     shape would spin round as it morphs.
\
\ EASING. A morph at constant speed starts and stops abruptly. Here
\ the speed ramps up, cruises and ramps down ("ease in and out"). The
\ morph takes MORPHF = 20 frames. Each frame a point moves k steps,
\ where a step is 1/64 of its whole journey (target - start), and k
\ comes from a schedule in easetab:
\
\     frame:  1  2  3  4  5 ... 16 17 18 19 20
\     k:      1  2  2  3  4 ...  4  3  2  2  1      total 64 steps
\
\ So that each frame costs the same as a constant-speed morph, the
\ four possible moves (1, 2, 3 or 4 steps) are worked out for every
\ coordinate before the morph starts: D1 = (T - S) / 64, D2 = 2 D1,
\ D3 = 3 D1, D4 = 4 D1. Each frame then just adds one of them: one
\ 16-bit addition per coordinate.
\
\ The division by 64 is rounded toward zero, so 64 steps never quite
\ reach the target and no point ever passes it (overshooting would
\ draw outside the area that gets cleared). The last frame copies the
\ target exactly, to land precisely.
\
\ STRAIGHT SEGMENTS. A segment's bend a = P0 - 2 P1 + P2 is a sum of
\ its points, and each point moves in a straight line from S to T.
\ So the bend also moves in a straight line, from its S value to its
\ T value, and is never bigger than the larger of the two. If a
\ segment is (almost) straight at both ends of the morph, it stays
\ (almost) straight all the way through. Such segments are found
\ once, at the start (flagstraight), and are then drawn as one line
\ without measuring their bend every frame.
\
\ ------------------------------------------------------------------
\ 7. DRAWING A CURVE: SPLITTING IT INTO STRAIGHT PIECES
\ ------------------------------------------------------------------
\ The screen can only show pixels, and straight lines are cheap to
\ draw, so each curve is drawn as N straight pieces joining points on
\ it ("flattening"). More pieces follow the curve more closely but
\ take longer. How many are needed?
\
\ If the curve is cut into N equal parts of t, each straight piece
\ is at most |a| / (4 N^2) from the true curve. (The curve's second
\ derivative is 2a; a chord over a parameter range h bows by at most
\ |second derivative| h^2 / 8 = 2|a| / (8 N^2).) So N is chosen from
\ the bend, measured in whole pixels from the high bytes:
\
\     bend (largest of x, y)   pieces N   furthest from the curve
\       0 - 2                     1        under 3/4 pixel
\       3 - 8                     2        8 / 16  = 1/2 pixel
\       9 - 32                    4        32 / 64 = 1/2 pixel
\      33 - 128                   8        128/256 = 1/2 pixel
\     129 +                      16        (see below)
\
\ How often each is used, over one run of "Hello Stardot from the BBC
\ Micro" at 76 px (counted with morphmodel.py), out of about 9,400
\ segment drawings:
\     flagged straight (no test)  26%      1 piece   25%
\     2 pieces                    32%      4 pieces  16%
\     8 or 16 pieces               0%  (the biggest bend is 31 px)
\ Merging curves in gen_letters.py keeps segments short, and the 40 px
\ leg limit caps the bend at 80 px. The bend is measured as a signed
\ byte, so it can never reach 129 anyway: the 16 piece case is
\ unreachable, kept only for completeness. The 8 piece case would
\ be used by bigger letters or a looser merge tolerance.
\
\ The 1, 2 and 4 piece cases are found by halving (de Casteljau with
\ t = 1/2):
\     midpoint     B(1/2) = ((P0 + P2)/2 + P1) / 2
\     quarter      B(1/4) and B(3/4) by halving each half again
\ That is only additions and shifts.
\
\ For 8 or 16 pieces it is cheaper to use FORWARD DIFFERENCING. The
\ points wanted are B(i/N) for i = 1 .. N-1. From B(t) = P0 + 2tb + t^2 a:
\
\     B_i         = P0 + (2b/N) i + (a/N^2) i^2
\     first  difference  D_i = B_(i+1) - B_i = 2b/N + a (2i + 1) / N^2
\     second difference  D_(i+1) - D_i       = 2a / N^2   (a constant!)
\
\ So start with pos = P0, D = 2b/N + a/N^2 and DD = 2a/N^2. Then each
\ point is just:    pos = pos + D,   D = D + DD
\ two 16-bit additions per axis, with no multiplication at all. With
\ N = 2^k the divisions are arithmetic shifts:
\     DD = a >> (2k - 1)        D = (b >> (k - 1)) + (DD >> 1)
\ The small rounding errors these shifts make add up along the curve,
\ so the last piece is always drawn to the exact end point P2.
\
\ ------------------------------------------------------------------
\ 8. DRAWING A STRAIGHT LINE: BRESENHAM'S METHOD
\ ------------------------------------------------------------------
\ Bresenham's line algorithm draws a line between two pixels using
\ only whole-number additions and comparisons. Suppose the line goes
\ further in x than in y ("x-major": |dx| >= |dy|). Then every step
\ moves one pixel in x (the "major" axis), and some steps also move
\ one pixel in y (the "minor" axis). An error term keeps track of
\ how far the true line is from the pixel being drawn, and decides
\ when the minor step is due.
\
\ Here the error term starts at err = |dx| - |dy|. Each pixel:
\     x-major: take a y step if 2 err <= |dx|, then
\              err = err - |dy| (always), + |dx| (if y stepped)
\     y-major: take an x step if 2 err >= -|dy|, then
\              err = err + |dx| (always), - |dy| (if x stepped)
\ This is the common "err = dx + dy" form of Bresenham, split by
\ which axis always steps. (morphmodel.py has it in four lines.)
\
\ Making it fast on a 6502:
\   * Lines are at most 80 pixels, so err stays between about -80
\     and +80. 128 is added to it, so it is always 0-255: one byte,
\     compared with a plain unsigned CMP. The test "2 err <= |dx|"
\     becomes "err+128 < |dx|/2 + 129", a constant worked out once
\     per line (the threshold, fthr).
\   * There are 8 OCTANTS (directions): x-major or y-major, times
\     x going left or right, times y going up or down. Each has its
\     own copy of the drawing loop with its directions built in, so
\     the loop never tests which way it is going.
\   * Exactly vertical and horizontal lines (very common in letters)
\     have simpler loops still, with no error term at all.
\   * Each loop draws two pixels per pass (unrolled), halving the
\     cost of counting. A line with an odd number of pixels starts
\     part way into the first pass.
\   * The screen position is kept as a pointer to the character cell
\     (fptr), the line within the cell (frow, in Y) and the pixel's
\     bit (fmask). Each step only shifts the mask or changes Y, and
\     only at a cell edge touches the pointer.
\   * Each line starts where the previous one ended, so the pointer
\     is simply carried on: the full address is only calculated once
\     per loop of the outline, at its first point.
\   * No clipping is needed: gen_letters.py checks every pixel of
\     every frame lands on the screen.
\ A pixel costs about 37-47 cycles in a sloping line and 22-25 in a
\ vertical or horizontal one.
\
\ ------------------------------------------------------------------
\ 9. ONE FRAME: CLEAR, DRAW, SHOW
\ ------------------------------------------------------------------
\ Drawing a frame takes up to about 19 ms. If it were drawn on the
\ screen being shown, the half-drawn picture would be seen flickering.
\ So there are two screens, at &3000 and &5000 ("double buffering"):
\   1. clear the hidden screen's old drawing (from two frames ago);
\   2. draw the new frame into it (ORing pixels in);
\   3. tell the CRTC to show it from the next frame on (register 12,
\      the screen start address);
\   4. wait for the vertical sync, when the swap takes effect.
\ Then the screens swap roles. The OS's interrupts are switched off
\ for speed, so the program watches the vsync flag in the VIA itself.
\
\ Clearing the whole 8K screen would take about 20 ms on its own, so
\ only the box that was drawn in is cleared. gen_letters.py works out
\ each transition's box exactly. The clear routine is a column of
\ STA instructions, one per character row, run once for each byte
\ offset across the box: 5 cycles a byte, 1-3 ms a frame.
\
\ ------------------------------------------------------------------
\ 10. SPEED TRICKS USED (where to find them)
\ ------------------------------------------------------------------
\   * 32-column screen: cheap row and cell stepping (XSTEP, YSTEP).
\   * Flattening chooses the fewest pieces that look right (drawloop).
\   * Straight segments found once per morph (flagstraight).
\   * Easing costs nothing per frame: precomputed steps (makesteps).
\   * Octant-specialised, unrolled line loops; plain loops for
\     vertical and horizontal lines (line, dispatch, FASTPIX).
\   * Screen pointer carried from line to line (fastdone).
\   * 8-bit biased error term (line).
\   * Loops kept within a page: taken branches cost no extra
\     cycle (PAGEFIT).
\   * Self-modifying clear, adapted to each box (WIPEAREA, rebase).
\   * OS interrupts off; vsync polled (waitvsync).
\   * Outlines built during pauses, never during movement
\     (setupstep).
\
\ ------------------------------------------------------------------
\ 11. MEMORY MAP, AND HOW TO BUILD
\ ------------------------------------------------------------------
\   &0000-&008F               zero page variables
\   &0400-&07FF, &0900-&0B3F  working arrays (BASIC's workspace and
\                             OS buffers, unused while this runs)
\   &0E00-&18FF               letter and plan data, copied down at
\                             start (the disc system's workspace,
\                             which isn't needed once loaded)
\   &1900-&2FFF               code
\   &3000-&4FFF               screen 0
\   &5000-&6FFF               screen 1
\   &7000-&7FFF               free
\
\ Build:  python3 gen_letters.py DejaVuSans-Bold.ttf letters.asm letters.json ["message" [cap]]
\         (writes letters.asm, letters_def.asm and letters.json;
\          needs morphmodel.py alongside)
\         beebasm -i morph.asm -do morph.ssd -boot MORPH
\ Runs until BREAK is pressed. It uses BASIC's workspace and turns
\ interrupts off (vertical sync is polled), so the OS takes no time.
\ ******************************************************************

\ ------------------------------------------------------------------
\ Hardware addresses and constants
\ ------------------------------------------------------------------
OSWRCH = &FFEE          \ OS routine: write a character (VDU)
CRTC   = &FE00          \ 6845: write a register number to &FE00,
                        \ then its value to &FE01
VIAIFR = &FE4D          \ system VIA interrupt flags: bit 1 = vertical
                        \ sync. Set by the hardware even with
                        \ interrupts off; cleared by writing a 1 to it.

BUF0   = &3000          \ the two screens, 8K each
BUF1   = &5000
ROWB   = 256            \ bytes per character row (32 columns)
DATA   = &0E00          \ where the letter data runs from

\ Working arrays. An outline is a list of up to 64 points; point i
\ has x = XHI,i : XLO,i (8.8 fixed point, high byte then low byte)
\ and y = YHI,i : YLO,i. Keeping the low and high bytes in separate
\ arrays means one index register reaches both.
\
\ Points come in pairs: for each segment, its start point P0 (even
\ index) then its control point P1 (odd index). Its end point P2 is
\ the next segment's start point (index + 2), wrapping round to the
\ first point of the loop for the last segment. So a loop of n
\ segments takes 2n points, and the loops of an outline follow one
\ another in the arrays.
\
\ Each array is 64 bytes, so an indexed access never crosses a page
\ (which would cost an extra cycle).
\   X/Y:   the outline being drawn (moves every frame)
\   TX/TY: the morph's target outline
\   Dn:    the move for easing level n (n steps of 1/64 of T - S)
XLO   = &0400 : XHI   = &0440 : YLO   = &0480 : YHI   = &04C0
TXLO  = &0500 : TXHI  = &0540 : TYLO  = &0580 : TYHI  = &05C0
D1XLO = &0600 : D1XHI = &0640 : D1YLO = &0680 : D1YHI = &06C0
D2XLO = &0700 : D2XHI = &0740 : D2YLO = &0780 : D2YHI = &07C0
D3XLO = &0900 : D3XHI = &0940 : D3YLO = &0980 : D3YHI = &09C0
D4XLO = &0A00 : D4XHI = &0A40 : D4YLO = &0A80 : D4YHI = &0AC0
STRAIGHT = &0B00        \ per segment start point: non-zero = always straight

PH_TRACE = 0 : PH_MORPH = 1 : PH_HOLD = 2    \ what the animation is doing
MAXSLOTS = 3            \ at most three loops per letter

INCLUDE "letters_def.asm"      \ placement and timing constants
ASSERT NPMAX <= 64             \ outlines fit the 64-entry arrays

\ ------------------------------------------------------------------
\ Zero page (&00-&8F)
\
\ Several areas are shared between routines that never run at the
\ same time (the outline builder and the curve drawer).
\ ------------------------------------------------------------------
ORG &00
GUARD &90
\ --- line drawing ---
.lx0     SKIP 1         \ line: current pixel (letter-local)
.ly0     SKIP 1
.lx1     SKIP 1         \ line: end pixel
.ly1     SKIP 1
.ddx     SKIP 1         \ |dx|, the line's width in pixels
.fady    SKIP 1         \ |dy|, its height
.fidx    SKIP 1         \ octant loop table offset
.fptr    SKIP 2         \ address of the character cell holding the
                        \ current pixel (always a multiple of 8)
.fmask   SKIP 1         \ the pixel's bit within its byte
.frow    SKIP 1         \ its line within the cell (0-7), kept in Y
                        \ while drawing
.ferr    SKIP 1         \ Bresenham error term + 128
.fthr    SKIP 1         \ threshold: minor step when ferr passes it
.fstep1  SKIP 1         \ error change, no minor step
.fstep2  SKIP 1         \ error change, minor step
.fvec    SKIP 2         \ address to jump to (octant loop, or move
                        \ routine)

\ --- curve drawing ---
.qi      SKIP 1         \ index of the current segment's start point
.qi2     SKIP 1         \ index of its end point
.cstart  SKIP 1         \ current loop: first point index
.cend    SKIP 1         \   one past its last point
.qleft   SKIP 1         \   segments still to draw
.kk      SKIP 1         \ log2 of the pieces in this segment (N = 2^kk)
.nst     SKIP 1         \ pieces left
.mx      SKIP 1         \ |bend| in pixels, x
.lcnt    SKIP 1         \ line: passes (two pixels each)
.tmp     SKIP 2         \ general scratch
\ curve drawing scratch (also used by the builder, which never
\ runs at the same time)
.ax      SKIP 2         \ bend a = P0 - 2P1 + P2, then 2nd difference DD
.ay      SKIP 2
.bx      SKIP 2         \ b = P1 - P0, then part of the 1st difference
.by      SKIP 2
.d1x     SKIP 2         \ 1st difference D
.d1y     SKIP 2
.posx    SKIP 2         \ position along the curve, 8.8
.posy    SKIP 2
.l1      SKIP 2         \ subdivision: (P0+P1)/2
.r1      SKIP 2         \              (P1+P2)/2
.mm      SKIP 2         \              the curve's midpoint
.q1x     SKIP 1         \ piece end pixels: quarter, half, three-quarter
.q1y     SKIP 1
.mhx     SKIP 1
.mhy     SKIP 1
.q3x     SKIP 1
.q3y     SKIP 1
\ The builder's names for the same bytes. Each holds a point as four
\ bytes: x lo, x hi, y lo, y hi.
qa = ax                 \ the segment being split: start point
qb = bx                 \   control point
qc = d1x                \   end point
qab = posx              \ de Casteljau: AB (on the leg P0-P1)
qbc = l1                \   BC (on the leg P1-P2), using l1 and r1
qm  = mm                \   M (the split point), using mm, q1x, q1y

\ --- the current plan ---
.planptr SKIP 2         \ address of the plan being read
.pofs    SKIP 1         \ read offset into the plan
.nslots  SKIP 1         \ loops in it
.slotn   SKIP MAXSLOTS  \ segments in each loop
.slotf   SKIP MAXSLOTS  \ bit 7: exists in the source, bit 6: in the target
.slotlim SKIP MAXSLOTS  \ segments to draw this frame
.slotidx SKIP 1         \ loop counter over the slots
.np      SKIP 1         \ points in the outline (all loops)
.showmask SKIP 1        \ which loops to draw: &80 (source letter's),
                        \ &C0 (all) or &40 (target letter's)
.clrx0   SKIP 1         \ the plan's clear range (x byte offsets)
.clrx1   SKIP 1
.clrskip SKIP 1         \ ... and empty character rows at the top
.clrvec  SKIP 2         \ entry point into the clear routine

\ --- the outline builder ---
.srclet  SKIP 2         \ source and target letters
.dstlet  SKIP 2
.letp    SKIP 2         \ letter being read
.cptr    SKIP 2         \ its loop
.oxl     SKIP 2         \ output arrays: x lo, x hi, y lo, y hi
.oxh     SKIP 2
.oyl     SKIP 2
.oyh     SKIP 2
.obase   SKIP 1         \ first point of the current loop
.o       SKIP 1         \ next point to write
.nq      SKIP 1         \ segments in the loop being built
.sflags  SKIP 1         \ spec: bit 7 collapsed, bit 6 reversed, loop no.
.ncq     SKIP 1         \ segments in the letter's loop
.g       SKIP 1         \ letter segment being copied
.gn      SKIP 1         \ the one after it
.jj      SKIP 1         \ segments copied
.nspl    SKIP 1         \ splits left
.nextj   SKIP 1         \ next split: segment, t
.nextt   SKIP 1
.lu      SKIP 2         \ lerp: from, to, result
.lv      SKIP 2
.lr      SKIP 2
.mt      SKIP 1         \ multiply: multiplier, 24-bit product
.pr      SKIP 3

\ --- screens ---
.bufidx  SKIP 1         \ hidden screen: 0 = &3000, 1 = &5000
.bufoff  SKIP 1         \ ... as a high-byte offset from &3000: 0 or &20
.box0    SKIP 2         \ per screen: left edge of the box last drawn
.box1    SKIP 2         \ per screen: its right edge (0: nothing drawn
                        \ there yet)
.boxs    SKIP 2         \ per screen: empty character rows at its top
.wiped   SKIP 2         \ per screen: the left edge its clear routine
                        \ is currently patched for

\ --- animation ---
.step    SKIP 1         \ position in the step table
.phase   SKIP 1         \ PH_TRACE, PH_MORPH or PH_HOLD
.fcnt    SKIP 1         \ frame within the trace or morph
.holdcnt SKIP 1         \ frames left in the pause
.holdlen SKIP 1         \ length of the pause after this step
.dirty   SKIP 1         \ frames still to draw while holding
.cpy     SKIP 4         \ start-up copy: from, to
PRINT "Zero page used up to", ~P%

\ ------------------------------------------------------------------
\ Macros
\ ------------------------------------------------------------------
\ ASR16 - arithmetic shift right of a 16-bit number: halve it,
\ rounding down, keeping its sign. CMP #&80 copies the sign bit into
\ the carry (carry set if the byte is &80 or more, i.e. negative),
\ and ROR shifts that carry into the top as the rest moves right.
MACRO ASR16 v                   \ v >>= 1, arithmetic
    LDA v+1 : CMP #&80 : ROR v+1 : ROR v
ENDMACRO

MACRO ADD16 dst, src            \ dst += src (16 bits)
    CLC
    LDA dst   : ADC src   : STA dst
    LDA dst+1 : ADC src+1 : STA dst+1
ENDMACRO

\ ------------------------------------------------------------------
\ Letter data, assembled to run at &0E00. It is stored after the code
\ in the file and copied down at start (the disc system's workspace,
\ where it runs, is in use while the program is being loaded).
\ letters.asm explains its layout.
\ ------------------------------------------------------------------
ORG DATA
.data_start
INCLUDE "letters.asm"           \ steps, easing, plans and letters
.data_end
ASSERT data_end <= &1900

ORG &1900

.code_start

\ ==================================================================
\ Entry
\
\ Start-up: copy the data into place, select MODE 4, narrow the
\ screen to 32 columns, clear both screens, set up the first step,
\ then run one frame per vertical sync forever.
\ ==================================================================
.start
{
    \ Copy the letter data down to &0E00. This is done first, before
    \ the MODE change clears screen memory, which the stored copy (after
    \ the code) could reach with a long enough message. Interrupts are
    \ off while the disc system's workspace is overwritten.
    SEI                         \ copy the letter data down to &0E00
    LDA #LO(code_end) : STA cpy \ (first: its stored copy may run on
    LDA #HI(code_end) : STA cpy+1   \ into screen memory)
    LDA #LO(DATA) : STA cpy+2
    LDA #HI(DATA) : STA cpy+3
    LDX #HI(data_end - data_start) + 1  \ whole pages to copy
    LDY #0
.cp
    LDA (cpy),Y : STA (cpy+2),Y
    INY
    BNE cp
    INC cpy+1 : INC cpy+3       \ next page
    DEX
    BNE cp
    CLI

    LDX #0                      \ MODE 4, cursor off (through the OS,
.vdu                            \ which sets up the video hardware)
    LDA vdu_init,X : JSR OSWRCH
    INX : CPX #vdu_init_end - vdu_init : BNE vdu

    SEI                         \ no OS interrupts from here on: the
                                \ frame loop polls vertical sync itself

    \ Reprogram the CRTC (table crtctab below). R1 is the number of
    \ characters shown per line: 32 instead of 40, which makes each
    \ character row 32 x 8 = 256 bytes. R2 is where in the line the
    \ horizontal sync pulse comes: moved 4 characters earlier so the
    \ narrower picture sits in the middle of the TV. R12/R13 are the
    \ screen start address (in units of 8 bytes).
    LDX #0                      \ 32 columns: CRTC R1 = 32, and the
.crtc                           \ sync moved to keep it centred
    LDA crtctab,X : STA CRTC    \ register number
    LDA crtctab+1,X : STA CRTC+1    \ its new value
    INX : INX
    CPX #crtcend - crtctab
    BNE crtc

    LDA #0 : TAY                \ clear both screens, &3000-&6FFF
    LDX #HI(BUF0)               \ (one page at a time: the STA's
.clr                            \ high address byte is rewritten)
    STX clp+2
.clp
    STA BUF0,Y
    INY
    BNE clp
    INX
    CPX #HI(BUF1 + &2000)
    BNE clr

    LDA #0
    STA bufidx : STA bufoff     \ draw into &3000 first
    STA box0+1 : STA box1+1
    STA wiped : STA wiped+1     \ (clear routines assembled for edge 0)
    STA step
    JSR setupstep               \ build the first step's outline
.frame
    JSR doframe                 \ draw the next frame (hidden screen)
    JSR waitvsync               \ wait for it to be shown
    JMP frame
}

\ waitvsync - wait for the vertical sync flag, then clear it.
\ BIT copies the AND of A and the flags into Z, so with A = 2 it
\ tests bit 1 alone. Writing 2 back clears that flag.
.waitvsync
{
    LDA #2
.w
    BIT VIAIFR
    BEQ w
    STA VIAIFR
    RTS
}

\ ==================================================================
\ doframe - advance the animation by one frame
\
\ The animation is a list of steps (steptab, from gen_letters.py).
\ Each step is either:
\   a TRACE: the outline appears bit by bit. Over TRACEF frames, each
\            loop draws a growing number of its segments, until on
\            the last frame all of them are drawn. Used for the first
\            letter, and when a letter follows itself ("ll").
\   a MORPH: the outline changes from one letter into the next over
\            MORPHF frames, with easing.
\ and is followed by a HOLD (a pause) of a number of frames, longer at
\ the end of a word.
\
\ phase says which of these is happening. fcnt counts the frames of
\ a trace or morph.
\ ==================================================================
.doframe
{
    LDA phase                   \ 0 trace, 1 morph, 2 hold
    CMP #PH_MORPH
    BEQ morph
    BCS hold

    \ --- tracing: draw a growing part of each loop ---
    \ Frame fcnt (1..TRACEF) draws slotn * fcnt / TRACEF segments of
    \ each loop, so all loops finish together on the last frame.
    INC fcnt
    LDX nslots
    DEX
.tl
    LDA slotn,X : JSR tracelim : STA slotlim,X
    DEX
    BPL tl
    JSR drawframe
    LDA fcnt
    CMP #TRACEF
    BNE out
    BEQ tohold                  \ (always taken)

    \ --- morphing: move every point one eased step, then draw ---
    \ easetab gives the number of steps (1-4) for this frame. The
    \ matching routine, move1..move4, adds that many steps to every
    \ point. It's reached through a table of addresses and an
    \ indirect JMP.
.morph
    LDX fcnt
    CPX #MORPHF - 1
    BEQ last
    LDA easetab,X               \ step size 1-4
    ASL A : TAX                 \ x2: index into a table of words
    LDA movetab-2,X : STA fvec  \ (-2 because the sizes start at 1)
    LDA movetab-1,X : STA fvec+1
    JSR jmpfvec                 \ = JSR (fvec)
    JMP moved
.last
    JSR snap                    \ last frame: exactly the target
.moved
    JSR fulllims                \ every segment of every loop
    JSR drawframe
    INC fcnt
    LDA fcnt
    CMP #MORPHF
    BNE out
    LDA #&40 : STA showmask     \ arrived: only the target's loops
                                \ (a loop that shrank to a point
                                \ would otherwise leave a dot)
.tohold
    LDA #PH_HOLD : STA phase
    LDA #1 : STA dirty          \ the other screen still needs it
    LDA holdlen : STA holdcnt
.out
    RTS

    \ --- holding: draw once more into the other screen, then wait ---
    \ The finished picture has only been drawn into one screen. Once
    \ it is in the other one too, nothing changes, so the pause costs
    \ almost no time.
.hold
    LDA dirty
    BEQ wait
    DEC dirty
    JSR fulllims
    JSR drawframe
.wait
    DEC holdcnt
    BNE out
    LDX step                    \ pause over: next step
    INX
    CPX #NSTEPS
    BNE st
    LDX #LOOPSTEP               \ end of the message: go round again
.st                             \ (from the morph of the last letter
    STX step                    \ into the first, not its trace)
    \ fall through
}

\ ==================================================================
\ setupstep - start the step in 'step'. Building the outlines takes
\ from a few milliseconds up to about 40 ms (two frames) for a pair
\ with many splits. It happens at the end of a pause, when nothing moves, so
\ the only effect is a pause a frame or two longer.
\
\ Each steptab entry is three bytes: kind (0 trace, 1 morph), plan
\ number, pause length in frames.
\ ==================================================================
.setupstep
{
    LDA step : ASL A : ADC step : TAX   \ X = step * 3 (C = 0 after
                                        \ ASL: step < 128)
    LDA steptab+2,X : STA holdlen
    LDA steptab,X : PHA                 \ kind
    LDY steptab+1,X
    JSR buildplan                       \ both outlines into the arrays
    JSR flagstraight                    \ find the always-straight segments
    LDA #0 : STA fcnt
    PLA
    BNE morph
    STA phase                           \ trace (PH_TRACE = 0)
    LDA #&80 : STA showmask             \ the source letter's loops
    RTS
.morph
    JSR makesteps                       \ the four eased step sizes
    LDA #PH_MORPH : STA phase
    LDA #&C0 : STA showmask             \ every loop moves
    RTS
}

.jmpfvec                        \ the 6502 has no JSR (indirect), so
    JMP (fvec)                  \ JSR here, then JMP (indirect)

.movetab                        \ routine for 1, 2, 3 or 4 steps
    EQUW move1, move2, move3, move4

\ fulllims - draw every segment of every loop
.fulllims
{
    LDX nslots
    DEX
.l
    LDA slotn,X : STA slotlim,X
    DEX
    BPL l
    RTS
}

\ tracelim - A = A * fcnt / TRACEF (segments to draw while tracing).
\ Keeps X.
\
\ An 8 x 8 bit shift-and-add multiply: for each bit of the multiplier
\ (tmp), lowest first, add fcnt to the running total in A if the bit
\ is set, then shift the total right one place, the bit that drops
\ off going into pr. After 8 bits, A:pr is the 16-bit product. Then
\ dividing by 32 is taking the high byte of (product << 3).
.tracelim
{
    STA tmp
    STX tmp+1
    LDY #8                      \ A:pr = tmp * fcnt
    LDA #0
.m
    LSR tmp                     \ next multiplier bit into carry
    BCC no
    CLC
    ADC fcnt
.no
    ROR A                       \ shift the total right (with the
    ROR pr                      \ carry of the add) into pr
    DEY
    BNE m
    ASL pr : ROL A              \ divide by TRACEF = 32
    ASL pr : ROL A
    ASL pr : ROL A
    LDX tmp+1
    RTS
}
ASSERT TRACEF = 32

\ ==================================================================
\ buildplan - Y = plan number. Builds the source outline into the
\ X/Y arrays and the target outline into the TX/TY arrays, with the
\ same number of points, each source point paired with the target
\ point at the same index.
\
\ PLAN FORMAT (bytes, from letters.asm):
\   loops, clear x0, clear x1, empty rows, source letter, target letter
\   then for each loop ("slot"):
\     segments n, flags (bit 7: exists in the source letter,
\                        bit 6: exists in the target letter),
\     source spec, target spec
\ A SPEC says how to build one side of a slot from a letter:
\   &80, cx, cy        collapsed: the loop is a single point (cx, cy),
\                      repeated 2n times. The partner loop shrinks
\                      into it or grows out of it.
\   flags, rotation, number of splits, then (segment, t) for each:
\                      flags bits 0-2: which of the letter's loops,
\                      bit 6: go round it backwards.
\                      rotation: which segment to start from.
\                      each split cuts the segment being copied (the
\                      j-th copied, counting from 0) at t/256 of the
\                      way along what is left of it.
\
\ LETTER FORMAT:
\   number of loops, then for each loop:
\     segments n, then 2n x bytes, then 2n y bytes: each segment's
\     start point and control point, in half pixels.
\
\ For example the plan for o -> S: o's outside edge (8 segments) is
\ split at 8 places to make 16, matching S's 16; o's hole has no
\ partner in S, so it collapses into a point at its own centre.
\ ==================================================================
.buildplan
{
    LDA planlo,Y : STA planptr
    LDA planhi,Y : STA planptr+1
    LDA #0 : STA pofs
    JSR getb : STA nslots       \ the plan's header
    JSR getb : STA clrx0
    JSR getb : STA clrx1
    JSR getb : STA clrskip
    JSR getb : TAX              \ source letter -> its address
    LDA letlo,X : STA srclet
    LDA lethi,X : STA srclet+1
    JSR getb : TAX              \ target letter
    LDA letlo,X : STA dstlet
    LDA lethi,X : STA dstlet+1
    LDA #0 : STA obase : STA slotidx
.slot                           \ each loop in turn
    JSR getb
    LDX slotidx
    STA slotn,X
    STA nq
    JSR getb
    STA slotf,X
    LDX #0                      \ source side -> X/Y arrays
    JSR setout
    LDA srclet : STA letp
    LDA srclet+1 : STA letp+1
    JSR buildspec
    LDX #8                      \ target side -> TX/TY arrays
    JSR setout
    LDA dstlet : STA letp
    LDA dstlet+1 : STA letp+1
    JSR buildspec
    LDA nq : ASL A : CLC : ADC obase : STA obase   \ next loop's points
    INC slotidx                                    \ follow this one's
    LDA slotidx
    CMP nslots
    BNE slot
    LDA obase : STA np
    RTS

.setout                         \ X = 0 (X/Y arrays) or 8 (TX/TY):
    LDY #0                      \ copy four array addresses into
.so                             \ oxl..oyh, where emitx writes
    LDA outtab,X : STA oxl,Y
    INX : INY
    CPY #8
    BNE so
    RTS
}

.outtab
    EQUW XLO, XHI, YLO, YHI
    EQUW TXLO, TXHI, TYLO, TYHI

\ ==================================================================
\ flagstraight - mark each segment whose bend P0 + P2 - 2 P1 is under
\ a pixel (-256..255 in 8.8) in both the source and the target
\ outline. Its bend moves in a straight line between those two values
\ during the morph (header, section 6), so it stays (nearly) straight
\ all through, and drawloop draws it as one piece without testing its
\ bend. Letters have many straight edges, so this saves a lot.
\
\ The result goes in STRAIGHT, indexed by each segment's start point.
\ ==================================================================
\ BENDCHK - X = start point, Y = end point (qi2). Works out the high
\ byte of P0 + P2 - 2 P1 for one coordinate of one outline, and
\ clears tmp if it is not 0 or &FF (bend not under a pixel). The sums
\ can overflow 16 bits on the way, but the true answer is small, so
\ the overflows cancel out (the arithmetic wraps round modulo 65536).
MACRO BENDCHK lo, hi
    LDA lo+1,X : ASL A : STA tmp+1      \ 2 P1
    LDA hi+1,X : ROL A : STA bx
    CLC                                 \ P0 + P2
    LDA lo,X : ADC lo,Y : STA by
    LDA hi,X : ADC hi,Y
    TAY                                 \ (Y back below)
    SEC                                 \ - 2 P1: just the high byte
    LDA by : SBC tmp+1                  \ (low byte: only its borrow)
    TYA : SBC bx
    LDY qi2
    CMP #0                              \ high byte 0 or &FF: under a pixel
    BEQ ok                              \ (CMP because LDY changed Z)
    CMP #&FF
    BEQ ok
    LDA #0 : STA tmp
.ok
ENDMACRO

.flagstraight
{
    LDA #0 : STA cstart : STA slotidx
.sl                             \ each loop
    LDX slotidx
    LDA slotn,X : ASL A : CLC : ADC cstart : STA cend
    LDX cstart
.q                              \ each segment: X = its start point
    TXA : CLC : ADC #2          \ Y = end point, wrapping
    CMP cend
    BCC nw
    LDA cstart
.nw
    STA qi2
    TAY
    LDA #1 : STA tmp            \ straight until shown otherwise
    BENDCHK XLO, XHI            \ source, x
    BENDCHK YLO, YHI            \ source, y
    BENDCHK TXLO, TXHI          \ target, x
    BENDCHK TYLO, TYHI          \ target, y
    LDA tmp : STA STRAIGHT,X
    INX : INX
    CPX cend
    BCS slotdone
    JMP q                       \ (too far for a branch)
.slotdone
    LDA cend : STA cstart
    INC slotidx
    LDA slotidx
    CMP nslots
    BEQ done
    JMP sl
.done
    RTS
}

\ getb - next byte of the plan, with N and Z set from it (keeps X)
.getb
{
    LDY pofs
    INC pofs
    LDA (planptr),Y             \ last, so the flags come from the byte
    RTS
}

\ toraw - A = half pixels -> A = 8.8 high byte, X = low byte
\ (value = (h + 1) * 128: the +0.5 makes the high byte round).
\ (h + 1) * 128 is (h + 1) / 2 in the high byte, with the bit shifted
\ out (0 or 1) becoming &00 or &80 in the low byte. The add can't
\ overflow: h is at most 254.
.toraw
{
    CLC : ADC #1
    LDX #0
    LSR A
    BCC even
    LDX #&80
.even
    RTS
}

\ ==================================================================
\ buildspec - build nq segments (2nq points from obase) for one side
\ of a slot, following one spec of the plan (format above buildplan).
\
\ For an ordinary spec, it walks round the chosen loop of the letter
\ from the rotation segment, forwards or backwards, copying each
\ segment's start and control point to the output. Where the plan
\ says, a segment is split (split, below) and its pieces copied
\ instead. Each segment's end point is not copied: it is the next
\ segment's start point.
\ ==================================================================
.buildspec
{
    LDA obase : STA o
    JSR getb : STA sflags
    BPL real
    \ collapsed to a point: write it 2nq times
    JSR getb : JSR toraw : STA qa+1 : STX qa
    JSR getb : JSR toraw : STA qa+3 : STX qa+2
    LDA nq : ASL A : STA jj
.fill
    JSR emitqa
    DEC jj
    BNE fill
    RTS

.real
    JSR getb : STA g            \ rotation: first letter segment
    JSR getb : STA nspl         \ number of splits
    BEQ nosplit
    JSR getb : STA nextj        \ the first split
    JSR getb : STA nextt
.nosplit
    CLC                         \ find the loop: skip (flags AND 7)
    LDA letp : ADC #1 : STA cptr        \ loops (past the count byte)
    LDA letp+1 : ADC #0 : STA cptr+1
    LDA sflags : AND #7 : TAX
    BEQ found
.skip
    LDY #0 : LDA (cptr),Y       \ cptr += 1 + 4n
    ASL A : ASL A
    SEC : ADC cptr : STA cptr   \ (SEC supplies the + 1)
    BCC sk
    INC cptr+1
.sk
    DEX
    BNE skip
.found
    LDY #0 : LDA (cptr),Y : STA ncq
    LDA #0 : STA jj

    \ Load letter segment g as three points qa, qb, qc. Going
    \ backwards, the segment is reversed: same control point, start
    \ and end swapped, so the outline runs the other way round.
.seg                            \ copy letter segment g
    LDX g : INX                 \ gn = (g + 1) mod ncq
    CPX ncq
    BCC gnok
    LDX #0
.gnok
    STX gn
    LDA g : ASL A               \ start point: 2g, or 2gn backwards
    BIT sflags                  \ (BIT copies bit 6 to V)
    BVC fwd0
    LDA gn : ASL A
.fwd0
    LDX #qa : JSR loadpt
    LDA g : ASL A : ORA #1      \ control point: 2g + 1
    LDX #qb : JSR loadpt
    LDA gn : ASL A              \ end point: 2gn, or 2g backwards
    BIT sflags
    BVC fwd2
    LDA g : ASL A
.fwd2
    LDX #qc : JSR loadpt

    \ Split it as many times as the plan says. Each split emits the
    \ first piece and leaves the rest in qa, qb, qc, to be split
    \ again or copied as it is.
.splits
    LDA nspl                    \ a split in this segment?
    BEQ copied
    LDA nextj
    CMP jj
    BNE copied
    JSR split                   \ yes: emit the first part, keep the rest
    DEC nspl
    BEQ splits
    JSR getb : STA nextj
    JSR getb : STA nextt
    JMP splits
.copied
    JSR emitqa                  \ emit start and control points
    LDX #qb : JSR emitx

    INC jj                      \ next letter segment, either way round
    BIT sflags
    BVS back
    LDA gn                      \ forwards: g + 1 (wrapping)
    JMP setg
.back
    LDA g                       \ backwards: g - 1 (wrapping)
    BNE gb
    LDA ncq
.gb
    SEC : SBC #1
.setg
    STA g
    LDA jj
    CMP ncq
    BNE seg
    RTS
}

\ loadpt - A = point number i in the loop at cptr -> 8.8 x, y into
\ zero page X..X+3 (x lo, x hi, y lo, y hi)
.loadpt
{
    STX tmp+1                   \ destination
    STA tmp                     \ i
    TAY : INY                   \ x: byte 1 + i
    LDA (cptr),Y
    JSR toraw                   \ A = high, X = low
    LDY tmp+1
    STA 1,Y
    TXA : STA 0,Y
    LDY #0 : LDA (cptr),Y       \ y: byte 1 + 2n + i
    ASL A : SEC : ADC tmp : TAY
    LDA (cptr),Y
    JSR toraw
    LDY tmp+1
    STA 3,Y
    TXA : STA 2,Y
    RTS
}

\ emitqa / emitx - write the point at zp qa / zp X to the next slot
\ of the output arrays (through the pointers set by setout)
.emitqa
    LDX #qa
.emitx
{
    LDY o
    LDA 0,X : STA (oxl),Y
    LDA 1,X : STA (oxh),Y
    LDA 2,X : STA (oyl),Y
    LDA 3,X : STA (oyh),Y
    INC o
    RTS
}

\ ==================================================================
\ split - cut the segment qa, qb, qc at t = nextt / 256 with de
\ Casteljau's construction (header, section 4):
\
\         qb                        AB = qa + t (qb - qa)
\        /  \                       BC = qb + t (qc - qb)
\      AB----M----BC                M  = AB + t (BC - AB)  (on the curve)
\      /           \
\    qa             qc              pieces: (qa, AB, M) and (M, BC, qc)
\
\ Emits the first piece's start and control points (qa, AB), then
\ leaves the second piece in qa, qb, qc (qa = M, qb = BC).
\ ==================================================================
.split
{
    LDX #0                      \ x (X = 0), then y (X = 2)
.axis
    LDA qa,X   : STA lu  : LDA qa+1,X : STA lu+1
    LDA qb,X   : STA lv  : LDA qb+1,X : STA lv+1
    JSR lerp                    \ AB
    LDA lr : STA qab,X : LDA lr+1 : STA qab+1,X
    LDA qb,X   : STA lu  : LDA qb+1,X : STA lu+1
    LDA qc,X   : STA lv  : LDA qc+1,X : STA lv+1
    JSR lerp                    \ BC
    LDA lr : STA qbc,X : LDA lr+1 : STA qbc+1,X
    LDA qab,X  : STA lu  : LDA qab+1,X : STA lu+1
    LDA qbc,X  : STA lv  : LDA qbc+1,X : STA lv+1
    JSR lerp                    \ M
    LDA lr : STA qm,X : LDA lr+1 : STA qm+1,X
    INX : INX
    CPX #4
    BNE axis
    JSR emitqa                  \ first part: qa, ab
    LDX #qab : JSR emitx
    LDX #3                      \ rest: qa = m, qb = bc
.cp
    LDA qm,X : STA qa,X
    LDA qbc,X : STA qb,X
    DEX
    BPL cp
    RTS
}

\ lerp - lr = lu + (lv - lu) * nextt / 256, truncated toward lu.
\ Keeps X. ("lerp" = linear interpolation: the point a fraction t of
\ the way from lu to lv.)
\
\ The difference is made positive first, so the multiply only has to
\ handle positive numbers; then the result is added to or subtracted
\ from lu. Taking the product's top two bytes divides by 256.
.lerp
{
    STX tmp+1
    SEC
    LDA lv   : SBC lu   : STA tmp   \ tmp = lv - lu (16 bits)
    LDA lv+1 : SBC lu+1
    BMI neg
    JSR mul
    CLC
    LDA lu   : ADC pr+1 : STA lr
    LDA lu+1 : ADC pr+2 : STA lr+1
    LDX tmp+1
    RTS
.neg
    TAY                         \ negate the difference
    SEC
    LDA #0 : SBC tmp : STA tmp
    TYA : EOR #&FF : ADC #0
    JSR mul
    SEC
    LDA lu   : SBC pr+1 : STA lr
    LDA lu+1 : SBC pr+2 : STA lr+1
    LDX tmp+1
    RTS

    \ mul - pr = (A:tmp) * nextt, a 16 x 8 bit multiply giving 24 bits.
    \ Shift and add, from the multiplier's top bit down: each round
    \ doubles the total, then adds the multiplicand if the bit is 1.
    \ (Long multiplication in binary.)
.mul                            \ pr = (A:tmp) * nextt (24-bit)
    STA mhi
    LDA nextt : STA mt
    LDA #0 : STA pr : STA pr+1 : STA pr+2
    LDY #8
.ml
    ASL pr : ROL pr+1 : ROL pr+2    \ total * 2
    ASL mt                          \ next multiplier bit
    BCC ms
    CLC
    LDA pr   : ADC tmp : STA pr
    LDA pr+1 : ADC mhi : STA pr+1
    LDA pr+2 : ADC #0  : STA pr+2
.ms
    DEY
    BNE ml
    RTS
.mhi                            \ multiplicand high byte
    EQUB 0
}

\ ==================================================================
\ makesteps - the four easing step sizes for every coordinate:
\ d1 = (target - source) / 64 rounded toward zero, d2 = 2 d1,
\ d3 = 3 d1, d4 = 4 d1
\
\ Run once at the start of each morph. The easing schedule (easetab)
\ adds up to 64 steps, so the points travel (almost) all the way, and
\ the last frame snaps them onto the target exactly.
\ ==================================================================
\ STEPS - one coordinate (x or y) of point X.
\
\ Dividing by 64 is a shift right by 6. Shifting a negative number
\ right rounds it DOWN (away from zero: -1/64 would become -1), so
\ for negatives 63 is added first, which makes it round toward zero.
\ Then no point can ever overshoot its target.
\
\ Rather than six shifts right, the 16-bit value is shifted LEFT
\ twice into a third byte (its sign extension: 0 or &FF), and the top
\ two bytes taken: (v << 2) / 256 = v / 64.
MACRO STEPS slo, shi, tlo, thi, d1l, d1h, d2l, d2h, d3l, d3h, d4l, d4h
    SEC
    LDA tlo,X : SBC slo,X : STA tmp     \ tmp = target - source
    LDA thi,X : SBC shi,X : STA tmp+1
    BPL nonneg                  \ negative: add 63 first, so the
    LDA tmp : CLC : ADC #63     \ shift rounds toward zero (no point
    STA tmp                     \ ever overshoots its target)
    LDA tmp+1 : ADC #0 : STA tmp+1
.nonneg
    LDY #0                      \ >> 6 as (sign:hi:lo) << 2
    LDA tmp+1
    BPL pos
    DEY                         \ sign byte = &FF for negatives
.pos
    STY mx
    ASL tmp : ROL tmp+1 : ROL mx
    ASL tmp : ROL tmp+1 : ROL mx
    LDA tmp+1 : STA d1l,X       \ d1 = the top two bytes
    LDA mx : STA d1h,X
    LDA d1l,X : ASL A : STA d2l,X       \ d2 = d1 * 2
    LDA d1h,X : ROL A : STA d2h,X
    CLC
    LDA d2l,X : ADC d1l,X : STA d3l,X   \ d3 = d2 + d1
    LDA d2h,X : ADC d1h,X : STA d3h,X
    LDA d2l,X : ASL A : STA d4l,X       \ d4 = d2 * 2
    LDA d2h,X : ROL A : STA d4h,X
ENDMACRO

.makesteps
{
    LDX np
    DEX
.l
    STEPS XLO, XHI, TXLO, TXHI, D1XLO, D1XHI, D2XLO, D2XHI, D3XLO, D3XHI, D4XLO, D4XHI
    STEPS YLO, YHI, TYLO, TYHI, D1YLO, D1YHI, D2YLO, D2YHI, D3YLO, D3YHI, D4YLO, D4YHI
    DEX
    BMI done
    JMP l                       \ (the loop is too long for a branch)
.done
    RTS
}

\ move1-4 - add one easing step to every control point. This is the
\ whole per-frame cost of the morph: 16-bit additions, unrolled two
\ points a pass (np is even, as every segment has two points).
\ Four copies, one per step size, so none of them has to choose.
MACRO MOVEPTS dxl, dxh, dyl, dyh
    LDX np
    DEX
.l
    FOR o, 0, 1                 \ points X and X-1
    CLC
    LDA XLO-o,X : ADC dxl-o,X : STA XLO-o,X
    LDA XHI-o,X : ADC dxh-o,X : STA XHI-o,X
    CLC
    LDA YLO-o,X : ADC dyl-o,X : STA YLO-o,X
    LDA YHI-o,X : ADC dyh-o,X : STA YHI-o,X
    NEXT
    DEX : DEX
    BPL l
    RTS
ENDMACRO

.move1
    MOVEPTS D1XLO, D1XHI, D1YLO, D1YHI
.move2
    MOVEPTS D2XLO, D2XHI, D2YLO, D2YHI
.move3
    MOVEPTS D3XLO, D3XHI, D3YLO, D3YHI
.move4
    MOVEPTS D4XLO, D4XHI, D4YLO, D4YHI

\ snap - control points = the target (the morph's last frame, so
\ it lands exactly despite the rounding of the steps)
.snap
{
    LDX np
    DEX
.l
    LDA TXLO,X : STA XLO,X
    LDA TXHI,X : STA XHI,X
    LDA TYLO,X : STA YLO,X
    LDA TYHI,X : STA YHI,X
    DEX
    BPL l
    RTS
}

\ ==================================================================
\ drawframe - clear the hidden screen's old box, draw the loops
\ selected by showmask (slotlim segments of each), and show it.
\
\ CLEARING. Each screen remembers the box it was last drawn in (box0
\ = left edge, box1 = right edge, boxs = empty rows at its top, one
\ of each per screen). That box is cleared with the WIPEAREA routine
\ for that screen, which is adjusted first:
\   * its STA addresses are rewritten for the box's left edge
\     (rebase), but only when that changes, which is only when a new
\     transition starts;
\   * it is entered part way down its list of STAs, skipping the box's
\     empty rows at the top, and its loop branch is rewritten to go
\     back to that entry point.
\ Then X counts across the box's width.
\
\ The box's edges are in pixels, rounded out to whole character
\ cells. Because the screen has 256-byte rows, the byte offsets of a
\ cell within its row are the same numbers as its pixel columns
\ (header, section 2), so the same numbers serve as byte offsets.
\
\ DRAWING. Each loop whose slot flags match showmask is drawn by
\ drawloop. The loops lie one after another in the point arrays:
\ loop s uses points cstart to cend - 1.
\
\ SHOWING. CRTC register 12 (the screen start address's high part)
\ is set to the hidden screen. The 6845 only reads it at the start of
\ the next frame, so the switch happens cleanly during vertical sync.
\ The vsync flag is cleared now, so that waitvsync waits for the
\ next sync, not one that passed while drawing.
\ ==================================================================
.drawframe
{
    LDX bufidx                  \ clear what was drawn here before
    LDA box1,X
    BEQ noclear
    LDA box0,X                  \ box's left edge: patched into the
    CMP wiped,X                 \ clear routine's addresses when it
    BEQ same                    \ changes (only at transitions)
    STA wiped,X
    JSR rebase
.same
    \ The routine is LDA #0 (2 bytes), then one 3-byte STA per row,
    \ then DEX (1 byte) and BPL (2 bytes). Entering at the STA for
    \ row s means starting 2 + 3s bytes in. The BPL's offset counts
    \ from the byte after it (3 N + 5 bytes in, N = NCELLS), so to go
    \ back to the entry it must be (2 + 3s) - (3N + 5) = 3s - 3N - 3.
    LDA boxs,X                  \ enter the row list after the empty
    STA tmp                     \ rows: entry = l + 3 * skip, and the
    ASL A : ADC tmp : STA tmp   \ loop branch goes back there
    SEC : SBC #3 * NCELLS + 3
    STA clr0bpl+1
    STA clr1bpl+1
    LDA bufidx
    BNE c1
    LDA #LO(clear0 + 2) : CLC : ADC tmp : STA clrvec
    LDA #HI(clear0 + 2) : ADC #0 : STA clrvec+1
    JMP doclear
.c1
    LDA #LO(clear1 + 2) : CLC : ADC tmp : STA clrvec
    LDA #HI(clear1 + 2) : ADC #0 : STA clrvec+1
.doclear
    LDA box1,X                  \ X = width - 1, counting down to 0
    SEC : SBC box0,X
    TAX
    LDA #0                      \ (the entry is past the LDA #0)
    JSR clrjmp
.noclear
    LDX bufidx                  \ remember this frame's box
    LDA clrx0 : STA box0,X
    LDA clrx1 : STA box1,X
    LDA clrskip : STA boxs,X

    LDA #0 : STA cstart : STA slotidx
.sl                             \ each loop
    LDX slotidx
    LDA slotn,X : ASL A : CLC : ADC cstart : STA cend
    LDA slotf,X
    AND showmask
    BEQ skipslot
    LDA slotlim,X : STA qleft
    JSR drawloop
.skipslot
    LDA cend : STA cstart
    INC slotidx
    LDA slotidx
    CMP nslots
    BNE sl
}
    LDA #12 : STA CRTC          \ display it from the next frame on
    LDX bufidx
    LDA r12tab,X
    STA CRTC+1
.shown                          \ (the simulator samples frames here)
    LDA #2 : STA VIAIFR         \ forget any sync that passed while
                                \ drawing: wait for the next one
    LDA bufidx : EOR #1 : STA bufidx            \ swap screens
    LDA bufoff : EOR #HI(BUF1 - BUF0) : STA bufoff
    RTS

\ CRTC R12 for each screen. In the BBC's 1-bit modes the CRTC's
\ address counts in units of 8 bytes, so a screen at &3000 has start
\ address &3000 / 8 = &0600: R12 = &06, R13 = &00.
.r12tab
    EQUB HI(BUF0) DIV 8, HI(BUF1) DIV 8

.crtctab                        \ register, value
    EQUB 1, 32                  \ 32 characters displayed (was 40)
    EQUB 2, 45                  \ horizontal sync 4 earlier: centred (was 49)
    EQUB 12, HI(BUF1) DIV 8     \ show the second screen first
    EQUB 13, 0
.crtcend

\ ------------------------------------------------------------------
\ WIPEAREA - clear the letter area of one screen: X = last byte
\ offset in each character row (counting down to 0). Each STA clears
\ one byte in one character row: NCELLS rows per pass, then X moves
\ one byte left. Because each byte offset is one line of one cell,
\ every pixel line of every row in the box is covered.
\
\ STA abs,X takes 5 cycles. Only the box drawn in is cleared: about
\ 1-3 ms, against about 20 ms for a whole screen.
\
\ This is self-modifying code: rebase rewrites the STA addresses for
\ the box's left edge, and drawframe rewrites the BPL's offset and
\ picks the entry point.
\ ------------------------------------------------------------------
MACRO WIPEAREA base
    LDA #0
.l
    FOR r, 0, NCELLS-1
        STA base + (TOPCELL + r) * ROWB, X  \ + box's left edge (patched)
    NEXT
    DEX
    BPL l                       \ (offset patched: rows skipped)
    RTS
ENDMACRO

.clear0
    WIPEAREA BUF0
.clear1
    WIPEAREA BUF1
clr0bpl = clear0 + 3 + 3 * NCELLS   \ address of each loop branch
clr1bpl = clear1 + 3 + 3 * NCELLS
.clrjmp
    JMP (clrvec)

\ rebase - X = screen (0/1), A = box's left edge: rewrite that screen's
\ clear routine so its row addresses start at the box. Keeps X.
\ The first STA gets the address of the box's left edge in the top
\ character row of the letter area; each following one is 256 bytes
\ (one character row) further on.
.rebase
{
    STX tmp+1
    STA tmp
    LDA rbaselo,X : CLC : ADC tmp : STA l1
    LDA rbasehi,X : ADC #0 : STA l1+1
    LDA ropslo,X : STA cpy      \ cpy -> the first STA's operand
    LDA ropshi,X : STA cpy+1
    LDX #NCELLS
.r
    LDY #0
    LDA l1 : STA (cpy),Y
    INY
    LDA l1+1 : STA (cpy),Y
    INC l1+1                    \ next character row: 256 bytes on
    CLC                         \ next STA operand
    LDA cpy : ADC #3 : STA cpy
    BCC nc
    INC cpy+1
.nc
    DEX
    BNE r
    LDX tmp+1
    RTS
}

.rbaselo                        \ each screen's letter area, top left
    EQUB LO(BUF0 + TOPCELL * ROWB), LO(BUF1 + TOPCELL * ROWB)
.rbasehi
    EQUB HI(BUF0 + TOPCELL * ROWB), HI(BUF1 + TOPCELL * ROWB)
.ropslo                         \ first STA operand of each routine
    EQUB LO(clear0 + 3), LO(clear1 + 3)
.ropshi
    EQUB HI(clear0 + 3), HI(clear1 + 3)

\ ==================================================================
\ drawloop - draw qleft segments of the loop of points
\ cstart..cend-1, starting with a plot of its first point.
\
\ For each segment (P0, P1, P2):
\   1. If it was flagged as always straight, draw one line to P2.
\   2. Otherwise measure its bend in whole pixels, from the high
\      bytes: (P0 - P1) + (P2 - P1) in x and in y, and take the larger
\      size. This is the same as the bend a = P0 - 2 P1 + P2, give or
\      take rounding, and costs only 8-bit sums.
\   3. Choose the number of straight pieces N from the bend (header,
\      section 7) and work out the points where the pieces join:
\        bend < 3     N = 1   one line, straight to P2
\        bend < 9     N = 2   midpoint by averaging
\        bend < 33    N = 4   quarter points by repeated averaging
\        bend < 129   N = 8   forward differencing, k = 3
\        otherwise    N = 16  forward differencing, k = 4
\      (With the current letters the bend never passes 31, so
\      forward differencing isn't used; the header, section 7, says
\      more.)
\   4. The last piece always goes exactly to P2's pixel, so segments
\      join without gaps and rounding errors don't build up.
\ Each line carries on from where the previous one ended (see line).
\ ==================================================================
.drawloop
{
    LDX cstart
    STX qi
    LDA XHI,X : STA lx0         \ the pixel of the first point
    LDA YHI,X : STA ly0         \ (the high byte: rounded, thanks to
    JSR faddr                   \ the half-pixel offset); pointer to
    LDA qleft                   \ P0, and plot it
    BNE seg
    RTS

.seg
    LDX qi                      \ end point: next-but-one, wrapping
    INX : INX
    CPX cend
    BCC nowrap
    LDX cstart
.nowrap
    STX qi2
    TXA : TAY                   \ Y = end point P2
    LDX qi                      \ X = start point P0, X+1 = control P1
    LDA STRAIGHT,X              \ straight all through the morph?
    BNE straight

    \ Bend in whole pixels from the high bytes: (P0-P1) + (P2-P1).
    \ Legs are at most 40 px, so this fits a signed byte.
    LDA XHI,X : SEC : SBC XHI+1,X : STA tmp
    LDA XHI,Y : SEC : SBC XHI+1,X
    CLC : ADC tmp
    BPL axp
    EOR #&FF : CLC : ADC #1     \ make it positive (negate)
.axp
    STA mx
    LDA YHI,X : SEC : SBC YHI+1,X : STA tmp
    LDA YHI,Y : SEC : SBC YHI+1,X
    CLC : ADC tmp
    BPL ayp
    EOR #&FF : CLC : ADC #1
.ayp
    CMP mx                      \ A = larger of the two
    BCS big
    LDA mx
.big
    CMP #3                      \ bend under 3 px: one straight piece
    BCS curved
.straight
    LDA XHI,Y : STA lx1
    LDA YHI,Y : STA ly1
    JSR line
    JMP next

    \ N = 2, 4, 8 or 16 pieces: the error is bend / (4 N^2), under
    \ 0.75 px. 2 and 4 pieces use midpoint subdivision (averages);
    \ more use forward differencing.
.curved
    CMP #9
    BCS not2
    JMP two
.not2
    CMP #33
    BCS many
    JMP four

    \ --- 8 or 16 pieces: forward differencing ------------------
    \ (header, section 7). With N = 2^k:
    \     DD = a >> (2k - 1)            the 2nd difference
    \     D  = (b >> (k - 1)) + DD / 2  the 1st difference
    \ then N - 1 times: pos += D, D += DD, line to pos.
    \ All 16-bit 8.8 values, for x and for y.
.many
    LDY #3
    CMP #129 : BCC gotk : INY
.gotk
    STY kk
    LDY qi2                     \ Y = end point again
    \ exact bend a = P0 + P2 - 2 P1 (8.8) for the forward differences
    LDA XLO+1,X : ASL A : STA tmp
    LDA XHI+1,X : ROL A : STA tmp+1
    CLC
    LDA XLO,X : ADC XLO,Y : STA ax
    LDA XHI,X : ADC XHI,Y : STA ax+1
    SEC
    LDA ax   : SBC tmp   : STA ax
    LDA ax+1 : SBC tmp+1 : STA ax+1
    LDA YLO+1,X : ASL A : STA tmp
    LDA YHI+1,X : ROL A : STA tmp+1
    CLC
    LDA YLO,X : ADC YLO,Y : STA ay
    LDA YHI,X : ADC YHI,Y : STA ay+1
    SEC
    LDA ay   : SBC tmp   : STA ay
    LDA ay+1 : SBC tmp+1 : STA ay+1
    SEC                         \ b = P1 - P0, pos = P0
    LDA XLO+1,X : SBC XLO,X : STA bx
    LDA XHI+1,X : SBC XHI,X : STA bx+1
    SEC
    LDA YLO+1,X : SBC YLO,X : STA by
    LDA YHI+1,X : SBC YHI,X : STA by+1
    LDA XLO,X : STA posx
    LDA XHI,X : STA posx+1
    LDA YLO,X : STA posy
    LDA YHI,X : STA posy+1

    LDA kk : ASL A : TAX : DEX  \ 2nd difference = a >> (2k-1)
.s1
    ASR16 ax
    ASR16 ay
    DEX
    BNE s1
    LDX kk                      \ b >>= k-1
    DEX
    BEQ s2done
.s2
    ASR16 bx
    ASR16 by
    DEX
    BNE s2
.s2done
    \ 1st difference = b + (2nd difference >> 1)
    \ (the halved value goes to tmp+1:A, leaving ax/ay as they are)
    LDA ax+1 : CMP #&80 : ROR A : STA tmp+1
    LDA ax : ROR A
    CLC : ADC bx : STA d1x
    LDA tmp+1 : ADC bx+1 : STA d1x+1
    LDA ay+1 : CMP #&80 : ROR A : STA tmp+1
    LDA ay : ROR A
    CLC : ADC by : STA d1y
    LDA tmp+1 : ADC by+1 : STA d1y+1

    LDX kk                      \ N-1 pieces by stepping...
    LDA pieces,X : STA nst
.piece
    ADD16 posx, d1x             \ pos += D
    ADD16 d1x, ax               \ D += DD
    ADD16 posy, d1y
    ADD16 d1y, ay
    LDA posx+1 : STA lx1        \ line to the new point's pixel
    LDA posy+1 : STA ly1
    JSR line
    DEC nst
    BNE piece
    JMP last                    \ ...then the last one to P2

    \ --- 2 pieces: midpoint = ((P0 + P2) / 2 + P1) / 2 -------------
    \ That is B(1/2) = (P0 + 2 P1 + P2) / 4. Averages are made by adding
    \ two 16-bit numbers, then ROR: the carry (the 17th bit of the sum)
    \ goes back in at the top, so the average never overflows. Only
    \ the high byte (the pixel) of the result is needed, so the second
    \ low-byte sum is only done for its carry.
.two
    FOR axis, 0, 1
    IF axis = 0
        LO = XLO : HI = XHI : OUT = lx1
    ELSE
        LO = YLO : HI = YHI : OUT = ly1
    ENDIF
    CLC
    LDA LO,X : ADC LO,Y : STA tmp
    LDA HI,X : ADC HI,Y : ROR A : STA tmp+1 : ROR tmp
    CLC
    LDA tmp : ADC LO+1,X        \ (only the carry matters)
    LDA tmp+1 : ADC HI+1,X : ROR A : STA OUT
    NEXT
    JSR line
    JMP last

    \ --- 4 pieces: de Casteljau ---------------------------------
    \ L1 = (P0+P1)/2, R1 = (P1+P2)/2, M = (L1+R1)/2,
    \ quarter = ((P0+M)/2 + L1)/2, three-quarter = ((M+P2)/2 + R1)/2
    \ M is the curve at t = 1/2, and splits it into the halves
    \ (P0, L1, M) and (M, R1, P2). The quarter and three-quarter points
    \ are each half's own midpoint, by the same formula as above.
.four
    FOR axis, 0, 1
    IF axis = 0
        LO = XLO : HI = XHI : Q1 = q1x : MH = mhx : Q3 = q3x
    ELSE
        LO = YLO : HI = YHI : Q1 = q1y : MH = mhy : Q3 = q3y
    ENDIF
    CLC
    LDA LO,X : ADC LO+1,X : STA l1
    LDA HI,X : ADC HI+1,X : ROR A : STA l1+1 : ROR l1
    CLC
    LDA LO+1,X : ADC LO,Y : STA r1
    LDA HI+1,X : ADC HI,Y : ROR A : STA r1+1 : ROR r1
    CLC
    LDA l1 : ADC r1 : STA mm
    LDA l1+1 : ADC r1+1 : ROR A : STA mm+1 : STA MH : ROR mm
    CLC
    LDA LO,X : ADC mm : STA tmp
    LDA HI,X : ADC mm+1 : ROR A : STA tmp+1 : ROR tmp
    CLC
    LDA tmp : ADC l1
    LDA tmp+1 : ADC l1+1 : ROR A : STA Q1
    CLC
    LDA mm : ADC LO,Y : STA tmp
    LDA mm+1 : ADC HI,Y : ROR A : STA tmp+1 : ROR tmp
    CLC
    LDA tmp : ADC r1
    LDA tmp+1 : ADC r1+1 : ROR A : STA Q3
    NEXT
    LDA q1x : STA lx1 : LDA q1y : STA ly1 : JSR line
    LDA mhx : STA lx1 : LDA mhy : STA ly1 : JSR line
    LDA q3x : STA lx1 : LDA q3y : STA ly1 : JSR line

.last
    LDY qi2                     \ last piece exactly to P2
    LDA XHI,Y : STA lx1
    LDA YHI,Y : STA ly1
    JSR line

.next
    LDA qi2 : STA qi            \ this segment's end starts the next
    DEC qleft
    BEQ done
    JMP seg
.done
    RTS
}

.pieces
    EQUB 0, 1, 3, 7, 15         \ N-1 for k = 0..4

\ ==================================================================
\ faddr - fptr/fmask/frow for pixel (lx0,ly0), and plot it
\
\ The one full screen address calculation per loop (header, section
\ 2). The row tables give, for each letter-local y, the address of
\ the start of that pixel line in the &3000 screen; bufoff moves it to
\ the &5000 screen when that is the hidden one. Then:
\   x AND &F8  = the cell's byte offset in the row (added to fptr)
\   x AND 7    = which bit (pixmask)
\   address AND 7 = the line within the cell (frow), split off so
\                   fptr points at the top of the cell
\ ==================================================================
.faddr
{
    LDA lx0 : CLC : ADC #XORG   \ screen x
    TAX
    AND #7 : TAY
    LDA pixmask,Y : STA fmask
    TXA : AND #&F8
    LDY ly0
    CLC : ADC rowlo,Y : STA fptr
    LDA rowhi,Y : ADC bufoff : STA fptr+1
    LDA fptr : AND #7 : STA frow
    LDA fptr : AND #&F8 : STA fptr
    LDY frow
    LDA (fptr),Y : ORA fmask : STA (fptr),Y
    RTS
}

\ ==================================================================
\ line - from (lx0,ly0) to (lx1,ly1), letter-local 8-bit pixels,
\ continuing from the screen pointer left by the previous line.
\ The start pixel is not plotted (the previous line ended on it).
\
\ Bresenham's method (header, section 8). This routine works out the
\ line's size and direction, sets up the error term, and picks one of
\ twelve drawing loops through a table:
\
\   offset  0- 6  x-major (|dx| >= |dy|): x steps every pixel
\   offset  8-14  y-major (|dy| > |dx|):  y steps every pixel
\                 within each group of four: +4 if x increases,
\                 +2 if y increases (y up the screen)
\   offset 16-18  vertical (dx = 0): down, up
\   offset 20-22  horizontal (dy = 0): left, right
\
\ The error term, with 128 added so it fits an unsigned byte:
\   ferr starts at |dx| - |dy| + 128
\   x-major: minor (y) step when ferr < fthr = |dx|/2 + 129, which
\            is "2 err <= |dx|" for whole numbers. Then
\            ferr += |dx| - |dy| (fstep2); otherwise ferr -= |dy| (fstep1)
\   y-major: minor (x) step when ferr >= fthr = 128 - |dy|/2, which
\            is "2 err >= -|dy|". Then
\            ferr -= |dy| - |dx| (fstep2); otherwise ferr += |dx| (fstep1)
\ ==================================================================
.line
{
    LDX #0                      \ loop table offset: x+ = 4, y+ = 2
    SEC
    LDA lx1 : SBC lx0           \ dx
    BMI dxneg
    LDX #4
    BNE dxdone
.dxneg
    EOR #&FF : ADC #1           \ C = 0 here (the SBC borrowed)
.dxdone
    STA ddx                     \ |dx|
    SEC
    LDA ly1 : SBC ly0           \ dy
    BMI dyneg
    INX : INX
    BNE dydone
.dyneg
    EOR #&FF : ADC #1           \ C = 0 here
.dydone
    STA fady                    \ |dy|
    CMP ddx
    BCC xmajor
    BNE ymajor
    TAY                         \ |dx| = |dy|: a diagonal, unless both 0
    BNE xmajor
    RTS                         \ no length: nothing to draw

.ymajor                         \ A = |dy|: one pixel per y step
    LDY ddx                     \ vertical: no error term needed
    BNE yslope
    JMP vert
.yslope
    LSR A : EOR #&FF            \ threshold = 128 - |dy|/2
    SEC : ADC #&80 : STA fthr
    LDA fady : SEC : SBC ddx    \ subtracted when x steps: |dy| - |dx|
    STA fstep2
    EOR #&7F : CLC : ADC #1     \ err = |dx| - |dy| + 128
    STA ferr                    \ ((v EOR &7F) + 1 = 128 - v)
    LDA ddx : STA fstep1        \ added when x doesn't step: |dx|
    TXA : ORA #8 : TAX          \ y-major loops are the second four
    LDA fady                    \ pixel count
    JMP dispatch

.xmajor                         \ one pixel per x step
    LDY fady                    \ horizontal: no error term needed
    BNE xslope
    JMP horiz
.xslope
    LDA ddx
    LSR A                       \ threshold = |dx|/2 + 129
    SEC : ADC #&80 : STA fthr
    LDA ddx : SEC : SBC fady    \ added when y steps: |dx| - |dy|
    STA fstep2
    EOR #&80 : STA ferr         \ err = |dx| - |dy| + 128
    LDA fady : STA fstep1       \ subtracted when y doesn't step: |dy|
    LDA ddx                     \ pixel count
    \ fall through
}

\ dispatch - A = pixel count (1 or more), X = loop table offset.
\ The loops do two pixels a pass: n/2 passes from the top, or for
\ odd n, (n+1)/2 passes entering at the second pixel.
\ On entry to a loop: X = passes, Y = line within the cell (frow).
.dispatch
{
    LSR A                       \ passes = n / 2, odd bit in carry
    BCC even
    ADC #0                      \ C = 1: one more pass
    STA lcnt
    LDA fltab2,X   : STA fvec
    LDA fltab2+1,X : STA fvec+1
    LDY frow
    LDX lcnt
    JMP (fvec)
.even
    STA lcnt
    LDA fltab,X   : STA fvec
    LDA fltab+1,X : STA fvec+1
    LDY frow
    LDX lcnt
    JMP (fvec)
}

\ Straight up/down or left/right: the plain loops, table entries
\ 16/18 (down/up) and 20/22 (left/right).
.vert
    TXA : AND #2 : ORA #16 : TAX    \ keep the y direction
    LDA fady
    JMP dispatch
.horiz
    TXA : AND #4 : LSR A : ORA #20 : TAX    \ keep the x direction
    LDA ddx
    JMP dispatch

.fastdone                       \ every line ends here
    LDA lx1 : STA lx0           \ the next line starts from this
    LDA ly1 : STA ly0           \ one's end, with the screen pointer
    STY frow                    \ (fptr, fmask, frow) left as it is
    RTS

\ ------------------------------------------------------------------
\ The pixel-stepping macros. While drawing:
\   fptr  = address of the current character cell (top line)
\   Y     = line within the cell, 0-7
\   fmask = the pixel's bit
\ ------------------------------------------------------------------

\ x step: move the mask, crossing into the next cell every 8 pixels.
\ A character row is 256 bytes, so the low byte never carries.
\ Right: shift the bit right. When it falls out (into carry), the
\ pixel is the leftmost one of the next cell: the ROR puts it back in
\ at bit 7, and the cell address moves on 8 bytes.
\ Left: the mirror image.
MACRO XSTEP xpos
IF xpos
    LSR fmask
    BCC done
    ROR fmask                   \ mask = &80, C = 0
    LDA fptr : ADC #8 : STA fptr
ELSE
    ASL fmask
    BCC done
    ROL fmask                   \ mask = &01, C = 0
    LDA fptr : SBC #7 : STA fptr    \ C = 0, so this subtracts 8
ENDIF
.done
ENDMACRO

\ y step: up = previous screen row, down = next: 256 bytes per
\ character row, so crossing one is just the high byte.
\ Within a cell, Y counts lines 0-7 from the top. Going up the screen
\ (y increasing in letter coordinates) Y goes down; below line 0 it
\ wraps to line 7 of the cell above, one character row (256 bytes)
\ earlier.
MACRO YSTEP ypos
IF ypos
    DEY
    BPL done
    LDY #7
    DEC fptr+1
ELSE
    INY
    CPY #8
    BNE done
    LDY #0
    INC fptr+1
ENDIF
.done
ENDMACRO

\ One pixel of an octant loop: decide the minor step from the error
\ term, always take the major step, set the pixel.
\
\ The carry left by CMP is exactly what the following ADC or SBC
\ needs (clear for ADC, set for SBC), so no CLC or SEC is needed.
\ The pixel is ORed into its byte, so pixels already there stay.
MACRO FASTPIX xmajor, xpos, ypos
IF xmajor
    LDA ferr
    CMP fthr
    BCS nominor
    ADC fstep2                  \ C = 0: err += |dx| - |dy|
    STA ferr
    YSTEP ypos
    JMP major
.nominor
    SBC fstep1                  \ C = 1: err -= |dy|
    STA ferr
.major
    XSTEP xpos
ELSE
    LDA ferr
    CMP fthr
    BCC nominor
    SBC fstep2                  \ C = 1: err -= |dy| - |dx|
    STA ferr
    XSTEP xpos
    JMP major
.nominor
    ADC fstep1                  \ C = 0: err += |dx|
    STA ferr
.major
    YSTEP ypos
ENDIF
    LDA (fptr),Y
    ORA fmask
    STA (fptr),Y
ENDMACRO

\ One pixel of a plain loop (vertical: x = 0, horizontal: x = 1)
MACRO STRAIGHTPIX horiz, pos
IF horiz
    XSTEP pos
ELSE
    YSTEP pos
ENDIF
    LDA (fptr),Y
    ORA fmask
    STA (fptr),Y
ENDMACRO

\ Start a new page if the next n bytes wouldn't fit in this one: a
\ taken branch that crosses a page costs an extra cycle.
MACRO PAGEFIT n
IF (P% AND &FF) + n > &100
    ALIGN &100
ENDIF
ENDMACRO

\ ------------------------------------------------------------------
\ The twelve drawing loops.
\ Each loop does two pixels a pass: X = passes. "a" is the top,
\ "b" the second pixel (the entry for odd lengths). Each loop is kept
\ within one page (checked by the ASSERTs), so its branches never
\ pay the page-crossing cycle.
\ ------------------------------------------------------------------
    PAGEFIT 124
.fl0a                          \ x-major, x-, y-
    FASTPIX 1, 0, 0
.fl0b
    FASTPIX 1, 0, 0
    DEX
    BNE fl0a
    JMP fastdone
.fl0end
ASSERT HI(fl0a) = HI(fl0end - 1)
    PAGEFIT 124
.fl1a                          \ x-major, x-, y+
    FASTPIX 1, 0, 1
.fl1b
    FASTPIX 1, 0, 1
    DEX
    BNE fl1a
    JMP fastdone
.fl1end
ASSERT HI(fl1a) = HI(fl1end - 1)
    PAGEFIT 124
.fl2a                          \ x-major, x+, y-
    FASTPIX 1, 1, 0
.fl2b
    FASTPIX 1, 1, 0
    DEX
    BNE fl2a
    JMP fastdone
.fl2end
ASSERT HI(fl2a) = HI(fl2end - 1)
    PAGEFIT 124
.fl3a                          \ x-major, x+, y+
    FASTPIX 1, 1, 1
.fl3b
    FASTPIX 1, 1, 1
    DEX
    BNE fl3a
    JMP fastdone
.fl3end
ASSERT HI(fl3a) = HI(fl3end - 1)
    PAGEFIT 124
.fl4a                          \ y-major, x-, y-
    FASTPIX 0, 0, 0
.fl4b
    FASTPIX 0, 0, 0
    DEX
    BNE fl4a
    JMP fastdone
.fl4end
ASSERT HI(fl4a) = HI(fl4end - 1)
    PAGEFIT 124
.fl5a                          \ y-major, x-, y+
    FASTPIX 0, 0, 1
.fl5b
    FASTPIX 0, 0, 1
    DEX
    BNE fl5a
    JMP fastdone
.fl5end
ASSERT HI(fl5a) = HI(fl5end - 1)
    PAGEFIT 124
.fl6a                          \ y-major, x+, y-
    FASTPIX 0, 1, 0
.fl6b
    FASTPIX 0, 1, 0
    DEX
    BNE fl6a
    JMP fastdone
.fl6end
ASSERT HI(fl6a) = HI(fl6end - 1)
    PAGEFIT 124
.fl7a                          \ y-major, x+, y+
    FASTPIX 0, 1, 1
.fl7b
    FASTPIX 0, 1, 1
    DEX
    BNE fl7a
    JMP fastdone
.fl7end
ASSERT HI(fl7a) = HI(fl7end - 1)
    PAGEFIT 60
.pl0a                          \ plain, down
    STRAIGHTPIX 0, 0
.pl0b
    STRAIGHTPIX 0, 0
    DEX
    BNE pl0a
    JMP fastdone
.pl0end
ASSERT HI(pl0a) = HI(pl0end - 1)
    PAGEFIT 60
.pl1a                          \ plain, up
    STRAIGHTPIX 0, 1
.pl1b
    STRAIGHTPIX 0, 1
    DEX
    BNE pl1a
    JMP fastdone
.pl1end
ASSERT HI(pl1a) = HI(pl1end - 1)
    PAGEFIT 60
.pl2a                          \ plain, left
    STRAIGHTPIX 1, 0
.pl2b
    STRAIGHTPIX 1, 0
    DEX
    BNE pl2a
    JMP fastdone
.pl2end
ASSERT HI(pl2a) = HI(pl2end - 1)
    PAGEFIT 60
.pl3a                          \ plain, right
    STRAIGHTPIX 1, 1
.pl3b
    STRAIGHTPIX 1, 1
    DEX
    BNE pl3a
    JMP fastdone
.pl3end
ASSERT HI(pl3a) = HI(pl3end - 1)

.fltab                          \ even lengths: enter at the top
    EQUW fl0a, fl1a, fl2a, fl3a \ x-major: x-y-, x-y+, x+y-, x+y+
    EQUW fl4a, fl5a, fl6a, fl7a \ y-major: same order
    EQUW pl0a, pl1a, pl2a, pl3a \ plain: down, up, left, right
.fltab2                         \ odd lengths: enter at the second pixel
    EQUW fl0b, fl1b, fl2b, fl3b
    EQUW fl4b, fl5b, fl6b, fl7b
    EQUW pl0b, pl1b, pl2b, pl3b

\ ------------------------------------------------------------------
\ Tables
\ ------------------------------------------------------------------
.vdu_init
    EQUB 22, 4                          \ MODE 4
    EQUB 23, 1, 0, 0, 0, 0, 0, 0, 0, 0  \ cursor off
.vdu_init_end

.pixmask                                \ bit for each x AND 7
    EQUB &80, &40, &20, &10, &08, &04, &02, &01

\ Screen address (in the &3000 screen) of each letter-local row ly:
\ screen y = YORG + ly (y up), memory row = 255 - screen y.
\ Each entry is the start of that pixel line: character row * 256 +
\ line within the cell. YORG is built in, so faddr just looks it up.
.rowlo
FOR ly, 0, 95
    EQUB LO(BUF0 + ((255-YORG-ly) DIV 8) * ROWB + ((255-YORG-ly) AND 7))
NEXT
.rowhi
FOR ly, 0, 95
    EQUB HI(BUF0 + ((255-YORG-ly) DIV 8) * ROWB + ((255-YORG-ly) AND 7))
NEXT

.code_end

\ The letter data is stored after the code and copied to &0E00 at start
COPYBLOCK data_start, data_end, code_end
ASSERT code_end <= BUF0                         \ code below the screens
ASSERT HI(data_end - data_start) <= &0A          \ copied in whole pages
ASSERT code_end + (data_end - data_start) <= &7C00   \ below the MODE 7 screen

PRINT "Code from", ~code_start, "to", ~code_end, "exec", ~start
PRINT "Letter data", data_end - data_start, "bytes (room for", &B00, ")"
PRINT "Free code space below the screens:", BUF0 - code_end, "bytes"

SAVE "MORPH", code_start, code_end + (data_end - data_start), start
