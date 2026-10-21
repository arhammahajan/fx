const std = @import("std");
const tables = @import("tables.zig");

pub fn activeTurn(view: *const tables.SessionView) ?tables.TurnRow {
    const id = view.session.latest_turn_id orelse return null;
    const row = view.turns.get(id) orelse return null;
    return if (std.mem.eql(u8, row.status, "settled")) null else row;
}

pub fn reply(view: *const tables.SessionView, turn_id: []const u8) []const []const u8 {
    return (view.turns.get(turn_id) orelse return &.{}).reply;
}

pub fn idle(view: *const tables.SessionView) bool {
    return std.mem.eql(u8, view.session.status, "open") and activeTurn(view) == null;
}

pub fn waiting(view: *const tables.SessionView) bool {
    const turn = activeTurn(view) orelse return false;
    if (std.mem.eql(u8, turn.status, "paused")) return true;
    var calls = view.calls.iterator();
    while (calls.next()) |entry| if (!std.mem.eql(u8, entry.value_ptr.status, "settled")) return true;
    return false;
}

pub fn activity(view: *const tables.SessionView) []const u8 {
    if (waiting(view)) return "waiting";
    if (idle(view)) return "idle";
    if (activeTurn(view) != null) return "running";
    return view.session.status;
}

pub fn callState(row: tables.CallRow) []const u8 {
    if (!std.mem.eql(u8, row.status, "settled")) return row.status;
    return row.outcome orelse "settled";
}

pub fn callLabel(row: tables.CallRow) []const u8 {
    return row.label orelse row.capability.label orelse row.capability.name;
}

pub fn openInteractions(view: *const tables.SessionView, alloc: std.mem.Allocator) ![]tables.InteractionRow {
    var out: std.ArrayList(tables.InteractionRow) = .empty;
    var rows = view.interactions.iterator();
    while (rows.next()) |entry| if (std.mem.eql(u8, entry.value_ptr.status, "open")) try out.append(alloc, entry.value_ptr.*);
    return out.toOwnedSlice(alloc);
}

pub fn tasks(view: *const tables.SessionView, alloc: std.mem.Allocator) ![]tables.TaskRow {
    var out: std.ArrayList(tables.TaskRow) = .empty;
    var rows = view.tasks.iterator();
    while (rows.next()) |entry| try out.append(alloc, entry.value_ptr.*);
    return out.toOwnedSlice(alloc);
}
