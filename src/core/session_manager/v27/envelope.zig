const std = @import("std");
const facts = @import("facts.zig");
const log = @import("../log.zig");

pub const version: u32 = 3;
pub const fold_version: u32 = 1;

pub const PrivateKind = enum {
    model_context,
    provider_replay,
    compaction_records,
    permissions,
    prefs,
    title,
    workspace,
    language,
    client_prompt,
    tool_identities,
    moved_files,
};

pub const PrivateEntry = struct {
    kind: PrivateKind,
    ref: ?[]const u8 = null,
    data: std.json.Value,
};

pub const Commit = struct {
    seq: u64,
    ts_ms: u64,
    pos: u64,
    facts: []const facts.Fact,
    private: []const PrivateEntry = &.{},
};

pub const Snapshot = struct {
    seq: u64,
    ts_ms: u64,
    pos: u64,
    state: std.json.Value,
};

pub fn appendCommit(alloc: std.mem.Allocator, out: *std.ArrayList(u8), commit: Commit) !void {
    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try payload.print(alloc, "{{\"v\":3,\"seq\":{d},\"ts\":{d},\"kind\":\"commit\",\"pos\":{d},\"facts\":", .{ commit.seq, commit.ts_ms, commit.pos });
    var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &payload);
    try std.json.Stringify.value(commit.facts, .{ .emit_null_optional_fields = false }, &writer.writer);
    payload = writer.toArrayList();
    try payload.appendSlice(alloc, ",\"private\":");
    writer = .fromArrayList(alloc, &payload);
    try std.json.Stringify.value(commit.private, .{ .emit_null_optional_fields = false }, &writer.writer);
    payload = writer.toArrayList();
    try log.appendFramed(alloc, out, payload.items);
}

pub fn appendSnapshot(alloc: std.mem.Allocator, out: *std.ArrayList(u8), snapshot: Snapshot) !void {
    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try payload.print(alloc, "{{\"v\":3,\"seq\":{d},\"ts\":{d},\"kind\":\"snapshot\",\"pos\":{d},\"fold\":1,\"state\":", .{ snapshot.seq, snapshot.ts_ms, snapshot.pos });
    var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &payload);
    try std.json.Stringify.value(snapshot.state, .{}, &writer.writer);
    payload = writer.toArrayList();
    try log.appendFramed(alloc, out, payload.items);
}

pub const Decoded = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(decoded: *Decoded) void {
        decoded.parsed.deinit();
        decoded.* = undefined;
    }

    pub fn kind(decoded: *const Decoded) ?[]const u8 {
        const object = switch (decoded.parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const value = object.get("kind") orelse return null;
        return switch (value) {
            .string => |string| string,
            else => null,
        };
    }
};

pub fn decode(alloc: std.mem.Allocator, line: []const u8) !Decoded {
    const payload = try log.checkFrame(line);
    const object_bytes = try alloc.alloc(u8, payload.len + 1);
    defer alloc.free(object_bytes);
    @memcpy(object_bytes[0..payload.len], payload);
    object_bytes[payload.len] = '}';
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, object_bytes, .{});
    errdefer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadEnvelope,
    };
    if (object.get("v") == null or object.get("seq") == null or object.get("ts") == null or object.get("pos") == null) return error.BadEnvelope;
    const kind = object.get("kind") orelse return error.BadEnvelope;
    if (kind != .string) return error.BadEnvelope;
    if (std.mem.eql(u8, kind.string, "commit")) {
        if (object.get("facts") == null or object.get("private") == null) return error.BadEnvelope;
    } else if (std.mem.eql(u8, kind.string, "snapshot")) {
        if (object.get("fold") == null or object.get("state") == null) return error.BadEnvelope;
    } else return error.BadEnvelope;
    return .{ .parsed = parsed };
}

test "commit and snapshot envelopes retain their positions" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const one = [_]facts.Fact{facts.sessionStarted(.{})};
    try appendCommit(alloc, &out, .{ .seq = 1, .ts_ms = 1, .pos = 0, .facts = &one });
    var decoded = try decode(alloc, out.items);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("commit", decoded.kind().?);
}
