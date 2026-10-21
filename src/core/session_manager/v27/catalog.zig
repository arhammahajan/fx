//! Generated from tests/v27/catalog.json at eve badc42fbf.

const std = @import("std");

pub const Family = enum { session, delivery, turn, model, content, call, task, interaction, response, child, context, usage };
pub const Role = enum { introduces, updates, terminal, complete, record };

pub const FactType = enum {
    call_requested,
    call_settled,
    call_started,
    child_opened,
    content_completed,
    context_settled,
    context_started,
    delivery_admitted,
    delivery_consumed,
    delivery_settled,
    interaction_opened,
    interaction_settled,
    model_requested,
    model_retried,
    model_settled,
    model_started,
    response_admitted,
    response_settled,
    response_submitted,
    session_ended,
    session_started,
    task_ended,
    task_started,
    turn_paused,
    turn_settled,
    turn_started,
    usage_recorded,

    pub fn wireName(value: FactType) []const u8 {
        return names[@backingInt(value)];
    }

    pub fn parse(name: []const u8) ?FactType {
        inline for (std.meta.tags(FactType)) |value| {
            if (std.mem.eql(u8, name, value.wireName())) return value;
        }
        return null;
    }
};

const names = [_][]const u8{
    "call.requested",    "call.settled",     "call.started",       "child.opened",
    "content.completed", "context.settled",  "context.started",    "delivery.admitted",
    "delivery.consumed", "delivery.settled", "interaction.opened", "interaction.settled",
    "model.requested",   "model.retried",    "model.settled",      "model.started",
    "response.admitted", "response.settled", "response.submitted", "session.ended",
    "session.started",   "task.ended",       "task.started",       "turn.paused",
    "turn.settled",      "turn.started",     "usage.recorded",
};

pub const Descriptor = struct { family: Family, role: Role, id_field: []const u8 };

pub const descriptors = [_]Descriptor{
    .{ .family = .call, .role = .introduces, .id_field = "callId" },
    .{ .family = .call, .role = .terminal, .id_field = "callId" },
    .{ .family = .call, .role = .updates, .id_field = "callId" },
    .{ .family = .child, .role = .introduces, .id_field = "sessionId" },
    .{ .family = .content, .role = .complete, .id_field = "partId" },
    .{ .family = .context, .role = .terminal, .id_field = "changeId" },
    .{ .family = .context, .role = .introduces, .id_field = "changeId" },
    .{ .family = .delivery, .role = .introduces, .id_field = "deliveryId" },
    .{ .family = .delivery, .role = .updates, .id_field = "deliveryId" },
    .{ .family = .delivery, .role = .terminal, .id_field = "deliveryId" },
    .{ .family = .interaction, .role = .introduces, .id_field = "interactionId" },
    .{ .family = .interaction, .role = .terminal, .id_field = "interactionId" },
    .{ .family = .model, .role = .introduces, .id_field = "runId" },
    .{ .family = .model, .role = .updates, .id_field = "runId" },
    .{ .family = .model, .role = .terminal, .id_field = "runId" },
    .{ .family = .model, .role = .updates, .id_field = "runId" },
    .{ .family = .response, .role = .updates, .id_field = "responseId" },
    .{ .family = .response, .role = .terminal, .id_field = "responseId" },
    .{ .family = .response, .role = .introduces, .id_field = "responseId" },
    .{ .family = .session, .role = .terminal, .id_field = "" },
    .{ .family = .session, .role = .introduces, .id_field = "" },
    .{ .family = .task, .role = .terminal, .id_field = "taskId" },
    .{ .family = .task, .role = .introduces, .id_field = "taskId" },
    .{ .family = .turn, .role = .updates, .id_field = "turnId" },
    .{ .family = .turn, .role = .terminal, .id_field = "turnId" },
    .{ .family = .turn, .role = .introduces, .id_field = "turnId" },
    .{ .family = .usage, .role = .record, .id_field = "" },
};

pub fn descriptor(fact_type: FactType) Descriptor {
    return descriptors[@backingInt(fact_type)];
}

pub const session_outcomes = [_][]const u8{ "completed", "failed" };
pub const delivery_outcomes = [_][]const u8{ "handled", "awaiting-input", "applied", "ignored", "refused", "failed" };
pub const turn_outcomes = [_][]const u8{ "completed", "failed", "cancelled" };
pub const model_outcomes = [_][]const u8{ "completed", "failed", "interrupted", "abandoned" };
pub const call_outcomes = [_][]const u8{ "completed", "failed", "rejected", "interrupted", "abandoned" };
pub const task_outcomes = [_][]const u8{ "completed", "failed", "cancelled" };
pub const interaction_outcomes = [_][]const u8{ "accepted", "declined", "invalid", "failed", "withdrawn", "interrupted", "abandoned", "expired" };
pub const response_outcomes = [_][]const u8{ "applied", "refused", "failed", "withdrawn", "abandoned", "expired" };
pub const context_outcomes = [_][]const u8{ "completed", "failed", "cancelled", "interrupted" };

test "catalog has one descriptor for every fact type" {
    try std.testing.expectEqual(std.meta.tags(FactType).len, descriptors.len);
    for (std.meta.tags(FactType)) |fact_type| {
        try std.testing.expectEqual(fact_type, FactType.parse(fact_type.wireName()).?);
        const empty_id = descriptor(fact_type).id_field.len == 0;
        try std.testing.expectEqual(descriptor(fact_type).family == .session or descriptor(fact_type).family == .usage, empty_id);
    }
}
