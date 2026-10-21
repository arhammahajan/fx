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
        next_run: u64 = 0,
        next_delivery: u64 = 0,
        turn_id: ?[]const u8 = null,
        delivery_id: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
        last_run_id: ?[]const u8 = null,
        next_part: u64 = 0,
        next_change: u64 = 0,
        removed_turns: u64 = 0,
        next_interaction: u64 = 0,
        interactions_by_call: std.StringHashMapUnmanaged([]const u8) = .empty,
        steering_count: usize = 0,
        run_assistant_recorded: bool = false,
        compat_selection: ?std.json.Value = null,
        compat_keep_tool_steps: usize = 0,
        compat_keep_steering: usize = 0,
        pending: std.ArrayList(facts.Fact) = .empty,
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
            self.interactions_by_call.deinit(self.alloc);
            self.pending.deinit(self.alloc);
            const alloc = self.alloc;
            self.* = undefined;
            alloc.destroy(self);
        }

        pub fn beginTurn(self: *Self) !void {
            if (self.turn_id != null) return;
            self.turn_number += 1;
            self.next_delivery += 1;
            self.delivery_id = try self.id("delivery", self.next_delivery);
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
            self.last_run_id = null;
            self.delivery_consumed = false;
            self.steering_count = 0;
            try self.write(&.{facts.turnSettled(.{ .turnId = turn_id, .outcome = outcome })});
        }

        pub fn progress(self: *Self, user: types.UserTurn, execution: types.ExecutionMemory, running: []const types.ToolCall) !void {
            try self.updateExecution(user, execution, running);
        }

        fn updateExecution(self: *Self, user: types.UserTurn, execution: types.ExecutionMemory, running: []const types.ToolCall) !void {
            try self.beginTurn();
            try self.consumeDelivery(user);
            try self.consumeSteering(execution.steering);
            if (self.run_id == null and self.last_run_id == null and (execution.tool_steps.len > 0 or running.len > 0)) try self.startModel();
            for (execution.tool_steps) |step| {
                for (step.tool_calls) |call| try self.requestCall(call);
                for (step.tool_results) |result| {
                    try self.startCall(result.tool_call_id);
                    try self.settleCall(result);
                }
            }
            if (running.len > 0) {
                if (self.run_id == null) try self.startModel();
                for (running) |call| {
                    try self.requestCall(call);
                    try self.startCall(call.id);
                }
            }
        }

        pub fn finish(self: *Self, turn: types.HistoryTurn) !void {
            const user, const execution, const text, const outcome = switch (turn) {
                .assistant => |entry| .{ entry.user, entry.execution, @as(?[]const u8, entry.assistant), "completed" },
                .interrupted => |entry| .{ entry.user, entry.execution, entry.assistant, if (entry.terminal_reason == .cancelled) "cancelled" else "failed" },
                .compacted_summary => return,
            };
            try self.updateExecution(user, execution, &.{});
            if (self.run_id == null and self.last_run_id == null) try self.startModel();
            const reply_run_id = self.run_id orelse self.last_run_id.?;
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
                try self.write(&.{facts.contentCompleted(.{ .partId = part_id, .runId = reply_run_id, .kind = "text", .value = .{ .string = owned_text }, .phase = "reply", .interrupted = if (std.mem.eql(u8, outcome, "completed")) null else true })});
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
            self.last_run_id = null;
            self.delivery_consumed = false;
            self.steering_count = 0;
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
                if (image.path.len > 0) try image_object.put(arena, "filename", .{ .string = try arena.dupe(u8, image.path) });
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

        fn consumeSteering(self: *Self, steering: []const types.PersistedSteering) !void {
            if (self.steering_count >= steering.len) return;
            const arena = self.json_arena.allocator();
            for (steering[self.steering_count..]) |entry| {
                self.next_delivery += 1;
                const delivery_id = try self.id("delivery", self.next_delivery);
                var source: std.json.ObjectMap = .empty;
                try source.put(arena, "control", .{ .string = "steer" });
                var part: std.json.ObjectMap = .empty;
                try part.put(arena, "kind", .{ .string = "text" });
                try part.put(arena, "text", .{ .string = try arena.dupe(u8, entry.text) });
                const parts = try arena.alloc(std.json.Value, 1);
                parts[0] = .{ .object = part };
                try self.write(&.{
                    facts.deliveryAdmitted(.{ .deliveryId = delivery_id, .source = .{ .object = source } }),
                    facts.deliveryConsumed(.{ .deliveryId = delivery_id, .turnId = self.turn_id.?, .parts = parts }),
                    facts.deliverySettled(.{ .deliveryId = delivery_id, .turnId = self.turn_id.?, .outcome = "handled" }),
                });
            }
            self.steering_count = steering.len;
        }

        fn startModel(self: *Self) !void {
            try self.beginTurn();
            if (self.run_id != null) return;
            try self.modelRequested(self.model_id orelse "fx/model");
            try self.modelStarted(0);
        }

        pub fn modelRequested(self: *Self, model: []const u8) !void {
            try self.beginTurn();
            if (self.run_id != null) return;
            self.next_run += 1;
            self.run_id = try self.id("run", self.next_run);
            self.run_assistant_recorded = false;
            try self.setModel(model);
            try self.write(&.{facts.modelRequested(.{ .runId = self.run_id.?, .owner = .{ .turnId = self.turn_id.? } })});
        }

        pub fn modelStarted(self: *Self, attempt: u32) !void {
            const run_id = self.run_id orelse return error.ModelRunNotOpen;
            try self.write(&.{facts.modelStarted(.{ .runId = run_id, .modelId = self.model_id orelse "fx/model", .attempt = attempt })});
        }

        pub fn modelRetried(self: *Self, attempt: u32, code: []const u8, message: []const u8) !void {
            const run_id = self.run_id orelse return error.ModelRunNotOpen;
            const owned_code = try self.ownString(code);
            const owned_message = try self.ownString(message);
            try self.write(&.{facts.modelRetried(.{ .runId = run_id, .attempt = attempt, .@"error" = .{ .code = owned_code, .message = owned_message } })});
        }

        pub fn modelSettled(self: *Self, outcome: []const u8, finish_reason: ?[]const u8, usage: ?types.Usage) !void {
            const run_id = self.run_id orelse return error.ModelRunNotOpen;
            const owned_finish = if (finish_reason) |value| try self.ownString(value) else null;
            var committed: std.ArrayList(facts.Fact) = .empty;
            defer committed.deinit(self.alloc);
            try committed.append(self.alloc, facts.modelSettled(.{ .runId = run_id, .outcome = outcome, .finishReason = owned_finish }));
            if (usage) |value| try committed.append(self.alloc, facts.usageRecorded(.{
                .owner = .{ .runId = run_id },
                .kind = "model",
                .usage = .{
                    .inputTokens = value.input_tokens orelse 0,
                    .outputTokens = value.output_tokens orelse 0,
                    .cacheReadTokens = value.cache_read_tokens orelse 0,
                    .cacheWriteTokens = value.cache_write_tokens orelse 0,
                },
            }));
            try self.write(committed.items);
            self.last_run_id = run_id;
            self.run_id = null;
        }

        pub fn runningAssistant(self: *Self, text: []const u8) !void {
            if (text.len == 0 or self.run_assistant_recorded) return;
            const run_id = self.run_id orelse return;
            self.next_part += 1;
            const part_id = try self.id("part", self.next_part);
            const owned = try self.ownString(text);
            try self.write(&.{facts.contentCompleted(.{
                .partId = part_id,
                .runId = run_id,
                .kind = "text",
                .value = .{ .string = owned },
                .phase = "tool",
            })});
            self.run_assistant_recorded = true;
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
            if (std.mem.eql(u8, call.name, "ask_user_question")) try self.interactionOpened(call_id, "question");
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
            const encoded = try std.json.Stringify.valueAlloc(self.alloc, result, .{ .emit_null_optional_fields = false });
            defer self.alloc.free(encoded);
            const output = try std.json.parseFromSliceLeaky(std.json.Value, self.json_arena.allocator(), encoded, .{ .allocate = .alloc_always });
            const outcome = if (result.status == .success) "completed" else "failed";
            if (self.interactions_by_call.contains(call_id)) try self.interactionSettled(call_id, if (result.status == .success) "accepted" else "failed");
            if (self.view.calls.get(call_id)) |call| if (call.task_id) |task_id| {
                try self.write(&.{
                    facts.callSettled(.{ .callId = call_id, .outcome = outcome, .output = output }),
                    facts.taskEnded(.{ .taskId = task_id, .outcome = outcome }),
                });
                return;
            };
            try self.write(&.{facts.callSettled(.{ .callId = call_id, .outcome = outcome, .output = output })});
        }

        pub fn compaction(self: *Self, summary: types.CompactedSummaryHistoryTurn, keep_from: ?u64, keep_tool_steps: usize, keep_steering: usize) !void {
            const change_id = try self.id("change", summary.compaction_count);
            self.removed_turns += summary.removed_turn_count;
            const arena = self.json_arena.allocator();
            try self.setCompatSelection(summary.summary, self.removed_turns, summary.compaction_count);
            self.compat_keep_tool_steps = keep_tool_steps;
            self.compat_keep_steering = keep_steering;
            var selects: ?std.json.Value = null;
            if (keep_from) |turn_number| {
                var object: std.json.ObjectMap = .empty;
                try object.put(arena, "turnId", .{ .string = try self.id("turn", turn_number) });
                selects = .{ .object = object };
            }
            try self.write(&.{
                facts.contextStarted(.{ .changeId = change_id, .kind = "compaction" }),
                facts.contextSettled(.{ .changeId = change_id, .kind = "compaction", .outcome = "completed", .selects = selects }),
            });
        }

        pub fn restoreCompaction(self: *Self, raw: []const u8) !void {
            const arena = self.json_arena.allocator();
            const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .allocate = .alloc_always });
            if (value != .object) return error.BadCompaction;
            const summary = value.object.get("summary") orelse return error.BadCompaction;
            const removed = value.object.get("removed_turn_count") orelse return error.BadCompaction;
            const count = value.object.get("compaction_count") orelse return error.BadCompaction;
            if (summary != .string or removed != .integer or count != .integer or removed.integer < 0 or count.integer < 0) return error.BadCompaction;
            self.removed_turns = @intCast(removed.integer);
            if (value.object.get("keep_tool_steps")) |kept| {
                if (kept == .integer and kept.integer >= 0) self.compat_keep_tool_steps = @intCast(kept.integer);
            }
            if (value.object.get("keep_steering")) |kept| {
                if (kept == .integer and kept.integer >= 0) self.compat_keep_steering = @intCast(kept.integer);
            }
            try self.setCompatSelection(summary.string, self.removed_turns, @intCast(count.integer));
        }

        pub fn restoreCallOutput(self: *Self, raw: []const u8) !void {
            const value = try std.json.parseFromSliceLeaky(std.json.Value, self.json_arena.allocator(), raw, .{ .allocate = .alloc_always });
            if (value != .object) return error.BadToolResult;
            const call_id = value.object.get("tool_call_id") orelse return error.BadToolResult;
            if (call_id != .string) return error.BadToolResult;
            const row = self.view.calls.getPtr(call_id.string) orelse return;
            row.output = value;
        }

        fn setCompatSelection(self: *Self, summary: []const u8, removed: u64, count: u64) !void {
            const arena = self.json_arena.allocator();
            var selection: std.json.ObjectMap = .empty;
            try selection.put(arena, "summary", .{ .string = try arena.dupe(u8, summary) });
            try selection.put(arena, "removedTurnCount", .{ .integer = @intCast(removed) });
            try selection.put(arena, "compactionCount", .{ .integer = @intCast(count) });
            self.compat_selection = .{ .object = selection };
        }

        pub fn metadataChange(self: *Self, kind: []const u8) !void {
            self.next_change += 1;
            const change_id = try self.id("metadata", self.next_change);
            const owned_kind = try self.ownString(kind);
            try self.write(&.{
                facts.contextStarted(.{ .changeId = change_id, .kind = owned_kind }),
                facts.contextSettled(.{ .changeId = change_id, .kind = owned_kind, .outcome = "completed" }),
            });
        }

        pub fn interactionOpened(self: *Self, call_id: []const u8, kind: []const u8) !void {
            if (self.interactions_by_call.contains(call_id)) return;
            const known_call_id = try self.knownId(call_id);
            self.next_interaction += 1;
            const interaction_id = try self.id("interaction", self.next_interaction);
            const arena = self.json_arena.allocator();
            var request: std.json.ObjectMap = .empty;
            try request.put(arena, "kind", .{ .string = try arena.dupe(u8, kind) });
            try request.put(arena, "prompt", .{ .string = "Approve this tool call?" });
            try self.interactions_by_call.put(self.alloc, known_call_id, interaction_id);
            try self.write(&.{facts.interactionOpened(.{
                .interactionId = interaction_id,
                .subject = .{ .callId = known_call_id },
                .request = .{ .object = request },
            })});
        }

        pub fn interactionSettled(self: *Self, call_id: []const u8, outcome: []const u8) !void {
            const interaction_id = self.interactions_by_call.get(call_id) orelse return;
            if (std.mem.eql(u8, outcome, "accepted")) {
                const arena = self.json_arena.allocator();
                var grant: std.json.ObjectMap = .empty;
                try grant.put(arena, "interactionId", .{ .string = interaction_id });
                var cleared_by: std.json.ObjectMap = .empty;
                try cleared_by.put(arena, "grant", .{ .object = grant });
                try self.write(&.{
                    facts.callStarted(.{ .callId = try self.knownId(call_id), .clearedBy = .{ .object = cleared_by } }),
                    facts.interactionSettled(.{ .interactionId = interaction_id, .outcome = outcome }),
                });
            } else {
                try self.write(&.{facts.interactionSettled(.{ .interactionId = interaction_id, .outcome = outcome })});
            }
            _ = self.interactions_by_call.remove(call_id);
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
            _ = outcome;
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
            try self.pending.appendSlice(self.alloc, committed.items);
        }

        pub fn pendingJsonAlloc(self: *Self, alloc: std.mem.Allocator) !?[]u8 {
            if (self.pending.items.len == 0) return null;
            return @as(?[]u8, try std.json.Stringify.valueAlloc(alloc, self.pending.items, .{ .emit_null_optional_fields = false }));
        }

        pub fn hasPendingFacts(self: *const Self) bool {
            return self.pending.items.len > 0;
        }

        pub fn externalizeReply(self: *Self, ref: []const u8, size: usize) !void {
            const owned_ref = try self.ownString(ref);
            var index = self.pending.items.len;
            while (index > 0) {
                index -= 1;
                switch (self.pending.items[index].data) {
                    .content_completed => |*content| {
                        if (!std.mem.eql(u8, content.phase, "reply") or content.value == null) continue;
                        content.value = null;
                        content.valueRef = .{ .ref = owned_ref, .mediaType = "application/json", .size = size };
                        return;
                    },
                    else => {},
                }
            }
        }

        pub fn factsCommitted(self: *Self) void {
            self.pending.clearRetainingCapacity();
        }

        pub fn replay(self: *Self, committed: []const facts.Fact) !void {
            for (committed) |fact| try self.state.apply(self.alloc, fact);
            try v27.fold.foldCommit(self.alloc, &self.view, committed, self.view.position, .complete);
            self.turn_number = self.view.session.turn_count;
            self.next_run = self.view.runs.count();
            self.next_delivery = self.view.deliveries.count();
            self.next_part = self.view.parts.count();
            self.next_change = self.view.changes.count();
            self.next_interaction = self.view.interactions.count();
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
            self.last_run_id = null;
            self.run_assistant_recorded = false;
            self.delivery_consumed = false;
            self.steering_count = 0;

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
