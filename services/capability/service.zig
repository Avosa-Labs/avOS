//! The capability service: the authenticated endpoint through which authority is
//! issued, delegated, and revoked, keeping a store of live capabilities behind a
//! typed IPC surface rather than in every caller's hands.
//!
//! A capability is authority a holder can exercise and pass on. Where the pure
//! `delegation` module decides whether one *may* be re-delegated, this service holds
//! the capabilities that exist, mints new ones, attenuates them down a delegation
//! chain, and revokes them — the state the decision is made against. It runs behind
//! the shared endpoint, so every request is authenticated, bound to a capability the
//! caller actually holds, metered, and journaled before it reaches a handler here.
//!
//! Holding a capability record that names a method is necessary but not sufficient when the caller is an
//! agent. Above the record gate sits the manifest gate: an authority-bearing call by a manifest-governed
//! agent must also clear the agent's accepted, endorsed manifest — deny-by-default for a capability the
//! manifest never named, and fail-closed once the agent's trust is revoked, its manifest expires, or its
//! endorsement stops verifying. The gate is a borrowed seam over the principal service's manifest store,
//! so this service reads authority without depending on that service or on any mind, and the decision is
//! the same whichever mind backs the agent. A principal with no manifest — a human root, a system caller
//! — is ungoverned and passes through to the record gate unchanged.
//!
//! Every mutation is keyed by the request's idempotency key and recorded once. That
//! is what makes a restart mid-transition safe: re-applying an issue or a revoke the
//! service has already seen returns the same result rather than minting a second
//! capability or double-counting a revocation, so the journal can re-drive an
//! in-doubt transition to completion without fear of doubling its effect.

const std = @import("std");
const core = @import("core");
const ipc = @import("ipc");
const endpoint = @import("../endpoint/endpoint.zig");
const dispatch = @import("../endpoint/dispatch.zig");
const journal_module = @import("../endpoint/journal.zig");
const payload = @import("../endpoint/payload.zig");
const delegation = @import("delegation.zig");

pub const CapabilityId = u128;
pub const Scope = delegation.Scope;
pub const Operation = delegation.Operation;

/// A capability the service holds.
pub const Record = struct {
    id: CapabilityId,
    holder: u128,
    scope: Scope,
    delegatable: bool,
    remaining_depth: u8,
    /// Bumped when the capability is revoked, so a stale handle fails the binding
    /// check's generation test at use.
    generation: u32 = 1,
    revoked: bool = false,
};

/// The result the service recorded for a mutation, so re-applying the same
/// idempotency key returns it rather than repeating the effect.
const Applied = struct {
    idempotency_key: u128,
    result_id: CapabilityId,
};

