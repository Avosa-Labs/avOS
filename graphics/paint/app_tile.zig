//! Rendering the delivered app tiles from their source vectors: gradient bodies, specular highlight,
//! clip, and the white glyph, rasterised natively at any target size.
//!
//! Each app tile ships as a small SVG on a 512 viewBox — a squircle body filled with a linear gradient,
//! a radial specular highlight and a linear shade painted through a clip of that same squircle, a hairline
//! white outline, and the app's white glyph in a translate+scale group. The stroke-only glyph renderer
//! cannot show any of that, so this module carries a small analytic scanline fill: it flattens the path
//! and arc vocabulary the tiles use to polylines, fills them with a nonzero or even-odd winding rule and
//! per-pixel antialiased coverage, samples linear and radial gradients (colour and opacity per stop) in
//! O(1) per pixel, and intersects a fill with a clip path by multiplying coverage. Fills composite
//! alpha-over onto the framebuffer, so a translucent highlight reads as a highlight rather than a hard
//! disc. Work is bounded to each shape's own scanlines, so a small tile touches only a small patch of
//! pixels, and no pixel allocates.
//!
//! It parses the app-tile structure — the three gradients, the clip squircle, the clipped body and
//! washes, the outline, and the transformed glyph paths — and renders it into an arbitrary rectangle. It
//! is a renderer of a known asset family, not a general SVG engine; a tile it cannot parse renders false
//! so the caller can fall back to the hand-built composition.

const std = @import("std");
const fb = @import("framebuffer.zig");
const vector = @import("vector.zig");
const paint = @import("paint.zig");

const Framebuffer = fb.Framebuffer;
const Rgba = fb.Rgba;
const Rect = paint.Rect;
const Point = vector.Point;

/// The viewBox every app tile is authored on.
const view: f32 = 512.0;
/// Vertical sub-scanlines per pixel row: the antialias oversampling in y (analytic in x).
const samples: usize = 4;
/// The widest device row a single fill accumulates coverage across. Tiles are far smaller; a wider
/// target rectangle is clamped to this rather than overrunning the scratch buffers.
const max_row: usize = 2048;

const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// The winding rule that decides which side of a boundary is inside.
const Rule = enum { nonzero, even_odd };

/// A translate + scale map from an authoring space into device pixels: `device = origin + coord * scale`.
const Affine = struct {
    ox: f32,
    oy: f32,
    sx: f32,
    sy: f32,

    fn at(self: Affine, x: f32, y: f32) Point {
        return .{ .x = self.ox + x * self.sx, .y = self.oy + y * self.sy };
    }
};

/// A gradient stop: a position along the axis and the straight-alpha colour there.
const Stop = struct { offset: f32, colour: Rgba };

const Linear = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    stops: [4]Stop,
    count: usize,

    fn at(self: Linear, vx: f32, vy: f32) Rgba {
        const dx = self.x2 - self.x1;
        const dy = self.y2 - self.y1;
        const len2 = dx * dx + dy * dy;
        const t = if (len2 <= 0.0) 0.0 else ((vx - self.x1) * dx + (vy - self.y1) * dy) / len2;
        return sampleStops(self.stops[0..self.count], t);
    }
};

const Radial = struct {
    cx: f32,
    cy: f32,
    r: f32,
    stops: [4]Stop,
    count: usize,

    fn at(self: Radial, vx: f32, vy: f32) Rgba {
        const dx = vx - self.cx;
        const dy = vy - self.cy;
        const t = if (self.r <= 0.0) 0.0 else @sqrt(dx * dx + dy * dy) / self.r;
        return sampleStops(self.stops[0..self.count], t);
    }
};

/// The paint a fill lays down: a flat colour (the white glyph) or a gradient sampled in viewBox space.
const Paint = union(enum) {
    solid: Rgba,
    linear: Linear,
    radial: Radial,
};

/// Maps a device pixel centre back to viewBox space so a userSpaceOnUse gradient samples where it was
/// authored: `viewBox = (device - origin) / scale`.
const Inverse = struct {
    ox: f32,
    oy: f32,
    sx: f32,
    sy: f32,
};

fn sampleStops(stops: []const Stop, t_in: f32) Rgba {
    const t = std.math.clamp(t_in, 0.0, 1.0);
    if (stops.len == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (t <= stops[0].offset) return stops[0].colour;
    var i: usize = 0;
    while (i + 1 < stops.len) : (i += 1) {
        const a = stops[i];
        const b = stops[i + 1];
        if (t <= b.offset) {
            const span = b.offset - a.offset;
            const f = if (span <= 0.0) 0.0 else (t - a.offset) / span;
            return mix(a.colour, b.colour, f);
        }
    }
    return stops[stops.len - 1].colour;
}

fn mix(a: Rgba, b: Rgba, f: f32) Rgba {
    return .{
        .r = lerp(a.r, b.r, f),
        .g = lerp(a.g, b.g, f),
        .b = lerp(a.b, b.b, f),
        .a = lerp(a.a, b.a, f),
    };
}

fn lerp(a: u8, b: u8, f: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * f));
}

fn paintAt(pnt: Paint, inv: Inverse, dx: f32, dy: f32) Rgba {
    switch (pnt) {
        .solid => |c| return c,
        .linear => |g| return g.at((dx - inv.ox) / inv.sx, (dy - inv.oy) / inv.sy),
        .radial => |g| return g.at((dx - inv.ox) / inv.sx, (dy - inv.oy) / inv.sy),
    }
}

// --- Scanline coverage ---

const Crossing = struct { x: f32, dir: i32 };

fn crossingLess(_: void, a: Crossing, b: Crossing) bool {
    return a.x < b.x;
}

