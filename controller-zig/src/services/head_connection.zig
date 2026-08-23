const std = @import("std");
const repository = @import("../repository/head_connection.zig");

const Io = std.Io;

pub fn payload(allocator: std.mem.Allocator, io: Io, data_dir: []const u8) ![]u8 {
    var connection = try repository.load(allocator, io, data_dir);
    defer if (connection) |*value| value.deinit();
    if (connection == null) return allocator.dupe(u8, "{\"connected\":false,\"name\":null,\"url\":null,\"hasApiKey\":false}");
    return response(allocator, &connection.?);
}

pub fn updatePayload(allocator: std.mem.Allocator, io: Io, data_dir: []const u8, document: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, document, .{}) catch return error.InvalidHeadConnection;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHeadConnection;
    const name = optionalString(parsed.value.object, "name") orelse "Studio Head";
    const raw_url = optionalString(parsed.value.object, "url") orelse return error.HeadUrlRequired;
    const api_key = optionalString(parsed.value.object, "apiKey") orelse "local-studio";
    const url = try normalizeUrl(allocator, raw_url);
    defer allocator.free(url);
    try repository.save(allocator, io, data_dir, name, url, api_key);
    var connection = (try repository.load(allocator, io, data_dir)) orelse return error.HeadConnectionWriteFailed;
    defer connection.deinit();
    return response(allocator, &connection);
}

pub fn deletePayload(allocator: std.mem.Allocator, io: Io, data_dir: []const u8) ![]u8 {
    try repository.remove(allocator, io, data_dir);
    return allocator.dupe(u8, "{\"success\":true,\"connected\":false}");
}

fn response(allocator: std.mem.Allocator, connection: *const repository.Connection) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"connected\":true,\"name\":");
    try std.json.Stringify.value(connection.name, .{}, &output.writer);
    try output.writer.writeAll(",\"url\":");
    try std.json.Stringify.value(connection.url, .{}, &output.writer);
    try output.writer.print(",\"hasApiKey\":{}}}", .{connection.api_key.len > 0});
    return output.toOwnedSlice();
}

fn normalizeUrl(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, value, " \t\r\n"), "/");
    if (trimmed.len == 0) return error.InvalidHeadUrl;
    const uri = std.Uri.parse(trimmed) catch return error.InvalidHeadUrl;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null) return error.InvalidHeadUrl;
    return allocator.dupe(u8, trimmed);
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}
