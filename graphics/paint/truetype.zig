//! A small TrueType parser and rasterizer, so the interface can render its real
//! typeface from the font's own outlines rather than an approximation of them.
//!
//! The design's typeface is a specific font, and matching it means drawing its actual
//! glyphs. This reads a glyf-based TrueType face — the tables that map a character to a
//! glyph, give the glyph's advance, and hold its outline — and fills that outline into a
//! coverage bitmap the renderer blends. It supports the parts a Latin UI needs: the
//! character map (format 4), horizontal metrics, simple and composite glyphs, and
//! quadratic outlines. Rasterization is a scanline fill under the nonzero-winding rule
//! with vertical supersampling and fractional horizontal coverage, which is enough
//! antialiasing to read cleanly at UI sizes. It hints nothing and shapes nothing — a
//! separate shaper positions runs; this only turns one glyph into pixels.
//!
//! The parser is defensive: a malformed offset or length yields an error or an empty
//! glyph, never a read out of bounds, because a font can arrive from anywhere.

const std = @import("std");

pub const Error = error{
    NotTrueType,
    MissingTable,
    Malformed,
    UnsupportedCmap,
    OutOfMemory,
};

/// A read cursor over big-endian font data with bounds checks.
const Reader = struct {
    data: []const u8,

    fn u8At(reader: Reader, offset: usize) !u8 {
        if (offset >= reader.data.len) return Error.Malformed;
        return reader.data[offset];
    }
    fn u16At(reader: Reader, offset: usize) !u16 {
        if (offset + 2 > reader.data.len) return Error.Malformed;
        return std.mem.readInt(u16, reader.data[offset..][0..2], .big);
    }
    fn i16At(reader: Reader, offset: usize) !i16 {
        if (offset + 2 > reader.data.len) return Error.Malformed;
        return std.mem.readInt(i16, reader.data[offset..][0..2], .big);
    }
    fn u32At(reader: Reader, offset: usize) !u32 {
        if (offset + 4 > reader.data.len) return Error.Malformed;
        return std.mem.readInt(u32, reader.data[offset..][0..4], .big);
    }
};

