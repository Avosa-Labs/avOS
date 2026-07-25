//! Why a capability check refused, and the error each refusal surfaces.
//!
//! The store records the precise refusal for the ledger while the caller learns
//! only that it may not proceed, so several distinct refusals map onto one error.

const outcome = @import("../base/outcome.zig");

const DomainError = outcome.DomainError;

pub const Refusal = enum {
    unknown_handle,
    stale_handle,
    revoked,
    issuer_revoked,
    not_yet_valid,
    expired,
    wrong_holder,
    holder_not_authorized,
    operation_not_granted,
    resource_not_covered,
    task_binding_violated,
    session_binding_violated,
    device_binding_violated,
    invocations_exhausted,
    confirmation_required,
    remote_processing_forbidden,
    destination_not_permitted,
    recipient_not_permitted,
    field_not_permitted,
    monetary_limit_exceeded,
    delegation_forbidden,
    delegation_would_widen,
    cross_domain,
    model_not_permitted,
    rate_limited,

    /// The error a refusal surfaces to the caller. Several distinct refusals
    /// map onto one error deliberately: the caller learns it may not proceed,
    /// while the ledger retains which check failed.
    pub fn toError(refusal: Refusal) DomainError {
        return switch (refusal) {
            .unknown_handle,
            .wrong_holder,
            .holder_not_authorized,
            .operation_not_granted,
            .resource_not_covered,
            .cross_domain,
            => error.Unauthorized,
            .stale_handle => error.IntegrityFailure,
            .revoked, .issuer_revoked => error.CapabilityRevoked,
            .expired => error.CapabilityExpired,
            .not_yet_valid,
            .task_binding_violated,
            .session_binding_violated,
            .device_binding_violated,
            .confirmation_required,
            .remote_processing_forbidden,
            .destination_not_permitted,
            .recipient_not_permitted,
            .field_not_permitted,
            .monetary_limit_exceeded,
            .delegation_forbidden,
            .delegation_would_widen,
            .model_not_permitted,
            => error.ConstraintViolation,
            .invocations_exhausted, .rate_limited => error.BudgetExhausted,
        };
    }
};
