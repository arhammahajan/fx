const std = @import("std");
const catalog = @import("catalog.zig");

pub const Scope = struct {
    turnId: ?[]const u8 = null,
    taskId: ?[]const u8 = null,
    runId: ?[]const u8 = null,
    changeId: ?[]const u8 = null,
};

pub const Cause = struct {
    deliveryId: ?[]const u8 = null,
    turnId: ?[]const u8 = null,
    taskId: ?[]const u8 = null,
    callId: ?[]const u8 = null,
    interactionId: ?[]const u8 = null,
    responseId: ?[]const u8 = null,
    changeId: ?[]const u8 = null,
    policy: ?[]const u8 = null,
    hook: ?[]const u8 = null,
};

pub const ErrorInfo = struct {
    name: ?[]const u8 = null,
    code: []const u8,
    message: []const u8,
    id: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

pub const Owner = struct {
    turnId: ?[]const u8 = null,
    changeId: ?[]const u8 = null,
    runId: ?[]const u8 = null,
    callId: ?[]const u8 = null,
    taskId: ?[]const u8 = null,
};

pub const Usage = struct {
    inputTokens: u64 = 0,
    outputTokens: u64 = 0,
    cacheReadTokens: u64 = 0,
    cacheWriteTokens: u64 = 0,
    costUsd: ?f64 = null,
};

pub const ValueReference = struct {
    ref: ?[]const u8 = null,
    mediaType: ?[]const u8 = null,
    size: ?u64 = null,
    preview: ?[]const u8 = null,
    withheld: ?bool = null,
};

pub const Capability = struct {
    kind: []const u8,
    name: []const u8,
    label: ?[]const u8 = null,
    remote: ?bool = null,
};

pub const SessionStarted = struct { parent: ?std.json.Value = null, predecessor: ?std.json.Value = null, runtime: ?std.json.Value = null, trace: ?std.json.Value = null };
pub const SessionEnded = struct { outcome: []const u8, cause: ?Cause = null, @"error": ?ErrorInfo = null };
pub const DeliveryAdmitted = struct { deliveryId: []const u8, principal: ?std.json.Value = null, source: ?std.json.Value = null, clientContext: ?std.json.Value = null };
pub const DeliveryConsumed = struct { deliveryId: []const u8, turnId: []const u8, parts: []const std.json.Value, history: ?[]const std.json.Value = null };
pub const DeliverySettled = struct { deliveryId: []const u8, outcome: []const u8, turnId: ?[]const u8 = null, reason: ?[]const u8 = null };
pub const TurnStarted = struct { turnId: []const u8, cause: Cause, follows: std.json.Value, trace: ?std.json.Value = null };
pub const Awaiting = struct { interactionId: []const u8 };
pub const TurnPaused = struct { turnId: []const u8, awaiting: []const Awaiting };
pub const TurnSettled = struct { turnId: []const u8, outcome: []const u8, reply: ?[]const []const u8 = null, cause: ?Cause = null, @"error": ?ErrorInfo = null };
pub const ModelRequested = struct { runId: []const u8, owner: Owner };
pub const ModelStarted = struct { runId: []const u8, modelId: []const u8, attempt: u32 };
pub const ModelRetried = struct { runId: []const u8, attempt: u32, @"error": ErrorInfo };
pub const ModelSettled = struct { runId: []const u8, outcome: []const u8, finishReason: ?[]const u8 = null, generationId: ?[]const u8 = null, @"error": ?ErrorInfo = null };
pub const ContentCompleted = struct { partId: []const u8, runId: []const u8, kind: []const u8, value: ?std.json.Value = null, valueRef: ?ValueReference = null, phase: []const u8, interrupted: ?bool = null, mediaType: ?[]const u8 = null, fallbackText: ?[]const u8 = null };
pub const CallRequested = struct { callId: []const u8, owner: Owner, capability: Capability, input: ?std.json.Value = null, inputRef: ?ValueReference = null, inputError: ?ErrorInfo = null };
pub const CallStarted = struct { callId: []const u8, clearedBy: ?std.json.Value = null, taskId: ?[]const u8 = null };
pub const CallSettled = struct { callId: []const u8, outcome: []const u8, output: ?std.json.Value = null, outputRef: ?ValueReference = null, outputOf: ?std.json.Value = null, @"error": ?ErrorInfo = null, reason: ?[]const u8 = null, cause: ?Cause = null, label: ?[]const u8 = null };
pub const TaskStarted = struct { taskId: []const u8, startedBy: Owner, kind: []const u8, name: []const u8 };
pub const TaskEnded = struct { taskId: []const u8, outcome: []const u8, reason: ?[]const u8 = null, @"error": ?ErrorInfo = null };
pub const InteractionOpened = struct { interactionId: []const u8, subject: Owner, request: std.json.Value, origin: ?std.json.Value = null, audience: ?std.json.Value = null };
pub const InteractionSettled = struct { interactionId: []const u8, outcome: []const u8, reason: ?[]const u8 = null, cause: ?Cause = null, response: ?std.json.Value = null };
pub const ResponseSubmitted = struct { responseId: []const u8, interactionId: []const u8, deliveryId: []const u8, value: ?std.json.Value = null };
pub const ResponseAdmitted = struct { responseId: []const u8 };
pub const ResponseSettled = struct { responseId: []const u8, outcome: []const u8, reason: ?[]const u8 = null };
pub const ChildOpened = struct { sessionId: []const u8, owner: Owner, name: []const u8, stream: []const u8 };
pub const ContextStarted = struct { changeId: []const u8, kind: []const u8, turnId: ?[]const u8 = null, cause: ?Cause = null, trigger: ?std.json.Value = null };
pub const ContextSettled = struct { changeId: []const u8, kind: []const u8, outcome: []const u8, selects: ?std.json.Value = null, @"error": ?ErrorInfo = null };
pub const UsageRecorded = struct { owner: ?Owner = null, kind: []const u8, usage: Usage };

pub const Data = union(catalog.FactType) {
    call_requested: CallRequested,
    call_settled: CallSettled,
    call_started: CallStarted,
    child_opened: ChildOpened,
    content_completed: ContentCompleted,
    context_settled: ContextSettled,
    context_started: ContextStarted,
    delivery_admitted: DeliveryAdmitted,
    delivery_consumed: DeliveryConsumed,
    delivery_settled: DeliverySettled,
    interaction_opened: InteractionOpened,
    interaction_settled: InteractionSettled,
    model_requested: ModelRequested,
    model_retried: ModelRetried,
    model_settled: ModelSettled,
    model_started: ModelStarted,
    response_admitted: ResponseAdmitted,
    response_settled: ResponseSettled,
    response_submitted: ResponseSubmitted,
    session_ended: SessionEnded,
    session_started: SessionStarted,
    task_ended: TaskEnded,
    task_started: TaskStarted,
    turn_paused: TurnPaused,
    turn_settled: TurnSettled,
    turn_started: TurnStarted,
    usage_recorded: UsageRecorded,
};

pub const Fact = struct {
    scope: ?Scope = null,
    data: Data,

    pub fn factType(self: Fact) catalog.FactType {
        return std.meta.activeTag(self.data);
    }

    pub fn jsonStringify(self: Fact, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("type");
        try writer.write(self.factType().wireName());
        if (self.scope) |scope| {
            try writer.objectField("scope");
            try writer.write(scope);
        }
        try writer.objectField("data");
        switch (self.data) {
            inline else => |payload| try writer.write(payload),
        }
        try writer.endObject();
    }
};

fn make(comptime tag: catalog.FactType, payload: anytype) Fact {
    return .{ .data = @unionInit(Data, @tagName(tag), payload) };
}

pub fn sessionStarted(data: SessionStarted) Fact {
    return make(.session_started, data);
}
pub fn sessionEnded(data: SessionEnded) Fact {
    return make(.session_ended, data);
}
pub fn deliveryAdmitted(data: DeliveryAdmitted) Fact {
    return make(.delivery_admitted, data);
}
pub fn deliveryConsumed(data: DeliveryConsumed) Fact {
    return make(.delivery_consumed, data);
}
pub fn deliverySettled(data: DeliverySettled) Fact {
    return make(.delivery_settled, data);
}
pub fn turnStarted(data: TurnStarted) Fact {
    return make(.turn_started, data);
}
pub fn turnPaused(data: TurnPaused) Fact {
    return make(.turn_paused, data);
}
pub fn turnSettled(data: TurnSettled) Fact {
    return make(.turn_settled, data);
}
pub fn modelRequested(data: ModelRequested) Fact {
    return make(.model_requested, data);
}
pub fn modelStarted(data: ModelStarted) Fact {
    return make(.model_started, data);
}
pub fn modelRetried(data: ModelRetried) Fact {
    return make(.model_retried, data);
}
pub fn modelSettled(data: ModelSettled) Fact {
    return make(.model_settled, data);
}
pub fn contentCompleted(data: ContentCompleted) Fact {
    return make(.content_completed, data);
}
pub fn callRequested(data: CallRequested) Fact {
    return make(.call_requested, data);
}
pub fn callStarted(data: CallStarted) Fact {
    return make(.call_started, data);
}
pub fn callSettled(data: CallSettled) Fact {
    return make(.call_settled, data);
}
pub fn taskStarted(data: TaskStarted) Fact {
    return make(.task_started, data);
}
pub fn taskEnded(data: TaskEnded) Fact {
    return make(.task_ended, data);
}
pub fn interactionOpened(data: InteractionOpened) Fact {
    return make(.interaction_opened, data);
}
pub fn interactionSettled(data: InteractionSettled) Fact {
    return make(.interaction_settled, data);
}
pub fn responseSubmitted(data: ResponseSubmitted) Fact {
    return make(.response_submitted, data);
}
pub fn responseAdmitted(data: ResponseAdmitted) Fact {
    return make(.response_admitted, data);
}
pub fn responseSettled(data: ResponseSettled) Fact {
    return make(.response_settled, data);
}
pub fn childOpened(data: ChildOpened) Fact {
    return make(.child_opened, data);
}
pub fn contextStarted(data: ContextStarted) Fact {
    return make(.context_started, data);
}
pub fn contextSettled(data: ContextSettled) Fact {
    return make(.context_settled, data);
}
pub fn usageRecorded(data: UsageRecorded) Fact {
    return make(.usage_recorded, data);
}

pub fn encodeAlloc(alloc: std.mem.Allocator, fact: Fact) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, fact, .{ .emit_null_optional_fields = false });
}

