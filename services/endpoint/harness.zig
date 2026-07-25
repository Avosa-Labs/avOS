//! Shared scaffolding for exercising a service front end in tests: a trusted
//! signer, a permissive capability resolver, and a live endpoint, so each service's
//! own tests state only what is specific to that service.
//!
//! Every service front end is verified the same way — a signed request goes in, a
//! typed reply comes out — and standing that up means the same verifier, resolver,
//! routing table, and endpoint every time. Repeating it in every service's test
//! block buries the one thing each test is actually about. This gathers the common
//! setup behind a small fixture a service configures with its own handlers, routes,
//! and method prefix, and drives with `call` (the full authenticated wire path) or
//! `redrive` (a direct dispatch, standing in for a recovery re-drive that bypasses
//! the wire's replay guard).
//!
//! This is test scaffolding, not part of any service's runtime surface; it holds no
//! authority of its own and its permissive resolver exists only so a test can reach
//! the handler under test.

const std = @import("std");
const ipc = @import("ipc");
const endpoint = @import("endpoint.zig");
const dispatch = @import("dispatch.zig");

/// The single principal every fixture caller acts as. A test that needs a second
/// principal passes it explicitly.
pub const caller: u128 = 0xCA11;

/// A resolver that grants the caller a capability scoped to one method prefix, so
/// the binding check passes for that service's methods and no others.
pub const PrefixGrant = struct {
    prefix: []const u8,
    scopes: [1]ipc.capability_binding.Scope,

    pub fn init(prefix: []const u8) PrefixGrant {
        return .{ .prefix = prefix, .scopes = .{.{ .pattern = prefix, .prefix = true }} };
    }

    fn lookup(context: *anyopaque, capability: u128) ?ipc.capability_binding.Grant {
        _ = capability;
        const self: *PrefixGrant = @ptrCast(@alignCast(context));
        return .{ .bound_principal = caller, .scopes = &self.scopes };
    }

    pub fn resolver(self: *PrefixGrant) ipc.pipeline.Resolver {
        return .{ .context = self, .lookup = lookup };
    }
};

/// A configured service under test: a trusted verifier, a permissive resolver, and
/// the endpoint wrapping the service's handlers.
pub const Fixture = struct {
    gpa: std.mem.Allocator,
    verifier: ipc.authenticator.Verifier,
    grant: PrefixGrant,
    signer: ipc.authenticator.SigningIdentity,
    ep: endpoint.Endpoint,

    pub const Config = struct {
        service_id: ipc.routing.ServiceId,
        routes: ipc.routing.Table,
        handlers: []const dispatch.Handler,
        prefix: []const u8,
        /// The identity the fixture signs requests with. The caller builds it in its
        /// own test block, so the deterministic key generation stays test-only.
        signer: ipc.authenticator.SigningIdentity,
        capacity_units: u64 = 100_000,
    };

    pub fn init(gpa: std.mem.Allocator, fixture: *Fixture, config: Config) !void {
        fixture.gpa = gpa;
        fixture.signer = config.signer;
        fixture.verifier = ipc.authenticator.Verifier.init(gpa);
        try fixture.verifier.trust(caller, fixture.signer.publicKey());
        fixture.grant = PrefixGrant.init(config.prefix);
        fixture.ep = try endpoint.Endpoint.init(gpa, &fixture.verifier, fixture.grant.resolver(), .{
            .service_id = config.service_id,
            .routes = config.routes,
            .handlers = config.handlers,
            .capacity_units = config.capacity_units,
        });
    }

    pub fn deinit(fixture: *Fixture) void {
        fixture.ep.deinit();
        fixture.verifier.deinit();
    }

    fn envelope(method: []const u8, correlation: u64, key: u128, body: []const u8) endpoint.Envelope {
        return .{
            .version = .{ .major = 1, .minor = 0 },
            .kind = .request,
            .correlation = correlation,
            .idempotency_key = key,
            .principal = caller,
            .task = 0,
            .capability = 0x1,
            .deadline_nanoseconds = 0,
            .method = method,
            .fault = null,
            .payload = body,
        };
    }

    /// Sends a signed request through the whole authenticated path.
    pub fn call(fixture: *Fixture, method: []const u8, correlation: u64, key: u128, body: []const u8) !dispatch.Reply {
        const message = envelope(method, correlation, key, body);
        const bytes = try fixture.gpa.alloc(u8, message.encodedSize());
        defer fixture.gpa.free(bytes);
        _ = try ipc.envelope.encode(message, bytes);
        const signed = try ipc.authenticator.sign(fixture.signer, bytes);
        return fixture.ep.serve(signed, .system, 0);
    }

    /// Dispatches directly, standing in for a recovery re-drive where the same
    /// idempotency key legitimately arrives again after a restart.
    pub fn redrive(fixture: *Fixture, method: []const u8, correlation: u64, key: u128, body: []const u8) dispatch.Reply {
        return fixture.ep.dispatch(envelope(method, correlation, key, body), .system, 0);
    }
};
