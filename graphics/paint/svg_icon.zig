//! Rendering the delivered UI glyphs — the designed 24-grid, currentColor SVGs — onto a framebuffer.
//!
//! The icon set ships as small SVGs stroked in `currentColor` on a 0..24 grid: a handful of `path`,
//! `line`, `circle`, and `rect` elements at stroke-width 2. This module reads that vocabulary directly
//! and draws it with the vector rasteriser, so the symbols on screen are the designed glyphs rather than
//! hand-built approximations. Curves and arcs in a `path` are flattened to short polylines; a filled
//! circle becomes a disc, a stroked one a ring, a `rect` a rounded outline. A glyph is drawn centred in
//! a target box at a chosen colour, so one embedded definition renders crisply at any tile size.
//!
//! It parses only the element and command set the delivered glyphs actually use — absolute path commands
//! (M L H V C A Z), `line`, `circle`, `rect`, `polyline` — and treats anything else as absent. This is a
//! renderer of a known asset set, not a general SVG engine.

const std = @import("std");
const fb = @import("framebuffer.zig");
const vector = @import("vector.zig");

const Framebuffer = fb.Framebuffer;
const Rgba = fb.Rgba;
const Point = vector.Point;

/// The grid the glyphs are authored on: a 24×24 viewBox.
const grid: f32 = 24.0;
/// The authored stroke width on that grid.
const stroke_grid: f32 = 2.0;

/// Maps the 0..24 glyph grid into the target: a uniform scale plus an origin offset.
const Xform = struct {
    ox: f32,
    oy: f32,
    scale: f32,

    fn at(self: Xform, x: f32, y: f32) Point {
        return .{ .x = self.ox + x * self.scale, .y = self.oy + y * self.scale };
    }
};

/// Draws the glyph `svg` centred in `rect`, its 24-grid scaled to `fraction` of the box width, in
/// `colour`. `fraction` ~0.6 places the ink at roughly the inset the tile glyphs sit at.
pub fn drawInRect(target: *Framebuffer, svg: []const u8, rect_x: i32, rect_y: i32, rect_w: u32, rect_h: u32, fraction: f32, colour: Rgba) void {
    const box = @as(f32, @floatFromInt(rect_w)) * fraction;
    const scale = box / grid;
    const cx = @as(f32, @floatFromInt(rect_x)) + @as(f32, @floatFromInt(rect_w)) / 2.0;
    const cy = @as(f32, @floatFromInt(rect_y)) + @as(f32, @floatFromInt(rect_h)) / 2.0;
    const xf = Xform{ .ox = cx - (grid / 2.0) * scale, .oy = cy - (grid / 2.0) * scale, .scale = scale };
    const width = stroke_grid * scale;
    renderElements(target, svg, xf, width, colour);
}

/// Draws the glyph centred at (cx, cy) with the whole 24-grid scaled to `size` points.
pub fn draw(target: *Framebuffer, svg: []const u8, cx: f32, cy: f32, size: f32, colour: Rgba) void {
    const scale = size / grid;
    const xf = Xform{ .ox = cx - (grid / 2.0) * scale, .oy = cy - (grid / 2.0) * scale, .scale = scale };
    renderElements(target, svg, xf, stroke_grid * scale, colour);
}

// --- Element dispatch ---

fn renderElements(target: *Framebuffer, svg: []const u8, xf: Xform, width: f32, colour: Rgba) void {
    var i: usize = 0;
    while (i < svg.len) {
        if (svg[i] != '<') {
            i += 1;
            continue;
        }
        // Read the element up to its closing '>'.
        const close = std.mem.indexOfScalarPos(u8, svg, i, '>') orelse break;
        const elem = svg[i + 1 .. close];
        renderElement(target, elem, xf, width, colour);
        i = close + 1;
    }
}