/// The capability store and the endpoint that fronts it.
pub const Service = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    next_id: CapabilityId = 1,
    reply_buffer: [64]u8 = undefined,
    /// The manifest enforcement seam, borrowed from the principal service's provisioner. Null until the
    /// control plane wires it, so the service defaults to the capability-record gate alone; once set, an
    /// authority-bearing call by a manifest-governed agent must additionally clear its accepted manifest.
    /// The provisioner owning the store outlives this service, like the endpoint's borrowed resolver.
    manifest_gate: ?core.trust.enforcement.Gate = null,

    pub fn init(gpa: std.mem.Allocator) Service {
        return .{ .gpa = gpa };
    }

    pub fn deinit(service: *Service) void {
        service.records.deinit(service.gpa);
        service.applied.deinit(service.gpa);
        service.* = undefined;
    }

    fn find(service: *Service, id: CapabilityId) ?*Record {
        for (service.records.items) |*record| {
            if (record.id == id) return record;
        }
        return null;
    }

    /// The result already recorded for an idempotency key, if the mutation keyed by
    /// it has been applied before. This is the idempotency the journal relies on.
    fn priorResult(service: *Service, key: u128) ?CapabilityId {
        for (service.applied.items) |entry| {
            if (entry.idempotency_key == key) return entry.result_id;
        }
        return null;
    }

    fn recordApplied(service: *Service, key: u128, result: CapabilityId) !void {
        try service.applied.append(service.gpa, .{ .idempotency_key = key, .result_id = result });
    }

    /// The manifest gate's verdict for one authority-bearing call, if the gate is wired. The capability
    /// the method requires must be present in the caller's accepted manifest; a governed agent that does
    /// not hold it — or whose trust has been revoked, whose manifest expired, or whose endorsement no
    /// longer verifies — is refused `unauthorized` before any record is minted. A principal with no
    /// manifest (a human root, a system caller) is ungoverned and passes to the record gate unchanged.
    /// The gate memoizes its Ed25519 verification per principal generation, so this is an O(1) index hit
    /// plus a deny-by-default class lookup, not a signature check per call. It holds no ruling of its own,
    /// so a revoke takes effect on the very next call.
    fn manifestRefusal(service: *Service, call: dispatch.Call, capability_name: []const u8) ?dispatch.Reply {
        const gate = service.manifest_gate orelse return null;
        return switch (gate.rule(call.envelope.principal, capability_name)) {
            .ungoverned, .granted => null,
            .denied => .{ .fault = .unauthorized },
        };
    }

    // --- Handlers ---

    fn issue(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;

        // Idempotent replay: an issue already applied returns the same capability. This precedes the
        // manifest gate so a recovery re-drive of a committed issue still completes even if the agent was
        // later narrowed or revoked — recovery correctness beats re-checking a done effect.
        if (service.priorResult(key)) |existing| return service.replyId(existing);
        if (service.manifestRefusal(call, "capability.issue")) |refusal| return refusal;

        var reader = payload.Reader.init(call.envelope.payload);
        const holder = reader.u128_() catch return .{ .fault = .invalid_input };
        const scope_bits = reader.u8_() catch return .{ .fault = .invalid_input };
        const delegatable = reader.boolean() catch return .{ .fault = .invalid_input };
        const depth = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const id = service.next_id;
        service.records.append(service.gpa, .{
            .id = id,
            .holder = holder,
            .scope = scopeFromBits(scope_bits),
            .delegatable = delegatable,
            .remaining_depth = depth,
        }) catch return .{ .fault = .unavailable };
        service.recordApplied(key, id) catch return .{ .fault = .unavailable };
        service.next_id += 1;
        return service.replyId(id);
    }

    fn delegate(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        if (service.priorResult(key)) |existing| return service.replyId(existing);
        if (service.manifestRefusal(call, "capability.delegate")) |refusal| return refusal;

        var reader = payload.Reader.init(call.envelope.payload);
        const parent_id = reader.u128_() catch return .{ .fault = .invalid_input };
        const child_bits = reader.u8_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const parent = service.find(parent_id) orelse return .{ .fault = .invalid_input };
        if (parent.revoked) return .{ .fault = .capability_revoked };

        const child_scope = scopeFromBits(child_bits);
        // The pure rule decides whether this delegation is permitted: delegatable,
        // depth remaining, and a strict attenuation of the parent's scope.
        switch (delegation.decide(.{
            .scope = parent.scope,
            .delegatable = parent.delegatable,
            .remaining_depth = parent.remaining_depth,
        }, child_scope)) {
            .refuse => |refusal| return .{ .fault = switch (refusal) {
                .not_delegatable, .depth_exhausted => .constraint_violation,
                .widens_scope => .unauthorized,
            } },
            .delegate => |child_depth| {
                const id = service.next_id;
                service.records.append(service.gpa, .{
                    .id = id,
                    .holder = call.envelope.principal,
                    .scope = child_scope,
                    .delegatable = true,
                    .remaining_depth = child_depth,
                }) catch return .{ .fault = .unavailable };
                service.recordApplied(key, id) catch return .{ .fault = .unavailable };
                service.next_id += 1;
                return service.replyId(id);
            },
        }
    }

    fn revoke(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        const key = call.envelope.idempotency_key;
        if (service.priorResult(key)) |existing| return service.replyId(existing);
        if (service.manifestRefusal(call, "capability.revoke")) |refusal| return refusal;

        var reader = payload.Reader.init(call.envelope.payload);
        const id = reader.u128_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const record = service.find(id) orelse return .{ .fault = .invalid_input };
        // Revoking is idempotent in its own right — a second revoke is a no-op — but
        // recording the key keeps recovery from re-running the generation bump.
        if (!record.revoked) {
            record.revoked = true;
            record.generation += 1;
        }
        service.recordApplied(key, id) catch return .{ .fault = .unavailable };
        return service.replyId(id);
    }

    fn describe(context: *anyopaque, call: dispatch.Call) dispatch.Reply {
        const service: *Service = @ptrCast(@alignCast(context));
        var reader = payload.Reader.init(call.envelope.payload);
        const id = reader.u128_() catch return .{ .fault = .invalid_input };
        if (!reader.atEnd()) return .{ .fault = .invalid_input };

        const record = service.find(id) orelse return .{ .fault = .invalid_input };
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU8(scopeToBits(record.scope)) catch return .{ .fault = .internal_fault };
        writer.putBool(record.revoked) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    fn replyId(service: *Service, id: CapabilityId) dispatch.Reply {
        var writer = payload.Writer.init(&service.reply_buffer);
        writer.putU128(id) catch return .{ .fault = .internal_fault };
        return .{ .ok = writer.written() };
    }

    /// The handler set, bound to this service instance.
    pub fn handlers(service: *Service) [4]dispatch.Handler {
        return .{
            .{ .method = "capability.issue", .required_capability = "capability.issue", .effect = .value_transfer, .cost_units = 4, .context = service, .serve = issue },
            .{ .method = "capability.delegate", .required_capability = "capability.delegate", .effect = .value_transfer, .cost_units = 4, .context = service, .serve = delegate },
            .{ .method = "capability.revoke", .required_capability = "capability.revoke", .effect = .local_mutation, .cost_units = 2, .context = service, .serve = revoke },
            .{ .method = "capability.describe", .required_capability = "capability.describe", .effect = .read_only, .cost_units = 1, .context = service, .serve = describe },
        };
    }
};

