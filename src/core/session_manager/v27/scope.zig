const facts = @import("facts.zig");
const tree = @import("tree.zig");

pub fn stamp(state: *const tree.OpenState, fact: *facts.Fact) void {
    const about = aboutFact(fact.*) orelse return;
    const scope = tree.scopeOf(state, about);
    if (scope.turnId != null or scope.taskId != null or scope.runId != null or scope.changeId != null) fact.scope = scope;
}

fn aboutFact(fact: facts.Fact) ?tree.Ref {
    if (tree.terminalOf(fact)) |terminal| return terminal.ref;
    return switch (fact.data) {
        .turn_started => |data| .{ .family = .turn, .id = data.turnId },
        .model_requested => |data| .{ .family = .run, .id = data.runId },
        .model_started => |data| .{ .family = .run, .id = data.runId },
        .model_retried => |data| .{ .family = .run, .id = data.runId },
        .context_started => |data| .{ .family = .change, .id = data.changeId },
        .call_requested => |data| .{ .family = .call, .id = data.callId },
        .call_started => |data| .{ .family = .call, .id = data.callId },
        .task_started => |data| .{ .family = .task, .id = data.taskId },
        .interaction_opened => |data| .{ .family = .interaction, .id = data.interactionId },
        .response_submitted => |data| .{ .family = .response, .id = data.responseId },
        .response_admitted => |data| .{ .family = .response, .id = data.responseId },
        .delivery_admitted => |data| .{ .family = .delivery, .id = data.deliveryId },
        .delivery_consumed => |data| .{ .family = .delivery, .id = data.deliveryId },
        .child_opened => |data| .{ .family = .child, .id = data.sessionId },
        .content_completed => |data| .{ .family = .part, .id = data.partId },
        .turn_paused => |data| .{ .family = .turn, .id = data.turnId },
        .usage_recorded => |data| if (data.owner) |owner| tree.refOf(owner) else null,
        else => null,
    };
}
