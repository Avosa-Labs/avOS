//! Deciding which element a switch press selects during scanning, so a person who operates
//! the device with a single switch can reach any control by waiting for it and pressing.
//!
//! Switch control is how someone who can make only one deliberate movement — a button, a
//! puff of breath, a blink — operates a whole interface. The interface scans: a highlight
//! moves from one element to the next on a timer, and when it rests on the element the
//! person wants, they press the switch to select it. The correctness of the whole method
//! comes down to two things being exact. A press must select precisely the element the
//! highlight is on at that moment — not the one before or after — because a person who has
//! waited through the scan to reach their target must get that target, not a neighbour. And
//! the scan must be a bounded cycle: it advances through the elements in order and wraps
//! back to the first after the last, so every element is reachable and none is skipped,
//! and a person who misses their target can simply wait for it to come around again. Exact
//! selection and a complete cycle are what make a single switch enough to control
//! everything.
//!
//! This module scans nothing. It decides which element a press selects at a scan position
//! and where the scan advances next, as pure functions over the position and the element
//! count.

const std = @import("std");

/// The element a switch press selects at a given scan position.
///
/// The press selects exactly the element the highlight is on — the element at the scan
/// position — so a person who waited for their target gets that target. A position past the
/// element count selects nothing (there is no such element), which the caller treats as a
/// no-op rather than an out-of-range selection.
pub fn selectAt(scan_position: usize, element_count: usize) ?usize {
    if (scan_position >= element_count) return null;
    return scan_position;
}

/// The next scan position after the current one, wrapping to the first element after the
/// last so the cycle is complete.
///
/// The scan advances by one and wraps back to zero at the end, so every element is visited
/// in turn and a person who misses their target can wait for it to come around again. With
/// no elements the scan stays at zero.
pub fn advance(scan_position: usize, element_count: usize) usize {
    if (element_count == 0) return 0;
    const next = scan_position + 1;
    return if (next >= element_count) 0 else next;
}

test "a press selects the element at the scan position" {
    try std.testing.expectEqual(@as(?usize, 0), selectAt(0, 5));
    try std.testing.expectEqual(@as(?usize, 3), selectAt(3, 5));
}

test "a press at the last element selects it" {
    try std.testing.expectEqual(@as(?usize, 4), selectAt(4, 5));
}

test "a position past the elements selects nothing" {
    try std.testing.expectEqual(@as(?usize, null), selectAt(5, 5));
}

test "the scan advances one at a time" {
    try std.testing.expectEqual(@as(usize, 1), advance(0, 5));
    try std.testing.expectEqual(@as(usize, 4), advance(3, 5));
}

test "the scan wraps to the first element after the last" {
    try std.testing.expectEqual(@as(usize, 0), advance(4, 5));
}

test "an empty element set stays at zero" {
    try std.testing.expectEqual(@as(usize, 0), advance(0, 0));
    try std.testing.expectEqual(@as(?usize, null), selectAt(0, 0));
}

test "a press always selects exactly the highlighted element, swept" {
    // The exact-selection property: for every in-range position, the selection is that
    // position, never a neighbour.
    const count: usize = 6;
    var pos: usize = 0;
    while (pos < count) : (pos += 1) {
        try std.testing.expectEqual(@as(?usize, pos), selectAt(pos, count));
    }
}

test "scanning visits every element in a complete cycle, swept" {
    // The complete-cycle property: advancing from 0 visits all elements and returns to 0.
    const count: usize = 5;
    var visited = [_]bool{false} ** count;
    var pos: usize = 0;
    for (0..count) |_| {
        visited[pos] = true;
        pos = advance(pos, count);
    }
    for (visited) |v| try std.testing.expect(v);
    try std.testing.expectEqual(@as(usize, 0), pos); // wrapped back to the start
}