fn scopeFromBits(bits: u8) Scope {
    var scope: Scope = .initEmpty();
    inline for (@typeInfo(Operation).@"enum".fields, 0..) |field, index| {
        if (bits & (@as(u8, 1) << @intCast(index)) != 0) scope.insert(@enumFromInt(field.value));
    }
    return scope;
}

fn scopeToBits(scope: Scope) u8 {
    var bits: u8 = 0;
    inline for (@typeInfo(Operation).@"enum".fields, 0..) |field, index| {
        if (scope.contains(@enumFromInt(field.value))) bits |= (@as(u8, 1) << @intCast(index));
    }
    return bits;
}

/// The service id and routes the capability service owns.
pub const service_id: ipc.routing.ServiceId = 0x0CA9;

pub const routes = [_]ipc.routing.Route{
    .{ .method = "capability.issue", .service = service_id },
    .{ .method = "capability.delegate", .service = service_id },
    .{ .method = "capability.revoke", .service = service_id },
    .{ .method = "capability.describe", .service = service_id },
};

/// The capability descriptor clients and the router derive from.
pub const descriptor: ipc.descriptor.Descriptor = .{
    .service = "capability",
    .methods = &.{
        .{ .name = "capability.issue", .required_capability = "capability.issue", .effect = .value_transfer },
        .{ .name = "capability.delegate", .required_capability = "capability.delegate", .effect = .value_transfer },
        .{ .name = "capability.revoke", .required_capability = "capability.revoke", .effect = .local_mutation },
        .{ .name = "capability.describe", .required_capability = "capability.describe", .effect = .read_only },
    },
};

// The three views of this service — descriptor, routes, and handler set — are pinned
// to agree at build time, so a method that routes but has no handler, or a handler
// under a capability the descriptor never declared, fails to compile.
comptime {
    ipc.descriptor.validate(descriptor) catch unreachable;
}

// --- Tests ---

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

const admin: u128 = 0xAD41;
const cap_id_capability: u128 = 0x0C;

