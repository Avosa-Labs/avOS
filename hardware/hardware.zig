//! The device itself, behind interfaces.
//!
//! Each subsystem is an interface with at least two implementations: the real
//! one for a board, and one that stands in for it so the rest of the platform
//! can be exercised without hardware. A stand-in always says it is one, because
//! code tested against a guarantee it was not getting is code that has not been
//! tested.

pub const secure_element = @import("secure-element/secure_element.zig");
pub const thermal = @import("thermal/thermal.zig");

test {
    _ = secure_element;
    _ = thermal;
}
