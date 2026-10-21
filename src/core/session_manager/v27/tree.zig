const std = @import("std");
const facts = @import("facts.zig");

pub const Family = enum { turn, run, change, call, task, interaction, response, delivery, child, part };
pub const Ref = struct { family: Family, id: []const u8 };

pub const Entity = struct {
    ref: Ref,
    owner: ?Ref = null,
    made_by: ?Ref = null,
    introduced_at: u64,
    open: bool = true,
    outcome: ?[]const u8 = null,
    kind: ?[]const u8 = null,
};

pub const OpenState = struct {
    entities: std.ArrayList(Entity) = .empty,
    next_introduced_at: u64 = 0,
    session_started: bool = false,
    session_ended: bool = false,

    pub fn deinit(state: *OpenState, alloc: std.mem.Allocator) void {
        state.entities.deinit(alloc);
        state.* = undefined;
    }

    pub fn find(state: *OpenState, ref: Ref) ?*Entity {
        for (state.entities.items) |*entity| {
            if (same(entity.ref, ref)) return entity;
        }
        return null;
    }

    pub fn findConst(state: *const OpenState, ref: Ref) ?*const Entity {
        for (state.entities.items) |*entity| {
            if (same(entity.ref, ref)) return entity;
        }
        return null;
    }

    pub fn apply(state: *OpenState, alloc: std.mem.Allocator, fact: facts.Fact) !void {
        switch (fact.data) {
            .session_started => state.session_started = true,
            .session_ended => state.session_ended = true,
            .turn_started => |data| try state.introduce(alloc, .{ .family = .turn, .id = data.turnId }, null, null),
            .model_requested => |data| try state.introduce(alloc, .{ .family = .run, .id = data.runId }, refOf(data.owner), null),
            .context_started => |data| try state.introduce(alloc, .{ .family = .change, .id = data.changeId }, if (data.turnId) |id| .{ .family = .turn, .id = id } else null, data.kind),
            .call_requested => |data| {
                const owner = refOf(data.owner);
                try state.introduce(alloc, .{ .family = .call, .id = data.callId }, owner, null);
                state.find(.{ .family = .call, .id = data.callId }).?.made_by = owner;
            },
            .task_started => |data| try state.introduce(alloc, .{ .family = .task, .id = data.taskId }, null, data.kind),
            .interaction_opened => |data| try state.introduce(alloc, .{ .family = .interaction, .id = data.interactionId }, refOf(data.subject), null),
            .response_submitted => |data| try state.introduce(alloc, .{ .family = .response, .id = data.responseId }, .{ .family = .interaction, .id = data.interactionId }, null),
            .delivery_admitted => |data| try state.introduce(alloc, .{ .family = .delivery, .id = data.deliveryId }, null, null),
            .child_opened => |data| try state.introduce(alloc, .{ .family = .child, .id = data.sessionId }, refOf(data.owner), null),
            .content_completed => |data| try state.introduce(alloc, .{ .family = .part, .id = data.partId }, .{ .family = .run, .id = data.runId }, data.kind),
            .call_started => |data| if (data.taskId) |task_id| {
                if (state.find(.{ .family = .call, .id = data.callId })) |call| call.owner = .{ .family = .task, .id = task_id };
            },
            .delivery_consumed => |data| if (state.find(.{ .family = .delivery, .id = data.deliveryId })) |delivery| {
                delivery.owner = .{ .family = .turn, .id = data.turnId };
            },
            else => {},
        }
        if (terminalOf(fact)) |terminal| {
            if (state.find(terminal.ref)) |entity| {
                entity.open = false;
                entity.outcome = terminal.outcome;
            }
        }
    }

    fn introduce(state: *OpenState, alloc: std.mem.Allocator, ref: Ref, owner: ?Ref, kind: ?[]const u8) !void {
        if (state.find(ref) != null) return;
        try state.entities.append(alloc, .{ .ref = ref, .owner = owner, .kind = kind, .introduced_at = state.next_introduced_at });
        state.next_introduced_at += 1;
    }
};