fn renderElement(target: *Framebuffer, elem: []const u8, xf: Xform, width: f32, colour: Rgba) void {
    if (tagIs(elem, "path")) {
        if (attrSlice(elem, "d")) |d| renderPath(target, d, xf, width, colour);
    } else if (tagIs(elem, "line")) {
        const p1 = xf.at(attrF(elem, "x1") orelse return, attrF(elem, "y1") orelse return);
        const p2 = xf.at(attrF(elem, "x2") orelse return, attrF(elem, "y2") orelse return);
        vector.strokePolyline(target, &.{ p1, p2 }, width, colour, false);
    } else if (tagIs(elem, "circle")) {
        const c = xf.at(attrF(elem, "cx") orelse return, attrF(elem, "cy") orelse return);
        const r = (attrF(elem, "r") orelse return) * xf.scale;
        if (isFilled(elem)) {
            vector.fillDisc(target, c.x, c.y, r, colour);
        } else {
            vector.strokeCircle(target, c.x, c.y, r, width, colour);
        }
    } else if (tagIs(elem, "rect")) {
        renderRect(target, elem, xf, width, colour);
    } else if (tagIs(elem, "polyline") or tagIs(elem, "polygon")) {
        if (attrSlice(elem, "points")) |pts| renderPoly(target, pts, xf, width, colour, tagIs(elem, "polygon"));
    }
}

/// The element's tag name is `name` (the leading token before the first space or '/').
fn tagIs(elem: []const u8, name: []const u8) bool {
    const end = std.mem.indexOfAny(u8, elem, " \t/\n") orelse elem.len;
    return std.mem.eql(u8, elem[0..end], name);
}

/// True when the element paints a fill (a filled dot) rather than only a stroke.
fn isFilled(elem: []const u8) bool {
    const fill = attrSlice(elem, "fill") orelse return false;
    return !std.mem.eql(u8, fill, "none");
}

// --- Attributes ---

