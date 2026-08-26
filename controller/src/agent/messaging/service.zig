const std = @import("std");
const config = @import("../../app/config.zig");
const account_repository = @import("../../accounts/store.zig");
const repository = @import("store.zig");
const coordinator = @import("../sessions/coordinator.zig");
const run_completion = @import("../sessions/run_completion.zig");
const harness_runtime = @import("../harness/runtime.zig");
const sqlite = @import("../../storage/sqlite.zig");

const Io = std.Io;
const http = std.http;
const max_response_bytes = 8 * 1024 * 1024;

const BotAccount = struct {
    allocator: std.mem.Allocator,
    id: []u8,

    fn deinit(account: *BotAccount) void {
        account.allocator.free(account.id);
        account.* = undefined;
    }
};

const BotAccountList = struct {
    allocator: std.mem.Allocator,
    accounts: std.ArrayList(BotAccount) = .empty,

    fn deinit(list: *BotAccountList) void {
        for (list.accounts.items) |*account| account.deinit();
        list.accounts.deinit(list.allocator);
        list.* = undefined;
    }
};

const BotConfiguration = struct {
    allocator: std.mem.Allocator,
    token: []u8,
    public_key: ?[]u8,

    fn deinit(configuration: *BotConfiguration) void {
        configuration.allocator.free(configuration.token);
        if (configuration.public_key) |value| configuration.allocator.free(value);
        configuration.* = undefined;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: Io,
    data_dir: []u8,
    environment: *const std.process.Environ.Map,

    pub fn init(allocator: std.mem.Allocator, io: Io, data_dir: []const u8, environment: *const std.process.Environ.Map) !Manager {
        return .{ .allocator = allocator, .io = io, .data_dir = try allocator.dupe(u8, data_dir), .environment = environment };
    }

    pub fn deinit(manager: *Manager) void {
        manager.allocator.free(manager.data_dir);
        manager.* = undefined;
    }

    pub fn runTelegramPoller(manager: *Manager, client: *http.Client, database: *sqlite.Database) Io.Cancelable!void {
        while (true) {
            var accounts = manager.botAccounts("telegram") catch |failure| {
                std.log.warn("Telegram account discovery failed: {t}", .{failure});
                try manager.io.sleep(.fromSeconds(5), .awake);
                continue;
            };
            defer accounts.deinit();
            for (accounts.accounts.items) |account| manager.pollTelegram(client, database, account.id) catch |failure| std.log.warn("Telegram polling failed for account {s}: {t}", .{ account.id, failure });
            try manager.io.sleep(.fromSeconds(2), .awake);
        }
    }

    pub fn runDispatcher(manager: *Manager, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager) Io.Cancelable!void {
        while (true) {
            var message = blk: {
                try database.lock(manager.io);
                defer database.unlock(manager.io);
                break :blk repository.takeNext(manager.allocator, database) catch |failure| {
                    std.log.warn("Messaging queue read failed: {t}", .{failure});
                    break :blk null;
                };
            };
            if (message == null) {
                try manager.io.sleep(.fromMilliseconds(500), .awake);
                continue;
            }
            defer message.?.deinit();
            manager.dispatch(mode, client, database, harness, &message.?) catch |failure| {
                lockedFinish(manager.io, database, message.?.id, @errorName(failure)) catch {};
                manager.sendReply(client, message.?.provider, message.?.account_id, message.?.conversation_id, "The Chat run failed. Check Local Studio and try again.") catch {};
                continue;
            };
            lockedFinish(manager.io, database, message.?.id, null) catch |failure| {
                std.log.warn("Messaging queue completion failed for {s}: {t}", .{ message.?.id, failure });
            };
        }
    }

    pub fn accessPayload(manager: *Manager, database: *sqlite.Database) ![]u8 {
        try database.lock(manager.io);
        defer database.unlock(manager.io);
        return repository.accessPayload(manager.allocator, database);
    }

    pub fn defaultsPayload(manager: *Manager, database: *sqlite.Database) ![]u8 {
        try database.lock(manager.io);
        defer database.unlock(manager.io);
        return repository.defaultsPayload(manager.allocator, database);
    }

    pub fn updateDefaultsPayload(manager: *Manager, database: *sqlite.Database, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidMessagingDefaults;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMessagingDefaults;
        const model_id = stringField(parsed.value.object, "modelId") orelse return error.MessagingModelRequired;
        const route_id = stringField(parsed.value.object, "modelRouteId") orelse return error.MessagingModelRequired;
        try database.lock(manager.io);
        defer database.unlock(manager.io);
        try repository.setDefaults(database, model_id, route_id);
        return repository.defaultsPayload(manager.allocator, database);
    }

    pub fn approvePayload(manager: *Manager, database: *sqlite.Database, document: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidPairingPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPairingPayload;
        const pairing_id = stringField(parsed.value.object, "pairingId") orelse return error.PairingIdRequired;
        const code = stringField(parsed.value.object, "code") orelse return error.PairingCodeRequired;
        try database.lock(manager.io);
        defer database.unlock(manager.io);
        try repository.approve(database, pairing_id, code);
        return repository.accessPayload(manager.allocator, database);
    }

    pub fn revokePayload(manager: *Manager, database: *sqlite.Database, provider: []const u8, account_id: []const u8, external_user_id: []const u8) ![]u8 {
        try database.lock(manager.io);
        defer database.unlock(manager.io);
        try repository.revoke(database, provider, account_id, external_user_id);
        return repository.accessPayload(manager.allocator, database);
    }

    pub fn discordInteractionPayload(manager: *Manager, database: *sqlite.Database, account_id: []const u8, timestamp: []const u8, signature: []const u8, document: []const u8) ![]u8 {
        var bot = try manager.configuration(account_id, "discord");
        defer bot.deinit();
        try verifyDiscord(manager.allocator, timestamp, signature, document, bot.public_key orelse return error.DiscordPublicKeyRequired);
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, document, .{}) catch return error.InvalidDiscordInteraction;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDiscordInteraction;
        const interaction_type = integerField(parsed.value.object, "type") orelse return error.InvalidDiscordInteraction;
        if (interaction_type == 1) return manager.allocator.dupe(u8, "{\"type\":1}");
        if (interaction_type != 2 or parsed.value.object.get("guild_id") != null) return discordResponse(manager.allocator, "Direct-message Chat commands only.");
        const data = objectField(parsed.value.object, "data") orelse return error.InvalidDiscordInteraction;
        if (!std.mem.eql(u8, stringField(data, "name") orelse "", "chat")) return discordResponse(manager.allocator, "Use the /chat command.");
        const prompt = discordPrompt(data) orelse return discordResponse(manager.allocator, "Add a prompt to /chat.");
        const user = objectField(parsed.value.object, "user") orelse return error.InvalidDiscordInteraction;
        const external_user_id = stringField(user, "id") orelse return error.InvalidDiscordInteraction;
        const label = stringField(user, "global_name") orelse stringField(user, "username");
        const channel_id = stringField(parsed.value.object, "channel_id") orelse return error.InvalidDiscordInteraction;
        const interaction_id = stringField(parsed.value.object, "id") orelse return error.InvalidDiscordInteraction;
        const decision = try manager.authorizeOrQueue(database, "discord", account_id, external_user_id, label, channel_id, interaction_id, prompt);
        defer manager.allocator.free(decision);
        return discordResponse(manager.allocator, decision);
    }

    fn pollTelegram(manager: *Manager, client: *http.Client, database: *sqlite.Database, account_id: []const u8) !void {
        var bot = try manager.configuration(account_id, "telegram");
        defer bot.deinit();
        const offset = blk: {
            try database.lock(manager.io);
            defer database.unlock(manager.io);
            break :blk try repository.cursor(manager.allocator, database, "telegram", account_id);
        };
        defer if (offset) |value| manager.allocator.free(value);
        const path = try std.fmt.allocPrint(manager.allocator, "/getUpdates?timeout=0&allowed_updates=%5B%22message%22%5D&offset={s}", .{offset orelse "0"});
        defer manager.allocator.free(path);
        const response = try telegramRequest(manager.allocator, client, bot.token, path, .GET, null);
        defer manager.allocator.free(response);
        var parsed = std.json.parseFromSlice(std.json.Value, manager.allocator, response, .{}) catch return error.InvalidTelegramResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidTelegramResponse;
        const result = parsed.value.object.get("result") orelse return error.InvalidTelegramResponse;
        if (result != .array) return error.InvalidTelegramResponse;
        var next_offset: ?i64 = null;
        for (result.array.items) |update| {
            if (update != .object) continue;
            const update_id = integerField(update.object, "update_id") orelse continue;
            next_offset = @max(next_offset orelse 0, update_id + 1);
            const message = update.object.get("message") orelse continue;
            if (message != .object) continue;
            const chat = objectField(message.object, "chat") orelse continue;
            if (!std.mem.eql(u8, stringField(chat, "type") orelse "", "private")) continue;
            const from = objectField(message.object, "from") orelse continue;
            if (booleanField(from, "is_bot") orelse false) continue;
            const prompt = stringField(message.object, "text") orelse continue;
            const user_id = integerField(from, "id") orelse continue;
            const chat_id = integerField(chat, "id") orelse continue;
            const message_id = integerField(message.object, "message_id") orelse continue;
            var user_buffer: [32]u8 = undefined;
            var chat_buffer: [32]u8 = undefined;
            var message_buffer: [32]u8 = undefined;
            const user_text = try std.fmt.bufPrint(&user_buffer, "{d}", .{user_id});
            const chat_text = try std.fmt.bufPrint(&chat_buffer, "{d}", .{chat_id});
            const message_text = try std.fmt.bufPrint(&message_buffer, "{d}", .{message_id});
            const label = stringField(from, "username") orelse stringField(from, "first_name");
            const decision = try manager.authorizeOrQueue(database, "telegram", account_id, user_text, label, chat_text, message_text, prompt);
            defer manager.allocator.free(decision);
            if (decision.len > 0) try manager.sendTelegram(client, bot.token, chat_text, decision);
        }
        if (next_offset) |value| {
            var buffer: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
            try database.lock(manager.io);
            defer database.unlock(manager.io);
            try repository.saveCursor(database, "telegram", account_id, text);
        }
    }

    fn authorizeOrQueue(manager: *Manager, database: *sqlite.Database, provider: []const u8, account_id: []const u8, external_user_id: []const u8, label: ?[]const u8, conversation_id: []const u8, external_message_id: []const u8, prompt: []const u8) ![]u8 {
        if (prompt.len > 64 * 1024) return manager.allocator.dupe(u8, "That message is too large.");
        try database.lock(manager.io);
        defer database.unlock(manager.io);
        if (!try repository.allowed(database, provider, account_id, external_user_id)) {
            return switch (try repository.requestPairing(database, manager.io, provider, account_id, external_user_id, label)) {
                .existing => manager.allocator.dupe(u8, "Pairing is waiting for local approval in Local Studio."),
                .limited => manager.allocator.dupe(u8, "Too many pairing attempts. Try again in an hour."),
                .code => |code| std.fmt.allocPrint(manager.allocator, "Pairing code: {s}\nEnter this code in Local Studio within one hour.", .{code[0..]}),
            };
        }
        if (!try repository.rateAllowed(database, provider, account_id, external_user_id)) return manager.allocator.dupe(u8, "Rate limit reached. Try again in a minute.");
        try repository.enqueue(database, manager.io, provider, account_id, external_user_id, conversation_id, external_message_id, prompt);
        return manager.allocator.dupe(u8, if (std.mem.eql(u8, provider, "discord")) "Working…" else "");
    }

    fn dispatch(manager: *Manager, mode: config.Mode, client: *http.Client, database: *sqlite.Database, harness: *harness_runtime.Manager, message: *const repository.Message) !void {
        var defaults = blk: {
            try database.lock(manager.io);
            defer database.unlock(manager.io);
            break :blk try repository.defaults(manager.allocator, database);
        };
        defer defaults.deinit();
        if (defaults.model_id.len == 0 or defaults.route_id.len == 0) return error.MessagingModelRequired;
        const session_id = try std.fmt.allocPrint(manager.allocator, "message:{s}:{s}:{s}", .{ message.provider, message.account_id, message.external_user_id });
        defer manager.allocator.free(session_id);
        var turn: Io.Writer.Allocating = .init(manager.allocator);
        defer turn.deinit();
        try turn.writer.writeAll("{\"sessionId\":");
        try std.json.Stringify.value(session_id, .{}, &turn.writer);
        try turn.writer.writeAll(",\"kind\":\"chat\",\"modelId\":");
        try std.json.Stringify.value(defaults.model_id, .{}, &turn.writer);
        try turn.writer.writeAll(",\"modelRouteId\":");
        try std.json.Stringify.value(defaults.route_id, .{}, &turn.writer);
        try turn.writer.writeAll(",\"message\":");
        try std.json.Stringify.value(message.prompt, .{}, &turn.writer);
        try turn.writer.writeAll(",\"toolAccess\":\"read\",\"browserToolEnabled\":true,\"mode\":\"prompt\"}");
        const accepted = try coordinator.turnPayload(manager.allocator, manager.io, mode, client, database, harness, turn.writer.buffered());
        manager.allocator.free(accepted);
        var result = try run_completion.wait(manager.allocator, manager.io, mode, client, database, harness, session_id, 2000);
        defer result.deinit();
        const response = if (result.failure) |failure| failure else if (std.mem.trim(u8, result.summary, " \t\r\n").len > 0) result.summary else "Chat completed without a text response.";
        try manager.sendReply(client, message.provider, message.account_id, message.conversation_id, response);
    }

    fn sendReply(manager: *Manager, client: *http.Client, provider: []const u8, account_id: []const u8, conversation_id: []const u8, message: []const u8) !void {
        var bot = try manager.configuration(account_id, provider);
        defer bot.deinit();
        if (std.mem.eql(u8, provider, "telegram")) return manager.sendTelegram(client, bot.token, conversation_id, message);
        const path = try std.fmt.allocPrint(manager.allocator, "/channels/{s}/messages", .{conversation_id});
        defer manager.allocator.free(path);
        var body: Io.Writer.Allocating = .init(manager.allocator);
        defer body.deinit();
        try body.writer.writeAll("{\"content\":");
        try std.json.Stringify.value(message[0..@min(message.len, 2000)], .{}, &body.writer);
        try body.writer.writeAll(",\"allowed_mentions\":{\"parse\":[]}}");
        const authorization = try std.fmt.allocPrint(manager.allocator, "Bot {s}", .{bot.token});
        defer manager.allocator.free(authorization);
        const response = try request(manager.allocator, client, "https://discord.com/api/v10", path, .POST, body.writer.buffered(), &.{.{ .name = "Authorization", .value = authorization }});
        manager.allocator.free(response);
    }

    fn sendTelegram(manager: *Manager, client: *http.Client, token: []const u8, chat_id: []const u8, message: []const u8) !void {
        var body: Io.Writer.Allocating = .init(manager.allocator);
        defer body.deinit();
        try body.writer.writeAll("{\"chat_id\":");
        try std.json.Stringify.value(chat_id, .{}, &body.writer);
        try body.writer.writeAll(",\"text\":");
        try std.json.Stringify.value(message[0..@min(message.len, 4096)], .{}, &body.writer);
        try body.writer.writeByte('}');
        const response = try telegramRequest(manager.allocator, client, token, "/sendMessage", .POST, body.writer.buffered());
        manager.allocator.free(response);
    }

    fn botAccounts(manager: *Manager, provider: []const u8) !BotAccountList {
        var store = try account_repository.load(manager.allocator, manager.io, manager.data_dir);
        defer store.deinit();
        var result = BotAccountList{ .allocator = manager.allocator };
        errdefer result.deinit();
        for (store.accounts.items) |account| {
            if (!std.mem.eql(u8, account.provider, provider)) continue;
            try result.accounts.append(manager.allocator, .{ .allocator = manager.allocator, .id = try manager.allocator.dupe(u8, account.id) });
        }
        return result;
    }

    fn configuration(manager: *Manager, account_id: []const u8, provider: []const u8) !BotConfiguration {
        var store = try account_repository.load(manager.allocator, manager.io, manager.data_dir);
        defer store.deinit();
        const account = store.find(account_id) orelse return error.MessagingAccountNotFound;
        if (!std.mem.eql(u8, account.provider, provider)) return error.MessagingAccountNotFound;
        const secret = try account_repository.resolveSecret(manager.allocator, manager.io, manager.environment, manager.data_dir, &store, account.secret_ref, account.secret_provider);
        defer manager.allocator.free(secret);
        var parsed_secret = std.json.parseFromSlice(std.json.Value, manager.allocator, secret, .{}) catch return error.InvalidMessagingCredential;
        defer parsed_secret.deinit();
        var parsed_configuration = std.json.parseFromSlice(std.json.Value, manager.allocator, account.configuration_json, .{}) catch return error.InvalidMessagingConfiguration;
        defer parsed_configuration.deinit();
        if (parsed_secret.value != .object or parsed_configuration.value != .object) return error.InvalidMessagingConfiguration;
        const token = stringField(parsed_secret.value.object, "token") orelse return error.InvalidMessagingCredential;
        return .{
            .allocator = manager.allocator,
            .token = try manager.allocator.dupe(u8, token),
            .public_key = if (stringField(parsed_configuration.value.object, "publicKey")) |value| try manager.allocator.dupe(u8, value) else null,
        };
    }
};