/// Accumulates antialiased coverage for one device row `y` of the given subpaths into `cov` (indexed from
/// device column `x0`), by scanning `samples` sub-rows and adding analytic horizontal span coverage.
fn coverageRow(polys: []const []const Point, rule: Rule, y: i32, cov: []f32, x0: i32) void {
    @memset(cov, 0.0);
    const weight = 1.0 / @as(f32, @floatFromInt(samples));
    var s: usize = 0;
    while (s < samples) : (s += 1) {
        const sy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, @floatFromInt(samples));
        var xs: [256]Crossing = undefined;
        var nc: usize = 0;
        for (polys) |poly| {
            if (poly.len < 2) continue;
            var i: usize = 0;
            while (i < poly.len) : (i += 1) {
                const a = poly[i];
                const b = poly[(i + 1) % poly.len];
                const top = @min(a.y, b.y);
                const bot = @max(a.y, b.y);
                if (sy < top or sy >= bot) continue;
                if (nc >= xs.len) break;
                const t = (sy - a.y) / (b.y - a.y);
                xs[nc] = .{ .x = a.x + t * (b.x - a.x), .dir = if (b.y > a.y) @as(i32, 1) else -1 };
                nc += 1;
            }
        }
        if (nc < 2) continue;
        std.mem.sort(Crossing, xs[0..nc], {}, crossingLess);
        var wind: i32 = 0;
        var k: usize = 0;
        while (k + 1 <= nc) : (k += 1) {
            switch (rule) {
                .nonzero => wind += xs[k].dir,
                .even_odd => wind ^= 1,
            }
            const inside = switch (rule) {
                .nonzero => wind != 0,
                .even_odd => (wind & 1) == 1,
            };
            if (inside and k + 1 < nc) addSpan(cov, x0, xs[k].x, xs[k + 1].x, weight);
        }
    }
}

/// Adds `weight` of coverage across the device x-span [xa, xb], with fractional coverage in the pixels
/// the span partially covers at each end.
fn addSpan(cov: []f32, x0: i32, xa: f32, xb: f32, weight: f32) void {
    const lo = @as(f32, @floatFromInt(x0));
    const hi = lo + @as(f32, @floatFromInt(cov.len));
    var a = @max(xa, lo);
    const b = @min(xb, hi);
    if (b <= a) return;
    var ix: i32 = @intFromFloat(@floor(a));
    while (@as(f32, @floatFromInt(ix)) < b) : (ix += 1) {
        const left = @max(a, @as(f32, @floatFromInt(ix)));
        const right = @min(b, @as(f32, @floatFromInt(ix + 1)));
        const f = right - left;
        if (f > 0.0) {
            const idx = ix - x0;
            if (idx >= 0 and idx < @as(i32, @intCast(cov.len))) cov[@intCast(idx)] += f * weight;
        }
        a = right;
    }
}

/// Fills `subject` with `pnt`, optionally intersected with `clip`, alpha-over onto `target`. Coverage is
/// antialiased; when `clip` is present the per-pixel coverage is the product of the two, which clips a
/// fill to a path. Cost is proportional to the covered rows and columns.
fn fillRegion(
    target: *Framebuffer,
    subject: []const []const Point,
    rule: Rule,
    clip: ?[]const []const Point,
    pnt: Paint,
    inv: Inverse,
    global_alpha: f32,
) void {
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (subject) |poly| {
        for (poly) |p| {
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }
    }
    if (max_x < min_x) return;
    const x0: i32 = @max(0, @as(i32, @intFromFloat(@floor(min_x))));
    const y0: i32 = @max(0, @as(i32, @intFromFloat(@floor(min_y))));
    const x1: i32 = @min(@as(i32, @intCast(target.width)), @as(i32, @intFromFloat(@ceil(max_x))) + 1);
    const y1: i32 = @min(@as(i32, @intCast(target.height)), @as(i32, @intFromFloat(@ceil(max_y))) + 1);
    if (x1 <= x0 or y1 <= y0) return;
    const width: usize = @min(max_row, @as(usize, @intCast(x1 - x0)));

    var sub_cov: [max_row]f32 = undefined;
    var clip_cov: [max_row]f32 = undefined;
    const sub = sub_cov[0..width];
    const clp = clip_cov[0..width];

    var y = y0;
    while (y < y1) : (y += 1) {
        coverageRow(subject, rule, y, sub, x0);
        if (clip) |c| {
            coverageRow(c, .nonzero, y, clp, x0);
            for (sub, clp) |*a, b| a.* *= b;
        }
        const dy = @as(f32, @floatFromInt(y)) + 0.5;
        var col: usize = 0;
        while (col < width) : (col += 1) {
            const c = sub[col];
            if (c <= 0.0) continue;
            const dx = @as(f32, @floatFromInt(x0 + @as(i32, @intCast(col)))) + 0.5;
            const colour = paintAt(pnt, inv, dx, dy);
            const alpha = std.math.clamp(c, 0.0, 1.0) * (@as(f32, @floatFromInt(colour.a)) / 255.0) * global_alpha;
            const coverage: u8 = @intFromFloat(std.math.clamp(alpha, 0.0, 1.0) * 255.0 + 0.5);
            if (coverage != 0) target.blend(@intCast(x0 + @as(i32, @intCast(col))), @intCast(y), .{ .r = colour.r, .g = colour.g, .b = colour.b, .a = 255 }, coverage);
        }
    }
}

// --- Path flattening ---

/// A flattened subpath: a run of device points and whether the source closed it with Z.
const Subpath = struct { start: usize, len: usize, closed: bool };

/// The result of flattening a path's `d`: device points plus the subpath spans over them.
const Flattened = struct {
    points: [768]Point = undefined,
    n: usize = 0,
    subs: [24]Subpath = undefined,
    sub_count: usize = 0,

    fn push(self: *Flattened, p: Point) void {
        if (self.n < self.points.len) {
            self.points[self.n] = p;
            self.n += 1;
        }
    }

    fn closeRange(self: *Flattened, start: usize, closed: bool) void {
        if (self.n > start and self.sub_count < self.subs.len) {
            self.subs[self.sub_count] = .{ .start = start, .len = self.n - start, .closed = closed };
            self.sub_count += 1;
        }
    }

    /// The subpaths as point slices, filled into `out`; returns the slice actually written.
    fn slices(self: *const Flattened, out: [][]const Point) [][]const Point {
        var k: usize = 0;
        while (k < self.sub_count and k < out.len) : (k += 1) {
            out[k] = self.points[self.subs[k].start .. self.subs[k].start + self.subs[k].len];
        }
        return out[0..k];
    }
};

