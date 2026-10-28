#!/usr/bin/env python3
"""ferret_view.py: fabric_ferret.sh's log full-screen with a ferret roaming over it; at the end, or on error, every
line is written plainly to stderr. Keys: r rolls it, q hides it; the run is never touched. Without a terminal the
lines are copied plainly as they come. FF_FERRET=1 turns it on."""
import math
import os
import random
import select
import signal
import sys
import time

# ---- the ferret, as shapes ------------------------------------------------------------------------------------------
PW, PH = 104, 48              # the pixel grid at scale 1 (52 x 12 braille cells), facing right
LEGS = (0.1, 0.84)            # where the back and the front pair of legs hang off the spine (0 rump .. 1 shoulder);
                              # 10-28: a long body between them


def disc(px, cx, cy, r, ch):
    r2 = r * r
    for y in range(int(cy - r), int(cy + r) + 2):
        if 0 <= y < len(px):
            dy = y - cy
            for x in range(int(cx - r), int(cx + r) + 2):
                if 0 <= x < len(px[0]) and (x - cx) ** 2 + dy * dy < r2:
                    px[y][x] = ch


def ellipse(px, cx, cy, a, b, ch, ymin=None, ymax=None):
    for y in range(max(0, int(cy - b)), min(len(px), int(cy + b) + 2)):
        if (ymin is not None and y < ymin) or (ymax is not None and y > ymax):
            continue
        dy = (y - cy) / b
        if dy * dy > 1:
            continue
        half = a * math.sqrt(1 - dy * dy)
        for x in range(max(0, int(cx - half)), min(len(px[0]), int(cx + half) + 2)):
            if ((x - cx) / a) ** 2 + dy * dy <= 1:
                px[y][x] = ch


def box(px, x0, y0, x1, y1, ch):
    for y in range(max(0, y0), min(len(px), y1 + 1)):
        for x in range(max(0, x0), min(len(px[0]), x1 + 1)):
            px[y][x] = ch


CX, CY = 48, 26               # the body's centre: the ball's centre when curled, the pivot when rolling
SPINE = 58.0                  # the body's length from rump to shoulder, in pixels at scale 1 (50 before 10-28 02:15)
GIRTH = 6.0                   # the body's radius (7.5 before 10-28: "a little longer and thinner")
# The WEKA mark (10-28): three strokes at 45 degrees, two long and one short at the top right, as
# segments in body-local pixels (x along the spine from its middle, y across it, down positive), 1.4 px wide.
LOGO = ((-11, -5, -1, 5), (-2, -5, 8, 5), (7, -5, 11, -1))   # centred on the body's middle


def rell(px, cx, cy, a, b, ang, ch):
    """An ellipse turned by ANG radians (its a axis along the angle)."""
    c, s_ = math.cos(ang), math.sin(ang)
    m = max(a, b)
    for y in range(max(0, int(cy - m)), min(len(px), int(cy + m) + 2)):
        dy = y - cy
        for x in range(max(0, int(cx - m)), min(len(px[0]), int(cx + m) + 2)):
            dx = x - cx
            u = (dx * c + dy * s_) / a
            v = (-dx * s_ + dy * c) / b
            if u * u + v * v <= 1:
                px[y][x] = ch


def capsule(px, x0, y0, x1, y1, r, ch, n=8):
    for i in range(n + 1):
        u = i / float(n)
        disc(px, x0 + (x1 - x0) * u, y0 + (y1 - y0) * u, r, ch)