/// A parsed face: the table locations and the metrics a renderer needs.
pub const Face = struct {
    data: []const u8,
    units_per_em: u16,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    num_glyphs: u16,
    num_h_metrics: u16,
    loca_long: bool,
    // Table offsets.
    loca: u32,
    glyf: u32,
    hmtx: u32,
    cmap_sub: u32,

    fn reader(face: Face) Reader {
        return .{ .data = face.data };
    }

    /// Parses the tables of a glyf-based TrueType face.
    pub fn parse(data: []const u8) Error!Face {
        const r: Reader = .{ .data = data };
        const sfnt = try r.u32At(0);
        // 0x00010000 (TrueType outlines) or 'true'. CFF ('OTTO') is not supported.
        if (sfnt != 0x00010000 and sfnt != 0x74727565) return Error.NotTrueType;
        const num_tables = try r.u16At(4);

        var head: u32 = 0;
        var maxp: u32 = 0;
        var hhea: u32 = 0;
        var hmtx: u32 = 0;
        var loca: u32 = 0;
        var glyf: u32 = 0;
        var cmap: u32 = 0;
        var entry: usize = 12;
        var i: u16 = 0;
        while (i < num_tables) : (i += 1) {
            if (entry + 16 > data.len) return Error.Malformed;
            const tag = data[entry .. entry + 4];
            const off = try r.u32At(entry + 8);
            if (std.mem.eql(u8, tag, "head")) head = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea = off;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = off;
            if (std.mem.eql(u8, tag, "loca")) loca = off;
            if (std.mem.eql(u8, tag, "glyf")) glyf = off;
            if (std.mem.eql(u8, tag, "cmap")) cmap = off;
            entry += 16;
        }
        if (head == 0 or maxp == 0 or hhea == 0 or hmtx == 0 or loca == 0 or glyf == 0 or cmap == 0) {
            return Error.MissingTable;
        }

        const units_per_em = try r.u16At(head + 18);
        const loca_long = (try r.i16At(head + 50)) != 0;
        const num_glyphs = try r.u16At(maxp + 4);
        const ascent = try r.i16At(hhea + 4);
        const descent = try r.i16At(hhea + 6);
        const line_gap = try r.i16At(hhea + 8);
        const num_h_metrics = try r.u16At(hhea + 34);
        const cmap_sub = try findCmap(r, cmap);

        return .{
            .data = data,
            .units_per_em = units_per_em,
            .ascent = ascent,
            .descent = descent,
            .line_gap = line_gap,
            .num_glyphs = num_glyphs,
            .num_h_metrics = num_h_metrics,
            .loca_long = loca_long,
            .loca = loca,
            .glyf = glyf,
            .hmtx = hmtx,
            .cmap_sub = cmap_sub,
        };
    }

    /// Finds a usable Unicode BMP subtable (format 4) and returns its offset.
    fn findCmap(r: Reader, cmap: u32) Error!u32 {
        const count = try r.u16At(cmap + 2);
        var best: u32 = 0;
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const rec = cmap + 4 + @as(u32, i) * 8;
            const platform = try r.u16At(rec);
            const encoding = try r.u16At(rec + 2);
            const sub = cmap + try r.u32At(rec + 4);
            const unicode = (platform == 0) or (platform == 3 and (encoding == 1 or encoding == 10));
            if (unicode and (try r.u16At(sub)) == 4) best = sub;
        }
        if (best == 0) return Error.UnsupportedCmap;
        return best;
    }

    /// The glyph index for a codepoint, or 0 (the missing glyph) if unmapped.
    pub fn glyphIndex(face: Face, codepoint: u21) u16 {
        return face.glyphIndexChecked(codepoint) catch 0;
    }

    fn glyphIndexChecked(face: Face, codepoint: u21) Error!u16 {
        if (codepoint > 0xffff) return 0;
        const cp: u16 = @intCast(codepoint);
        const r = face.reader();
        const sub = face.cmap_sub;
        const seg_x2 = try r.u16At(sub + 6);
        const segs = seg_x2 / 2;
        const ends = sub + 14;
        const starts = ends + seg_x2 + 2;
        const deltas = starts + seg_x2;
        const ranges = deltas + seg_x2;
        var i: u32 = 0;
        while (i < segs) : (i += 1) {
            const end = try r.u16At(ends + i * 2);
            if (cp > end) continue;
            const start = try r.u16At(starts + i * 2);
            if (cp < start) return 0;
            const delta = try r.u16At(deltas + i * 2);
            const range_off = try r.u16At(ranges + i * 2);
            if (range_off == 0) return cp +% delta;
            const gi_addr = ranges + i * 2 + range_off + (cp - start) * 2;
            const gi = try r.u16At(gi_addr);
            if (gi == 0) return 0;
            return gi +% delta;
        }
        return 0;
    }

    /// The advance width of a glyph in font units.
    pub fn advance(face: Face, glyph: u16) u16 {
        const r = face.reader();
        const index = if (glyph < face.num_h_metrics) glyph else face.num_h_metrics - 1;
        return r.u16At(face.hmtx + @as(u32, index) * 4) catch 0;
    }

    fn glyphRange(face: Face, glyph: u16) Error!?[2]u32 {
        if (glyph >= face.num_glyphs) return null;
        const r = face.reader();
        if (face.loca_long) {
            const a = try r.u32At(face.loca + @as(u32, glyph) * 4);
            const b = try r.u32At(face.loca + @as(u32, glyph) * 4 + 4);
            if (b <= a) return null; // empty glyph (e.g. space)
            return .{ face.glyf + a, face.glyf + b };
        } else {
            const a = @as(u32, try r.u16At(face.loca + @as(u32, glyph) * 2)) * 2;
            const b = @as(u32, try r.u16At(face.loca + @as(u32, glyph) * 2 + 2)) * 2;
            if (b <= a) return null;
            return .{ face.glyf + a, face.glyf + b };
        }
    }
};

/// A 2x3 affine transform in font units: point' = (a·x + c·y + e, b·x + d·y + f).
/// Composite glyphs place a component under one of these; the base case is identity.
const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    fn apply(t: Affine, x: f32, y: f32) [2]f32 {
        return .{ t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f };
    }

    /// The transform that applies `child` first, then `parent`.
    fn compose(parent: Affine, child: Affine) Affine {
        return .{
            .a = parent.a * child.a + parent.c * child.b,
            .b = parent.b * child.a + parent.d * child.b,
            .c = parent.a * child.c + parent.c * child.d,
            .d = parent.b * child.c + parent.d * child.d,
            .e = parent.a * child.e + parent.c * child.f + parent.e,
            .f = parent.b * child.e + parent.d * child.f + parent.f,
        };
    }
};