/// Flattens the SVG path data `d` — absolute and relative M L H V C S Q T A Z — into device polylines
/// through `af`. Curves and arcs are flattened to short segments, matching how the stroke renderer
/// flattens its glyphs.
fn flattenPath(d: []const u8, af: Affine, out: *Flattened) void {
    var scan = Scanner{ .s = d };
    var cur = Point{ .x = 0, .y = 0 };
    var origin = cur;
    var sub_start: usize = out.n;
    var have_sub = false;
    var cmd: u8 = 0;
    var last_ctrl = Point{ .x = 0, .y = 0 };
    var last_cubic = false;
    var last_quad = false;

    while (true) {
        const letter = scan.command();
        if (letter) |ch| {
            cmd = ch;
        } else if (cmd == 0) {
            break;
        }
        const rel = std.ascii.isLower(cmd);
        const up = std.ascii.toUpper(cmd);
        var this_cubic = false;
        var this_quad = false;
        switch (up) {
            'M' => {
                if (have_sub) out.closeRange(sub_start, false);
                const x = scan.number() orelse break;
                const y = scan.number() orelse break;
                cur = .{ .x = if (rel) cur.x + x else x, .y = if (rel) cur.y + y else y };
                origin = cur;
                sub_start = out.n;
                have_sub = true;
                out.push(af.at(cur.x, cur.y));
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                const x = scan.number() orelse break;
                const y = scan.number() orelse break;
                cur = .{ .x = if (rel) cur.x + x else x, .y = if (rel) cur.y + y else y };
                out.push(af.at(cur.x, cur.y));
            },
            'H' => {
                const x = scan.number() orelse break;
                cur.x = if (rel) cur.x + x else x;
                out.push(af.at(cur.x, cur.y));
            },
            'V' => {
                const y = scan.number() orelse break;
                cur.y = if (rel) cur.y + y else y;
                out.push(af.at(cur.x, cur.y));
            },
            'C' => {
                const c1 = readPoint(&scan, rel, cur) orelse break;
                const c2 = readPoint(&scan, rel, cur) orelse break;
                const end = readPoint(&scan, rel, cur) orelse break;
                flattenCubic(out, af, cur, c1, c2, end);
                cur = end;
                last_ctrl = c2;
                this_cubic = true;
            },
            'S' => {
                const c1 = if (last_cubic) reflect(cur, last_ctrl) else cur;
                const c2 = readPoint(&scan, rel, cur) orelse break;
                const end = readPoint(&scan, rel, cur) orelse break;
                flattenCubic(out, af, cur, c1, c2, end);
                cur = end;
                last_ctrl = c2;
                this_cubic = true;
            },
            'Q' => {
                const c = readPoint(&scan, rel, cur) orelse break;
                const end = readPoint(&scan, rel, cur) orelse break;
                flattenQuad(out, af, cur, c, end);
                cur = end;
                last_ctrl = c;
                this_quad = true;
            },
            'T' => {
                const c = if (last_quad) reflect(cur, last_ctrl) else cur;
                const end = readPoint(&scan, rel, cur) orelse break;
                flattenQuad(out, af, cur, c, end);
                cur = end;
                last_ctrl = c;
                this_quad = true;
            },
            'A' => {
                const rx = scan.number() orelse break;
                const ry = scan.number() orelse break;
                const rot = scan.number() orelse break;
                const large = (scan.flag() orelse break) != 0;
                const sweep = (scan.flag() orelse break) != 0;
                const end = readPoint(&scan, rel, cur) orelse break;
                flattenArc(out, af, cur, rx, ry, rot, large, sweep, end);
                cur = end;
            },
            'Z' => {
                out.closeRange(sub_start, true);
                cur = origin;
                have_sub = false;
                cmd = 0;
            },
            else => break,
        }
        last_cubic = this_cubic;
        last_quad = this_quad;
        if (letter == null and cmd == 0) break;
    }
    if (have_sub) out.closeRange(sub_start, false);
}

fn readPoint(scan: *Scanner, rel: bool, cur: Point) ?Point {
    const x = scan.number() orelse return null;
    const y = scan.number() orelse return null;
    return .{ .x = if (rel) cur.x + x else x, .y = if (rel) cur.y + y else y };
}

fn reflect(cur: Point, ctrl: Point) Point {
    return .{ .x = 2.0 * cur.x - ctrl.x, .y = 2.0 * cur.y - ctrl.y };
}

fn flattenCubic(out: *Flattened, af: Affine, p0: Point, c1: Point, c2: Point, p1: Point) void {
    const steps: u8 = 16;
    var k: u8 = 1;
    while (k <= steps) : (k += 1) {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
        const u = 1.0 - t;
        const x = u * u * u * p0.x + 3.0 * u * u * t * c1.x + 3.0 * u * t * t * c2.x + t * t * t * p1.x;
        const y = u * u * u * p0.y + 3.0 * u * u * t * c1.y + 3.0 * u * t * t * c2.y + t * t * t * p1.y;
        out.push(af.at(x, y));
    }
}

fn flattenQuad(out: *Flattened, af: Affine, p0: Point, c: Point, p1: Point) void {
    const steps: u8 = 14;
    var k: u8 = 1;
    while (k <= steps) : (k += 1) {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
        const u = 1.0 - t;
        const x = u * u * p0.x + 2.0 * u * t * c.x + t * t * p1.x;
        const y = u * u * p0.y + 2.0 * u * t * c.y + t * t * p1.y;
        out.push(af.at(x, y));
    }
}

/// Flattens an SVG elliptical arc (endpoint parameterisation) via the spec's endpoint-to-centre
/// conversion; `rot` is the x-axis rotation in degrees.
fn flattenArc(out: *Flattened, af: Affine, p0: Point, rx_in: f32, ry_in: f32, rot: f32, large: bool, sweep: bool, p1: Point) void {
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx == 0 or ry == 0) {
        out.push(af.at(p1.x, p1.y));
        return;
    }
    const phi = rot * std.math.pi / 180.0;
    const cos_p = @cos(phi);
    const sin_p = @sin(phi);
    const dx = (p0.x - p1.x) / 2.0;
    const dy = (p0.y - p1.y) / 2.0;
    const x1p = cos_p * dx + sin_p * dy;
    const y1p = -sin_p * dx + cos_p * dy;

    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1.0) {
        const scale_r = @sqrt(lambda);
        rx *= scale_r;
        ry *= scale_r;
    }

    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coef = if (den > 0) @sqrt(@max(0.0, num / den)) else 0.0;
    if (large == sweep) coef = -coef;
    const cxp = coef * (rx * y1p / ry);
    const cyp = coef * (-ry * x1p / rx);
    const cx = cos_p * cxp - sin_p * cyp + (p0.x + p1.x) / 2.0;
    const cy = sin_p * cxp + cos_p * cyp + (p0.y + p1.y) / 2.0;

    const theta1 = angleBetween(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dtheta = angleBetween((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep and dtheta > 0.0) dtheta -= 2.0 * std.math.pi;
    if (sweep and dtheta < 0.0) dtheta += 2.0 * std.math.pi;

    const steps: u8 = @intFromFloat(@max(4.0, @abs(dtheta) / (std.math.pi / 16.0)));
    var k: u8 = 1;
    while (k <= steps) : (k += 1) {
        const t = theta1 + dtheta * (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps)));
        const px = cos_p * rx * @cos(t) - sin_p * ry * @sin(t) + cx;
        const py = sin_p * rx * @cos(t) + cos_p * ry * @sin(t) + cy;
        out.push(af.at(px, py));
    }
}