const Harness = struct {
    service: *Service,
    verifier: ipc.authenticator.Verifier,
    grant: GrantBox,
    ep: endpoint.Endpoint,
    signer: ipc.authenticator.SigningIdentity,
    handler_storage: [4]dispatch.Handler,

    const GrantBox = struct {
        scope: []const delegation.Operation = &.{},
        fn lookup(context: *anyopaque, capability: u128) ?ipc.capability_binding.Grant {
            _ = capability;
            const box: *GrantBox = @ptrCast(@alignCast(context));
            _ = box;
            return .{ .bound_principal = admin, .scopes = &.{.{ .pattern = "capability.", .prefix = true }} };
        }
        fn resolver(box: *GrantBox) ipc.pipeline.Resolver {
            return .{ .context = box, .lookup = lookup };
        }
    };

    fn init(gpa: std.mem.Allocator, service: *Service, harness: *Harness) !void {
        service.* = Service.init(gpa);
        harness.service = service;
        harness.signer = .{ .service = admin, .key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(3)) };
        harness.verifier = ipc.authenticator.Verifier.init(gpa);
        try harness.verifier.trust(admin, harness.signer.publicKey());
        harness.grant = .{};
        harness.handler_storage = service.handlers();
        harness.ep = try endpoint.Endpoint.init(gpa, &harness.verifier, harness.grant.resolver(), .{
            .service_id = service_id,
            .routes = .{ .routes = &routes },
            .handlers = &harness.handler_storage,
            .capacity_units = 10_000,
        });
    }

    fn deinit(harness: *Harness) void {
        harness.ep.deinit();
        harness.verifier.deinit();
        harness.service.deinit();
    }

    fn envelopeFor(method: []const u8, correlation: u64, key: u128, body: []const u8) endpoint.Envelope {
        return .{
            .version = .{ .major = 1, .minor = 0 },
            .kind = .request,
            .correlation = correlation,
            .idempotency_key = key,
            .principal = admin,
            .task = 0,
            .capability = cap_id_capability,
            .deadline_nanoseconds = 0,
            .method = method,
            .fault = null,
            .payload = body,
        };
    }

    fn call(harness: *Harness, gpa: std.mem.Allocator, method: []const u8, correlation: u64, key: u128, body: []const u8) !dispatch.Reply {
        const message = envelopeFor(method, correlation, key, body);
        const bytes = try gpa.alloc(u8, message.encodedSize());
        defer gpa.free(bytes);
        _ = try ipc.envelope.encode(message, bytes);
        const signed = try ipc.authenticator.sign(harness.signer, bytes);
        return harness.ep.serve(signed, .system, 0);
    }

    /// Dispatches directly, bypassing the wire's replay guard, to simulate a
    /// recovery re-drive after a restart — where the same idempotency key legitimately
    /// arrives again and the store's own idempotency must absorb it.
    fn redrive(harness: *Harness, method: []const u8, correlation: u64, key: u128, body: []const u8) dispatch.Reply {
        return harness.ep.dispatch(envelopeFor(method, correlation, key, body), .system, 0);
    }
};

fn issueBody(buffer: []u8, holder: u128, scope_bits: u8, delegatable: bool, depth: u8) []const u8 {
    var writer = payload.Writer.init(buffer);
    writer.putU128(holder) catch unreachable;
    writer.putU8(scope_bits) catch unreachable;
    writer.putBool(delegatable) catch unreachable;
    writer.putU8(depth) catch unreachable;
    return writer.written();
}

test "issuing a capability returns an id and records the capability" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    const reply = try harness.call(gpa, "capability.issue", 1, 0x100, issueBody(&buffer, admin, 0b0001, true, 3));
    try testing.expect(reply.succeeded());
    try testing.expectEqual(@as(usize, 1), service.records.items.len);
}

test "re-issuing with the same idempotency key returns the same id and mints nothing new" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    const body = issueBody(&buffer, admin, 0b0001, true, 3);
    const first = try harness.call(gpa, "capability.issue", 1, 0x100, body);
    var first_reader = payload.Reader.init(first.ok);
    const first_id = try first_reader.u128_();

    // A crash-and-recovery re-drives the same transition: the same idempotency key
    // arrives again on a fresh dispatch. The service must return the same id and not
    // create a second capability — the property recovery depends on.
    const second = harness.redrive("capability.issue", 2, 0x100, body);
    var second_reader = payload.Reader.init(second.ok);
    const second_id = try second_reader.u128_();

    try testing.expectEqual(first_id, second_id);
    try testing.expectEqual(@as(usize, 1), service.records.items.len);
}