def frame(t, dir_, sniff, hump, scale=1, curl=0.0):
    """The ferret at time T (ticks) as PH*scale rows of PW*scale chars: b body, d dark, w muzzle, k eye, p nose,
    . empty. SNIFF > 0: stopped, eyes shut, nose bobbing. HUMP: None or the x of the arch along the back. CURL 0..1:
    the body is a chain of discs along a spine; curl bends the spine into a ring (belly inward), the head rides its
    end and turns with it, the legs hang off it and tuck in, the tail wraps around the outside."""
    s = scale
    f = curl
    W, H = PW * s, PH * s
    px = [["."] * W for _ in range(H)]
    # the spine: straight when stretched; bent by THETA (up to 315 degrees) when curled; centred on CX, CY
    theta = f * 1.75 * math.pi
    pts = []
    for i in range(61):
        u = i / 60.0
        if theta < 1e-6:
            x, y, a = SPINE * u, 0.0, 0.0
        else:
            R = SPINE / theta
            x, y, a = R * math.sin(theta * u), R * (1 - math.cos(theta * u)), theta * u
        pts.append([x, y, a, u])
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    for p in pts:
        p[0] += CX - mx
        p[1] += CY - my
        if f == 0 and hump is not None:                    # the back arches at HUMP
            p[1] -= 5 * math.exp(-((p[0] - hump) / 8.0) ** 2)

    def tail():   # discs along a curve: stretched, from the rump up and back with the wave running along it;
        x0, y0 = pts[0][0], pts[0][1]                      # curled, an arc round the outside of the ball
        phi0 = math.atan2(y0 - CY, x0 - CX)
        for i in range(40):
            u = i / 39.0
            xs = x0 - 17 * u
            ys = y0 - 9 * u + 2.5 * math.sin(2 * math.pi * (u * 1.2 - t * 0.08))
            ph = phi0 - math.radians(170) * u
            xa, ya = CX + 17 * math.cos(ph), CY + 17 * math.sin(ph)
            disc(px, (xs + (xa - xs) * f) * s, (ys + (ya - ys) * f) * s, (4.6 - 3.2 * u) * s, "d")

    def leg(u_at, k, near):   # hangs off the spine at U_AT, swings with the gait, shortens and tucks as it curls
        i = int(round(u_at * 60))
        x, y, a = pts[i][0], pts[i][1], pts[i][2]
        ph = t * 0.35 + k * math.pi + (0 if near else math.pi)
        ang = a + math.pi / 2 + 0.4 * math.sin(ph) * (1 - f)           # straight down from the body, plus the swing
        if not near:
            x -= 3 * math.cos(a)
            y -= 3 * math.sin(a)
        ln = 9 * (1 - 0.7 * f)
        top = 4 if not near else GIRTH + 3.5               # the near leg's first disc (radius 1.9) clears the body's
                                                           # edge (GIRTH + 1.2 bulge), so no dark strip shows inside it
        x0, y0 = x + top * math.cos(ang), y + top * math.sin(ang)
        x1, y1 = x + (4 + ln) * math.cos(ang), y + (4 + ln) * math.sin(ang)
        capsule(px, x0 * s, y0 * s, x1 * s, y1 * s, 1.9 * s, "d")
        disc(px, (x1 + 1.5 * math.cos(ang - math.pi / 2)) * s, (y1 + 1.5 * math.sin(ang - math.pi / 2)) * s, 2.3 * s, "d")

    if f < 0.5:
        tail()                                             # under the body
    for k, u_at in enumerate(LEGS):
        leg(u_at, k, False)
    for x, y, a, u in pts:                                 # the body, a little fuller in the middle
        disc(px, x * s, y * s, (GIRTH + 1.2 * math.sin(math.pi * u)) * s, "b")

    def local(lx, ly):   # body-local (along the spine from its middle, across it downward) to the grid
        i = min(60, max(0, int(round((lx / SPINE + 0.5) * 60))))
        x, y, a = pts[i][0], pts[i][1], pts[i][2]
        return ((x - ly * math.sin(a)) * s, (y + ly * math.cos(a)) * s)

    for x0, y0, x1, y1 in LOGO:                            # the WEKA mark on its flank, riding the spine
        capsule(px, *local(x0, y0), *local(x1, y1), 1.4 * s, "L", 12)
    for k, u_at in enumerate(LEGS):
        leg(u_at, k, True)
    # the head rides the spine's end and turns with it: skull, mask, pale muzzle to the nose, chin, ear, eye
    xe, ye, ae = pts[-1][0], pts[-1][1], pts[-1][2]
    if sniff:
        ae += 0.15                                         # head down, sniffing
    k_ = (1 - 0.35 * f) * s
    c, s_ = math.cos(ae), math.sin(ae)

    def at(dx, dy):   # head-local (forward, down) to the grid
        return (xe * s + (9 * s + dx * k_) * c - dy * k_ * s_, ye * s + (9 * s + dx * k_) * s_ + dy * k_ * c)

    rell(px, *at(0, 0), 9 * k_, 6 * k_, ae, "b")                       # skull, pale
    rell(px, *at(8, 2), 8 * k_, 3.5 * k_, ae, "w")                     # muzzle
    rell(px, *at(1, 4), 7 * k_, 2.5 * k_, ae, "w")                     # chin and throat
    rell(px, *at(2, -1), 10 * k_, 2.6 * k_, ae, "d")                   # the mask, a band from the ear across the eyes
    disc(px, *at(-6, -5), 2.6 * k_, "d")                               # ear
    disc(px, *at(16, 1.5 + (1 if sniff and int(t) % 2 else 0)), 1.2 * k_, "p")   # nose, bobbing when it sniffs
    if sniff or f > 0.5:
        capsule(px, *at(4, -1.3), *at(6, -1.3), 0.6 * k_, "k", 3)     # eye shut: a line
    else:
        disc(px, *at(5, -1.5), 1.4 * k_, "k")
    if f >= 0.5:
        tail()                                             # wrapped over the ball
    rows = ["".join(r) for r in px]
    if dir_ < 0:
        rows = [r[::-1] for r in rows]
    return rows