fn angleBetween(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    const dot = ux * vx + uy * vy;
    const len = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    var c = if (len > 0) dot / len else 0.0;
    c = std.math.clamp(c, -1.0, 1.0);
    const a = std.math.acos(c);
    return if (ux * vy - uy * vx < 0.0) -a else a;
}

// --- SVG parsing ---

/// Renders the app-tile `svg` into `rect`. Returns true when the tile parsed and drew; false when the
/// asset is not the expected app-tile shape, so the caller can fall back.
// --- The rasterized-tile cache ---
//
// A tile's vectors never change, so it is rasterized once — parse, flatten, gradient-sample, clip — into
// a small RGBA image the size below, and every later draw copies that image scaled into place. The
// per-frame cost drops from re-running the whole SVG engine per tile to a bounded blit, so the 60fps
// render loop does no vector work for a static launcher. The cache is keyed by the source SVG's address
// (each app tile is one embedded, stable slice), scanned linearly over a set no larger than the app
// count. The rasters live in a fixed static store — process-lifetime, never allocated and never grown —
// so the cache holds about a megabyte and a half total and touches no allocator, and there is nothing to leak.

const cache_edge: u32 = 128;
const tile_pixels: usize = cache_edge * cache_edge * 4;
/// A hard, never-growing bound on distinct cached tiles. The mapped tile set is smaller (22 distinct app
/// tiles); a slot per entry keeps the raster backing and the slot table the same length by construction.
const tile_slots: usize = 24;

const Cached = struct { key: [*]const u8, pixels: []u8 };
var cache_slots: [tile_slots]?Cached = .{null} ** tile_slots;
/// Static backing for every slot's raster: bounded, process-lifetime, never allocated or freed.
var tile_store: [tile_slots][tile_pixels]u8 = undefined;

/// The rasterized image for a tile SVG, rasterising it once on first use. Null only if rasterisation
/// fails or the cache is unexpectedly full, so the caller can fall back.
fn cachedTile(svg: []const u8) ?*const Cached {
    for (&cache_slots) |*slot| {
        if (slot.*) |c| if (c.key == svg.ptr) return &slot.*.?;
    }
    var free_index: ?usize = null;
    for (&cache_slots, 0..) |*slot, i| {
        if (slot.* == null) {
            free_index = i;
            break;
        }
    }
    const index = free_index orelse return null;
    const pixels = tile_store[index][0..];
    // Clear to transparent, matching the offscreen's former {0,0,0,0} init fill, then rasterise into a
    // borrowed framebuffer view over the static row — no allocation, so nothing here can leak.
    @memset(pixels, 0);
    var offscreen = Framebuffer.over(pixels, cache_edge, cache_edge);
    if (!rasterize(&offscreen, .{ .x = 0, .y = 0, .w = cache_edge, .h = cache_edge }, svg)) return null;
    cache_slots[index] = .{ .key = svg.ptr, .pixels = pixels };
    return &cache_slots[index].?;
}

/// Draws a tile into `rect`, rasterising its source vectors once and blitting the cached image on every
/// later frame. Returns false when the tile could not be rendered, so the caller draws its fallback.
pub fn render(target: *Framebuffer, rect: Rect, svg: []const u8) bool {
    const cached = cachedTile(svg) orelse return false;
    blitCached(target, rect, cached.pixels);
    return true;
}

/// Copies the cached tile image into `rect`, bilinearly sampled and alpha-composited over the target so
/// the tile's soft glow and transparent corners blend with what is behind them.
fn blitCached(target: *Framebuffer, rect: Rect, src: []const u8) void {
    const edge_f = @as(f32, @floatFromInt(cache_edge));
    const rw: i32 = @intCast(rect.w);
    const rh: i32 = @intCast(rect.h);
    var dy: i32 = 0;
    while (dy < rh) : (dy += 1) {
        const py = rect.y + dy;
        if (py < 0 or py >= @as(i32, @intCast(target.height))) continue;
        const fy = (@as(f32, @floatFromInt(dy)) + 0.5) / @as(f32, @floatFromInt(rh)) * edge_f - 0.5;
        var dx: i32 = 0;
        while (dx < rw) : (dx += 1) {
            const px = rect.x + dx;
            if (px < 0 or px >= @as(i32, @intCast(target.width))) continue;
            const fx = (@as(f32, @floatFromInt(dx)) + 0.5) / @as(f32, @floatFromInt(rw)) * edge_f - 0.5;
            const s = sampleBilinear(src, fx, fy);
            if (s[3] == 0) continue;
            const a: u32 = s[3];
            const inv = 255 - a;
            const dst = target.get(@intCast(px), @intCast(py));
            target.set(@intCast(px), @intCast(py), .{
                .r = @intCast((@as(u32, s[0]) * a + @as(u32, dst.r) * inv) / 255),
                .g = @intCast((@as(u32, s[1]) * a + @as(u32, dst.g) * inv) / 255),
                .b = @intCast((@as(u32, s[2]) * a + @as(u32, dst.b) * inv) / 255),
                .a = 255,
            });
        }
    }
}

/// Bilinearly samples the cache_edge-square RGBA image at a fractional coordinate, clamped to the edges.
fn sampleBilinear(src: []const u8, fx: f32, fy: f32) [4]u8 {
    const last: f32 = @floatFromInt(cache_edge - 1);
    const cx = std.math.clamp(fx, 0.0, last);
    const cy = std.math.clamp(fy, 0.0, last);
    const x0: u32 = @intFromFloat(@floor(cx));
    const y0: u32 = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, cache_edge - 1);
    const y1 = @min(y0 + 1, cache_edge - 1);
    const tx = cx - @as(f32, @floatFromInt(x0));
    const ty = cy - @as(f32, @floatFromInt(y0));
    var out: [4]u8 = undefined;
    inline for (0..4) |k| {
        const p00: f32 = @floatFromInt(src[(y0 * cache_edge + x0) * 4 + k]);
        const p10: f32 = @floatFromInt(src[(y0 * cache_edge + x1) * 4 + k]);
        const p01: f32 = @floatFromInt(src[(y1 * cache_edge + x0) * 4 + k]);
        const p11: f32 = @floatFromInt(src[(y1 * cache_edge + x1) * 4 + k]);
        const top = p00 + (p10 - p00) * tx;
        const bot = p01 + (p11 - p01) * tx;
        out[k] = @intFromFloat(@round(top + (bot - top) * ty));
    }
    return out;
}