/// A point on a contour in font units. `on` marks an on-curve point; off-curve points
/// are quadratic control points.
const OutlinePoint = struct { x: f32, y: f32, on: bool };

/// A line segment of a flattened outline, in font units. Filling uses these directly.
const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// Collects a glyph's outline as flattened edges in font units, following composite
/// components up to a small depth. Appends nothing for an empty glyph.
fn collectEdges(
    face: Face,
    glyph: u16,
    transform: Affine,
    depth: u8,
    edges: *std.ArrayList(Edge),
    gpa: std.mem.Allocator,
) Error!void {
    if (depth > 5) return;
    const range = (try face.glyphRange(glyph)) orelse return;
    const r = face.reader();
    var off = range[0];
    const num_contours = try r.i16At(off);
    off += 10; // skip bounding box

    if (num_contours < 0) {
        try collectComposite(face, off, transform, depth, edges, gpa);
        return;
    }

    const contours: usize = @intCast(num_contours);
    var end_pts = try gpa.alloc(u16, contours);
    defer gpa.free(end_pts);
    for (0..contours) |i| {
        end_pts[i] = try r.u16At(off);
        off += 2;
    }
    const num_points: usize = if (contours == 0) 0 else @as(usize, end_pts[contours - 1]) + 1;
    const instr_len = try r.u16At(off);
    off += 2 + instr_len;

    // Flags (with repeat), then x then y coordinates (delta-encoded).
    var flags = try gpa.alloc(u8, num_points);
    defer gpa.free(flags);
    {
        var i: usize = 0;
        while (i < num_points) {
            const f = try r.u8At(off);
            off += 1;
            flags[i] = f;
            i += 1;
            if (f & 0x08 != 0) { // repeat
                var rep = try r.u8At(off);
                off += 1;
                while (rep > 0 and i < num_points) : (rep -= 1) {
                    flags[i] = f;
                    i += 1;
                }
            }
        }
    }

    var xs = try gpa.alloc(f32, num_points);
    defer gpa.free(xs);
    var ys = try gpa.alloc(f32, num_points);
    defer gpa.free(ys);
    {
        var x: i32 = 0;
        for (0..num_points) |i| {
            const f = flags[i];
            if (f & 0x02 != 0) { // short x
                const dx: i32 = try r.u8At(off);
                off += 1;
                x += if (f & 0x10 != 0) dx else -dx;
            } else if (f & 0x10 == 0) { // long x
                x += try r.i16At(off);
                off += 2;
            }
            xs[i] = @floatFromInt(x);
        }
        var y: i32 = 0;
        for (0..num_points) |i| {
            const f = flags[i];
            if (f & 0x04 != 0) { // short y
                const dy: i32 = try r.u8At(off);
                off += 1;
                y += if (f & 0x20 != 0) dy else -dy;
            } else if (f & 0x20 == 0) { // long y
                y += try r.i16At(off);
                off += 2;
            }
            ys[i] = @floatFromInt(y);
        }
    }

    // Walk each contour, turning quadratic segments into line segments.
    var start: usize = 0;
    for (0..contours) |ci| {
        const end: usize = end_pts[ci];
        if (end < start) {
            start = end + 1;
            continue;
        }
        try emitContour(xs, ys, flags, start, end, transform, edges, gpa);
        start = end + 1;
    }
}

