const std = @import("std");
const types = @import("../shared/types.zig");

/// Native v27 producer state. The session manager owns persistence; this
/// type derives and folds commits without maintaining a second shadow file.
pub fn Native(comptime v27: type) type {
    return struct {
        const facts = v27.facts;
        const Self = @This();

        alloc: std.mem.Allocator,
        json_arena: std.heap.ArenaAllocator,
        state: v27.tree.OpenState = .{},
        view: v27.tables.SessionView = .{},
        owned_ids: std.ArrayList([]u8) = .empty,
        owned_strings: std.ArrayList([]u8) = .empty,
        owned_id_slices: std.ArrayList([][]const u8) = .empty,
        model_id: ?[]const u8 = null,
        turn_number: u64 = 0,
        turn_id: ?[]const u8 = null,
        delivery_id: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
        next_part: u64 = 0,
        pending: std.ArrayList(facts.Fact) = .empty,
        sink_context: ?*anyopaque = null,
        sink_fn: ?*const fn (*anyopaque, []const facts.Fact) anyerror!void = null,
        delivery_consumed: bool = false,

        pub fn create(alloc: std.mem.Allocator) !*Self {
            const self = try alloc.create(Self);
            self.* = .{ .alloc = alloc, .json_arena = .init(alloc) };
            errdefer self.deinit();
            try self.write(&.{facts.sessionStarted(.{})});
            self.pending.clearRetainingCapacity();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.state.deinit(self.alloc);
            self.view.deinit(self.alloc);
            self.json_arena.deinit();
            for (self.owned_ids.items) |owned| self.alloc.free(owned);
            self.owned_ids.deinit(self.alloc);
            for (self.owned_strings.items) |value| self.alloc.free(value);
            self.owned_strings.deinit(self.alloc);
            for (self.owned_id_slices.items) |ids| self.alloc.free(ids);
            self.owned_id_slices.deinit(self.alloc);
            self.pending.deinit(self.alloc);
            const alloc = self.alloc;
            self.* = undefined;
            alloc.destroy(self);
        }

        pub fn beginTurn(self: *Self) !void {
            if (self.turn_id != null) return;
            self.turn_number += 1;
            self.delivery_id = try self.id("delivery", self.turn_number);
            self.turn_id = try self.id("turn", self.turn_number);
            const turn_id = self.turn_id.?;
            const delivery_id = self.delivery_id.?;
            const follows: std.json.Value = if (self.view.session.latest_turn_id) |previous| .{ .string = previous } else .{ .null = {} };
            try self.write(&.{
                facts.deliveryAdmitted(.{ .deliveryId = delivery_id }),
                facts.turnStarted(.{ .turnId = turn_id, .cause = .{ .deliveryId = delivery_id }, .follows = follows }),
            });
            self.delivery_consumed = false;
        }

        pub fn settleTurn(self: *Self, outcome: []const u8) !void {
            try self.beginTurn();
            if (self.run_id) |run_id| try self.write(&.{facts.modelSettled(.{ .runId = run_id, .outcome = if (std.mem.eql(u8, outcome, "completed")) "completed" else "interrupted" })});
            const turn_id = self.turn_id.?;
            self.turn_id = null;
            self.delivery_id = null;
            self.run_id = null;
            self.delivery_consumed = false;
            try self.write(&.{facts.turnSettled(.{ .turnId = turn_id, .outcome = outcome })});
        }

        pub fn progress(self: *Self, user: types.UserTurn, execution: types.ExecutionMemory, running: []const types.ToolCall) !void {
            try self.beginTurn();
            try self.consumeDelivery(user);
            try self.startModel();
            for (running) |call| {
                try self.requestCall(call);
                try self.startCall(call.id);
            }
            for (execution.tool_steps) |step| {
                for (step.tool_calls) |call| try self.requestCall(call);
                for (step.tool_results) |result| {
                    try self.startCall(result.tool_call_id);
                    try self.settleCall(result);
                }
            }
        }

        pub fn finish(self: *Self, turn: types.HistoryTurn) !void {
            const user, const execution, const text, const outcome = switch (turn) {
                .assistant => |entry| .{ entry.user, entry.execution, @as(?[]const u8, entry.assistant), "completed" },
                .interrupted => |entry| .{ entry.user, entry.execution, entry.assistant, if (entry.terminal_reason == .cancelled) "cancelled" else "failed" },
                .compacted_summary => return,
            };
            try self.progress(user, execution, &.{});
            var reply: ?[]const []const u8 = null;
            if (text) |value| if (value.len > 0) {
                self.next_part += 1;
                const part_id = try self.id("part", self.next_part);
                const owned_text = try self.ownString(value);
                const reply_ids = try self.alloc.alloc([]const u8, 1);
                var reply_ids_kept = false;
                errdefer if (!reply_ids_kept) self.alloc.free(reply_ids);
                reply_ids[0] = part_id;
                try self.owned_id_slices.append(self.alloc, reply_ids);
                reply_ids_kept = true;
                reply = reply_ids;
                try self.write(&.{facts.contentCompleted(.{ .partId = part_id, .runId = self.run_id.?, .kind = "text", .value = .{ .string = owned_text }, .phase = "reply", .interrupted = if (std.mem.eql(u8, outcome, "completed")) null else true })});
            };
            if (self.run_id) |run_id| {
                const settled = facts.modelSettled(.{ .runId = run_id, .outcome = if (std.mem.eql(u8, outcome, "completed")) "completed" else "interrupted" });
                if (execution.turn_summary) |summary| {
                    try self.write(&.{ settled, facts.usageRecorded(.{
                        .owner = .{ .runId = run_id },
                        .kind = "model",
                        .usage = .{
                            .inputTokens = summary.token_progress.input_tokens,
                            .outputTokens = summary.token_progress.output_tokens,
                        },
                    }) });
                } else try self.write(&.{settled});
            }
            const turn_id = self.turn_id.?;
            self.turn_id = null;
            self.delivery_id = null;
            self.run_id = null;
            self.delivery_consumed = false;
            try self.write(&.{facts.turnSettled(.{ .turnId = turn_id, .outcome = outcome, .reply = reply })});
        }

        fn consumeDelivery(self: *Self, user: types.UserTurn) !void {
            if (self.delivery_consumed) return;
            const arena = self.json_arena.allocator();
            const text = try arena.dupe(u8, user.text);
            var object: std.json.ObjectMap = .empty;
            try object.put(arena, "kind", .{ .string = "text" });
            try object.put(arena, "text", .{ .string = text });
            const parts = try arena.alloc(std.json.Value, 1 + user.images.len);
            parts[0] = .{ .object = object };
            for (user.images, parts[1..]) |image, *part| {
                var image_object: std.json.ObjectMap = .empty;
                try image_object.put(arena, "kind", .{ .string = "file" });
                try image_object.put(arena, "mediaType", .{ .string = try arena.dupe(u8, image.media_type) });
                if (image.source_ref) |source_ref| {
                    try image_object.put(arena, "ref", .{ .string = try arena.dupe(u8, source_ref) });
                } else if (image.snapshot_sha256) |digest| {
                    try image_object.put(arena, "ref", .{ .string = try arena.dupe(u8, digest) });
                }
                part.* = .{ .object = image_object };
            }
            self.delivery_consumed = true;
            try self.write(&.{facts.deliveryConsumed(.{
                .deliveryId = self.delivery_id.?,
                .turnId = self.turn_id.?,
                .parts = parts,
            })});
        }

        fn startModel(self: *Self) !void {
            try self.beginTurn();
            if (self.run_id != null) return;
            self.run_id = try self.id("run", self.turn_number);
            try self.write(&.{
                facts.modelRequested(.{ .runId = self.run_id.?, .owner = .{ .turnId = self.turn_id.? } }),
                facts.modelStarted(.{ .runId = self.run_id.?, .modelId = self.model_id orelse "fx/model", .attempt = 0 }),
            });
        }

        pub fn setModel(self: *Self, model: []const u8) !void {
            if (self.model_id) |current| if (std.mem.eql(u8, current, model)) return;
            self.model_id = try self.ownString(model);
        }

        fn requestCall(self: *Self, call: types.ToolCall) !void {
            const call_id = try self.knownId(call.id);
            if (self.state.find(.{ .family = .call, .id = call_id }) != null) return;
            const name = try self.ownString(call.name);
            const input: ?std.json.Value = if (call.argument_integrity == .valid)
                try std.json.parseFromSliceLeaky(std.json.Value, self.json_arena.allocator(), call.arguments_json, .{ .allocate = .alloc_always })
            else
                null;
            const input_error: ?facts.ErrorInfo = switch (call.argument_integrity) {
                .valid => null,
                .malformed_json => .{ .code = "malformed_json", .message = "Tool arguments were not valid JSON." },
                .non_object_json => .{ .code = "non_object_json", .message = "Tool arguments were not a JSON object." },
            };
            try self.write(&.{
                facts.callRequested(.{ .callId = call_id, .owner = .{ .runId = self.run_id.? }, .capability = .{ .kind = "tool", .name = name }, .input = input, .inputError = input_error }),
            });
        }

        fn startCall(self: *Self, source_id: []const u8) !void {
            const call_id = try self.knownId(source_id);
            const row = self.view.calls.get(call_id) orelse return;
            if (!std.mem.eql(u8, row.status, "requested")) return;
            try self.write(&.{facts.callStarted(.{ .callId = call_id })});
        }

        fn settleCall(self: *Self, result: types.PersistedToolResult) !void {
            const call_id = try self.knownId(result.tool_call_id);
            const row = self.state.find(.{ .family = .call, .id = call_id }) orelse return;
            if (!row.open) return;
            const output = try self.ownString(result.output);
            try self.write(&.{facts.callSettled(.{
                .callId = call_id,
                .outcome = if (result.status == .success) "completed" else "failed",
                .output = .{ .string = output },
            })});
        }

        pub fn compaction(self: *Self, count: u64) !void {
            const change_id = try self.id("change", count);
            try self.write(&.{
                facts.contextStarted(.{ .changeId = change_id, .kind = "compaction" }),
                facts.contextSettled(.{ .changeId = change_id, .kind = "compaction", .outcome = "completed" }),
            });
        }

        pub fn child(self: *Self, session_id: []const u8, work_id: []const u8, started: bool, outcome: ?[]const u8) !void {
            const task_id = try self.idWithSuffix("task", work_id);
            const child_session_id = try self.knownId(session_id);
            var existing_call: ?[]const u8 = null;
            if (!started) {
                if (self.view.tasks.get(task_id)) |task| existing_call = task.started_by.callId;
            } else {
                for (self.state.entities.items) |entity| {
                    if (entity.ref.family != .call) continue;
                    const call = self.view.calls.get(entity.ref.id) orelse continue;
                    if (!std.mem.eql(u8, call.capability.name, "subagent") or
                        std.mem.eql(u8, call.status, "settled") or
                        call.task_id != null) continue;
                    existing_call = entity.ref.id;
                    break;
                }
            }
            const call_id = existing_call orelse try self.copyId(work_id);
            const needs_open = started or self.view.tasks.get(task_id) == null;
            if (needs_open) {
                try self.startModel();
                if (existing_call == null) try self.write(&.{facts.callRequested(.{ .callId = call_id, .owner = .{ .runId = self.run_id.? }, .capability = .{ .kind = "agent", .name = "subagent" } })});
                try self.write(&.{
                    facts.taskStarted(.{ .taskId = task_id, .startedBy = .{ .callId = call_id }, .kind = "agent", .name = "subagent" }),
                    facts.childOpened(.{ .sessionId = child_session_id, .owner = .{ .taskId = task_id }, .name = "subagent", .stream = child_session_id }),
                    facts.callStarted(.{ .callId = call_id, .taskId = task_id }),
                });
            }
            if (outcome) |settled| try self.write(&.{
                facts.callSettled(.{ .callId = call_id, .outcome = settled }),
                facts.taskEnded(.{ .taskId = task_id, .outcome = if (std.mem.eql(u8, settled, "completed")) "completed" else if (std.mem.eql(u8, settled, "interrupted")) "cancelled" else "failed" }),
            });
        }

        pub fn end(self: *Self) !void {
            if (self.state.session_ended) return;
            try self.write(&.{facts.sessionEnded(.{ .outcome = "completed" })});
        }

        pub fn write(self: *Self, input: []const facts.Fact) !void {
            var committed: std.ArrayList(facts.Fact) = .empty;
            defer committed.deinit(self.alloc);
            try v27.cascade.apply(self.alloc, &self.state, input, &committed);
            try v27.fold.foldCommit(self.alloc, &self.view, committed.items, self.view.position, .complete);
            if (self.sink_fn) |sink| {
                try sink(self.sink_context.?, committed.items);
            } else {
                try self.pending.appendSlice(self.alloc, committed.items);
            }
        }

        pub fn setSink(self: *Self, context: *anyopaque, sink: *const fn (*anyopaque, []const facts.Fact) anyerror!void) !void {
            self.sink_context = context;
            self.sink_fn = sink;
            if (self.pending.items.len > 0) {
                try sink(context, self.pending.items);
                self.pending.clearRetainingCapacity();
            }
        }

        pub fn replay(self: *Self, committed: []const facts.Fact) !void {
            for (committed) |fact| try self.state.apply(self.alloc, fact);
            try v27.fold.foldCommit(self.alloc, &self.view, committed, self.view.position, .complete);
            self.turn_number = self.view.session.turn_count;
            self.next_part = self.view.parts.count();
            self.syncRuntimeState();
        }

        pub fn recoverOpenTurns(self: *Self) !void {
            self.syncRuntimeState();
            while (self.turn_id != null) {
                try self.settleTurn("failed");
                self.syncRuntimeState();
            }
        }

        fn id(self: *Self, prefix: []const u8, number: u64) ![]const u8 {
            const value = try self.alloc.print("{s}_{d}", .{ prefix, number });
            errdefer self.alloc.free(value);
            try self.owned_ids.append(self.alloc, value);
            return value;
        }

        fn idWithSuffix(self: *Self, prefix: []const u8, suffix: []const u8) ![]const u8 {
            const value = try self.alloc.print("{s}_{s}", .{ prefix, suffix });
            errdefer self.alloc.free(value);
            try self.owned_ids.append(self.alloc, value);
            return value;
        }

        fn copyId(self: *Self, source: []const u8) ![]const u8 {
            const value = try self.alloc.dupe(u8, source);
            errdefer self.alloc.free(value);
            try self.owned_ids.append(self.alloc, value);
            return value;
        }

        fn syncRuntimeState(self: *Self) void {
            self.turn_id = null;
            self.delivery_id = null;
            self.run_id = null;
            self.delivery_consumed = false;

            for (self.state.entities.items) |entity| {
                if (entity.open and entity.ref.family == .turn) self.turn_id = entity.ref.id;
            }
            const turn_id = self.turn_id orelse return;
            const delivery_id = if (self.view.turns.get(turn_id)) |turn| turn.delivery_id else null;
            for (self.state.entities.items) |entity| {
                if (!entity.open) continue;
                switch (entity.ref.family) {
                    .delivery => {
                        if (delivery_id) |expected| {
                            if (std.mem.eql(u8, entity.ref.id, expected)) self.delivery_id = entity.ref.id;
                        }
                    },
                    .run => if (entity.owner) |owner| {
                        if (owner.family == .turn and std.mem.eql(u8, owner.id, turn_id)) self.run_id = entity.ref.id;
                    },
                    else => {},
                }
            }
            if (self.delivery_id) |active_delivery_id| {
                const row = self.view.deliveries.get(active_delivery_id) orelse return;
                self.delivery_consumed = !std.mem.eql(u8, row.status, "admitted");
            }
        }

        fn knownId(self: *Self, source: []const u8) ![]const u8 {
            for (self.owned_ids.items) |value| if (std.mem.eql(u8, value, source)) return value;
            return self.copyId(source);
        }

        fn ownString(self: *Self, source: []const u8) ![]const u8 {
            const value = try self.alloc.dupe(u8, source);
            errdefer self.alloc.free(value);
            try self.owned_strings.append(self.alloc, value);
            return value;
        }
    };
}