def rotate(rows, deg):
    """ROWS turned by DEG degrees about the body's centre, on a square canvas (the long axis must fit at any angle).
    Nearest-neighbour sampling of the source; pixels are square enough in braille for this to look right."""
    H, W = len(rows), len(rows[0])
    S = max(W, H)
    cx, cy = CX * W / PW, CY * H / PH
    ccx, ccy = S / 2.0, S / 2.0
    c, s_ = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    out = []
    for Y in range(S):
        dy = Y - ccy
        line = []
        for X in range(S):
            dx = X - ccx
            x = int(cx + dx * c + dy * s_)
            y = int(cy - dx * s_ + dy * c)
            line.append(rows[y][x] if 0 <= x < W and 0 <= y < H else ".")
        out.append("".join(line))
    return out


def vscale(rows, ys):
    """ROWS squeezed vertically about the spine by YS (1 upright, 0 edge-on, -1 upside down): the roll-over, seen
    from the side, is the body turning about its own long axis."""
    H = len(rows)
    cy = CY * H / PH
    ys = max(abs(ys), 0.08) * (1 if ys >= 0 else -1)
    out = []
    for Y in range(H):
        y = int(round(cy + (Y - cy) / ys))
        out.append(rows[y] if 0 <= y < H else "." * len(rows[0]))
    return out


# ---- braille cells ---------------------------------------------------------------------------------------------------
DOTS = ((0x01, 0x08), (0x02, 0x10), (0x04, 0x20), (0x40, 0x80))   # [row][col] bit of a braille cell