fn emitContour(
    xs: []const f32,
    ys: []const f32,
    flags: []const u8,
    start: usize,
    end: usize,
    transform: Affine,
    edges: *std.ArrayList(Edge),
    gpa: std.mem.Allocator,
) Error!void {
    const count = end - start + 1;
    if (count < 2) return;

    var pts: std.ArrayList(OutlinePoint) = .empty;
    defer pts.deinit(gpa);
    for (0..count) |k| {
        const idx = start + k;
        const p = transform.apply(xs[idx], ys[idx]);
        try pts.append(gpa, .{ .x = p[0], .y = p[1], .on = (flags[idx] & 0x01) != 0 });
    }

    // Reorder so the sequence begins on-curve, synthesizing a start midpoint if the
    // whole contour is off-curve, then repeat the start at the end to close the ring.
    var seq: std.ArrayList(OutlinePoint) = .empty;
    defer seq.deinit(gpa);
    var s0: usize = 0;
    var found_on = false;
    for (0..count) |k| {
        if (pts.items[k].on) {
            s0 = k;
            found_on = true;
            break;
        }
    }
    if (found_on) {
        for (0..count) |k| try seq.append(gpa, pts.items[(s0 + k) % count]);
    } else {
        try seq.append(gpa, .{
            .x = (pts.items[0].x + pts.items[1].x) * 0.5,
            .y = (pts.items[0].y + pts.items[1].y) * 0.5,
            .on = true,
        });
        for (0..count) |k| try seq.append(gpa, pts.items[k]);
    }
    try seq.append(gpa, seq.items[0]); // close the ring on-curve

    var ring: std.ArrayList([2]f32) = .empty;
    defer ring.deinit(gpa);
    try ring.append(gpa, .{ seq.items[0].x, seq.items[0].y });
    var cur: [2]f32 = .{ seq.items[0].x, seq.items[0].y };

    var i: usize = 1;
    while (i < seq.items.len) {
        const p = seq.items[i];
        if (p.on) {
            try ring.append(gpa, .{ p.x, p.y });
            cur = .{ p.x, p.y };
            i += 1;
        } else {
            const nxt = seq.items[i + 1]; // the closing on-curve point guarantees this exists
            if (nxt.on) {
                try flattenQuadratic(cur, .{ p.x, p.y }, .{ nxt.x, nxt.y }, &ring, gpa);
                cur = .{ nxt.x, nxt.y };
                i += 2;
            } else {
                const mid: [2]f32 = .{ (p.x + nxt.x) * 0.5, (p.y + nxt.y) * 0.5 };
                try flattenQuadratic(cur, .{ p.x, p.y }, mid, &ring, gpa);
                cur = mid;
                i += 1;
            }
        }
    }

    const rv = ring.items;
    if (rv.len < 2) return;
    for (0..rv.len) |ei| {
        const a = rv[ei];
        const b = rv[(ei + 1) % rv.len];
        try edges.append(gpa, .{ .x0 = a[0], .y0 = a[1], .x1 = b[0], .y1 = b[1] });
    }
}

fn flattenQuadratic(p0: [2]f32, p1: [2]f32, p2: [2]f32, ring: *std.ArrayList([2]f32), gpa: std.mem.Allocator) !void {
    const steps: usize = 8;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const mt = 1.0 - t;
        const x = mt * mt * p0[0] + 2.0 * mt * t * p1[0] + t * t * p2[0];
        const y = mt * mt * p0[1] + 2.0 * mt * t * p1[1] + t * t * p2[1];
        try ring.append(gpa, .{ x, y });
    }
}

fn f2dot14(r: Reader, off: usize) Error!f32 {
    return @as(f32, @floatFromInt(try r.i16At(off))) / 16384.0;
}

fn collectComposite(
    face: Face,
    start_off: u32,
    transform: Affine,
    depth: u8,
    edges: *std.ArrayList(Edge),
    gpa: std.mem.Allocator,
) Error!void {
    const r = face.reader();
    var off = start_off;
    while (true) {
        const flags = try r.u16At(off);
        const component = try r.u16At(off + 2);
        off += 4;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
            dx = @floatFromInt(try r.i16At(off));
            dy = @floatFromInt(try r.i16At(off + 2));
            off += 4;
        } else {
            dx = @floatFromInt(@as(i8, @bitCast(try r.u8At(off))));
            dy = @floatFromInt(@as(i8, @bitCast(try r.u8At(off + 1))));
            off += 2;
        }
        // The component's 2x2 linear part. A glyph like "9" is another glyph placed
        // under a rotation or reflection; ignoring the matrix drops it in the wrong
        // place at the wrong orientation, which is exactly what a translate-only reader
        // does wrong.
        var component_transform: Affine = .{ .e = dx, .f = dy };
        if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
            const scale = try f2dot14(r, off);
            component_transform.a = scale;
            component_transform.d = scale;
            off += 2;
        } else if (flags & 0x0040 != 0) { // X_AND_Y_SCALE
            component_transform.a = try f2dot14(r, off);
            component_transform.d = try f2dot14(r, off + 2);
            off += 4;
        } else if (flags & 0x0080 != 0) { // 2x2
            component_transform.a = try f2dot14(r, off);
            component_transform.b = try f2dot14(r, off + 2);
            component_transform.c = try f2dot14(r, off + 4);
            component_transform.d = try f2dot14(r, off + 6);
            off += 8;
        }
        try collectEdges(face, component, transform.compose(component_transform), depth + 1, edges, gpa);
        if (flags & 0x0020 == 0) break; // no MORE_COMPONENTS
    }
}

