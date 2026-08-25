const std = @import("std");
const repository = @import("../repository/account_store.zig");
const sqlite = @import("../repository/sqlite.zig");
const agent_connectors = @import("agent_connectors.zig");
const code_storage_auth = @import("code_storage_auth.zig");
const harness_nodes = @import("harness_nodes.zig");
const node_transport = @import("node_transport.zig");

const Io = std.Io;
const http = std.http;

pub const State = struct {
    allocator: std.mem.Allocator,
    io: Io,
    data_dir: []u8,
    environment: *const std.process.Environ.Map,
    mutex: Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: Io, data_dir: []const u8, environment: *const std.process.Environ.Map) !State {
        return .{ .allocator = allocator, .io = io, .data_dir = try allocator.dupe(u8, data_dir), .environment = environment };
    }

    pub fn deinit(state: *State) void {
        state.allocator.free(state.data_dir);
        state.* = undefined;
    }

    pub fn accountPayload(state: *State) ![]u8 {
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        var store = try repository.load(state.allocator, state.io, state.data_dir);
        defer store.deinit();
        return writeAccounts(state.allocator, &store);
    }

    pub fn credentialStorePayload(state: *State) ![]u8 {
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        var store = try repository.load(state.allocator, state.io, state.data_dir);
        defer store.deinit();
        return writeCredentialStore(state.allocator, store.secret_provider);
    }

    pub fn updateCredentialStorePayload(state: *State, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, state.allocator, document, .{}) catch return error.InvalidCredentialStorePayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCredentialStorePayload;
        const provider = stringField(parsed.value.object, "provider") orelse return error.SecretProviderRequired;
        try validateSecretProvider(provider);
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        var store = try repository.load(state.allocator, state.io, state.data_dir);
        defer store.deinit();
        try repository.migrateSecretProvider(state.allocator, state.io, state.environment, state.data_dir, &store, provider);
        return writeCredentialStore(state.allocator, store.secret_provider);
    }

    pub fn connectPayload(state: *State, database: *sqlite.Database, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, state.allocator, document, .{}) catch return error.InvalidCodeStorageAccountPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCodeStorageAccountPayload;
        const organization = stringField(parsed.value.object, "organization") orelse return error.CodeStorageOrganizationRequired;
        const private_key = stringField(parsed.value.object, "privateKey") orelse return error.CodeStoragePrivateKeyRequired;
        const label = stringField(parsed.value.object, "label") orelse organization;
        try code_storage_auth.validateOrganization(organization);
        try code_storage_auth.validatePrivateKey(state.allocator, private_key);
        const id_buffer = repository.accountId("code-storage", organization, private_key);
        const secret_ref = try std.fmt.allocPrint(state.allocator, "CODE_STORAGE_PRIVATE_KEY_{s}", .{id_buffer});
        defer state.allocator.free(secret_ref);
        var timestamp_buffer: [24]u8 = undefined;
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        var store = try repository.load(state.allocator, state.io, state.data_dir);
        defer store.deinit();
        const secret_provider = store.secret_provider;
        try validateSecretProvider(secret_provider);
        var account = store.find(&id_buffer);
        if (account == null) {
            try store.accounts.append(state.allocator, .{
                .allocator = state.allocator,
                .id = try state.allocator.dupe(u8, &id_buffer),
                .provider = try state.allocator.dupe(u8, "code-storage"),
                .subject = try state.allocator.dupe(u8, organization),
                .label = try state.allocator.dupe(u8, label),
                .credential_kind = try state.allocator.dupe(u8, "pkcs8-pem"),
                .secret_provider = try state.allocator.dupe(u8, secret_provider),
                .secret_ref = try state.allocator.dupe(u8, secret_ref),
                .connected_at = try state.allocator.dupe(u8, formatTimestamp(state.io, &timestamp_buffer)),
            });
            account = &store.accounts.items[store.accounts.items.len - 1];
        } else if (!std.mem.eql(u8, account.?.label, label)) {
            state.allocator.free(account.?.label);
            account.?.label = try state.allocator.dupe(u8, label);
        }
        try repository.setSecret(state.allocator, state.io, state.environment, state.data_dir, &store, account.?.secret_ref, account.?.secret_provider, private_key);
        try repository.save(state.allocator, state.io, state.data_dir, &store);
        try agent_connectors.connectCodeStorageLocal(state.allocator, state.io, database, account.?.id, account.?.subject, account.?.label);
        return writeAccounts(state.allocator, &store);
    }

    pub fn disconnectPayload(state: *State, database: *sqlite.Database, account_id: []const u8) ![]u8 {
        if (!repository.validId(account_id)) return error.CodeStorageAccountRequired;
        try state.mutex.lock(state.io);
        defer state.mutex.unlock(state.io);
        var store = try repository.load(state.allocator, state.io, state.data_dir);
        defer store.deinit();
        var index: ?usize = null;
        for (store.accounts.items, 0..) |account, account_index| if (std.mem.eql(u8, account.id, account_id) and std.mem.eql(u8, account.provider, "code-storage")) {
            index = account_index;
            break;
        };
        const account_index = index orelse return error.CodeStorageAccountNotFound;
        const account = &store.accounts.items[account_index];
        try repository.deleteSecret(state.allocator, state.io, state.environment, state.data_dir, &store, account.secret_ref, account.secret_provider);
        try agent_connectors.disconnectCodeStorageLocal(state.allocator, state.io, database, account.id);
        var removed = store.accounts.orderedRemove(account_index);
        removed.deinit();
        try repository.save(state.allocator, state.io, state.data_dir, &store);
        return writeAccounts(state.allocator, &store);
    }
};