fn telegramRequest(allocator: std.mem.Allocator, client: *http.Client, token: []const u8, path: []const u8, method: http.Method, payload: ?[]const u8) ![]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}", .{token});
    defer allocator.free(endpoint);
    return request(allocator, client, endpoint, path, method, payload, &.{});
}

fn request(allocator: std.mem.Allocator, client: *http.Client, endpoint: []const u8, path: []const u8, method: http.Method, payload: ?[]const u8, extra: []const http.Header) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ endpoint, path });
    defer allocator.free(url);
    var headers: [2]http.Header = undefined;
    var count: usize = 0;
    for (extra) |header| {
        headers[count] = header;
        count += 1;
    }
    headers[count] = .{ .name = "Content-Type", .value = "application/json" };
    count += 1;
    const storage = try allocator.alloc(u8, max_response_bytes);
    errdefer allocator.free(storage);
    var output: Io.Writer = .fixed(storage);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = headers[0..count],
        .response_writer = &output,
    });
    if (response.status.class() != .success) {
        allocator.free(storage);
        return error.MessagingRequestRejected;
    }
    const result = try allocator.dupe(u8, output.buffered());
    allocator.free(storage);
    return result;
}

fn verifyDiscord(allocator: std.mem.Allocator, timestamp: []const u8, signature_hex: []const u8, document: []const u8, public_key_hex: []const u8) !void {
    if (signature_hex.len != 128 or public_key_hex.len != 64 or timestamp.len == 0 or timestamp.len > 64) return error.InvalidDiscordSignature;
    var signature_bytes: [64]u8 = undefined;
    var public_key_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&signature_bytes, signature_hex) catch return error.InvalidDiscordSignature;
    _ = std.fmt.hexToBytes(&public_key_bytes, public_key_hex) catch return error.InvalidDiscordSignature;
    const message = try std.mem.concat(allocator, u8, &.{ timestamp, document });
    defer allocator.free(message);
    const public_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key_bytes) catch return error.InvalidDiscordSignature;
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(signature_bytes);
    signature.verify(message, public_key) catch return error.InvalidDiscordSignature;
}

fn discordResponse(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"type\":4,\"data\":{\"content\":");
    try std.json.Stringify.value(content[0..@min(content.len, 2000)], .{}, &output.writer);
    try output.writer.writeAll(",\"allowed_mentions\":{\"parse\":[]}}}");
    return output.toOwnedSlice();
}

fn discordPrompt(data: std.json.ObjectMap) ?[]const u8 {
    const options = data.get("options") orelse return null;
    if (options != .array) return null;
    for (options.array.items) |option| {
        if (option != .object or !std.mem.eql(u8, stringField(option.object, "name") orelse "", "prompt")) continue;
        return stringField(option.object, "value");
    }
    return null;
}

fn lockedFinish(io: Io, database: *sqlite.Database, message_id: []const u8, failure: ?[]const u8) !void {
    try database.lock(io);
    defer database.unlock(io);
    try repository.finish(database, message_id, failure);
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    return if (trimmed.len == 0 or trimmed.len > 1024 * 1024) null else trimmed;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn booleanField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}