/// A rasterized glyph: an 8-bit coverage bitmap and where it sits relative to the pen.
/// `left` and `top` are the offset in pixels from the pen origin (baseline) to the
/// bitmap's top-left; y grows downward.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    left: i32,
    top: i32,
    coverage: []u8,

    pub fn deinit(bitmap: *Bitmap, gpa: std.mem.Allocator) void {
        gpa.free(bitmap.coverage);
        bitmap.* = undefined;
    }
};

/// Rasterizes a glyph at `pixel_size` (the em size in pixels) into a coverage bitmap.
/// Returns a zero-size bitmap for an empty glyph (a space).
pub fn rasterize(face: Face, glyph: u16, pixel_size: f32, gpa: std.mem.Allocator) Error!Bitmap {
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try collectEdges(face, glyph, .{}, 0, &edges, gpa);

    const scale = pixel_size / @as(f32, @floatFromInt(face.units_per_em));
    if (edges.items.len == 0) {
        return .{ .width = 0, .height = 0, .left = 0, .top = 0, .coverage = try gpa.alloc(u8, 0) };
    }

    // Bounds in pixel space (y flipped: font y grows up, bitmap y grows down).
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    for (edges.items) |*e| {
        e.x0 *= scale;
        e.x1 *= scale;
        e.y0 *= -scale;
        e.y1 *= -scale;
        min_x = @min(min_x, @min(e.x0, e.x1));
        max_x = @max(max_x, @max(e.x0, e.x1));
        min_y = @min(min_y, @min(e.y0, e.y1));
        max_y = @max(max_y, @max(e.y0, e.y1));
    }

    const pad: f32 = 1.0;
    const left_i: i32 = @intFromFloat(@floor(min_x - pad));
    const top_i: i32 = @intFromFloat(@floor(min_y - pad));
    const right_i: i32 = @intFromFloat(@ceil(max_x + pad));
    const bottom_i: i32 = @intFromFloat(@ceil(max_y + pad));
    const w: u32 = @intCast(@max(1, right_i - left_i));
    const h: u32 = @intCast(@max(1, bottom_i - top_i));

    const coverage = try gpa.alloc(u8, w * h);
    @memset(coverage, 0);

    // Translate edges so the bitmap origin is (0,0).
    const ofx: f32 = @floatFromInt(left_i);
    const ofy: f32 = @floatFromInt(top_i);
    for (edges.items) |*e| {
        e.x0 -= ofx;
        e.x1 -= ofx;
        e.y0 -= ofy;
        e.y1 -= ofy;
    }

    try fillEdges(edges.items, coverage, w, h, gpa);

    return .{ .width = w, .height = h, .left = left_i, .top = top_i, .coverage = coverage };
}

/// A crossing of a sub-scanline: the x it crosses at and the winding direction.
const Crossing = struct { x: f32, dir: i2 };