test "a delegation attenuates and a widening one is refused" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    // Parent covers read+write (bits 0b0011), delegatable, depth 2.
    const issued = try harness.call(gpa, "capability.issue", 1, 0x100, issueBody(&buffer, admin, 0b0011, true, 2));
    var reader = payload.Reader.init(issued.ok);
    const parent_id = try reader.u128_();

    // Delegate read only (0b0001): a strict subset, permitted.
    var del_buffer: [32]u8 = undefined;
    var del_writer = payload.Writer.init(&del_buffer);
    try del_writer.putU128(parent_id);
    try del_writer.putU8(0b0001);
    const ok = try harness.call(gpa, "capability.delegate", 2, 0x200, del_writer.written());
    try testing.expect(ok.succeeded());

    // Delegate read+write+delete (0b0111): widens beyond the parent, refused.
    var wide_buffer: [32]u8 = undefined;
    var wide_writer = payload.Writer.init(&wide_buffer);
    try wide_writer.putU128(parent_id);
    try wide_writer.putU8(0b0111);
    const refused = try harness.call(gpa, "capability.delegate", 3, 0x300, wide_writer.written());
    try testing.expectEqual(endpoint.FaultCode.unauthorized, refused.fault);
}

test "revoking a capability bumps its generation and is idempotent" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    var buffer: [32]u8 = undefined;
    const issued = try harness.call(gpa, "capability.issue", 1, 0x100, issueBody(&buffer, admin, 0b0001, true, 1));
    var reader = payload.Reader.init(issued.ok);
    const id = try reader.u128_();

    var rev_buffer: [16]u8 = undefined;
    var rev_writer = payload.Writer.init(&rev_buffer);
    try rev_writer.putU128(id);
    _ = try harness.call(gpa, "capability.revoke", 2, 0x200, rev_writer.written());

    const record = service.find(id).?;
    try testing.expect(record.revoked);
    try testing.expectEqual(@as(u32, 2), record.generation);

    // A second revoke under a different key must not bump the generation again.
    rev_writer = payload.Writer.init(&rev_buffer);
    try rev_writer.putU128(id);
    _ = try harness.call(gpa, "capability.revoke", 3, 0x201, rev_writer.written());
    try testing.expectEqual(@as(u32, 2), service.find(id).?.generation);
}

test "the descriptor, routes, and handlers all agree" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    const table: dispatch.Table = .{ .handlers = &harness.handler_storage };
    try dispatch.reconcile(table, descriptor);
    try ipc.descriptor.reconcileWithRoutes(descriptor, .{ .routes = &routes });
}

// --- Manifest-gated tests ---
//
// These wire the capability service to a real principal-service provisioner over the neutral enforcement
// seam and drive it through the full serve path, so the manifest gate is exercised exactly as it is in the
// running system: the wire binding proves the caller holds a capability record, and the manifest gate is
// the additional check on top of it.

const issuance = @import("../principal/issuance.zig");
const provisioning = @import("../principal/provisioning.zig");
const account = @import("../account/creation.zig");
const identity = core.identity;
const time = core.time;
const principal_core = core.principal;
const trust_manifest = core.trust.manifest;

/// A signer backing `manifest.Signer` with an in-process key pair, standing in for the account keystore.
const KeyCustody = struct {
    key: Ed25519.KeyPair,

    fn signFor(context: *anyopaque, digest: [trust_manifest.digest_bytes]u8) ?[trust_manifest.signature_bytes]u8 {
        const self: *KeyCustody = @ptrCast(@alignCast(context));
        const signature = self.key.sign(&digest, null) catch return null;
        return signature.toBytes();
    }

    fn signer(self: *KeyCustody) trust_manifest.Signer {
        return .{ .context = self, .signFn = signFor };
    }
};

