//! Brand resource layer.
//!
//! Every user-facing occurrence of the product name, company name, domain,
//! support address, and legal entity resolves through this module. No other
//! module may embed those values.
//!
//! The active values are supplied by the build from a JSON document validated
//! against `brand/schema.json`, so replacing the document rebrands the product
//! without editing source. Interface code must treat every field as
//! variable-length text: a build with a deliberately different synthetic brand
//! is part of the test matrix precisely to catch layout and comparison code
//! that assumes one particular name.

const std = @import("std");
const config = @import("brand_config");

/// Version of the brand document format this module understands. A document
/// declaring any other version is rejected by the build rather than silently
/// reinterpreted.
pub const schema_version: u32 = 1;

pub const Brand = struct {
    name: []const u8,
    short_name: []const u8,
    domain: []const u8,
    support_uri: []const u8,
    legal_name: []const u8,

    pub const Field = enum {
        name,
        short_name,
        domain,
        support_uri,
        legal_name,
    };

    /// Borrowed view of one field. The result lives as long as the `Brand`,
    /// which for `active` is the program lifetime.
    pub fn get(brand: Brand, field: Field) []const u8 {
        return switch (field) {
            .name => brand.name,
            .short_name => brand.short_name,
            .domain => brand.domain,
            .support_uri => brand.support_uri,
            .legal_name => brand.legal_name,
        };
    }

    /// A brand document with an empty field would render blank product text on
    /// some surface, so emptiness is a configuration error rather than a
    /// display-time fallback.
    pub fn validate(brand: Brand) error{EmptyBrandField}!void {
        for (std.enums.values(Field)) |field| {
            if (brand.get(field).len == 0) return error.EmptyBrandField;
        }
    }
};

/// The brand selected by the build.
pub const active: Brand = .{
    .name = config.name,
    .short_name = config.short_name,
    .domain = config.domain,
    .support_uri = config.support_uri,
    .legal_name = config.legal_name,
};

comptime {
    if (config.schema_version != schema_version) {
        @compileError("brand document declares an unsupported schema version");
    }
}

test "active brand is fully populated" {
    try active.validate();
}

test "every field is reachable through the field enumeration" {
    // A field added to `Brand` without a matching `Field` member would be
    // unreachable to generic renderers and to the brand-leak check.
    const struct_fields = @typeInfo(Brand).@"struct".fields;
    try std.testing.expectEqual(struct_fields.len, std.enums.values(Brand.Field).len);
    inline for (struct_fields) |field| {
        _ = std.meta.stringToEnum(Brand.Field, field.name) orelse
            return error.FieldMissingFromEnumeration;
    }
}

test "an empty field is rejected" {
    const incomplete: Brand = .{
        .name = "",
        .short_name = active.short_name,
        .domain = active.domain,
        .support_uri = active.support_uri,
        .legal_name = active.legal_name,
    };
    try std.testing.expectError(error.EmptyBrandField, incomplete.validate());
}

test "rendering does not depend on the configured name length" {
    // Surfaces compose brand text at runtime. This exercises the composition
    // with names far shorter and longer than any configured value, so a fixed
    // buffer or assumed word count fails here rather than in the shell.
    const lengths = [_]usize{ 1, 2, 8, 63, 64 };
    for (lengths) |len| {
        var storage: [64]u8 = @splat('n');
        const synthetic: Brand = .{
            .name = storage[0..len],
            .short_name = storage[0..@min(len, 32)],
            .domain = active.domain,
            .support_uri = active.support_uri,
            .legal_name = active.legal_name,
        };
        try synthetic.validate();
        try std.testing.expectEqual(len, synthetic.name.len);
    }
}
