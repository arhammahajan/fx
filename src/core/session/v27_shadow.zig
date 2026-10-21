const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub fn Shadow(comptime v27: type) type {
    return struct {
        const facts = v27.facts;
        const Self = @This();

        alloc: std.mem.Allocator,
        file: ?std.Io.File = null,
        report_file: ?std.Io.File = null,
        state: v27.tree.OpenState = .{},
        view: v27.tables.SessionView = .{},
        owned_ids: std.ArrayList([]u8) = .empty,
        turn_number: u64 = 0,
        turn_id: ?[]const u8 = null,
        delivery_id: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
        next_part: u64 = 0,

        pub fn createMemory(alloc: std.mem.Allocator) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);
            self.* = .{ .alloc = alloc };
            try self.write(&.{facts.sessionStarted(.{})});
            return self;
        }

        pub fn enableFiles(self: *Self, session_folder: []const u8) !void {
            if (self.file != null) return;
            const path = try std.Io.Dir.path.join(self.alloc, &.{ session_folder, "stream.v27.ndjson" });
            defer self.alloc.free(path);
            self.file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
            errdefer {
                self.file.?.close(io_mod.getIo());
                self.file = null;
            }
            if (io_mod.getenv("FX_SESSION_V27_REPORT_DIR")) |report_dir| {
                const report_name = try self.alloc.print("{s}.ndjson", .{std.Io.Dir.path.basename(session_folder)});
                defer self.alloc.free(report_name);
                const report_path = try std.Io.Dir.path.join(self.alloc, &.{ report_dir, report_name });
                defer self.alloc.free(report_path);
                self.report_file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), report_path, .{ .truncate = true });
            }
            const opening = "{\"at\":\"1970-01-01T00:00:00.000Z\",\"facts\":[{\"type\":\"session.started\",\"data\":{}}]}\n";
            try self.file.?.writeStreamingAll(io_mod.getIo(), opening);
            if (self.report_file) |file| try file.writeStreamingAll(io_mod.getIo(), opening);
        }

        pub fn deinit(self: *Self) void {
            if (self.file) |file| file.close(io_mod.getIo());
            if (self.report_file) |file| file.close(io_mod.getIo());
            self.state.deinit(self.alloc);
            self.view.deinit(self.alloc);
            for (self.owned_ids.items) |owned| self.alloc.free(owned);
            self.owned_ids.deinit(self.alloc);
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
            const parts: []const std.json.Value = &.{};
            try self.write(&.{
                facts.deliveryAdmitted(.{ .deliveryId = delivery_id }),
                facts.turnStarted(.{ .turnId = turn_id, .cause = .{ .deliveryId = delivery_id }, .follows = .null }),
                facts.deliveryConsumed(.{ .deliveryId = delivery_id, .turnId = turn_id, .parts = parts }),
            });
        }

        pub fn settleTurn(self: *Self, outcome: []const u8) !void {
            try self.beginTurn();
            if (self.run_id) |run_id| try self.write(&.{facts.modelSettled(.{ .runId = run_id, .outcome = if (std.mem.eql(u8, outcome, "completed")) "completed" else "interrupted" })});
            try self.write(&.{facts.turnSettled(.{ .turnId = self.turn_id.?, .outcome = outcome })});
            self.turn_id = null;
            self.delivery_id = null;
            self.run_id = null;
        }

        pub fn progress(self: *Self, execution: types.ExecutionMemory, running: []const types.ToolCall) !void {
            try self.startModel();
            for (running) |call| try self.requestCall(call);
            for (execution.tool_steps) |step| {
                for (step.tool_calls) |call| try self.requestCall(call);
                for (step.tool_results) |result| try self.settleCall(result);
            }
        }

        pub fn finish(self: *Self, turn: types.HistoryTurn) !void {
            const execution, const text, const outcome = switch (turn) {
                .assistant => |entry| .{ entry.execution, @as(?[]const u8, entry.assistant), "completed" },
                .interrupted => |entry| .{ entry.execution, entry.assistant, if (entry.terminal_reason == .cancelled) "cancelled" else "failed" },
                .compacted_summary => return,
            };
            try self.progress(execution, &.{});
            var reply: ?[]const []const u8 = null;
            var reply_ids: [1][]const u8 = undefined;
            if (text) |value| if (value.len > 0) {
                self.next_part += 1;
                const part_id = try self.id("part", self.next_part);
                try self.write(&.{facts.contentCompleted(.{ .partId = part_id, .runId = self.run_id.?, .kind = "text", .value = .{ .string = value }, .phase = "reply", .interrupted = if (std.mem.eql(u8, outcome, "completed")) null else true })});
                reply_ids[0] = part_id;
                reply = &reply_ids;
            };
            if (self.run_id) |run_id| try self.write(&.{facts.modelSettled(.{ .runId = run_id, .outcome = if (std.mem.eql(u8, outcome, "completed")) "completed" else "interrupted" })});
            try self.write(&.{facts.turnSettled(.{ .turnId = self.turn_id.?, .outcome = outcome, .reply = reply })});
            self.turn_id = null;
            self.delivery_id = null;
            self.run_id = null;
        }

        fn startModel(self: *Self) !void {
            try self.beginTurn();
            if (self.run_id != null) return;
            self.run_id = try self.id("run", self.turn_number);
            try self.write(&.{
                facts.modelRequested(.{ .runId = self.run_id.?, .owner = .{ .turnId = self.turn_id.? } }),
                facts.modelStarted(.{ .runId = self.run_id.?, .modelId = "fx/model", .attempt = 0 }),
            });
        }

        fn requestCall(self: *Self, call: types.ToolCall) !void {
            const call_id = try self.knownId(call.id);
            if (self.state.find(.{ .family = .call, .id = call_id }) != null) return;
            try self.write(&.{
                facts.callRequested(.{ .callId = call_id, .owner = .{ .runId = self.run_id.? }, .capability = .{ .kind = "tool", .name = call.name } }),
                facts.callStarted(.{ .callId = call_id }),
            });
        }

        fn settleCall(self: *Self, result: types.PersistedToolResult) !void {
            const call_id = try self.knownId(result.tool_call_id);
            const row = self.state.find(.{ .family = .call, .id = call_id }) orelse return;
            if (!row.open) return;
            try self.write(&.{facts.callSettled(.{
                .callId = call_id,
                .outcome = if (result.status == .success) "completed" else "failed",
                .output = .{ .string = result.output },
            })});
        }

        pub fn compaction(self: *Self, count: u64) !void {
            const change_id = try self.id("change", count);
            try self.write(&.{
                facts.contextStarted(.{ .changeId = change_id, .kind = "compaction" }),
                facts.contextSettled(.{ .changeId = change_id, .kind = "compaction", .outcome = "completed" }),
            });
        }

        pub fn child(self: *Self, session_id: []const u8, work_id: []const u8, started: bool, completed: bool) !void {
            const call_id = try self.copyId(work_id);
            const task_id = try self.idWithSuffix("task", work_id);
            if (started) {
                try self.startModel();
                try self.write(&.{
                    facts.callRequested(.{ .callId = call_id, .owner = .{ .runId = self.run_id.? }, .capability = .{ .kind = "agent", .name = "subagent" } }),
                    facts.taskStarted(.{ .taskId = task_id, .startedBy = .{ .callId = call_id }, .kind = "agent", .name = "subagent" }),
                    facts.childOpened(.{ .sessionId = session_id, .owner = .{ .taskId = task_id }, .name = "subagent", .stream = session_id }),
                    facts.callStarted(.{ .callId = call_id, .taskId = task_id }),
                });
            }
            if (completed) try self.write(&.{
                facts.callSettled(.{ .callId = call_id, .outcome = "completed" }),
                facts.taskEnded(.{ .taskId = task_id, .outcome = "completed" }),
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
            var encoded: std.Io.Writer.Allocating = .init(self.alloc);
            defer encoded.deinit();
            try encoded.writer.writeAll("{\"at\":\"1970-01-01T00:00:00.000Z\",\"facts\":");
            try std.json.Stringify.value(committed.items, .{ .emit_null_optional_fields = false }, &encoded.writer);
            try encoded.writer.writeAll("}\n");
            if (self.file) |file| try file.writeStreamingAll(io_mod.getIo(), encoded.written());
            if (self.report_file) |file| try file.writeStreamingAll(io_mod.getIo(), encoded.written());
        }

        fn id(self: *Self, prefix: []const u8, number: u64) ![]const u8 {
            const value = try self.alloc.print("{s}_{d}", .{ prefix, number });
            try self.owned_ids.append(self.alloc, value);
            return value;
        }

        fn idWithSuffix(self: *Self, prefix: []const u8, suffix: []const u8) ![]const u8 {
            const value = try self.alloc.print("{s}_{s}", .{ prefix, suffix });
            try self.owned_ids.append(self.alloc, value);
            return value;
        }

        fn copyId(self: *Self, source: []const u8) ![]const u8 {
            const value = try self.alloc.dupe(u8, source);
            try self.owned_ids.append(self.alloc, value);
            return value;
        }

        fn knownId(self: *Self, source: []const u8) ![]const u8 {
            for (self.owned_ids.items) |value| if (std.mem.eql(u8, value, source)) return value;
            return self.copyId(source);
        }
    };
}