pub const Terminal = struct { ref: Ref, outcome: []const u8 };

pub fn terminalOf(fact: facts.Fact) ?Terminal {
    return switch (fact.data) {
        .turn_settled => |data| .{ .ref = .{ .family = .turn, .id = data.turnId }, .outcome = data.outcome },
        .model_settled => |data| .{ .ref = .{ .family = .run, .id = data.runId }, .outcome = data.outcome },
        .context_settled => |data| .{ .ref = .{ .family = .change, .id = data.changeId }, .outcome = data.outcome },
        .call_settled => |data| .{ .ref = .{ .family = .call, .id = data.callId }, .outcome = data.outcome },
        .task_ended => |data| .{ .ref = .{ .family = .task, .id = data.taskId }, .outcome = data.outcome },
        .interaction_settled => |data| .{ .ref = .{ .family = .interaction, .id = data.interactionId }, .outcome = data.outcome },
        .response_settled => |data| .{ .ref = .{ .family = .response, .id = data.responseId }, .outcome = data.outcome },
        .delivery_settled => |data| .{ .ref = .{ .family = .delivery, .id = data.deliveryId }, .outcome = data.outcome },
        else => null,
    };
}

pub fn parentOf(state: *const OpenState, ref: Ref) ?Ref {
    const entity = state.findConst(ref) orelse return null;
    if (ref.family == .call) {
        if (entity.made_by) |made_by| {
            if (made_by.family == .run) {
                const run = state.findConst(made_by);
                if (run != null and !run.?.open and std.mem.eql(u8, run.?.outcome orelse "", "completed")) return run.?.owner;
            }
        }
    }
    return entity.owner;
}

pub fn isUnder(state: *const OpenState, ref: Ref, owner: Ref) bool {
    var current = parentOf(state, ref);
    var steps: usize = 0;
    while (current) |parent| : (steps += 1) {
        if (same(parent, owner)) return true;
        if (steps >= state.entities.items.len) return false;
        current = parentOf(state, parent);
    }
    return false;
}

pub fn scopeOf(state: *const OpenState, ref: Ref) facts.Scope {
    var scope: facts.Scope = .{};
    var current: ?Ref = ref;
    var steps: usize = 0;
    while (current) |owner| : (steps += 1) {
        switch (owner.family) {
            .turn => if (scope.turnId == null) {
                scope.turnId = owner.id;
            },
            .task => if (scope.taskId == null) {
                scope.taskId = owner.id;
            },
            .run => if (scope.runId == null) {
                scope.runId = owner.id;
            },
            .change => if (scope.changeId == null) {
                scope.changeId = owner.id;
            },
            else => {},
        }
        if (steps >= state.entities.items.len) break;
        current = parentOf(state, owner);
    }
    if (ref.family == .call) {
        if (state.findConst(ref)) |call| {
            if (call.made_by) |made_by| {
                if (made_by.family == .run and scope.runId == null) scope.runId = made_by.id;
                var ancestor: ?Ref = made_by;
                while (ancestor) |entry| {
                    if (entry.family == .turn and scope.turnId == null) scope.turnId = entry.id;
                    ancestor = parentOf(state, entry);
                }
            }
        }
    }
    return scope;
}

pub fn refOf(owner: facts.Owner) ?Ref {
    if (owner.turnId) |id| return .{ .family = .turn, .id = id };
    if (owner.runId) |id| return .{ .family = .run, .id = id };
    if (owner.changeId) |id| return .{ .family = .change, .id = id };
    if (owner.callId) |id| return .{ .family = .call, .id = id };
    if (owner.taskId) |id| return .{ .family = .task, .id = id };
    return null;
}

pub fn same(a: Ref, b: Ref) bool {
    return a.family == b.family and std.mem.eql(u8, a.id, b.id);
}
