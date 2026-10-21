const std = @import("std");
const facts = @import("facts.zig");
const scope = @import("scope.zig");
const tree = @import("tree.zig");

pub fn apply(alloc: std.mem.Allocator, state: *tree.OpenState, input: []const facts.Fact, out: *std.ArrayList(facts.Fact)) !void {
    for (input) |event| {
        const owner = endedOwner(event);
        if (owner == null) {
            try appendApplied(alloc, state, out, event);
            continue;
        }

        var probe: tree.OpenState = .{ .next_introduced_at = state.next_introduced_at, .session_started = state.session_started, .session_ended = state.session_ended };
        defer probe.deinit(alloc);
        try probe.entities.appendSlice(alloc, state.entities.items);
        try probe.apply(alloc, event);

        var under: std.ArrayList(tree.Ref) = .empty;
        defer under.deinit(alloc);
        try collectOpen(alloc, &probe, owner.?, input, &under);
        sortLeavesFirst(&probe, under.items);

        const superseded = terminalOutcome(event) orelse "";
        for (under.items) |ref| {
            if (ref.family == .delivery and owner.? != .session) continue;
            try appendApplied(alloc, state, out, closing(state, ref, owner.?, std.mem.eql(u8, superseded, "abandoned")));
        }
        try appendApplied(alloc, state, out, event);
        for (under.items) |ref| {
            if (ref.family != .delivery or owner.? == .session) continue;
            try appendApplied(alloc, state, out, closing(state, ref, owner.?, std.mem.eql(u8, superseded, "abandoned")));
        }
    }
}

const Owner = union(enum) { session, entity: tree.Ref };

fn endedOwner(fact: facts.Fact) ?Owner {
    if (fact.factType() == .session_ended) return .session;
    if (tree.terminalOf(fact)) |terminal| return .{ .entity = terminal.ref };
    return null;
}

fn terminalOutcome(fact: facts.Fact) ?[]const u8 {
    if (tree.terminalOf(fact)) |terminal| return terminal.outcome;
    return switch (fact.data) {
        .session_ended => |data| data.outcome,
        else => null,
    };
}

fn collectOpen(alloc: std.mem.Allocator, state: *const tree.OpenState, owner: Owner, input: []const facts.Fact, out: *std.ArrayList(tree.Ref)) !void {
    for (state.entities.items) |entity| {
        if (!entity.open or !closable(entity.ref.family) or explicitlyClosed(entity.ref, input)) continue;
        const included = switch (owner) {
            .session => true,
            .entity => |ref| tree.isUnder(state, entity.ref, ref),
        };
        if (included) try out.append(alloc, entity.ref);
    }
}

fn closable(family: tree.Family) bool {
    return switch (family) {
        .child, .part => false,
        else => true,
    };
}

fn explicitlyClosed(ref: tree.Ref, input: []const facts.Fact) bool {
    for (input) |event| {
        if (tree.terminalOf(event)) |terminal| if (tree.same(ref, terminal.ref)) return true;
    }
    return false;
}

fn sortLeavesFirst(state: *const tree.OpenState, refs: []tree.Ref) void {
    const Context = struct {
        state: *const tree.OpenState,
        fn lessThan(context: @This(), a: tree.Ref, b: tree.Ref) bool {
            const ad = depth(context.state, a);
            const bd = depth(context.state, b);
            if (ad != bd) return ad > bd;
            const ai = context.state.findConst(a).?.introduced_at;
            const bi = context.state.findConst(b).?.introduced_at;
            return ai > bi;
        }
    };
    std.mem.sort(tree.Ref, refs, Context{ .state = state }, Context.lessThan);
}

fn depth(state: *const tree.OpenState, ref: tree.Ref) usize {
    var result: usize = 0;
    var current = tree.parentOf(state, ref);
    while (current) |parent| : (result += 1) current = tree.parentOf(state, parent);
    return result;
}

fn appendApplied(alloc: std.mem.Allocator, state: *tree.OpenState, out: *std.ArrayList(facts.Fact), source: facts.Fact) !void {
    var event = source;
    try state.apply(alloc, event);
    scope.stamp(state, &event);
    try out.append(alloc, event);
}

