const std = @import("std");
const builtin = @import("builtin");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_OPEN_READWRITE = 0x00000002;
const SQLITE_OPEN_CREATE = 0x00000004;
const SQLITE_OPEN_FULLMUTEX = 0x00010000;

const Open = *const fn ([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) callconv(.c) c_int;
const Close = *const fn (*sqlite3) callconv(.c) c_int;
const BusyTimeout = *const fn (*sqlite3, c_int) callconv(.c) c_int;
const Prepare = *const fn (*sqlite3, [*]const u8, c_int, *?*sqlite3_stmt, ?*?[*]const u8) callconv(.c) c_int;
const Step = *const fn (*sqlite3_stmt) callconv(.c) c_int;
const ColumnText = *const fn (*sqlite3_stmt, c_int) callconv(.c) ?[*:0]const u8;
const Finalize = *const fn (*sqlite3_stmt) callconv(.c) c_int;
const ErrorMessage = *const fn (*sqlite3) callconv(.c) [*:0]const u8;
const LibraryVersion = *const fn () callconv(.c) [*:0]const u8;

const Api = struct {
    open_v2: Open,
    close_v2: Close,
    busy_timeout: BusyTimeout,
    prepare_v2: Prepare,
    step: Step,
    column_text: ColumnText,
    finalize: Finalize,
    errmsg: ErrorMessage,
    libversion: LibraryVersion,

    fn load(library: *std.DynLib) !Api {
        return .{
            .open_v2 = library.lookup(Open, "sqlite3_open_v2") orelse return error.SqliteSymbolMissing,
            .close_v2 = library.lookup(Close, "sqlite3_close_v2") orelse return error.SqliteSymbolMissing,
            .busy_timeout = library.lookup(BusyTimeout, "sqlite3_busy_timeout") orelse return error.SqliteSymbolMissing,
            .prepare_v2 = library.lookup(Prepare, "sqlite3_prepare_v2") orelse return error.SqliteSymbolMissing,
            .step = library.lookup(Step, "sqlite3_step") orelse return error.SqliteSymbolMissing,
            .column_text = library.lookup(ColumnText, "sqlite3_column_text") orelse return error.SqliteSymbolMissing,
            .finalize = library.lookup(Finalize, "sqlite3_finalize") orelse return error.SqliteSymbolMissing,
            .errmsg = library.lookup(ErrorMessage, "sqlite3_errmsg") orelse return error.SqliteSymbolMissing,
            .libversion = library.lookup(LibraryVersion, "sqlite3_libversion") orelse return error.SqliteSymbolMissing,
        };
    }
};

pub const Database = struct {
    library: std.DynLib,
    api: Api,
    handle: *sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        var library = try openLibrary();
        errdefer library.close();
        const api = try Api.load(&library);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var handle: ?*sqlite3 = null;
        const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
        if (api.open_v2(path_z.ptr, &handle, flags, null) != SQLITE_OK) {
            if (handle) |opened| _ = api.close_v2(opened);
            return error.DatabaseOpenFailed;
        }
        const opened = handle orelse return error.DatabaseOpenFailed;
        errdefer _ = api.close_v2(opened);
        if (api.busy_timeout(opened, 5_000) != SQLITE_OK) return error.DatabaseConfigureFailed;
        return .{ .library = library, .api = api, .handle = opened };
    }

    pub fn deinit(database: *Database) void {
        if (database.api.close_v2(database.handle) != SQLITE_OK) {
            std.log.err("SQLite close failed: {s}", .{database.api.errmsg(database.handle)});
        }
        database.library.close();
        database.* = undefined;
    }

    pub fn quickCheck(database: *Database) !bool {
        var statement: ?*sqlite3_stmt = null;
        const sql = "PRAGMA quick_check";
        if (database.api.prepare_v2(database.handle, sql, @intCast(sql.len), &statement, null) != SQLITE_OK) {
            return error.DatabasePrepareFailed;
        }
        const prepared = statement orelse return error.DatabasePrepareFailed;
        defer _ = database.api.finalize(prepared);
        if (database.api.step(prepared) != SQLITE_ROW) return error.DatabaseQueryFailed;
        const text = database.api.column_text(prepared, 0) orelse return false;
        return std.mem.eql(u8, std.mem.span(text), "ok");
    }

    pub fn version(database: *Database) []const u8 {
        return std.mem.span(database.api.libversion());
    }
};

fn openLibrary() !std.DynLib {
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/usr/lib/libsqlite3.dylib", "libsqlite3.dylib" },
        .linux => &.{ "libsqlite3.so.0", "libsqlite3.so" },
        else => return error.SqlitePlatformUnsupported,
    };
    for (candidates) |candidate| {
        return std.DynLib.open(candidate) catch continue;
    }
    return error.SqliteLibraryUnavailable;
}
