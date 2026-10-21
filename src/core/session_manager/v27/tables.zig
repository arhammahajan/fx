const std = @import("std");
const facts = @import("facts.zig");

pub const SessionRow = struct {
    status: []const u8 = "new",
    turn_count: u64 = 0,
    latest_turn_id: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
};

pub const DeliveryRow = struct { delivery_id: []const u8, status: []const u8, turn_id: ?[]const u8 = null, outcome: ?[]const u8 = null };
pub const TurnRow = struct { turn_id: []const u8, status: []const u8, delivery_id: ?[]const u8 = null, follows: ?[]const u8 = null, outcome: ?[]const u8 = null, reply: []const []const u8 = &.{}, runs: u64 = 0 };
pub const RunRow = struct { run_id: []const u8, owner: facts.Owner, status: []const u8, model_id: ?[]const u8 = null, attempt: ?u32 = null, outcome: ?[]const u8 = null, finish_reason: ?[]const u8 = null, step: u64 = 0 };
pub const PartRow = struct { part_id: []const u8, run_id: []const u8, kind: []const u8, phase: []const u8, value: ?std.json.Value = null, interrupted: bool = false };
pub const CallRow = struct { call_id: []const u8, owner: facts.Owner, capability: facts.Capability, status: []const u8, task_id: ?[]const u8 = null, outcome: ?[]const u8 = null, output: ?std.json.Value = null, label: ?[]const u8 = null, reason: ?[]const u8 = null };
pub const TaskRow = struct { task_id: []const u8, started_by: facts.Owner, kind: []const u8, name: []const u8, status: []const u8, outcome: ?[]const u8 = null };
pub const InteractionRow = struct { interaction_id: []const u8, subject: facts.Owner, request: std.json.Value, status: []const u8, outcome: ?[]const u8 = null };
pub const ResponseRow = struct { response_id: []const u8, interaction_id: []const u8, delivery_id: []const u8, status: []const u8, outcome: ?[]const u8 = null };
pub const ChildRow = struct { session_id: []const u8, owner: facts.Owner, name: []const u8, stream: []const u8 };
pub const ChangeRow = struct { change_id: []const u8, kind: []const u8, turn_id: ?[]const u8 = null, status: []const u8, outcome: ?[]const u8 = null };

pub const SessionView = struct {
    position: u64 = 0,
    session: SessionRow = .{},
    deliveries: std.StringHashMapUnmanaged(DeliveryRow) = .empty,
    turns: std.StringHashMapUnmanaged(TurnRow) = .empty,
    runs: std.StringHashMapUnmanaged(RunRow) = .empty,
    parts: std.StringHashMapUnmanaged(PartRow) = .empty,
    calls: std.StringHashMapUnmanaged(CallRow) = .empty,
    tasks: std.StringHashMapUnmanaged(TaskRow) = .empty,
    interactions: std.StringHashMapUnmanaged(InteractionRow) = .empty,
    responses: std.StringHashMapUnmanaged(ResponseRow) = .empty,
    children: std.StringHashMapUnmanaged(ChildRow) = .empty,
    changes: std.StringHashMapUnmanaged(ChangeRow) = .empty,
    usage: facts.Usage = .{},

    pub fn deinit(view: *SessionView, alloc: std.mem.Allocator) void {
        inline for (.{ "deliveries", "turns", "runs", "parts", "calls", "tasks", "interactions", "responses", "children", "changes" }) |field| @field(view, field).deinit(alloc);
        view.* = undefined;
    }
};