/// The raw value of attribute `name` in `elem`, or null. Matches `name="..."`, guarding against a
/// longer attribute that merely ends in `name` (so `y` does not match `cy`).
fn attrSlice(elem: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, elem, from, name)) |at| {
        const after = at + name.len;
        if (after < elem.len and elem[after] == '=' and elem[after + 1] == '"') {
            // The char before the name must be a boundary, not a letter or dash.
            const boundary = at == 0 or elem[at - 1] == ' ' or elem[at - 1] == '\n' or elem[at - 1] == '\t';
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

fn attrF(elem: []const u8, name: []const u8) ?f32 {
    const raw = attrSlice(elem, name) orelse return null;
    return std.fmt.parseFloat(f32, raw) catch null;
}

// --- Rect ---

fn renderRect(target: *Framebuffer, elem: []const u8, xf: Xform, width: f32, colour: Rgba) void {
    const x = attrF(elem, "x") orelse return;
    const y = attrF(elem, "y") orelse return;
    const w = attrF(elem, "width") orelse return;
    const h = attrF(elem, "height") orelse return;
    const r = @min(attrF(elem, "rx") orelse 0.0, @min(w, h) / 2.0);

    var buf: [64]Point = undefined;
    var n: usize = 0;
    // Clockwise from the top edge, rounding each corner with a short quarter arc.
    const corners = [4][3]f32{
        .{ x + w - r, y + r, -std.math.pi / 2.0 }, // top-right
        .{ x + w - r, y + h - r, 0.0 }, // bottom-right
        .{ x + r, y + h - r, std.math.pi / 2.0 }, // bottom-left
        .{ x + r, y + r, std.math.pi }, // top-left
    };
    for (corners) |corner| {
        const ccx = corner[0];
        const ccy = corner[1];
        const start = corner[2];
        var k: u8 = 0;
        while (k <= 4) : (k += 1) {
            const a = start + (std.math.pi / 2.0) * (@as(f32, @floatFromInt(k)) / 4.0);
            push(&buf, &n, xf.at(ccx + r * @cos(a), ccy + r * @sin(a)));
        }
    }
    vector.strokePolyline(target, buf[0..n], width, colour, true);
}

fn renderPoly(target: *Framebuffer, pts: []const u8, xf: Xform, width: f32, colour: Rgba, closed: bool) void {
    var buf: [64]Point = undefined;
    var n: usize = 0;
    var scan = Scanner{ .s = pts };
    while (scan.number()) |x| {
        const y = scan.number() orelse break;
        push(&buf, &n, xf.at(x, y));
    }
    if (n >= 2) vector.strokePolyline(target, buf[0..n], width, colour, closed);
}

// --- Path ---

fn renderPath(target: *Framebuffer, d: []const u8, xf: Xform, width: f32, colour: Rgba) void {
    var buf: [256]Point = undefined;
    var n: usize = 0;
    var cur = Point{ .x = 0, .y = 0 };
    var start = cur;
    var scan = Scanner{ .s = d };
    var cmd: u8 = 0;

    while (true) {
        const next = scan.command();
        if (next) |ch| {
            cmd = ch;
        } else if (cmd == 0) {
            break;
        }
        // A command with no following letter repeats until the numbers run out; Z takes no args.
        switch (cmd) {
            'M' => {
                // Flush any open subpath, then begin a new one.
                if (n >= 2) vector.strokePolyline(target, buf[0..n], width, colour, false);
                n = 0;
                const x = scan.number() orelse break;
                const y = scan.number() orelse break;
                cur = .{ .x = x, .y = y };
                start = cur;
                push(&buf, &n, xf.at(cur.x, cur.y));
                cmd = 'L'; // subsequent implicit pairs are line-tos
            },
            'L' => {
                const x = scan.number() orelse break;
                const y = scan.number() orelse break;
                cur = .{ .x = x, .y = y };
                push(&buf, &n, xf.at(cur.x, cur.y));
            },
            'H' => {
                const x = scan.number() orelse break;
                cur.x = x;
                push(&buf, &n, xf.at(cur.x, cur.y));
            },
            'V' => {
                const y = scan.number() orelse break;
                cur.y = y;
                push(&buf, &n, xf.at(cur.x, cur.y));
            },
            'C' => {
                const x1 = scan.number() orelse break;
                const y1 = scan.number() orelse break;
                const x2 = scan.number() orelse break;
                const y2 = scan.number() orelse break;
                const x = scan.number() orelse break;
                const y = scan.number() orelse break;
                flattenCubic(&buf, &n, xf, cur, .{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 }, .{ .x = x, .y = y });
                cur = .{ .x = x, .y = y };
            },
            'A' => {
                const rx = scan.number() orelse break;
                const ry = scan.number() orelse break;
                const rot = scan.number() orelse break;
                const large = (scan.number() orelse break) != 0.0;
                const sweep = (scan.number() orelse break) != 0.0;
                const x = scan.number() orelse break;
                const y = scan.number() orelse break;
                flattenArc(&buf, &n, xf, cur, rx, ry, rot, large, sweep, .{ .x = x, .y = y });
                cur = .{ .x = x, .y = y };
            },
            'Z' => {
                if (n >= 2) vector.strokePolyline(target, buf[0..n], width, colour, true);
                n = 0;
                cur = start;
                cmd = 0; // await the next explicit command
            },
            else => break,
        }
        if (next == null and cmd == 0) break;
    }
    if (n >= 2) vector.strokePolyline(target, buf[0..n], width, colour, false);
}

/// Flattens a cubic bézier into line segments appended to the buffer (endpoints in grid space).
fn flattenCubic(buf: []Point, n: *usize, xf: Xform, p0: Point, c1: Point, c2: Point, p1: Point) void {
    const steps: u8 = 18;
    var k: u8 = 1;
    while (k <= steps) : (k += 1) {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
        const u = 1.0 - t;
        const x = u * u * u * p0.x + 3.0 * u * u * t * c1.x + 3.0 * u * t * t * c2.x + t * t * t * p1.x;
        const y = u * u * u * p0.y + 3.0 * u * u * t * c1.y + 3.0 * u * t * t * c2.y + t * t * t * p1.y;
        push(buf, n, xf.at(x, y));
    }
}

/// Flattens an SVG elliptical arc (endpoint parameterisation) into segments, per the SVG spec's
/// endpoint-to-centre conversion. `rot` is the x-axis rotation in degrees.
fn flattenArc(buf: []Point, n: *usize, xf: Xform, p0: Point, rx_in: f32, ry_in: f32, rot: f32, large: bool, sweep: bool, p1: Point) void {
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx == 0 or ry == 0) {
        push(buf, n, xf.at(p1.x, p1.y));
        return;
    }
    const phi = rot * std.math.pi / 180.0;
    const cos_p = @cos(phi);
    const sin_p = @sin(phi);

    const dx = (p0.x - p1.x) / 2.0;
    const dy = (p0.y - p1.y) / 2.0;
    const x1p = cos_p * dx + sin_p * dy;
    const y1p = -sin_p * dx + cos_p * dy;

    // Grow the radii if they cannot span the endpoints.
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
        push(buf, n, xf.at(px, py));
    }
}