/// Scanline fill under the nonzero-winding rule, with vertical supersampling and
/// fractional horizontal coverage, writing 0..255 into `coverage`.
fn fillEdges(edges: []const Edge, coverage: []u8, w: u32, h: u32, gpa: std.mem.Allocator) Error!void {
    const subsamples: u32 = 5;
    const sub_weight: f32 = 1.0 / @as(f32, @floatFromInt(subsamples));

    const accum = try gpa.alloc(f32, w);
    defer gpa.free(accum);
    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(gpa);

    var py: u32 = 0;
    while (py < h) : (py += 1) {
        @memset(accum, 0);
        var s: u32 = 0;
        while (s < subsamples) : (s += 1) {
            const y = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(s)) + 0.5) * sub_weight;
            crossings.clearRetainingCapacity();
            for (edges) |e| {
                const y0 = e.y0;
                const y1 = e.y1;
                if ((y0 <= y and y1 > y) or (y1 <= y and y0 > y)) {
                    const t = (y - y0) / (y1 - y0);
                    const x = e.x0 + t * (e.x1 - e.x0);
                    try crossings.append(gpa, .{ .x = x, .dir = if (y1 > y0) @as(i2, 1) else @as(i2, -1) });
                }
            }
            if (crossings.items.len < 2) continue;
            std.mem.sort(Crossing, crossings.items, {}, lessByX);

            var winding: i32 = 0;
            var i: usize = 0;
            while (i + 1 < crossings.items.len) : (i += 1) {
                winding += @as(i32, crossings.items[i].dir);
                if (winding == 0) continue;
                const xa = @max(0.0, crossings.items[i].x);
                const xb = @min(@as(f32, @floatFromInt(w)), crossings.items[i + 1].x);
                if (xb <= xa) continue;
                addSpan(accum, xa, xb, sub_weight);
            }
        }
        for (0..w) |x| {
            const c = std.math.clamp(accum[x], 0.0, 1.0);
            coverage[py * w + x] = @intFromFloat(@round(c * 255.0));
        }
    }
}

fn lessByX(_: void, a: Crossing, b: Crossing) bool {
    return a.x < b.x;
}

/// Adds `weight` of coverage across [xa, xb) to the pixel accumulator, with fractional
/// coverage at the two ends.
fn addSpan(accum: []f32, xa: f32, xb: f32, weight: f32) void {
    const first: usize = @intFromFloat(@floor(xa));
    const last: usize = @intFromFloat(@ceil(xb));
    var px = first;
    while (px < last and px < accum.len) : (px += 1) {
        const cell_l = @as(f32, @floatFromInt(px));
        const cell_r = cell_l + 1.0;
        const covered = @min(xb, cell_r) - @max(xa, cell_l);
        if (covered > 0) accum[px] += covered * weight;
    }
}

// --- Tests ---

const testing = std.testing;
const design = @import("design");

test "the rasterizer fills a covered interior for a real glyph" {
    const font = design.fonts.sora_semibold;
    const face = try Face.parse(font);
    try testing.expect(face.units_per_em == 1000);

    const glyph = face.glyphIndex('a');
    try testing.expect(glyph != 0);
    try testing.expect(face.advance(glyph) > 0);

    var bitmap = try rasterize(face, glyph, 64.0, testing.allocator);
    defer bitmap.deinit(testing.allocator);
    try testing.expect(bitmap.width > 0 and bitmap.height > 0);

    // Some pixel is fully or nearly covered: the glyph has a filled interior.
    var max_cov: u8 = 0;
    for (bitmap.coverage) |c| max_cov = @max(max_cov, c);
    try testing.expect(max_cov > 200);
}

test "a composite glyph is placed by its transform, aligned with a simple one" {
    // '9' in Sora is a composite glyph — another glyph under a transform. A reader that
    // ignored the transform placed it far above the em; it must land on the same line as
    // a simple digit like '4'.
    const face = try Face.parse(design.fonts.sora_regular);
    const nine = face.glyphIndex('9');
    const four = face.glyphIndex('4');

    var b9 = try rasterize(face, nine, 30.0, testing.allocator);
    defer b9.deinit(testing.allocator);
    var b4 = try rasterize(face, four, 30.0, testing.allocator);
    defer b4.deinit(testing.allocator);

    // Both cap-height digits: their tops sit within a few pixels of each other, and well
    // inside the em (never dozens of pixels above the baseline).
    try testing.expect(b9.top < 0 and b9.top > -34);
    try testing.expect(@abs(b9.top - b4.top) <= 3);
    try testing.expect(@abs(b9.left) <= 3);
}

test "an unmapped codepoint is the missing glyph and a space has no outline" {
    const font = design.fonts.sora_regular;
    const face = try Face.parse(font);
    try testing.expectEqual(@as(u16, 0), face.glyphIndex(0x2603)); // snowman: not in the latin subset

    const space = face.glyphIndex(' ');
    var bitmap = try rasterize(face, space, 32.0, testing.allocator);
    defer bitmap.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), bitmap.width * bitmap.height);
    try testing.expect(face.advance(space) > 0); // a space still advances
}