pub fn forward(allocator: std.mem.Allocator, io: Io, client: *http.Client, database: *sqlite.Database, path: []const u8, method: http.Method, document: ?[]const u8) ![]u8 {
    var target = (try harness_nodes.selectCapability(allocator, io, database, "mcp", null)) orelse return error.ConnectorNodeRequired;
    defer target.deinit();
    return if (method == .GET)
        node_transport.get(allocator, client, &target, path)
    else
        node_transport.send(allocator, client, &target, path, method, document);
}

pub fn validAccountId(value: []const u8) bool {
    return repository.validId(value);
}

fn writeAccounts(allocator: std.mem.Allocator, store: *repository.Store) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"accounts\":[");
    var wrote = false;
    for (store.accounts.items) |account| {
        if (!std.mem.eql(u8, account.provider, "code-storage")) continue;
        if (wrote) try output.writer.writeByte(',');
        wrote = true;
        try output.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(account.id, .{}, &output.writer);
        try output.writer.writeAll(",\"organization\":");
        try std.json.Stringify.value(account.subject, .{}, &output.writer);
        try output.writer.writeAll(",\"label\":");
        try std.json.Stringify.value(account.label, .{}, &output.writer);
        try output.writer.writeAll(",\"connectedAt\":");
        try std.json.Stringify.value(account.connected_at, .{}, &output.writer);
        try output.writer.writeAll(",\"connectorId\":\"account-code-storage-");
        try output.writer.writeAll(account.id);
        try output.writer.writeAll("\",\"secretProvider\":");
        try std.json.Stringify.value(account.secret_provider, .{}, &output.writer);
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn writeCredentialStore(allocator: std.mem.Allocator, provider: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"provider\":");
    try std.json.Stringify.value(provider, .{}, &output.writer);
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn formatTimestamp(io: Io, buffer: *[24]u8) []const u8 {
    const seconds = Io.Clock.real.now(io).toSeconds();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() }) catch unreachable;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len == 0 or trimmed.len > 512 * 1024) null else trimmed;
}

pub fn validateSecretProvider(value: []const u8) !void {
    if (value.len == 0 or value.len > 512 or value[0] == '-') return error.InvalidSecretProvider;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e or byte == '"' or byte == '\'' or byte == '\\') return error.InvalidSecretProvider;
}
