//! Validating where an item may be placed on the home screen, so the grid stays within its
//! bounds and no two items land on the same cell.
//!
//! The home screen is a grid of pages, and arranging it is the most direct way a person
//! makes the device theirs. The rules that keep it coherent are simple and must be exact. An
//! item occupies a cell on a page, and that cell must exist — a placement off the edge of the
//! grid, or on a page that is not there, has nowhere to go and must be refused rather than
//! silently clamped to somewhere the person did not choose. And two items must not occupy the
//! same cell, because an item dropped onto an occupied cell either hides the one beneath or
//! displaces it unpredictably; a placement onto a taken cell is rejected so the person can put
//! it somewhere real. Widgets that span more than one cell must fit entirely on the page.
//! These are the invariants of a grid that never loses an icon or overlaps two, which is what
//! makes rearranging the home screen feel solid rather than fragile.
//!
//! This module draws no icons. It decides whether a placement is within the grid and
//! unoccupied, as pure functions over the grid geometry and the occupied cells.

const std = @import("std");

/// The home grid's geometry: pages of columns by rows.
pub const Grid = struct {
    pages: u32,
    columns: u32,
    rows: u32,
};

/// A placement of an item on the grid. An item may span more than one cell (a widget).
pub const Placement = struct {
    page: u32,
    column: u32,
    row: u32,
    /// How many columns and rows the item spans. One for an ordinary icon.
    span_columns: u32 = 1,
    span_rows: u32 = 1,
};

/// Why a placement was refused.
pub const Refusal = enum {
    /// The placement falls outside the grid — a missing page, or off the edge.
    out_of_bounds,
    /// The placement overlaps a cell another item already occupies.
    occupied,
};

/// Whether a placement lies wholly within the grid.
fn withinGrid(grid: Grid, placement: Placement) bool {
    if (placement.page >= grid.pages) return false;
    if (placement.span_columns == 0 or placement.span_rows == 0) return false;
    const right = @as(u64, placement.column) + placement.span_columns;
    const bottom = @as(u64, placement.row) + placement.span_rows;
    return right <= grid.columns and bottom <= grid.rows;
}

/// Whether two placements overlap: same page and intersecting cell ranges.
fn overlaps(a: Placement, b: Placement) bool {
    if (a.page != b.page) return false;
    const a_right = a.column + a.span_columns;
    const a_bottom = a.row + a.span_rows;
    const b_right = b.column + b.span_columns;
    const b_bottom = b.row + b.span_rows;
    return a.column < b_right and b.column < a_right and a.row < b_bottom and b.row < a_bottom;
}

/// The outcome of a placement.
pub const Decision = union(enum) {
    place,
    refuse: Refusal,

    pub fn placed(decision: Decision) bool {
        return decision == .place;
    }
};

/// Decides whether an item may be placed, given the grid and the already-occupied cells.
///
/// The placement must lie wholly within the grid — on an existing page and inside the column
/// and row bounds, spanning at least one cell — or it is refused as out of bounds rather than
/// clamped somewhere the person did not choose. It must also not overlap any occupied
/// placement, or it is refused as occupied, so no two items share a cell.
pub fn decide(grid: Grid, placement: Placement, occupied: []const Placement) Decision {
    if (!withinGrid(grid, placement)) return .{ .refuse = .out_of_bounds };
    for (occupied) |existing| {
        if (overlaps(placement, existing)) return .{ .refuse = .occupied };
    }
    return .place;
}

const sample_grid: Grid = .{ .pages = 3, .columns = 4, .rows = 6 };

fn at(page: u32, col: u32, row: u32) Placement {
    return .{ .page = page, .column = col, .row = row };
}

test "an in-bounds placement on an empty cell is placed" {
    try std.testing.expect(decide(sample_grid, at(0, 1, 1), &.{}).placed());
}

test "a placement off the grid edge is out of bounds" {
    try std.testing.expectEqual(Decision{ .refuse = .out_of_bounds }, decide(sample_grid, at(0, 4, 0), &.{}));
    try std.testing.expectEqual(Decision{ .refuse = .out_of_bounds }, decide(sample_grid, at(0, 0, 6), &.{}));
}

test "a placement on a missing page is out of bounds" {
    try std.testing.expectEqual(Decision{ .refuse = .out_of_bounds }, decide(sample_grid, at(3, 0, 0), &.{}));
}

test "a placement on an occupied cell is refused" {
    const occupied = [_]Placement{at(0, 1, 1)};
    try std.testing.expectEqual(Decision{ .refuse = .occupied }, decide(sample_grid, at(0, 1, 1), &occupied));
}

test "a placement on a different page does not conflict" {
    const occupied = [_]Placement{at(0, 1, 1)};
    try std.testing.expect(decide(sample_grid, at(1, 1, 1), &occupied).placed());
}

test "a widget must fit entirely on the page" {
    // A 2x2 widget at column 3 would run off the 4-wide grid.
    const widget: Placement = .{ .page = 0, .column = 3, .row = 0, .span_columns = 2, .span_rows = 2 };
    try std.testing.expectEqual(Decision{ .refuse = .out_of_bounds }, decide(sample_grid, widget, &.{}));
}

test "a widget overlapping an icon is refused" {
    const occupied = [_]Placement{at(0, 1, 1)};
    const widget: Placement = .{ .page = 0, .column = 0, .row = 0, .span_columns = 2, .span_rows = 2 };
    try std.testing.expectEqual(Decision{ .refuse = .occupied }, decide(sample_grid, widget, &occupied));
}

test "no placement ever lands off the grid or on a taken cell, swept" {
    // The grid-integrity property: an accepted placement is within bounds and overlaps
    // nothing occupied.
    const occupied = [_]Placement{ at(0, 0, 0), at(0, 2, 2) };
    var page: u32 = 0;
    while (page < sample_grid.pages + 1) : (page += 1) {
        var col: u32 = 0;
        while (col < sample_grid.columns + 1) : (col += 1) {
            var row: u32 = 0;
            while (row < sample_grid.rows + 1) : (row += 1) {
                const placement = at(page, col, row);
                if (decide(sample_grid, placement, &occupied).placed()) {
                    try std.testing.expect(withinGrid(sample_grid, placement));
                    for (occupied) |existing| try std.testing.expect(!overlaps(placement, existing));
                }
            }
        }
    }
}