/// A capability service fronted by a real provisioner: the provisioner owns an accepted-manifest store and
/// hands the service its enforcement gate. The wire grant binds a caller to the capability prefix, so the
/// record gate passes and the manifest gate is what decides.
const GovernedHarness = struct {
    ids: identity.Source,
    clock: time.ManualClock,
    registry: principal_core.Registry,
    custody: KeyCustody,
    provisioner: issuance.Provisioner,
    account_id: identity.PrincipalId,
    service: *Service,
    verifier: ipc.authenticator.Verifier,
    grant: GrantBox,
    ep: endpoint.Endpoint,
    wire_key: Ed25519.KeyPair,
    handler_storage: [4]dispatch.Handler,

    /// A wire grant that binds whatever principal a test sets as the caller to the capability prefix, so
    /// the wire-layer binding always passes and the manifest gate is the deciding check.
    const GrantBox = struct {
        caller: u128 = 0,
        fn lookup(context: *anyopaque, capability: u128) ?ipc.capability_binding.Grant {
            _ = capability;
            const box: *GrantBox = @ptrCast(@alignCast(context));
            return .{ .bound_principal = box.caller, .scopes = &.{.{ .pattern = "capability.", .prefix = true }} };
        }
        fn resolver(box: *GrantBox) ipc.pipeline.Resolver {
            return .{ .context = box, .lookup = lookup };
        }
    };

    fn init(gpa: std.mem.Allocator, service: *Service, self: *GovernedHarness) !void {
        self.ids = .initDeterministic(1);
        self.clock = .init(.fromSeconds(1_000));
        self.registry = .init(gpa, &self.ids, self.clock.clock());
        self.custody = .{ .key = try Ed25519.KeyPair.generateDeterministic(@splat(3)) };
        const account_public_key = self.custody.key.public_key.toBytes();
        self.account_id = try self.registry.enroll(.{
            .kind = .human,
            .display_name = "owner",
            .policy_domain = "personal",
            .public_key = account_public_key,
        });
        self.provisioner = issuance.Provisioner.init(gpa, &self.registry, self.account_id, account_public_key, self.custody.signer(), "personal");

        service.* = Service.init(gpa);
        service.manifest_gate = self.provisioner.gate();
        self.service = service;

        self.wire_key = try Ed25519.KeyPair.generateDeterministic(@splat(7));
        self.verifier = ipc.authenticator.Verifier.init(gpa);
        self.grant = .{};
        self.handler_storage = service.handlers();
        self.ep = try endpoint.Endpoint.init(gpa, &self.verifier, self.grant.resolver(), .{
            .service_id = service_id,
            .routes = .{ .routes = &routes },
            .handlers = &self.handler_storage,
            .capacity_units = 10_000,
        });
    }

    fn deinit(self: *GovernedHarness) void {
        self.ep.deinit();
        self.verifier.deinit();
        self.service.deinit();
        self.provisioner.deinit();
        self.registry.deinit();
    }

    fn provisionAgent(self: *GovernedHarness, role: []const u8, seed: u8, idem: u128) !identity.PrincipalId {
        const agent_pair = try Ed25519.KeyPair.generateDeterministic(@splat(seed));
        const outcome = try self.provisioner.provision(.{
            .issuer = .human,
            .kind = .application_bound,
            .role = role,
            .envelope = .{},
            .policy = .{},
            .expires_at = .fromSeconds(10_000),
            .agent_public_key = agent_pair.public_key.toBytes(),
            .idempotency_key = idem,
        });
        return switch (outcome) {
            .provisioned => |id| id,
            .refused => error.TestUnexpectedResult,
        };
    }

    /// Serves one request as `caller`. The wire grant is bound to the caller and the message is signed by a
    /// key trusted under the caller's id, so the request survives authentication and the record gate; only
    /// the manifest gate can refuse it here.
    fn callAs(self: *GovernedHarness, gpa: std.mem.Allocator, caller: u128, method: []const u8, key: u128, body: []const u8) !dispatch.Reply {
        self.grant.caller = caller;
        try self.verifier.trust(caller, self.wire_key.public_key.toBytes());
        const message: endpoint.Envelope = .{
            .version = .{ .major = 1, .minor = 0 },
            .kind = .request,
            .correlation = @truncate(key),
            .idempotency_key = key,
            .principal = caller,
            .task = 0,
            .capability = cap_id_capability,
            .deadline_nanoseconds = 0,
            .method = method,
            .fault = null,
            .payload = body,
        };
        const bytes = try gpa.alloc(u8, message.encodedSize());
        defer gpa.free(bytes);
        _ = try ipc.envelope.encode(message, bytes);
        const signed = try ipc.authenticator.sign(.{ .service = caller, .key_pair = self.wire_key }, bytes);
        return self.ep.serve(signed, .system, 0);
    }
};