fn closing(state: *const tree.OpenState, ref: tree.Ref, owner: Owner, superseded: bool) facts.Fact {
    const cut = switch (ref.family) {
        .call, .interaction, .run, .change => "interrupted",
        .response => "withdrawn",
        .delivery => "handled",
        .task, .turn => "cancelled",
        else => unreachable,
    };
    const abandoned = switch (ref.family) {
        .call, .interaction, .response, .run => "abandoned",
        else => cut,
    };
    const outcome = if (superseded) abandoned else cut;
    const reason = reasonFor(owner, superseded);
    return switch (ref.family) {
        .call => facts.callSettled(.{ .callId = ref.id, .outcome = outcome, .reason = reason }),
        .interaction => facts.interactionSettled(.{ .interactionId = ref.id, .outcome = outcome, .reason = reason }),
        .response => facts.responseSettled(.{ .responseId = ref.id, .outcome = outcome, .reason = reason }),
        .run => facts.modelSettled(.{ .runId = ref.id, .outcome = outcome }),
        .task => facts.taskEnded(.{ .taskId = ref.id, .outcome = outcome, .reason = reason }),
        .change => facts.contextSettled(.{ .changeId = ref.id, .kind = state.findConst(ref).?.kind orelse "unknown", .outcome = outcome }),
        .delivery => blk: {
            const parent = tree.parentOf(state, ref);
            if (owner == .session or parent == null or parent.?.family != .turn) break :blk facts.deliverySettled(.{ .deliveryId = ref.id, .outcome = "failed", .reason = reason });
            break :blk facts.deliverySettled(.{ .deliveryId = ref.id, .outcome = outcome, .turnId = parent.?.id });
        },
        .turn => facts.turnSettled(.{ .turnId = ref.id, .outcome = outcome }),
        else => unreachable,
    };
}

fn reasonFor(owner: Owner, superseded: bool) []const u8 {
    return switch (owner) {
        .session => "session-ended",
        .entity => |ref| switch (ref.family) {
            .turn => if (superseded) "turn-ended" else "turn-cancelled",
            .run => if (superseded) "model-call-retried" else "steered",
            .task => "task-ended",
            .interaction => "interaction-ended",
            .change => "context-change-failed",
            .call => "call-ended",
            .response => "response-ended",
            .delivery => "delivery-ended",
            else => "owner-ended",
        },
    };
}

test "turn cancellation closes leaves before owners and deliveries after" {
    const alloc = std.testing.allocator;
    var state: tree.OpenState = .{};
    defer state.deinit(alloc);
    var out: std.ArrayList(facts.Fact) = .empty;
    defer out.deinit(alloc);
    const empty_parts: []const std.json.Value = &.{};
    const opening = [_]facts.Fact{
        facts.sessionStarted(.{}),
        facts.deliveryAdmitted(.{ .deliveryId = "d" }),
        facts.turnStarted(.{ .turnId = "t", .cause = .{ .deliveryId = "d" }, .follows = null }),
        facts.deliveryConsumed(.{ .deliveryId = "d", .turnId = "t", .parts = empty_parts }),
        facts.modelRequested(.{ .runId = "r", .owner = .{ .turnId = "t" } }),
        facts.callRequested(.{ .callId = "c", .owner = .{ .runId = "r" }, .capability = .{ .kind = "tool", .name = "deploy" } }),
        facts.interactionOpened(.{ .interactionId = "i", .subject = .{ .callId = "c" }, .request = .{ .null = {} } }),
    };
    try apply(alloc, &state, &opening, &out);
    out.clearRetainingCapacity();
    const ending = [_]facts.Fact{facts.turnSettled(.{ .turnId = "t", .outcome = "cancelled" })};
    try apply(alloc, &state, &ending, &out);
    const expected = [_][]const u8{ "interaction.settled", "call.settled", "model.settled", "turn.settled", "delivery.settled" };
    try std.testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |name, event| try std.testing.expectEqualStrings(name, event.factType().wireName());
}