def cells(rows):
    """(cy, cx, char, color) for every braille cell with at least one lit pixel."""
    H, W = len(rows), len(rows[0])
    out = []
    for cy in range(0, H, 4):
        for cx in range(0, W, 2):
            bits = 0
            count = {}
            for dy in range(4):
                if cy + dy >= H:
                    break
                r = rows[cy + dy]
                for dx in range(2):
                    if cx + dx < W and r[cx + dx] != ".":
                        bits |= DOTS[dy][dx]
                        count[r[cx + dx]] = count.get(r[cx + dx], 0) + 1
            if bits:
                color = max(count, key=count.get)
                out.append((cy // 4, cx // 2, chr(0x2800 + bits), color))
    return out



# ---- the log stream ---------------------------------------------------------------------------------------------------
class Stream:
    """Lines from LOG_FD as they arrive: pull() takes what is readable now (no blocking) and returns the complete new
    lines; eof is set when the writer closed the pipe. A last line without a newline is delivered at EOF."""

    def __init__(self, log_fd):
        self.fd = log_fd
        self.buf = b""
        self.eof = False

    def pull(self, wait=0.0):
        out = []
        while not self.eof:
            r, _, _ = select.select([self.fd], [], [], wait)
            wait = 0.0
            if not r:
                break
            chunk = os.read(self.fd, 65536)
            if not chunk:
                self.eof = True
                if self.buf:
                    out.append(self.buf.decode("utf-8", "replace"))
                    self.buf = b""
                break
            self.buf += chunk
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                out.append(line.decode("utf-8", "replace"))
        return out


def emit(lines):
    """The lines plainly on stderr (the terminal): what a run looks like without the viewer."""
    for text in lines:
        sys.stderr.write(text + "\n")
    sys.stderr.flush()


def copy_plain(stream):
    """No terminal: copy the log to stderr as it comes, to the end."""
    while not stream.eof:
        emit(stream.pull(wait=1.0))


# ---- curses ----------------------------------------------------------------------------------------------------------
def run_curses(stream, log):
    """The viewer: the log lines fill the screen, the ferret roams over them, until the stream ends. LOG keeps every
    line received (the caller writes them plainly afterwards)."""
    import curses
    scale = 1

    def main(scr):
        curses.curs_set(0)
        scr.nodelay(True)
        color = curses.has_colors()
        attr = {}
        if color:
            curses.start_color()
            curses.use_default_colors()
            if curses.COLORS >= 256:
                # light, with a purple hue: lavender cream body, purple mask, tail and legs, pale lilac muzzle,
                # orchid nose, the mark in violet
                pal = {"b": 189, "d": 134, "k": 236, "w": 225, "p": 213, "L": 93}
            else:
                pal = {"b": curses.COLOR_MAGENTA, "d": curses.COLOR_BLUE, "k": curses.COLOR_BLACK,
                       "w": curses.COLOR_WHITE, "p": curses.COLOR_MAGENTA, "L": curses.COLOR_BLUE}
            for n, (key, col) in enumerate(pal.items(), 1):
                curses.init_pair(n, col, -1)
                attr[key] = curses.color_pair(n)
        hidden = False                              # q: the log alone for the rest of the run
        t = 0
        rows_c, cols_c = (PH * scale) // 4, (PW * scale) // 2       # the ferret's cell footprint
        x, y = 0.0, 0.0
        tx, ty = x, y
        dir_, sniff, hump, hwait = 1, 0, None, 10
        # the roll: r starts it; CURL ticks curling up, ROLL ticks rolling (two turns), CURL ticks uncurling
        CURL, ROLL, FLOP = 3, 24, 16                    # the roll-over takes FLOP ticks
        force = os.environ.get("FF_FERRET", "")         # FF_FERRET=ball|over forces one kind of roll
        phase, cnt, curl, roll_angle, roll_dx, roll_dy, roll_spin = None, 0, 0.0, 0, 0.0, 0.0, 30
        while not stream.eof:
            ch = scr.getch()
            if ch == ord("q"):
                hidden = True
            if ch == ord("r") and phase is None and not hidden:   # ferrets love to roll: curl up and off it goes,
                over = force == "over" or (force != "ball" and random.random() < 0.5)   # or roll over like a dog
                phase, cnt, hump = ("flop" if over else "curl"), 0, None
            rows_total, cols = scr.getmaxyx()
            log.extend(stream.pull())
            # the ferret's step: toward a waypoint anywhere on the screen, a new one when it arrives or at random
            xmax, ymax = max(0, cols - cols_c - 1), max(0, rows_total - rows_c)
            if phase == "curl":
                cnt += 1
                curl = cnt / float(CURL)
                if cnt >= CURL:
                    phase, cnt, roll_angle = "roll", 0, 0
                    a = random.uniform(0, 2 * math.pi)
                    roll_dx, roll_dy = 1.8 * math.cos(a), 0.9 * math.sin(a)
                    roll_spin = 30 if roll_dx >= 0 else -30
            elif phase == "roll":
                cnt += 1
                roll_angle += roll_spin
                x = min(max(x + roll_dx, 0), xmax)
                y = min(max(y + roll_dy, 0), ymax)
                if cnt >= ROLL:
                    phase, cnt = "uncurl", 0
                    if abs(roll_dx) > 0.3:
                        dir_ = 1 if roll_dx > 0 else -1
            elif phase == "flop":                           # on its back and up again, in place, legs kicking
                cnt += 1
                t += 1
                if cnt >= FLOP:
                    phase = None
            elif phase == "uncurl":
                cnt += 1
                curl = 1 - cnt / float(CURL)
                if cnt >= CURL:
                    phase, curl = None, 0.0
                    tx, ty = x, y
            elif sniff:
                sniff -= 1
            else:
                t += 1
                if (abs(tx - x) < 1 and abs(ty - y) < 1) or random.randrange(120) == 0:
                    tx, ty = random.uniform(0, xmax), random.uniform(0, ymax)
                dx, dy = tx - x, ty - y
                dist = math.hypot(dx, dy) or 1.0
                step = min(dist, 1.6)
                x += step * dx / dist
                y += step * dy / dist * 0.5          # cells are about twice as tall as wide
                if abs(dx) > 1:
                    dir_ = 1 if dx > 0 else -1
                x = min(max(x, 0), xmax)
                y = min(max(y, 0), ymax)
                if random.randrange(50) == 0:
                    sniff = 10
                if hump is None:
                    hwait -= 1
                    if hwait <= 0:
                        hump = 20
                else:
                    hump += random.choice((1, 1, 1, 2, 0, -1))
                    if hump > 64:
                        hump, hwait = None, random.randint(6, 16)
            # draw: the log lines fill the screen, the ferret over them in its lit cells only
            scr.erase()
            shown = log[-(rows_total - 1):] if rows_total > 1 else []
            for i, text in enumerate(shown):
                try:
                    scr.addstr(i, 0, text[: cols - 1])
                except curses.error:
                    pass
            if not hidden:
                ox, oy = int(round(x)), int(round(y))
                rows = frame(t, dir_, sniff, hump, scale, curl)
                if phase == "flop":
                    rows = vscale(rows, math.cos(2 * math.pi * cnt / FLOP))
                elif phase == "roll":                       # the square canvas is centred on the ball
                    S = max(len(rows[0]), len(rows))
                    rows = rotate(rows, roll_angle)
                    ox -= (S // 2 - CX * scale) // 2
                    oy -= (S // 2 - CY * scale) // 4
                for cy, cx, chr_, key in cells(rows):
                    sy, sx = oy + cy, ox + cx
                    if 0 <= sy < rows_total and 0 <= sx < cols - 1:
                        try:
                            scr.addstr(sy, sx, chr_, attr.get(key, 0))
                        except curses.error:
                            pass
            scr.refresh()
            time.sleep(0.08)

    curses.wrapper(main)


def run():
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    log = []
    stream = Stream(0)
    if not sys.stdout.isatty():
        copy_plain(stream)
        return 0
    try:
        # curses takes its keys from fd 0: the log pipe moves to another fd and the terminal takes fd 0
        log_fd = os.dup(0)
        tty = os.open("/dev/tty", os.O_RDONLY)
        os.dup2(tty, 0)
        os.close(tty)
        stream = Stream(log_fd)
    except OSError:
        copy_plain(stream)
        return 0
    try:
        run_curses(stream, log)
    except Exception as e:                          # whatever broke, the run's lines come first; then say what
        try:
            import curses
            curses.endwin()
        except Exception:
            pass
        log.append("# FF_FERRET: the ferret viewer stopped (%s: %s); the run continues plainly, the full log is in run.log" % (type(e).__name__, e))
    emit(log)
    copy_plain(stream)
    return 0


if __name__ == "__main__":
    sys.exit(run())
