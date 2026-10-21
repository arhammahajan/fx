const std = @import("std");
const builtin = @import("builtin");
const cascade = @import("cascade.zig");
const checker = @import("checker.zig");
const envelope = @import("envelope.zig");
const facts = @import("facts.zig");
const tree = @import("tree.zig");

pub const Result = struct {
    line: []u8,
    committed: []facts.Fact,

    pub fn deinit(result: *Result, alloc: std.mem.Allocator) void {
        alloc.free(result.line);
        alloc.free(result.committed);
        result.* = undefined;
    }
};

pub fn commit(
    alloc: std.mem.Allocator,
    state: *tree.OpenState,
    seq: u64,
    ts_ms: u64,
    pos: u64,
    input: []const facts.Fact,
    private: []const envelope.PrivateEntry,
) !Result {
    var committed: std.ArrayList(facts.Fact) = .empty;
    errdefer committed.deinit(alloc);
    try cascade.apply(alloc, state, input, &committed);
    if (builtin.optimize.runtimeSafety()) try checker.check(committed.items);

    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    try envelope.appendCommit(alloc, &line, .{
        .seq = seq,
        .ts_ms = ts_ms,
        .pos = pos,
        .facts = committed.items,
        .private = private,
    });
    return .{ .line = try line.toOwnedSlice(alloc), .committed = try committed.toOwnedSlice(alloc) };
}

test "writer cascades and frames one commit" {
    const alloc = std.testing.allocator;
    var state: tree.OpenState = .{};
    defer state.deinit(alloc);
    const opening = [_]facts.Fact{facts.sessionStarted(.{})};
    var result = try commit(alloc, &state, 1, 10, 0, &opening, &.{});
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, result.line, "{\"v\":3,\"seq\":1,\"ts\":10,\"kind\":\"commit\",\"pos\":0"));
}
