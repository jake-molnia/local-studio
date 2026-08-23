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
    try writer.writeAll(document);
    try writer.writeAll(",\"native\":");
    try writer.writeAll(document);
    try writer.writeByte('}');
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
