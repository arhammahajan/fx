const std = @import("std");
const facts = @import("facts.zig");
const tables = @import("tables.zig");

pub const Retention = enum { complete, operational };

pub fn emptySessionView() tables.SessionView {
    return .{};
}

pub fn foldCommit(alloc: std.mem.Allocator, view: *tables.SessionView, events: []const facts.Fact, position: u64, retention: Retention) !void {
    if (position < view.position) return;
    if (retention == .operational) prune(view);
    for (events) |event| try foldFact(alloc, view, event);
    view.position = position + 1;
}

pub fn foldFact(alloc: std.mem.Allocator, view: *tables.SessionView, fact: facts.Fact) !void {
    if (std.mem.eql(u8, view.session.status, "ended")) return;
    switch (fact.data) {
        .session_started => if (std.mem.eql(u8, view.session.status, "new")) {
            view.session.status = "open";
        },
        .session_ended => |data| {
            view.session.status = "ended";
            view.session.outcome = data.outcome;
        },
        .delivery_admitted => |data| try view.deliveries.put(alloc, data.deliveryId, .{ .delivery_id = data.deliveryId, .status = "admitted" }),
        .delivery_consumed => |data| if (view.deliveries.getPtr(data.deliveryId)) |row| {
            row.status = "consumed";
            row.turn_id = data.turnId;
        },
        .delivery_settled => |data| if (view.deliveries.getPtr(data.deliveryId)) |row| {
            row.status = "settled";
            row.outcome = data.outcome;
            if (data.turnId) |id| row.turn_id = id;
        },
        .turn_started => |data| {
            try view.turns.put(alloc, data.turnId, .{ .turn_id = data.turnId, .status = "running", .follows = switch (data.follows) {
                .string => |value| value,
                else => null,
            } });
            view.session.latest_turn_id = data.turnId;
            view.session.turn_count += 1;
        },
        .turn_paused => |data| {
            if (view.turns.getPtr(data.turnId)) |row| row.status = "paused";
        },
        .turn_settled => |data| if (view.turns.getPtr(data.turnId)) |row| {
            row.status = "settled";
            row.outcome = data.outcome;
            row.reply = data.reply orelse &.{};
        },
        .model_requested => |data| {
            var step: u64 = 0;
            if (data.owner.turnId) |turn_id| if (view.turns.getPtr(turn_id)) |turn| {
                step = turn.runs;
                turn.runs += 1;
            };
            try view.runs.put(alloc, data.runId, .{ .run_id = data.runId, .owner = data.owner, .status = "requested", .step = step });
        },
        .model_started => |data| if (view.runs.getPtr(data.runId)) |row| {
            row.status = "running";
            row.model_id = data.modelId;
            row.attempt = data.attempt;
        },
        .model_retried => {},
        .model_settled => |data| if (view.runs.getPtr(data.runId)) |row| {
            row.status = "settled";
            row.outcome = data.outcome;
            row.finish_reason = data.finishReason;
        },
        .content_completed => |data| try view.parts.put(alloc, data.partId, .{ .part_id = data.partId, .run_id = data.runId, .kind = data.kind, .phase = data.phase, .value = data.value, .interrupted = data.interrupted orelse false }),
        .call_requested => |data| try view.calls.put(alloc, data.callId, .{ .call_id = data.callId, .owner = data.owner, .capability = data.capability, .status = "requested" }),
        .call_started => |data| if (view.calls.getPtr(data.callId)) |row| {
            row.status = "running";
            row.task_id = data.taskId;
        },
        .call_settled => |data| if (view.calls.getPtr(data.callId)) |row| {
            row.status = "settled";
            row.outcome = data.outcome;
            row.output = data.output;
            row.label = data.label;
            row.reason = data.reason;
        },
        .task_started => |data| try view.tasks.put(alloc, data.taskId, .{ .task_id = data.taskId, .started_by = data.startedBy, .kind = data.kind, .name = data.name, .status = "running" }),
        .task_ended => |data| if (view.tasks.getPtr(data.taskId)) |row| {
            row.status = "ended";
            row.outcome = data.outcome;
        },
        .interaction_opened => |data| try view.interactions.put(alloc, data.interactionId, .{ .interaction_id = data.interactionId, .subject = data.subject, .request = data.request, .status = "open" }),
        .interaction_settled => |data| if (view.interactions.getPtr(data.interactionId)) |row| {
            row.status = "settled";
            row.outcome = data.outcome;
        },
        .response_submitted => |data| try view.responses.put(alloc, data.responseId, .{ .response_id = data.responseId, .interaction_id = data.interactionId, .delivery_id = data.deliveryId, .status = "submitted" }),
        .response_admitted => |data| {
            if (view.responses.getPtr(data.responseId)) |row| row.status = "admitted";
        },
        .response_settled => |data| if (view.responses.getPtr(data.responseId)) |row| {
            row.status = "settled";
            row.outcome = data.outcome;
        },
        .child_opened => |data| try view.children.put(alloc, data.sessionId, .{ .session_id = data.sessionId, .owner = data.owner, .name = data.name, .stream = data.stream }),
        .context_started => |data| try view.changes.put(alloc, data.changeId, .{ .change_id = data.changeId, .kind = data.kind, .turn_id = data.turnId, .status = "running" }),
        .context_settled => |data| if (view.changes.getPtr(data.changeId)) |row| {
            row.status = "settled";
            row.outcome = data.outcome;
        },
        .usage_recorded => |data| {
            view.usage.inputTokens += data.usage.inputTokens;
            view.usage.outputTokens += data.usage.outputTokens;
            view.usage.cacheReadTokens += data.usage.cacheReadTokens;
            view.usage.cacheWriteTokens += data.usage.cacheWriteTokens;
            if (data.usage.costUsd) |cost| view.usage.costUsd = (view.usage.costUsd orelse 0) + cost;
        },
    }
}

fn prune(view: *tables.SessionView) void {
    // Rows stay until the next committed snapshot in this first operational
    // implementation. Large settled values are withheld immediately.
    var calls = view.calls.iterator();
    while (calls.next()) |entry| if (entry.value_ptr.output) |value| switch (value) {
        .string => |text| if (text.len > 16_384) {
            entry.value_ptr.output = null;
        },
        else => {},
    };
}

test "fold tracks the active turn reply and calls" {
    const alloc = std.testing.allocator;
    var view = emptySessionView();
    defer view.deinit(alloc);
    const events = [_]facts.Fact{
        facts.sessionStarted(.{}),
        facts.turnStarted(.{ .turnId = "t", .cause = .{ .hook = "test" }, .follows = .null }),
        facts.modelRequested(.{ .runId = "r", .owner = .{ .turnId = "t" } }),
        facts.contentCompleted(.{ .partId = "p", .runId = "r", .kind = "text", .phase = "reply", .value = .{ .string = "hello" } }),
        facts.modelSettled(.{ .runId = "r", .outcome = "completed" }),
        facts.turnSettled(.{ .turnId = "t", .outcome = "completed", .reply = &.{"p"} }),
    };
    try foldCommit(alloc, &view, &events, 0, .complete);
    try std.testing.expectEqualStrings("settled", view.turns.get("t").?.status);
}
