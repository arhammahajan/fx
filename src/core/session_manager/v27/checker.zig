const std = @import("std");
const catalog = @import("catalog.zig");
const facts = @import("facts.zig");

pub fn check(events: []const facts.Fact) error{Violation}!void {
    if (events.len == 0) return error.Violation;
    for (events) |event| {
        const outcome: ?[]const u8, const allowed: ?[]const []const u8 = switch (event.data) {
            .session_ended => |data| .{ data.outcome, &catalog.session_outcomes },
            .delivery_settled => |data| .{ data.outcome, &catalog.delivery_outcomes },
            .turn_settled => |data| .{ data.outcome, &catalog.turn_outcomes },
            .model_settled => |data| .{ data.outcome, &catalog.model_outcomes },
            .call_settled => |data| .{ data.outcome, &catalog.call_outcomes },
            .task_ended => |data| .{ data.outcome, &catalog.task_outcomes },
            .interaction_settled => |data| .{ data.outcome, &catalog.interaction_outcomes },
            .response_settled => |data| .{ data.outcome, &catalog.response_outcomes },
            .context_settled => |data| .{ data.outcome, &catalog.context_outcomes },
            else => .{ null, null },
        };
        if (outcome) |value| {
            var known = false;
            for (allowed.?) |candidate| known = known or std.mem.eql(u8, value, candidate);
            if (!known) return error.Violation;
        }
    }
}