/// The signed angle from vector u to vector v.
fn angleBetween(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    const dot = ux * vx + uy * vy;
    const len = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    var c = if (len > 0) dot / len else 0.0;
    c = std.math.clamp(c, -1.0, 1.0);
    const a = std.math.acos(c);
    return if (ux * vy - uy * vx < 0.0) -a else a;
}

fn push(buf: []Point, n: *usize, p: Point) void {
    if (n.* < buf.len) {
        buf[n.*] = p;
        n.* += 1;
    }
}

/// A tiny forward scanner over an SVG number/command stream: numbers separated by spaces or commas,
/// single-letter commands interspersed.
const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(self: *Scanner) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == ',' or self.s[self.i] == '\n' or self.s[self.i] == '\t')) self.i += 1;
    }

    /// Returns the next command letter if the stream is positioned on one, else null (leaving position).
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

    /// Parses the next number, or null if the next token is a command letter or the stream ends.
    fn number(self: *Scanner) ?f32 {
        self.skipSep();
        const begin = self.i;
        if (self.i < self.s.len and (self.s[self.i] == '-' or self.s[self.i] == '+')) self.i += 1;
        var seen = false;
        while (self.i < self.s.len) {
            const ch = self.s[self.i];
            if (std.ascii.isDigit(ch) or ch == '.') {
                seen = true;
                self.i += 1;
            } else break;
        }
        if (!seen) {
            self.i = begin;
            return null;
        }
        return std.fmt.parseFloat(f32, self.s[begin..self.i]) catch null;
    }
};

const testing = std.testing;

const delivered = @import("design").icons.glyphs;
const test_call = delivered.call;
const test_agent = delivered.agent;
const test_settings = delivered.settings;

test "a glyph with arcs and a bezier lays down ink" {
    var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    drawInRect(&target, test_call, 0, 0, 64, 64, 0.7, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    try testing.expect(inkCount(&target) > 40);
}

test "a filled-dot glyph draws its solid centre" {
    var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    drawInRect(&target, test_agent, 0, 0, 64, 64, 0.7, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    // The centre dot is filled, so the middle pixel is lit.
    try testing.expect(target.get(32, 32).r > 200);
}

test "a glyph of stroked circle plus spokes renders" {
    var target = try Framebuffer.init(testing.allocator, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    drawInRect(&target, test_settings, 0, 0, 64, 64, 0.7, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    try testing.expect(inkCount(&target) > 40);
}

fn inkCount(target: *Framebuffer) u32 {
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        var x: u32 = 0;
        while (x < target.width) : (x += 1) {
            if (target.get(x, y).r > 200) count += 1;
        }
    }
    return count;
}
