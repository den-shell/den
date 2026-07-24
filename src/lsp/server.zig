const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_windows = builtin.os.tag == .windows;

fn getStdinFile() !std.Io.File {
    if (is_windows) {
        // Return an error rather than panic via `unreachable` if stdin isn't
        // available (e.g., GUI apps, detached processes).
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.NoStdin;
        return .{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else {
        return .{ .handle = posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    }
}

fn getStdoutFile() !std.Io.File {
    if (is_windows) {
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.NoStdout;
        return .{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else {
        return .{ .handle = posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    }
}

fn readStdin(buf: []u8) !usize {
    if (is_windows) {
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.Unexpected;
        var bytes_read: u32 = 0;
        const success = @import("windows_compat").ReadFile(handle, buf.ptr, @intCast(buf.len), &bytes_read, null);
        if (success == 0) return error.Unexpected;
        return @intCast(bytes_read);
    } else {
        return posix.read(posix.STDIN_FILENO, buf) catch |err| return err;
    }
}
const completion = @import("completion.zig");
const diagnostics = @import("diagnostics.zig");
const hover = @import("hover.zig");

// ---------------------------------------------------------------------------
// Document store
// ---------------------------------------------------------------------------

/// Stores the content of every open document, keyed by URI.
const DocumentStore = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *DocumentStore) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    fn open(self: *DocumentStore, uri: []const u8, text: []const u8) !void {
        const uri_owned = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_owned);
        const text_owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_owned);
        try self.map.put(uri_owned, text_owned);
    }

    fn change(self: *DocumentStore, uri: []const u8, text: []const u8) !void {
        if (self.map.getEntry(uri)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = try self.allocator.dupe(u8, text);
        }
    }

    fn close(self: *DocumentStore, uri: []const u8) void {
        if (self.map.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    fn get(self: *const DocumentStore, uri: []const u8) ?[]const u8 {
        return self.map.get(uri);
    }
};

// ---------------------------------------------------------------------------
// LSP Server
// ---------------------------------------------------------------------------

pub const LspServer = struct {
    allocator: std.mem.Allocator,
    documents: DocumentStore,
    running: bool,
    shutdown_requested: bool,

    pub fn init(allocator: std.mem.Allocator) LspServer {
        return .{
            .allocator = allocator,
            .documents = DocumentStore.init(allocator),
            .running = true,
            .shutdown_requested = false,
        };
    }

    pub fn deinit(self: *LspServer) void {
        self.documents.deinit();
    }

    // ------------------------------------------------------------------
    // Main loop
    // ------------------------------------------------------------------

    /// Run the server until an `exit` notification is received.
    pub fn run(self: *LspServer) !void {
        while (self.running) {
            const message = self.readMessage() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer self.allocator.free(message);

            self.handleMessage(message) catch |err| {
                // Log and continue -- a single bad message should not tear
                // down the server.
                std.log.err("Error handling message: {}", .{err});
            };
        }
    }

    // ------------------------------------------------------------------
    // Transport: read Content-Length framed JSON-RPC messages from stdin
    // ------------------------------------------------------------------

    fn readMessage(self: *LspServer) ![]u8 {
        var content_length: ?usize = null;

        // Read headers until we get an empty line
        while (true) {
            const header_line = try self.readLine();
            defer self.allocator.free(header_line);

            if (header_line.len == 0) {
                // Empty line: end of headers
                break;
            }

            // Parse "Content-Length: <number>"
            const prefix = "Content-Length: ";
            if (std.mem.startsWith(u8, header_line, prefix)) {
                const value_str = header_line[prefix.len..];
                content_length = try std.fmt.parseInt(usize, value_str, 10);
            }
            // Other headers (e.g. Content-Type) are silently ignored.
        }

        const length = content_length orelse return error.MissingContentLength;

        const body = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(body);

        var total_read: usize = 0;
        while (total_read < length) {
            const n = try readStdin(body[total_read..]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }

        return body;
    }

    /// Read a single line terminated by \r\n.  Returns the line *without*
    /// the trailing \r\n.
    fn readLine(self: *LspServer) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        while (true) {
            var byte_buf: [1]u8 = undefined;
            const n = readStdin(&byte_buf) catch |err| {
                if (buf.items.len > 0) {
                    return try self.allocator.dupe(u8, buf.items);
                }
                return err;
            };
            if (n == 0) {
                if (buf.items.len > 0) {
                    return try self.allocator.dupe(u8, buf.items);
                }
                return error.EndOfStream;
            }

            const byte = byte_buf[0];

            if (byte == '\r') {
                // Expect \n to follow
                var skip: [1]u8 = undefined;
                _ = readStdin(&skip) catch {};
                const result = try self.allocator.dupe(u8, buf.items);
                buf.deinit(self.allocator);
                return result;
            }
            if (byte == '\n') {
                const result = try self.allocator.dupe(u8, buf.items);
                buf.deinit(self.allocator);
                return result;
            }

            try buf.append(self.allocator, byte);
        }
    }

    // ------------------------------------------------------------------
    // Transport: write a JSON-RPC message to stdout
    // ------------------------------------------------------------------

    fn sendMessage(self: *LspServer, json_bytes: []const u8) !void {
        _ = self;
        const stdout_file = try getStdoutFile();
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json_bytes.len});
        try stdout_file.writeStreamingAll(std.Options.debug_io, header);
        try stdout_file.writeStreamingAll(std.Options.debug_io, json_bytes);
    }

    // ------------------------------------------------------------------
    // Dispatch
    // ------------------------------------------------------------------

    fn handleMessage(self: *LspServer, raw_json: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw_json, .{}) catch {
            return; // Malformed JSON -- ignore
        };
        defer parsed.deinit();

        const root = parsed.value;
        const obj = switch (root) {
            .object => |o| o,
            else => return,
        };

        const method_val = obj.get("method") orelse return; // No method = response; ignore
        const method = switch (method_val) {
            .string => |s| s,
            else => return,
        };

        // Extract id (may be null for notifications)
        const id = obj.get("id");
        const params = obj.get("params");

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // No-op acknowledgement
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try self.handleShutdown(id);
        } else if (std.mem.eql(u8, method, "exit")) {
            self.handleExit();
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id, params);
        } else {
            // Unknown method -- if it has an id we should reply with
            // MethodNotFound; otherwise ignore (notification).
            if (id != null) {
                try self.sendError(id, -32601, "Method not found");
            }
        }
    }

    // ------------------------------------------------------------------
    // Handlers
    // ------------------------------------------------------------------

    fn handleInitialize(self: *LspServer, id: ?std.json.Value) !void {
        const response =
            \\{"jsonrpc":"2.0","id":
        ;
        const capabilities =
            \\,"result":{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"completionProvider":{"triggerCharacters":["$"," ","."]},"hoverProvider":true},"serverInfo":{"name":"den-lsp","version":"0.1.0"}}}
        ;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, response);
        try self.writeJsonValue(&buf, id);
        try buf.appendSlice(self.allocator, capabilities);

        try self.sendMessage(buf.items);
    }

    fn handleShutdown(self: *LspServer, id: ?std.json.Value) !void {
        self.shutdown_requested = true;
        const response_prefix =
            \\{"jsonrpc":"2.0","id":
        ;
        const response_suffix =
            \\,"result":null}
        ;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, response_prefix);
        try self.writeJsonValue(&buf, id);
        try buf.appendSlice(self.allocator, response_suffix);

        try self.sendMessage(buf.items);
    }

    fn handleExit(self: *LspServer) void {
        self.running = false;
    }

    // -- Document sync ------------------------------------------------

    fn handleDidOpen(self: *LspServer, params: ?std.json.Value) !void {
        const p = params orelse return;
        const text_doc = jsonGet(p, "textDocument") orelse return;
        const uri = jsonGetString(text_doc, "uri") orelse return;
        const text = jsonGetString(text_doc, "text") orelse return;

        try self.documents.open(uri, text);
        try self.publishDiagnostics(uri, text);
    }

    fn handleDidChange(self: *LspServer, params: ?std.json.Value) !void {
        const p = params orelse return;
        const text_doc = jsonGet(p, "textDocument") orelse return;
        const uri = jsonGetString(text_doc, "uri") orelse return;

        // We request full-document sync (change = 1), so contentChanges[0].text
        // contains the complete new text.
        const changes = jsonGet(p, "contentChanges") orelse return;
        const arr = switch (changes) {
            .array => |a| a,
            else => return,
        };
        if (arr.items.len == 0) return;
        const new_text = jsonGetString(arr.items[0], "text") orelse return;

        try self.documents.change(uri, new_text);
        try self.publishDiagnostics(uri, new_text);
    }

    fn handleDidClose(self: *LspServer, params: ?std.json.Value) !void {
        const p = params orelse return;
        const text_doc = jsonGet(p, "textDocument") orelse return;
        const uri = jsonGetString(text_doc, "uri") orelse return;

        // Clear diagnostics for the closed document
        try self.publishDiagnosticsEmpty(uri);
        self.documents.close(uri);
    }

    // -- Completion ---------------------------------------------------

    fn handleCompletion(self: *LspServer, id: ?std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse {
            try self.sendResult(id, "[]");
            return;
        };

        const text_doc = jsonGet(p, "textDocument") orelse {
            try self.sendResult(id, "[]");
            return;
        };
        const uri = jsonGetString(text_doc, "uri") orelse {
            try self.sendResult(id, "[]");
            return;
        };

        const pos_val = jsonGet(p, "position") orelse {
            try self.sendResult(id, "[]");
            return;
        };
        const pos_line = jsonGetInt(pos_val, "line") orelse {
            try self.sendResult(id, "[]");
            return;
        };
        const pos_char = jsonGetInt(pos_val, "character") orelse {
            try self.sendResult(id, "[]");
            return;
        };

        const doc_text = self.documents.get(uri) orelse {
            try self.sendResult(id, "[]");
            return;
        };

        const items = try completion.getCompletions(
            doc_text,
            .{ .line = @intCast(pos_line), .character = @intCast(pos_char) },
            self.allocator,
        );
        defer completion.freeCompletions(items, self.allocator);

        // Serialize completion items to JSON
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "[");
        for (items, 0..) |item, idx| {
            if (idx > 0) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, "{\"label\":");
            try writeJsonString(&buf, self.allocator, item.label);
            try buf.appendSlice(self.allocator, ",\"kind\":");
            try appendInt(&buf, self.allocator, item.kind.toInt());
            try buf.appendSlice(self.allocator, ",\"detail\":");
            try writeJsonString(&buf, self.allocator, item.detail);
            try buf.appendSlice(self.allocator, ",\"insertText\":");
            try writeJsonString(&buf, self.allocator, item.insert_text);
            try buf.appendSlice(self.allocator, "}");
        }
        try buf.appendSlice(self.allocator, "]");

        try self.sendResult(id, buf.items);
    }

    // -- Hover --------------------------------------------------------

    fn handleHover(self: *LspServer, id: ?std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse {
            try self.sendResult(id, "null");
            return;
        };

        const text_doc = jsonGet(p, "textDocument") orelse {
            try self.sendResult(id, "null");
            return;
        };
        const uri = jsonGetString(text_doc, "uri") orelse {
            try self.sendResult(id, "null");
            return;
        };

        const pos_val = jsonGet(p, "position") orelse {
            try self.sendResult(id, "null");
            return;
        };
        const pos_line = jsonGetInt(pos_val, "line") orelse {
            try self.sendResult(id, "null");
            return;
        };
        const pos_char = jsonGetInt(pos_val, "character") orelse {
            try self.sendResult(id, "null");
            return;
        };

        const doc_text = self.documents.get(uri) orelse {
            try self.sendResult(id, "null");
            return;
        };

        const hover_result = try hover.getHoverInfo(
            doc_text,
            .{ .line = @intCast(pos_line), .character = @intCast(pos_char) },
            self.allocator,
        );

        if (hover_result) |hr| {
            defer hover.freeHoverResult(hr, self.allocator);

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);

            try buf.appendSlice(self.allocator, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
            try writeJsonString(&buf, self.allocator, hr.contents);
            try buf.appendSlice(self.allocator, "},\"range\":{\"start\":{\"line\":");
            try appendInt(&buf, self.allocator, hr.range.start.line);
            try buf.appendSlice(self.allocator, ",\"character\":");
            try appendInt(&buf, self.allocator, hr.range.start.character);
            try buf.appendSlice(self.allocator, "},\"end\":{\"line\":");
            try appendInt(&buf, self.allocator, hr.range.end.line);
            try buf.appendSlice(self.allocator, ",\"character\":");
            try appendInt(&buf, self.allocator, hr.range.end.character);
            try buf.appendSlice(self.allocator, "}}}");

            try self.sendResult(id, buf.items);
        } else {
            try self.sendResult(id, "null");
        }
    }

    // -- Diagnostics (server -> client notification) ------------------

    fn publishDiagnostics(self: *LspServer, uri: []const u8, text: []const u8) !void {
        const diags = try diagnostics.getDiagnostics(text, self.allocator);
        defer diagnostics.freeDiagnostics(diags, self.allocator);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator,
            \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":
        );
        try writeJsonString(&buf, self.allocator, uri);
        try buf.appendSlice(self.allocator, ",\"diagnostics\":[");

        for (diags, 0..) |d, idx| {
            if (idx > 0) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, "{\"range\":{\"start\":{\"line\":");
            try appendInt(&buf, self.allocator, d.range.start.line);
            try buf.appendSlice(self.allocator, ",\"character\":");
            try appendInt(&buf, self.allocator, d.range.start.character);
            try buf.appendSlice(self.allocator, "},\"end\":{\"line\":");
            try appendInt(&buf, self.allocator, d.range.end.line);
            try buf.appendSlice(self.allocator, ",\"character\":");
            try appendInt(&buf, self.allocator, d.range.end.character);
            try buf.appendSlice(self.allocator, "}},\"severity\":");
            try appendInt(&buf, self.allocator, d.severity.toInt());
            try buf.appendSlice(self.allocator, ",\"source\":");
            try writeJsonString(&buf, self.allocator, d.source);
            try buf.appendSlice(self.allocator, ",\"message\":");
            try writeJsonString(&buf, self.allocator, d.message);
            try buf.appendSlice(self.allocator, "}");
        }

        try buf.appendSlice(self.allocator, "]}}");

        try self.sendMessage(buf.items);
    }

    fn publishDiagnosticsEmpty(self: *LspServer, uri: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator,
            \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":
        );
        try writeJsonString(&buf, self.allocator, uri);
        try buf.appendSlice(self.allocator, ",\"diagnostics\":[]}}");

        try self.sendMessage(buf.items);
    }

    // ------------------------------------------------------------------
    // Response helpers
    // ------------------------------------------------------------------

    fn sendResult(self: *LspServer, id: ?std.json.Value, result_json: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator,
            \\{"jsonrpc":"2.0","id":
        );
        try self.writeJsonValue(&buf, id);
        try buf.appendSlice(self.allocator, ",\"result\":");
        try buf.appendSlice(self.allocator, result_json);
        try buf.appendSlice(self.allocator, "}");

        try self.sendMessage(buf.items);
    }

    fn sendError(self: *LspServer, id: ?std.json.Value, code: i32, message: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator,
            \\{"jsonrpc":"2.0","id":
        );
        try self.writeJsonValue(&buf, id);
        try buf.appendSlice(self.allocator, ",\"error\":{\"code\":");
        try appendSignedInt(&buf, self.allocator, code);
        try buf.appendSlice(self.allocator, ",\"message\":");
        try writeJsonString(&buf, self.allocator, message);
        try buf.appendSlice(self.allocator, "}}");

        try self.sendMessage(buf.items);
    }

    /// Write a `std.json.Value` (typically the `id` field) into the buffer.
    fn writeJsonValue(self: *LspServer, buf: *std.ArrayList(u8), value: ?std.json.Value) !void {
        if (value) |v| {
            switch (v) {
                .integer => |n| try appendSignedInt(buf, self.allocator, @as(i32, @intCast(n))),
                .string => |s| try writeJsonString(buf, self.allocator, s),
                .null => try buf.appendSlice(self.allocator, "null"),
                else => try buf.appendSlice(self.allocator, "null"),
            }
        } else {
            try buf.appendSlice(self.allocator, "null");
        }
    }
};

