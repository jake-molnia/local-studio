const std = @import("std");

const http = std.http;

pub const ResponseCommitment = enum {
    pending,
    committed,

    pub fn canRetry(commitment: ResponseCommitment) bool {
        return commitment == .pending;
    }

    pub fn commit(commitment: *ResponseCommitment) void {
        commitment.* = .committed;
    }
};

const RequestBodyState = enum {
    untouched,
    streaming,
    complete,
};

pub fn serve(client: *http.Client, primary: []const u8, fallback: ?[]const u8, request: *http.Server.Request) !void {
    var commitment: ResponseCommitment = .pending;
    var request_body_state: RequestBodyState = .untouched;
    proxyAttempt(client, primary, request, &commitment, &request_body_state) catch |primary_failure| {
        if (request_body_state == .streaming) return primary_failure;
        if (!request.head.method.requestHasBody() and fallback != null and commitment.canRetry()) {
            proxyAttempt(client, fallback.?, request, &commitment, &request_body_state) catch |fallback_failure| {
                if (!commitment.canRetry()) return fallback_failure;
                try respondBadGateway(request);
            };
            return;
        }
        if (!commitment.canRetry()) return primary_failure;
        try respondBadGateway(request);
    };
}

fn proxyAttempt(client: *http.Client, upstream: []const u8, request: *http.Server.Request, commitment: *ResponseCommitment, request_body_state: *RequestBodyState) !void {
    const uri = try uriForTarget(upstream, request.head.target);
    var request_headers: [64]http.Header = undefined;
    const request_header_count = try collectRequestHeaders(request, &request_headers);
    var upstream_request = try client.request(request.head.method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = .omit,
            .user_agent = .omit,
            .connection = .omit,
            .accept_encoding = .omit,
            .content_type = .omit,
        },
        .extra_headers = request_headers[0..request_header_count],
    });
    defer upstream_request.deinit();

    if (request.head.method.requestHasBody()) {
        upstream_request.transfer_encoding = if (request.head.content_length) |length| .{ .content_length = length } else .chunked;
        var request_write_buffer: [16 * 1024]u8 = undefined;
        var upstream_body = try upstream_request.sendBody(&request_write_buffer);
        var request_read_buffer: [16 * 1024]u8 = undefined;
        request_body_state.* = .streaming;
        const downstream_body = try request.readerExpectContinue(&request_read_buffer);
        _ = try downstream_body.streamRemaining(&upstream_body.writer);
        try upstream_body.end();
        request_body_state.* = .complete;
    } else {
        try upstream_request.sendBodiless();
        request_body_state.* = .complete;
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var upstream_response = try upstream_request.receiveHead(&redirect_buffer);
    var response_headers: [64]http.Header = undefined;
    const response_header_count = try collectResponseHeaders(upstream_response.head, &response_headers);

    var response_write_buffer: [16 * 1024]u8 = undefined;
    commitment.commit();
    var downstream_response = try request.respondStreaming(&response_write_buffer, .{
        .content_length = upstream_response.head.content_length,
        .respond_options = .{
            .status = upstream_response.head.status,
            .keep_alive = false,
            .extra_headers = response_headers[0..response_header_count],
        },
    });
    try downstream_response.flush();
    var response_read_buffer: [16 * 1024]u8 = undefined;
    const upstream_body = upstream_response.reader(&response_read_buffer);
    const bytes_forwarded = try upstream_body.streamRemaining(&downstream_response.writer);
    if (upstream_response.head.content_length) |content_length| {
        if (bytes_forwarded != content_length) return error.UpstreamBodyTruncated;
    }
    try downstream_response.end();
}

fn uriForTarget(upstream: []const u8, target: []const u8) !std.Uri {
    var uri = try std.Uri.parse(upstream);
    const query_start = std.mem.findScalar(u8, target, '?');
    const path_end = query_start orelse target.len;
    uri.path = .{ .percent_encoded = target[0..path_end] };
    uri.query = if (query_start) |index| .{ .percent_encoded = target[index + 1 ..] } else null;
    uri.fragment = null;
    return uri;
}

fn collectRequestHeaders(request: *const http.Server.Request, output: *[64]http.Header) !usize {
    var count: usize = 0;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (isFramingOrHopByHop(header.name) or connectionNominatesRequestHeader(request, header.name)) continue;
        if (count == output.len) return error.TooManyForwardedHeaders;
        output[count] = header;
        count += 1;
    }
    return count;
}

fn collectResponseHeaders(head: http.Client.Response.Head, output: *[64]http.Header) !usize {
    var count: usize = 0;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (isFramingOrHopByHop(header.name) or connectionNominatesResponseHeader(head, header.name)) continue;
        if (count == output.len) return error.TooManyForwardedHeaders;
        output[count] = header;
        count += 1;
    }
    return count;
}

fn connectionNominatesRequestHeader(request: *const http.Server.Request, name: []const u8) bool {
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection") and containsHeaderToken(header.value, name)) return true;
    }
    return false;
}

fn connectionNominatesResponseHeader(head: http.Client.Response.Head, name: []const u8) bool {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection") and containsHeaderToken(header.value, name)) return true;
    }
    return false;
}

fn containsHeaderToken(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), expected)) return true;
    }
    return false;
}

fn isFramingOrHopByHop(name: []const u8) bool {
    const names = [_][]const u8{
        "connection",
        "content-length",
        "expect",
        "host",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    };
    for (names) |excluded| {
        if (std.ascii.eqlIgnoreCase(name, excluded)) return true;
    }
    return false;
}

fn respondBadGateway(request: *http.Server.Request) !void {
    try request.respond("{\"detail\":\"Upstream request failed\"}", .{
        .status = .bad_gateway,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
}