/// Rasterises a tile's source vectors directly into `target` at `rect` — the full SVG engine. Called
/// once per tile through the cache above, never per frame.
fn rasterize(target: *Framebuffer, rect: Rect, svg: []const u8) bool {
    const rx = @as(f32, @floatFromInt(rect.x));
    const ry = @as(f32, @floatFromInt(rect.y));
    const sx = @as(f32, @floatFromInt(rect.w)) / view;
    const sy = @as(f32, @floatFromInt(rect.h)) / view;
    const tile_map = Affine{ .ox = rx, .oy = ry, .sx = sx, .sy = sy };
    const inv = Inverse{ .ox = rx, .oy = ry, .sx = sx, .sy = sy };

    const body = parseLinear(svg, "body") orelse return false;
    const spec = parseRadial(svg, "spec") orelse return false;
    const shade = parseLinear(svg, "shade") orelse return false;

    const clip_d = clipPathData(svg) orelse return false;
    var squircle: Flattened = .{};
    flattenPath(clip_d, tile_map, &squircle);
    if (squircle.sub_count == 0) return false;
    var sq_slices: [24][]const Point = undefined;
    const squircle_polys = squircle.slices(&sq_slices);

    const ctx = Ctx{ .body = body, .spec = spec, .shade = shade, .squircle = squircle_polys, .inv = inv };
    // Walk the whole drawable tree after the defs: the clip group's gradient body and washes, the
    // hairline outline, and the app's glyph — whether a transformed path group outside the clip or
    // elements drawn straight in the viewBox inside it. Each element is painted, gradient-sampled, and
    // clipped to the squircle per the group it sits under.
    const defs_end = std.mem.indexOf(u8, svg, "</defs>");
    const content = if (defs_end) |e| svg[e + "</defs>".len ..] else svg;
    renderLayer(target, content, tile_map, .{}, ctx, 0);
    return true;
}

// --- The tile tree: a small grouped-SVG walker with gradients and clipping ---

/// The paints and clip the whole tile shares: the three named gradients sampled in viewBox space, the
/// squircle used as the clip, and the device→viewBox inverse a userSpaceOnUse gradient samples through.
const Ctx = struct {
    body: Linear,
    spec: Radial,
    shade: Linear,
    squircle: []const []const Point,
    inv: Inverse,
};

/// Resolves a `fill`/`stroke` value to a paint: `none` and unknown references to null, `url(#id)` to the
/// matching named gradient, and `#rgb`/`#rrggbb` to a flat colour.
fn resolvePaint(value: []const u8, ctx: Ctx) ?Paint {
    if (std.mem.eql(u8, value, "none")) return null;
    if (std.mem.startsWith(u8, value, "url(#")) {
        if (std.mem.indexOf(u8, value, "body") != null) return .{ .linear = ctx.body };
        if (std.mem.indexOf(u8, value, "spec") != null) return .{ .radial = ctx.spec };
        if (std.mem.indexOf(u8, value, "shade") != null) return .{ .linear = ctx.shade };
        return null;
    }
    if (value.len > 0 and value[0] == '#') return .{ .solid = parseHex(value) };
    return null;
}

/// The presentation state a group passes down to its children: the fill and stroke paints (null means
/// `none`), their opacities, the stroke width in user units, and an optional dash pattern.
const Style = struct {
    fill: ?Paint = null,
    fill_opacity: f32 = 1.0,
    fill_rule: Rule = .nonzero,
    stroke: ?Rgba = null,
    stroke_opacity: f32 = 1.0,
    stroke_width: f32 = 1.0,
    dash_on: f32 = 0.0,
    dash_off: f32 = 0.0,
    /// Whether an ancestor carried `clip-path`, so this element clips to the squircle.
    clip: bool = false,
};

/// Renders one layer of the glyph tree: each `<g>` opens a child layer with inherited style and a
/// composed transform, and each leaf element paints with the current style. Recursion is bounded by the
/// asset's shallow nesting.
fn renderLayer(target: *Framebuffer, region: []const u8, af: Affine, style: Style, ctx: Ctx, depth: u8) void {
    if (depth > 6) return;
    var i: usize = 0;
    while (i < region.len) {
        const lt = std.mem.indexOfScalarPos(u8, region, i, '<') orelse break;
        if (lt + 1 < region.len and region[lt + 1] == '/') {
            i = lt + 1;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, region, lt, '>') orelse break;
        const elem = region[lt + 1 .. gt];
        if (tagIs(elem, "g")) {
            const inner_start = gt + 1;
            const close = matchingGroupClose(region, inner_start) orelse {
                i = gt + 1;
                continue;
            };
            renderLayer(target, region[inner_start..close], applyTransform(af, elem), inheritStyle(style, elem, ctx), ctx, depth + 1);
            i = close + "</g>".len;
        } else {
            drawLeaf(target, elem, af, inheritStyle(style, elem, ctx), ctx);
            i = gt + 1;
        }
    }
}

/// The index (of its `<`) of the `</g>` that closes the group whose inner text starts at `from`.
fn matchingGroupClose(region: []const u8, from: usize) ?usize {
    var i = from;
    var depth: usize = 1;
    while (std.mem.indexOfScalarPos(u8, region, i, '<')) |lt| {
        if (lt + 1 < region.len and region[lt + 1] == '/') {
            if (std.mem.startsWith(u8, region[lt..], "</g>")) {
                depth -= 1;
                if (depth == 0) return lt;
            }
            i = lt + 2;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, region, lt, '>') orelse return null;
        if (tagIs(region[lt + 1 .. gt], "g")) depth += 1;
        i = gt + 1;
    }
    return null;
}

