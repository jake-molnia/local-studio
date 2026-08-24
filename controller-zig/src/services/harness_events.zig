const std = @import("std");

const Io = std.Io;

pub fn writeStreamEnvelope(allocator: std.mem.Allocator, writer: *Io.Writer, harness: []const u8, sequence: u64, document: []const u8) !void {
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(if (std.mem.eql(u8, harness, "pi")) "pi" else "harness", .{}, writer);
    try writer.writeAll(",\"harness\":");
    try std.json.Stringify.value(harness, .{}, writer);
    try writer.print(",\"seq\":{d},\"normalized\":", .{sequence});
    try writeNormalized(allocator, writer, harness, document);
    try writer.writeAll(",\"event\":");
    try writeCanonical(allocator, writer, harness, document);
    try writer.writeAll(",\"native\":");
    try writer.writeAll(document);
    try writer.writeByte('}');
}

pub fn canonicalDocument(allocator: std.mem.Allocator, harness: []const u8, document: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeCanonical(allocator, &output.writer, harness, document);
    return output.toOwnedSlice();
}

pub fn writeCanonical(allocator: std.mem.Allocator, writer: *Io.Writer, harness: []const u8, document: []const u8) !void {
    if (!std.mem.eql(u8, harness, "fx")) return writer.writeAll(document);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return writer.writeAll(document);
    defer parsed.deinit();
    if (parsed.value != .object) return writer.writeAll(document);
    const object = parsed.value.object;
    const method = stringField(object, "method");
    if (method) |value| if (std.mem.eql(u8, value, "session/update")) {
        const params = object.get("params") orelse return writer.writeAll(document);
        if (params != .object) return writer.writeAll(document);
        const update = params.object.get("update") orelse return writer.writeAll(document);
        if (update != .object) return writer.writeAll(document);
        const update_type = stringField(update.object, "sessionUpdate") orelse return writer.writeAll(document);
        if (std.mem.eql(u8, update_type, "agent_message_chunk")) {
            const text = contentText(update.object) orelse "";
            try writer.writeAll("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":");
            try std.json.Stringify.value(text, .{}, writer);
            try writer.writeAll("}}");
            return;
        }
        if (std.mem.eql(u8, update_type, "user_message_chunk")) {
            const text = contentText(update.object) orelse "";
            try writer.writeAll("{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(text, .{}, writer);
            try writer.writeAll("}]}}");
            return;
        }
        if (std.mem.eql(u8, update_type, "tool_call")) {
            try writer.writeAll("{\"type\":\"tool_execution_start\",\"toolCallId\":");
            try std.json.Stringify.value(stringField(update.object, "toolCallId") orelse "", .{}, writer);
            try writer.writeAll(",\"toolName\":");
            try std.json.Stringify.value(stringField(update.object, "title") orelse "tool", .{}, writer);
            try writer.writeByte('}');
            return;
        }
        if (std.mem.eql(u8, update_type, "tool_call_update")) {
            const status = stringField(update.object, "status") orelse "in_progress";
            const finished = std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed");
            try writer.writeAll("{\"type\":");
            try std.json.Stringify.value(if (finished) "tool_execution_end" else "tool_execution_update", .{}, writer);
            try writer.writeAll(",\"toolCallId\":");
            try std.json.Stringify.value(stringField(update.object, "toolCallId") orelse "", .{}, writer);
            try writer.writeAll(",\"isError\":");
            try writer.writeAll(if (std.mem.eql(u8, status, "failed")) "true" else "false");
            if (toolUpdateText(update.object)) |text| {
                try writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(text, .{}, writer);
                try writer.writeAll("}]}");
            }
            try writer.writeByte('}');
            return;
        }
        return writer.writeAll(document);
    };
    if (object.get("result") != null or object.get("error") != null) return writer.writeAll("{\"type\":\"agent_settled\"}");
    return writer.writeAll(document);
}

pub fn writeNormalized(allocator: std.mem.Allocator, writer: *Io.Writer, harness: []const u8, document: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch {
        try writer.writeAll("null");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try writer.writeAll("null");
        return;
    }
    if (std.mem.eql(u8, harness, "fx")) return writeAcpNormalized(writer, parsed.value.object);
    const native_type = stringField(parsed.value.object, "type") orelse {
        try writer.writeAll("null");
        return;
    };
    const kind = normalizedKind(parsed.value.object, native_type);
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(kind, .{}, writer);
    try writer.writeAll(",\"harness\":");
    try std.json.Stringify.value(harness, .{}, writer);
    try writer.writeAll(",\"nativeType\":");
    try std.json.Stringify.value(native_type, .{}, writer);
    try writer.writeByte('}');
}

fn writeAcpNormalized(writer: *Io.Writer, object: std.json.ObjectMap) !void {
    const method = stringField(object, "method");
    if (method) |value| if (std.mem.eql(u8, value, "session/update")) {
        const params = object.get("params") orelse return writer.writeAll("null");
        if (params != .object) return writer.writeAll("null");
        const update = params.object.get("update") orelse return writer.writeAll("null");
        if (update != .object) return writer.writeAll("null");
        const native_type = stringField(update.object, "sessionUpdate") orelse return writer.writeAll("null");
        const kind = if (std.mem.eql(u8, native_type, "agent_message_chunk"))
            "message.delta"
        else if (std.mem.eql(u8, native_type, "tool_call"))
            "tool.started"
        else if (std.mem.eql(u8, native_type, "tool_call_update"))
            "tool.updated"
        else
            "session.updated";
        try writer.writeAll("{\"type\":");
        try std.json.Stringify.value(kind, .{}, writer);
        try writer.writeAll(",\"harness\":\"fx\",\"nativeType\":");
        try std.json.Stringify.value(native_type, .{}, writer);
        try writer.writeByte('}');
        return;
    };
    const kind = if (object.get("error") != null) "session.failed" else if (object.get("result") != null) "turn.completed" else return writer.writeAll("null");
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(kind, .{}, writer);
    try writer.writeAll(",\"harness\":\"fx\",\"nativeType\":\"jsonrpc_response\"}");
}

fn normalizedKind(object: std.json.ObjectMap, native_type: []const u8) []const u8 {
    if (std.mem.eql(u8, native_type, "turn_start")) return "turn.started";
    if (std.mem.eql(u8, native_type, "agent_settled")) return "turn.completed";
    if (std.mem.eql(u8, native_type, "tool_execution_start")) return "tool.started";
    if (std.mem.eql(u8, native_type, "tool_execution_update")) return "tool.updated";
    if (std.mem.eql(u8, native_type, "tool_execution_end")) return "tool.completed";
    if (std.mem.eql(u8, native_type, "extension_ui_request")) return "approval.requested";
    if (std.mem.eql(u8, native_type, "extension_error")) return "session.failed";
    if (std.mem.eql(u8, native_type, "message_update")) {
        const event = object.get("assistantMessageEvent") orelse return "message.updated";
        if (event != .object) return "message.updated";
        const delta_type = stringField(event.object, "type") orelse return "message.updated";
        if (std.mem.eql(u8, delta_type, "text_delta")) return "message.delta";
        if (std.mem.eql(u8, delta_type, "thinking_delta")) return "thinking.delta";
        if (std.mem.startsWith(u8, delta_type, "toolcall_")) return "tool.updated";
        return "message.updated";
    }
    return "native.event";
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn contentText(object: std.json.ObjectMap) ?[]const u8 {
    const content = object.get("content") orelse return null;
    if (content != .object) return null;
    return stringField(content.object, "text");
}

fn toolUpdateText(object: std.json.ObjectMap) ?[]const u8 {
    const content = object.get("content") orelse return null;
    if (content != .array) return null;
    for (content.array.items) |item| {
        if (item != .object) continue;
        const nested = item.object.get("content") orelse continue;
        if (nested != .object) continue;
        if (stringField(nested.object, "text")) |text| return text;
    }
    return null;
}