/// Decodes one persisted fact. Returned slices and JSON values belong to
/// `arena` and remain valid for its lifetime.
pub fn decode(arena: std.mem.Allocator, raw: []const u8) !Fact {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .allocate = .alloc_always });
    const object = switch (parsed) {
        .object => |value| value,
        else => return error.BadFact,
    };
    const type_value = object.get("type") orelse return error.BadFact;
    const type_name = switch (type_value) {
        .string => |value| value,
        else => return error.BadFact,
    };
    const fact_type = catalog.FactType.parse(type_name) orelse return error.UnknownFact;
    const data_value = object.get("data") orelse return error.BadFact;
    const data: Data = switch (fact_type) {
        .call_requested => .{ .call_requested = try std.json.parseFromValueLeaky(CallRequested, arena, data_value, .{}) },
        .call_settled => .{ .call_settled = try std.json.parseFromValueLeaky(CallSettled, arena, data_value, .{}) },
        .call_started => .{ .call_started = try std.json.parseFromValueLeaky(CallStarted, arena, data_value, .{}) },
        .child_opened => .{ .child_opened = try std.json.parseFromValueLeaky(ChildOpened, arena, data_value, .{}) },
        .content_completed => .{ .content_completed = try std.json.parseFromValueLeaky(ContentCompleted, arena, data_value, .{}) },
        .context_settled => .{ .context_settled = try std.json.parseFromValueLeaky(ContextSettled, arena, data_value, .{}) },
        .context_started => .{ .context_started = try std.json.parseFromValueLeaky(ContextStarted, arena, data_value, .{}) },
        .delivery_admitted => .{ .delivery_admitted = try std.json.parseFromValueLeaky(DeliveryAdmitted, arena, data_value, .{}) },
        .delivery_consumed => .{ .delivery_consumed = try std.json.parseFromValueLeaky(DeliveryConsumed, arena, data_value, .{}) },
        .delivery_settled => .{ .delivery_settled = try std.json.parseFromValueLeaky(DeliverySettled, arena, data_value, .{}) },
        .interaction_opened => .{ .interaction_opened = try std.json.parseFromValueLeaky(InteractionOpened, arena, data_value, .{}) },
        .interaction_settled => .{ .interaction_settled = try std.json.parseFromValueLeaky(InteractionSettled, arena, data_value, .{}) },
        .model_requested => .{ .model_requested = try std.json.parseFromValueLeaky(ModelRequested, arena, data_value, .{}) },
        .model_retried => .{ .model_retried = try std.json.parseFromValueLeaky(ModelRetried, arena, data_value, .{}) },
        .model_settled => .{ .model_settled = try std.json.parseFromValueLeaky(ModelSettled, arena, data_value, .{}) },
        .model_started => .{ .model_started = try std.json.parseFromValueLeaky(ModelStarted, arena, data_value, .{}) },
        .response_admitted => .{ .response_admitted = try std.json.parseFromValueLeaky(ResponseAdmitted, arena, data_value, .{}) },
        .response_settled => .{ .response_settled = try std.json.parseFromValueLeaky(ResponseSettled, arena, data_value, .{}) },
        .response_submitted => .{ .response_submitted = try std.json.parseFromValueLeaky(ResponseSubmitted, arena, data_value, .{}) },
        .session_ended => .{ .session_ended = try std.json.parseFromValueLeaky(SessionEnded, arena, data_value, .{}) },
        .session_started => .{ .session_started = try std.json.parseFromValueLeaky(SessionStarted, arena, data_value, .{}) },
        .task_ended => .{ .task_ended = try std.json.parseFromValueLeaky(TaskEnded, arena, data_value, .{}) },
        .task_started => .{ .task_started = try std.json.parseFromValueLeaky(TaskStarted, arena, data_value, .{}) },
        .turn_paused => .{ .turn_paused = try std.json.parseFromValueLeaky(TurnPaused, arena, data_value, .{}) },
        .turn_settled => .{ .turn_settled = try std.json.parseFromValueLeaky(TurnSettled, arena, data_value, .{}) },
        .turn_started => .{ .turn_started = try std.json.parseFromValueLeaky(TurnStarted, arena, data_value, .{}) },
        .usage_recorded => .{ .usage_recorded = try std.json.parseFromValueLeaky(UsageRecorded, arena, data_value, .{}) },
    };
    const scope = if (object.get("scope")) |value| try std.json.parseFromValueLeaky(Scope, arena, value, .{}) else null;
    return .{ .scope = scope, .data = data };
}

test "fact builders use eve names and omit absent fields" {
    const encoded = try encodeAlloc(std.testing.allocator, modelSettled(.{ .runId = "run_0", .outcome = "completed" }));
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{\"type\":\"model.settled\",\"data\":{\"runId\":\"run_0\",\"outcome\":\"completed\"}}", encoded);
}

test "decoded facts do not borrow their input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "{\"type\":\"model.started\",\"data\":{\"runId\":\"run_0\",\"modelId\":\"provider/model\",\"attempt\":0}}";
    var raw: [source.len]u8 = undefined;
    @memcpy(&raw, source);
    const decoded = try decode(arena.allocator(), &raw);
    @memset(&raw, 'x');
    try std.testing.expectEqualStrings("run_0", decoded.data.model_started.runId);
    try std.testing.expectEqualStrings("provider/model", decoded.data.model_started.modelId);
}