/// Folds a group or leaf's presentation attributes onto the inherited style.
fn inheritStyle(base: Style, elem: []const u8, ctx: Ctx) Style {
    var s = base;
    if (attr(elem, "fill")) |f| s.fill = resolvePaint(f, ctx);
    if (attrNum(elem, "fill-opacity")) |o| s.fill_opacity = o;
    if (attr(elem, "fill-rule")) |fr| s.fill_rule = if (std.mem.eql(u8, fr, "evenodd")) .even_odd else .nonzero;
    if (attr(elem, "stroke")) |k| s.stroke = if (std.mem.eql(u8, k, "none")) null else parseHex(k);
    if (attrNum(elem, "stroke-opacity")) |o| s.stroke_opacity = o;
    if (attrNum(elem, "stroke-width")) |w| s.stroke_width = w;
    if (attr(elem, "stroke-dasharray")) |da| {
        var scan = Scanner{ .s = da };
        s.dash_on = scan.number() orelse 0.0;
        s.dash_off = scan.number() orelse s.dash_on;
    }
    // The only clip in the tile set is the squircle, so any clip-path turns squircle clipping on.
    if (attr(elem, "clip-path")) |_| s.clip = true;
    return s;
}

/// Composes any `translate`/`scale` in a group's transform onto the running affine.
fn applyTransform(af: Affine, elem: []const u8) Affine {
    var tx: f32 = 0;
    var ty: f32 = 0;
    var s: f32 = 1;
    if (std.mem.indexOf(u8, elem, "translate(")) |at| {
        var scan = Scanner{ .s = elem[at + "translate(".len ..] };
        tx = scan.number() orelse 0;
        ty = scan.number() orelse 0;
    }
    if (std.mem.indexOf(u8, elem, "scale(")) |at| {
        var scan = Scanner{ .s = elem[at + "scale(".len ..] };
        s = scan.number() orelse 1;
    }
    return .{ .ox = af.ox + tx * af.sx, .oy = af.oy + ty * af.sy, .sx = af.sx * s, .sy = af.sy * s };
}

fn strokeColour(style: Style) Rgba {
    const c = style.stroke orelse white;
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = @intFromFloat(std.math.clamp(style.stroke_opacity, 0.0, 1.0) * 255.0 + 0.5) };
}

fn strokeDeviceWidth(style: Style, af: Affine) f32 {
    return @max(0.75, style.stroke_width * af.sx);
}

/// Paints one leaf element — path, circle, line, rect, or polyline/polygon — with `style` through `af`,
/// clipping fills to the squircle when the element inherited a clip-path.
fn drawLeaf(target: *Framebuffer, elem: []const u8, af: Affine, style: Style, ctx: Ctx) void {
    const clip: ?[]const []const Point = if (style.clip) ctx.squircle else null;
    if (tagIs(elem, "path")) {
        const d = attr(elem, "d") orelse return;
        var flat: Flattened = .{};
        flattenPath(d, af, &flat);
        if (flat.sub_count == 0) return;
        var buf: [24][]const Point = undefined;
        const polys = flat.slices(&buf);
        if (style.fill) |p| fillRegion(target, polys, style.fill_rule, clip, p, ctx.inv, style.fill_opacity);
        if (style.stroke) |_| {
            const w = strokeDeviceWidth(style, af);
            const colour = strokeColour(style);
            for (flat.subs[0..flat.sub_count]) |sp| {
                vector.strokePolyline(target, flat.points[sp.start .. sp.start + sp.len], w, colour, sp.closed);
            }
        }
    } else if (tagIs(elem, "circle")) {
        const cx = attrNum(elem, "cx") orelse return;
        const cy = attrNum(elem, "cy") orelse return;
        const ru = attrNum(elem, "r") orelse return;
        if (style.fill) |p| fillCircle(target, af, cx, cy, ru, clip, p, ctx.inv, style.fill_opacity);
        if (style.stroke) |_| {
            const c = af.at(cx, cy);
            const rd = ru * af.sx;
            const colour = strokeColour(style);
            if (style.dash_on > 0.0) {
                dashedRing(target, c.x, c.y, rd, strokeDeviceWidth(style, af), colour, style.dash_on * af.sx, style.dash_off * af.sx);
            } else {
                vector.strokeCircle(target, c.x, c.y, rd, strokeDeviceWidth(style, af), colour);
            }
        }
    } else if (tagIs(elem, "line")) {
        if (style.stroke == null) return;
        const p1 = af.at(attrNum(elem, "x1") orelse return, attrNum(elem, "y1") orelse return);
        const p2 = af.at(attrNum(elem, "x2") orelse return, attrNum(elem, "y2") orelse return);
        vector.strokePolyline(target, &.{ p1, p2 }, strokeDeviceWidth(style, af), strokeColour(style), false);
    } else if (tagIs(elem, "rect")) {
        drawRect(target, elem, af, style, ctx, clip);
    } else if (tagIs(elem, "polyline") or tagIs(elem, "polygon")) {
        const pts = attr(elem, "points") orelse return;
        var flat: Flattened = .{};
        var scan = Scanner{ .s = pts };
        const start = flat.n;
        while (scan.number()) |x| {
            const y = scan.number() orelse break;
            flat.push(af.at(x, y));
        }
        const closed = tagIs(elem, "polygon");
        flat.closeRange(start, closed);
        if (flat.sub_count == 0) return;
        var buf: [24][]const Point = undefined;
        const polys = flat.slices(&buf);
        if (style.fill) |p| fillRegion(target, polys, style.fill_rule, clip, p, ctx.inv, style.fill_opacity);
        if (style.stroke) |_| vector.strokePolyline(target, flat.points[start..flat.n], strokeDeviceWidth(style, af), strokeColour(style), closed);
    }
}

/// Fills a circle by flattening it to a polygon in device space, so it composites through the same
/// clipped, gradient-aware fill path as everything else.
fn fillCircle(target: *Framebuffer, af: Affine, cx: f32, cy: f32, r_user: f32, clip: ?[]const []const Point, pnt: Paint, inv: Inverse, alpha: f32) void {
    var flat: Flattened = .{};
    const start = flat.n;
    const steps: usize = 40;
    var k: usize = 0;
    while (k < steps) : (k += 1) {
        const a = 2.0 * std.math.pi * (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps)));
        flat.push(af.at(cx + r_user * @cos(a), cy + r_user * @sin(a)));
    }
    flat.closeRange(start, true);
    var buf: [24][]const Point = undefined;
    fillRegion(target, flat.slices(&buf), .nonzero, clip, pnt, inv, alpha);
}