// ---------------------------------------------------------------------------
// JSON encoding helpers
// ---------------------------------------------------------------------------

fn writeJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // Control character -- encode as \u00XX
                    var tmp: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, &tmp);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    var tmp: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{value});
    try buf.appendSlice(allocator, s);
}

fn appendSignedInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    var tmp: [21]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{value});
    try buf.appendSlice(allocator, s);
}

// ---------------------------------------------------------------------------
// JSON navigation helpers
// ---------------------------------------------------------------------------

fn jsonGet(val: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (val) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

fn jsonGetString(val: std.json.Value, key: []const u8) ?[]const u8 {
    const v = jsonGet(val, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetInt(val: std.json.Value, key: []const u8) ?i64 {
    const v = jsonGet(val, key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeJsonString escapes special characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try writeJsonString(&buf, std.testing.allocator, "hello \"world\"\nnewline\\backslash");
    try std.testing.expectEqualStrings(
        "\"hello \\\"world\\\"\\nnewline\\\\backslash\"",
        buf.items,
    );
}

test "appendInt formats numbers" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendInt(&buf, std.testing.allocator, @as(u32, 42));
    try std.testing.expectEqualStrings("42", buf.items);
}

test "DocumentStore open and get" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///test.den", "echo hello");
    const text = store.get("file:///test.den");
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("echo hello", text.?);
}

test "DocumentStore change updates content" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///test.den", "echo hello");
    try store.change("file:///test.den", "echo world");
    const text = store.get("file:///test.den");
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("echo world", text.?);
}

test "DocumentStore close removes document" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///test.den", "echo hello");
    store.close("file:///test.den");
    try std.testing.expectEqual(@as(?[]const u8, null), store.get("file:///test.den"));
}
