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
    for (events) |event| try foldFactAt(alloc, view, event, position);
    view.position = position + 1;
}

pub fn foldFact(alloc: std.mem.Allocator, view: *tables.SessionView, fact: facts.Fact) !void {
    return foldFactAt(alloc, view, fact, view.position);
}

fn foldFactAt(alloc: std.mem.Allocator, view: *tables.SessionView, fact: facts.Fact, position: u64) !void {
    if (std.mem.eql(u8, view.session.status, "ended")) return;
    switch (fact.data) {
        .session_started => if (std.mem.eql(u8, view.session.status, "new")) {
            view.session.status = "open";
        },
        .session_ended => |data| {
            view.session.status = "ended";
            view.session.outcome = data.outcome;
        },
        .delivery_admitted => |data| if (!view.deliveries.contains(data.deliveryId)) try view.deliveries.put(alloc, data.deliveryId, .{ .delivery_id = data.deliveryId, .status = "admitted", .source = data.source, .introduced_at = position }),
        .delivery_consumed => |data| if (view.deliveries.getPtr(data.deliveryId)) |row| if (std.mem.eql(u8, row.status, "admitted")) {
            row.status = "consumed";
            row.turn_id = data.turnId;
            row.parts = data.parts;
            row.consumed_at = position;
        },
        .delivery_settled => |data| if (view.deliveries.getPtr(data.deliveryId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "settled";
            row.outcome = data.outcome;
            if (data.turnId) |id| row.turn_id = id;
        },
        .turn_started => |data| if (!view.turns.contains(data.turnId)) {
            try view.turns.put(alloc, data.turnId, .{ .turn_id = data.turnId, .status = "running", .delivery_id = data.cause.deliveryId, .introduced_at = position, .follows = switch (data.follows) {
                .string => |value| value,
                else => null,
            } });
            view.session.latest_turn_id = data.turnId;
            view.session.turn_count += 1;
        },
        .turn_paused => |data| if (view.turns.getPtr(data.turnId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "paused";
        },
        .turn_settled => |data| if (view.turns.getPtr(data.turnId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "settled";
            row.outcome = data.outcome;
            row.reply = data.reply orelse &.{};
        },
        .model_requested => |data| if (!view.runs.contains(data.runId)) {
            var step: u64 = 0;
            if (data.owner.turnId) |turn_id| if (view.turns.getPtr(turn_id)) |turn| {
                step = turn.runs;
                turn.runs += 1;
            };
            try view.runs.put(alloc, data.runId, .{ .run_id = data.runId, .owner = data.owner, .status = "requested", .step = step, .introduced_at = position });
        },
        .model_started => |data| if (view.runs.getPtr(data.runId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "running";
            row.model_id = data.modelId;
            row.attempt = data.attempt;
        },
        .model_retried => {},
        .model_settled => |data| if (view.runs.getPtr(data.runId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "settled";
            row.outcome = data.outcome;
            row.finish_reason = data.finishReason;
        },
        .content_completed => |data| if (!view.parts.contains(data.partId)) try view.parts.put(alloc, data.partId, .{ .part_id = data.partId, .run_id = data.runId, .kind = data.kind, .phase = data.phase, .value = data.value, .value_ref = data.valueRef, .interrupted = data.interrupted orelse false, .introduced_at = position }),
        .call_requested => |data| if (!view.calls.contains(data.callId)) try view.calls.put(alloc, data.callId, .{ .call_id = data.callId, .owner = data.owner, .capability = data.capability, .status = "requested", .input = data.input, .introduced_at = position }),
        .call_started => |data| if (view.calls.getPtr(data.callId)) |row| if (std.mem.eql(u8, row.status, "requested")) {
            row.status = "running";
            row.task_id = data.taskId;
        },
        .call_settled => |data| if (view.calls.getPtr(data.callId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "settled";
            row.outcome = data.outcome;
            row.output = data.output;
            row.label = data.label;
            row.reason = data.reason;
        },
        .task_started => |data| if (!view.tasks.contains(data.taskId)) try view.tasks.put(alloc, data.taskId, .{ .task_id = data.taskId, .started_by = data.startedBy, .kind = data.kind, .name = data.name, .status = "running", .introduced_at = position }),
        .task_ended => |data| if (view.tasks.getPtr(data.taskId)) |row| if (!std.mem.eql(u8, row.status, "ended")) {
            row.status = "ended";
            row.outcome = data.outcome;
        },
        .interaction_opened => |data| if (!view.interactions.contains(data.interactionId)) try view.interactions.put(alloc, data.interactionId, .{ .interaction_id = data.interactionId, .subject = data.subject, .request = data.request, .status = "open", .introduced_at = position }),
        .interaction_settled => |data| if (view.interactions.getPtr(data.interactionId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "settled";
            row.outcome = data.outcome;
        },
        .response_submitted => |data| if (!view.responses.contains(data.responseId)) try view.responses.put(alloc, data.responseId, .{ .response_id = data.responseId, .interaction_id = data.interactionId, .delivery_id = data.deliveryId, .status = "submitted", .introduced_at = position }),
        .response_admitted => |data| {
            if (view.responses.getPtr(data.responseId)) |row| row.status = "admitted";
        },
        .response_settled => |data| if (view.responses.getPtr(data.responseId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "settled";
            row.outcome = data.outcome;
        },
        .child_opened => |data| if (!view.children.contains(data.sessionId)) try view.children.put(alloc, data.sessionId, .{ .session_id = data.sessionId, .owner = data.owner, .name = data.name, .stream = data.stream, .introduced_at = position }),
        .context_started => |data| if (!view.changes.contains(data.changeId)) try view.changes.put(alloc, data.changeId, .{ .change_id = data.changeId, .kind = data.kind, .turn_id = data.turnId, .status = "running", .introduced_at = position }),
        .context_settled => |data| if (view.changes.getPtr(data.changeId)) |row| if (!std.mem.eql(u8, row.status, "settled")) {
            row.status = "settled";
            row.outcome = data.outcome;
            if (std.mem.eql(u8, data.outcome, "completed") and data.selects != null) view.selection = data.selects;
        },
        .usage_recorded => |data| {
            view.usage.inputTokens += data.usage.inputTokens;
            view.usage.outputTokens += data.usage.outputTokens;
            view.usage.cacheReadTokens += data.usage.cacheReadTokens;
            view.usage.cacheWriteTokens += data.usage.cacheWriteTokens;
            if (data.usage.costUsd) |cost| view.usage.costUsd = (view.usage.costUsd orelse 0) + cost;
            if (data.owner) |owner| {
                if (owner.runId) |run_id| {
                    if (view.runs.getPtr(run_id)) |run| run.usage = addUsage(run.usage, data.usage);
                }
                if (owner.callId) |call_id| {
                    if (view.calls.getPtr(call_id)) |call| call.usage = addUsage(call.usage, data.usage);
                }
            }
        },
    }
}

fn addUsage(a: facts.Usage, b: facts.Usage) facts.Usage {
    return .{
        .inputTokens = a.inputTokens + b.inputTokens,
        .outputTokens = a.outputTokens + b.outputTokens,
        .cacheReadTokens = a.cacheReadTokens + b.cacheReadTokens,
        .cacheWriteTokens = a.cacheWriteTokens + b.cacheWriteTokens,
        .costUsd = if (a.costUsd != null or b.costUsd != null) (a.costUsd orelse 0) + (b.costUsd orelse 0) else null,
    };
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