/// A rounded rectangle leaf: a closed superellipse-cornered outline built in user units.
fn drawRect(target: *Framebuffer, elem: []const u8, af: Affine, style: Style, ctx: Ctx, clip: ?[]const []const Point) void {
    const x = attrNum(elem, "x") orelse return;
    const y = attrNum(elem, "y") orelse return;
    const w = attrNum(elem, "width") orelse return;
    const h = attrNum(elem, "height") orelse return;
    const r = @min(attrNum(elem, "rx") orelse 0.0, @min(w, h) / 2.0);
    var flat: Flattened = .{};
    const start = flat.n;
    const corners = [4][3]f32{
        .{ x + w - r, y + r, -std.math.pi / 2.0 },
        .{ x + w - r, y + h - r, 0.0 },
        .{ x + r, y + h - r, std.math.pi / 2.0 },
        .{ x + r, y + r, std.math.pi },
    };
    for (corners) |corner| {
        var k: u8 = 0;
        while (k <= 4) : (k += 1) {
            const a = corner[2] + (std.math.pi / 2.0) * (@as(f32, @floatFromInt(k)) / 4.0);
            flat.push(af.at(corner[0] + r * @cos(a), corner[1] + r * @sin(a)));
        }
    }
    flat.closeRange(start, true);
    var buf: [24][]const Point = undefined;
    const polys = flat.slices(&buf);
    if (style.fill) |p| fillRegion(target, polys, .nonzero, clip, p, ctx.inv, style.fill_opacity);
    if (style.stroke) |_| vector.strokePolyline(target, flat.points[start..flat.n], strokeDeviceWidth(style, af), strokeColour(style), true);
}

/// Strokes a dashed ring: on/off arc lengths in device units around the circle, matching a
/// `stroke-dasharray` of two values.
fn dashedRing(target: *Framebuffer, cx: f32, cy: f32, r: f32, width: f32, colour: Rgba, on: f32, off: f32) void {
    if (r <= 0.0 or on <= 0.0) return;
    const circumference = 2.0 * std.math.pi * r;
    var pos: f32 = 0.0;
    while (pos < circumference) : (pos += on + off) {
        const seg_end = @min(pos + on, circumference);
        const a0 = pos / r;
        const a1 = seg_end / r;
        var pts: [12]Point = undefined;
        const steps: usize = @intFromFloat(@max(2.0, (a1 - a0) / 0.35));
        var k: usize = 0;
        var n: usize = 0;
        while (k <= steps and n < pts.len) : (k += 1) {
            const a = a0 + (a1 - a0) * (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps)));
            pts[n] = .{ .x = cx + r * @cos(a), .y = cy + r * @sin(a) };
            n += 1;
        }
        if (n >= 2) vector.strokePolyline(target, pts[0..n], width, colour, false);
        if (off <= 0.0) break;
    }
}

/// The clip squircle's path data: the `d` of the `<path>` inside `<clipPath ...>`. The path element is
/// located first so the `d="` search cannot latch onto the `d="` inside `id="clip"`.
fn clipPathData(svg: []const u8) ?[]const u8 {
    const cp = std.mem.indexOf(u8, svg, "clipPath") orelse return null;
    const p = std.mem.indexOfPos(u8, svg, cp, "<path") orelse return null;
    const close = std.mem.indexOfScalarPos(u8, svg, p, '>') orelse return null;
    return attr(svg[p + 1 .. close], "d");
}

fn parseLinear(svg: []const u8, id: []const u8) ?Linear {
    const el = elementById(svg, id, "</linearGradient>") orelse return null;
    var out = Linear{
        .x1 = attrNum(el.open, "x1") orelse 0.0,
        .y1 = attrNum(el.open, "y1") orelse 0.0,
        .x2 = attrNum(el.open, "x2") orelse 0.0,
        .y2 = attrNum(el.open, "y2") orelse view,
        .stops = undefined,
        .count = 0,
    };
    out.count = parseStops(el.inner, &out.stops);
    if (out.count == 0) return null;
    return out;
}

fn parseRadial(svg: []const u8, id: []const u8) ?Radial {
    const el = elementById(svg, id, "</radialGradient>") orelse return null;
    var out = Radial{
        .cx = attrNum(el.open, "cx") orelse 0.0,
        .cy = attrNum(el.open, "cy") orelse 0.0,
        .r = attrNum(el.open, "r") orelse view,
        .stops = undefined,
        .count = 0,
    };
    out.count = parseStops(el.inner, &out.stops);
    if (out.count == 0) return null;
    return out;
}

const Element = struct { open: []const u8, inner: []const u8 };

/// The element carrying `id="<id>"`: its open-tag attribute text and the inner text up to `close_tag`.
fn elementById(svg: []const u8, id: []const u8, close_tag: []const u8) ?Element {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "id=\"{s}\"", .{id}) catch return null;
    const id_at = std.mem.indexOf(u8, svg, needle) orelse return null;
    const tag_end = std.mem.indexOfScalarPos(u8, svg, id_at, '>') orelse return null;
    const inner_end = std.mem.indexOfPos(u8, svg, tag_end, close_tag) orelse return null;
    return .{ .open = svg[id_at..tag_end], .inner = svg[tag_end + 1 .. inner_end] };
}

/// Parses `<stop>` children into `out`, each carrying its offset and colour with stop-opacity folded into
/// the alpha channel. Returns the stop count.
fn parseStops(inner: []const u8, out: *[4]Stop) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (count < out.len) {
        const at = std.mem.indexOfPos(u8, inner, i, "<stop") orelse break;
        const close = std.mem.indexOfScalarPos(u8, inner, at, '>') orelse break;
        const elem = inner[at + 1 .. close];
        i = close + 1;
        const offset = attrNum(elem, "offset") orelse 0.0;
        var colour = if (attr(elem, "stop-color")) |c| parseHex(c) else white;
        const op = opacity(elem, "stop-opacity");
        colour.a = @intFromFloat(std.math.clamp(op, 0.0, 1.0) * 255.0 + 0.5);
        out[count] = .{ .offset = offset, .colour = colour };
        count += 1;
    }
    return count;
}

fn parseHex(s_in: []const u8) Rgba {
    var s = s_in;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len == 3) {
        const r = hexNibble(s[0]);
        const g = hexNibble(s[1]);
        const b = hexNibble(s[2]);
        return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 255 };
    }
    if (s.len >= 6) {
        return .{
            .r = hexNibble(s[0]) * 16 + hexNibble(s[1]),
            .g = hexNibble(s[2]) * 16 + hexNibble(s[3]),
            .b = hexNibble(s[4]) * 16 + hexNibble(s[5]),
            .a = 255,
        };
    }
    return white;
}

fn hexNibble(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => 0,
    };
}

fn opacity(elem: []const u8, name: []const u8) f32 {
    return attrNum(elem, name) orelse 1.0;
}

// --- Attribute reading ---