test "with the gate wired, an ungoverned root still issues" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var h: GovernedHarness = undefined;
    try GovernedHarness.init(gpa, &service, &h);
    defer h.deinit();

    // The account root holds no manifest: it is ungoverned and passes through to the record gate as before.
    var buffer: [32]u8 = undefined;
    const reply = try h.callAs(gpa, h.account_id.value, "capability.issue", 0x100, issueBody(&buffer, h.account_id.value, 0b0001, true, 3));
    try testing.expect(reply.succeeded());
    try testing.expectEqual(@as(usize, 1), service.records.items.len);
}

test "a capability absent from the agent's manifest is denied at the service before any record is minted" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var h: GovernedHarness = undefined;
    try GovernedHarness.init(gpa, &service, &h);
    defer h.deinit();

    // A governed agent whose manifest names mail capabilities, never `capability.issue`. It holds a wire
    // capability record for the prefix — the record gate passes — yet deny-by-default refuses it here.
    const agent = try h.provisionAgent("Mail agent", 20, 0x1);
    var buffer: [32]u8 = undefined;
    const reply = try h.callAs(gpa, agent.value, "capability.issue", 0x200, issueBody(&buffer, agent.value, 0b0001, true, 3));
    try testing.expectEqual(endpoint.FaultCode.unauthorized, reply.fault);
    try testing.expectEqual(@as(usize, 0), service.records.items.len);
}

test "a revoked agent fails closed at the service on its next call" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var h: GovernedHarness = undefined;
    try GovernedHarness.init(gpa, &service, &h);
    defer h.deinit();

    const agent = try h.provisionAgent("Mail agent", 21, 0x3);
    try h.provisioner.revokeAgent(agent);

    // The kill path denies before the record gate is even consulted for authority — inert everywhere.
    var buffer: [32]u8 = undefined;
    const reply = try h.callAs(gpa, agent.value, "capability.revoke", 0x400, buffer[0..0]);
    try testing.expectEqual(endpoint.FaultCode.unauthorized, reply.fault);
}

test "the manifest gate sits after idempotent replay so a recovery re-drive still completes" {
    const gpa = testing.allocator;
    var service: Service = undefined;
    var harness: Harness = undefined;
    try Harness.init(gpa, &service, &harness);
    defer harness.deinit();

    // Apply an issue with no gate wired: the admin caller mints one record.
    var buffer: [32]u8 = undefined;
    const body = issueBody(&buffer, admin, 0b0001, true, 3);
    const first = try harness.call(gpa, "capability.issue", 1, 0x100, body);
    var first_reader = payload.Reader.init(first.ok);
    const first_id = try first_reader.u128_();

    // Now wire a gate that denies this very caller. A re-drive of the already-applied key must still return
    // the prior id — the gate sits after the idempotency check, so a committed transition re-drives to
    // completion — while a fresh key is refused.
    var denier: DenyingGate = .{ .subject = admin };
    service.manifest_gate = denier.gate();

    const redriven = harness.redrive("capability.issue", 2, 0x100, body);
    var redriven_reader = payload.Reader.init(redriven.ok);
    try testing.expectEqual(first_id, try redriven_reader.u128_());
    try testing.expectEqual(@as(usize, 1), service.records.items.len);

    const fresh = harness.redrive("capability.issue", 3, 0x101, body);
    try testing.expectEqual(endpoint.FaultCode.unauthorized, fresh.fault);
    try testing.expectEqual(@as(usize, 1), service.records.items.len);
}

/// A stub enforcement gate that denies one subject and treats everyone else as ungoverned, for exercising
/// the gate's placement in the handler without standing up a provisioner.
const DenyingGate = struct {
    subject: u128,
    fn decide(context: *anyopaque, agent: u128, capability_name: []const u8) core.trust.enforcement.Ruling {
        _ = capability_name;
        const self: *DenyingGate = @ptrCast(@alignCast(context));
        return if (agent == self.subject) .denied else .ungoverned;
    }
    fn gate(self: *DenyingGate) core.trust.enforcement.Gate {
        return .{ .context = self, .decide = decide };
    }
};