/// The tag name of `elem` is `name` (the leading token before the first space or '/').
fn tagIs(elem: []const u8, name: []const u8) bool {
    const end = std.mem.indexOfAny(u8, elem, " \t/\n") orelse elem.len;
    return std.mem.eql(u8, elem[0..end], name);
}

/// The raw value of attribute `name` in `elem`, or null. Guards against a longer attribute that merely
/// ends in `name`, so `y` does not match `cy` and `offset` does not match a suffix.
fn attr(elem: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, elem, from, name)) |at| {
        const after = at + name.len;
        if (after + 1 < elem.len and elem[after] == '=' and elem[after + 1] == '"') {
            const boundary = at == 0 or elem[at - 1] == ' ' or elem[at - 1] == '\n' or elem[at - 1] == '\t' or elem[at - 1] == '"';
            if (boundary) {
                const start = after + 2;
                const stop = std.mem.indexOfScalarPos(u8, elem, start, '"') orelse return null;
                return elem[start..stop];
            }
        }
        from = at + 1;
    }
    return null;
}

fn attrNum(elem: []const u8, name: []const u8) ?f32 {
    const raw = attr(elem, name) orelse return null;
    return std.fmt.parseFloat(f32, raw) catch null;
}

/// A forward scanner over an SVG number/command stream: numbers separated by spaces or commas, single
/// letter commands interspersed, and single-digit arc flags.
const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(self: *Scanner) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == ',' or self.s[self.i] == '\n' or self.s[self.i] == '\t')) self.i += 1;
    }

    fn command(self: *Scanner) ?u8 {
        self.skipSep();
        if (self.i >= self.s.len) return null;
        const ch = self.s[self.i];
        if (std.ascii.isAlphabetic(ch)) {
            self.i += 1;
            return ch;
        }
        return null;
    }

    fn number(self: *Scanner) ?f32 {
        self.skipSep();
        const begin = self.i;
        if (self.i < self.s.len and (self.s[self.i] == '-' or self.s[self.i] == '+')) self.i += 1;
        var seen = false;
        var dot = false;
        while (self.i < self.s.len) {
            const ch = self.s[self.i];
            if (std.ascii.isDigit(ch)) {
                seen = true;
                self.i += 1;
            } else if (ch == '.' and !dot) {
                // A second '.' begins another number, as in the compact "13.6.9" — stop before it.
                dot = true;
                self.i += 1;
            } else break;
        }
        if (!seen) {
            self.i = begin;
            return null;
        }
        return std.fmt.parseFloat(f32, self.s[begin..self.i]) catch null;
    }

    /// Reads one arc flag: a single '0' or '1', which SVG allows to run straight into the next number.
    fn flag(self: *Scanner) ?u8 {
        self.skipSep();
        if (self.i >= self.s.len) return null;
        const ch = self.s[self.i];
        if (ch == '0' or ch == '1') {
            self.i += 1;
            return ch - '0';
        }
        return null;
    }
};

// --- Tests ---

const testing = std.testing;
const tiles = @import("design").icons.tiles;

fn nearWhite(p: Rgba) bool {
    return p.r > 230 and p.g > 230 and p.b > 230;
}

test "a tile renders its gradient body, a white glyph, and clipped corners" {
    var target = try Framebuffer.init(testing.allocator, 96, 96, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    try testing.expect(render(&target, .{ .x = 0, .y = 0, .w = 96, .h = 96 }, tiles.weather));

    // A body-only sample (lower-left, clear of the glyph) is the blue body, not the cleared background.
    const body_px = target.get(20, 70);
    try testing.expect(body_px.b > body_px.r and body_px.b > 120);

    // The corner is outside the squircle, so it stays cleared.
    try testing.expect(target.get(1, 1).r < 40 and target.get(1, 1).b < 40);

    // The white cloud glyph put down near-white ink somewhere.
    var found = false;
    var y: u32 = 0;
    outer: while (y < 96) : (y += 1) {
        var x: u32 = 0;
        while (x < 96) : (x += 1) {
            if (nearWhite(target.get(x, y))) {
                found = true;
                break :outer;
            }
        }
    }
    try testing.expect(found);
}

test "the specular highlight lifts the upper body brighter than the lower body" {
    var target = try Framebuffer.init(testing.allocator, 128, 128, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    try testing.expect(render(&target, .{ .x = 0, .y = 0, .w = 128, .h = 128 }, tiles.weather));
    // The radial highlight sits near the top; the shade darkens the bottom. Sample body-only columns.
    const top = target.get(30, 40);
    const bottom = target.get(30, 96);
    const top_lum = @as(u32, top.r) + top.g + top.b;
    const bottom_lum = @as(u32, bottom.r) + bottom.g + bottom.b;
    try testing.expect(top_lum > bottom_lum);
}

test "a stroked-glyph tile lays down white ink" {
    var target = try Framebuffer.init(testing.allocator, 96, 96, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    try testing.expect(render(&target, .{ .x = 0, .y = 0, .w = 96, .h = 96 }, tiles.settings));
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < 96) : (y += 1) {
        var x: u32 = 0;
        while (x < 96) : (x += 1) {
            if (nearWhite(target.get(x, y))) count += 1;
        }
    }
    try testing.expect(count > 20);
}

test "hex colour parses both short and long forms" {
    try testing.expectEqual(Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 }, parseHex("#fff"));
    try testing.expectEqual(Rgba{ .r = 138, .g = 194, .b = 255, .a = 255 }, parseHex("#8AC2FF"));
}

test "a linear gradient interpolates and clamps its stops" {
    var stops = [2]Stop{
        .{ .offset = 0.0, .colour = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
        .{ .offset = 1.0, .colour = .{ .r = 100, .g = 0, .b = 0, .a = 255 } },
    };
    try testing.expectEqual(@as(u8, 50), sampleStops(stops[0..], 0.5).r);
    try testing.expectEqual(@as(u8, 0), sampleStops(stops[0..], -1.0).r); // clamped low
    try testing.expectEqual(@as(u8, 100), sampleStops(stops[0..], 2.0).r); // clamped high
}

test "every mapped app tile parses and renders" {
    const set = [_][]const u8{
        tiles.agents,   tiles.settings, tiles.messages,   tiles.phone,
        tiles.calendar, tiles.files,    tiles.contacts,   tiles.camera,
        tiles.weather,  tiles.browser,  tiles.calculator, tiles.store,
        tiles.health,   tiles.mail,     tiles.notes,      tiles.maps,
    };
    for (set) |svg| {
        var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        defer target.deinit();
        try testing.expect(render(&target, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, svg));
    }
}
