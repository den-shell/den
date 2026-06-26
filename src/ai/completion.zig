//! AI-assisted command completion.
//!
//! Given a natural-language description, ask an OpenAI-compatible chat
//! completions endpoint for the corresponding shell command. The HTTPS request
//! is performed by shelling out to `curl` (every machine that ships a shell has
//! it, and it avoids depending on the in-tree TLS stack); the request body is
//! built and the response parsed in-tree so both are unit-testable.
//!
//! All network failures degrade gracefully to `null` so the shell never blocks
//! or errors when offline or unconfigured.

const std = @import("std");
const spawn = @import("../utils/spawn.zig");
const AiConfig = @import("../types/config.zig").AiConfig;

/// JSON-escape `s` into `out`.
pub fn escapeJson(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    try buf.print(allocator, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

const system_prompt =
    "You are a command-line assistant for the Den shell on a POSIX system. " ++
    "Translate the user's request into a single shell command. " ++
    "Respond with ONLY the command, no explanation, no markdown, no backticks.";

/// Build an OpenAI-compatible chat-completions request body.
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    user_prompt: []const u8,
    max_tokens: u32,
) ![]u8 {
    const esc_user = try escapeJson(allocator, user_prompt);
    defer allocator.free(esc_user);
    const esc_sys = try escapeJson(allocator, system_prompt);
    defer allocator.free(esc_sys);
    const esc_model = try escapeJson(allocator, model);
    defer allocator.free(esc_model);

    return std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","max_tokens":{d},"temperature":0.2,"messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}]}}
    , .{ esc_model, max_tokens, esc_sys, esc_user });
}

/// Extract `choices[0].message.content` (OpenAI) or `content[0].text`
/// (Anthropic) from a JSON response. Returns null if neither shape matches.
pub fn extractContent(allocator: std.mem.Allocator, response: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;

    // OpenAI: { choices: [ { message: { content: "..." } } ] }
    if (root.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first == .object) {
                if (first.object.get("message")) |msg| {
                    if (msg == .object) {
                        if (msg.object.get("content")) |content| {
                            if (content == .string) return try cleanup(allocator, content.string);
                        }
                    }
                }
            }
        }
    }

    // Anthropic: { content: [ { type: "text", text: "..." } ] }
    if (root.object.get("content")) |content| {
        if (content == .array and content.array.items.len > 0) {
            const first = content.array.items[0];
            if (first == .object) {
                if (first.object.get("text")) |t| {
                    if (t == .string) return try cleanup(allocator, t.string);
                }
            }
        }
    }

    return null;
}

/// Trim whitespace and strip a ```...``` markdown fence if the model added one.
fn cleanup(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, s, "```")) {
        // Drop the opening fence line.
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = s[nl + 1 ..];
        if (std.mem.endsWith(u8, s, "```")) s = s[0 .. s.len - 3];
        s = std.mem.trim(u8, s, " \t\r\n");
    }
    return allocator.dupe(u8, s);
}

/// Ask the configured endpoint for a command. `api_key` is the resolved key
/// value (already looked up from the environment by the caller). Returns the
/// suggested command, or null on any error / when disabled / when no key.
pub fn suggest(
    allocator: std.mem.Allocator,
    cfg: AiConfig,
    api_key: ?[]const u8,
    prompt: []const u8,
) !?[]u8 {
    if (!cfg.enabled) return null;
    const key = api_key orelse return null;
    if (key.len == 0) return null;

    const body = try buildRequestBody(allocator, cfg.model, prompt, cfg.max_tokens);
    defer allocator.free(body);

    // Write the body to a temp file so it survives argv length limits and
    // avoids quoting issues.
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/den-ai-{d}.json", .{std.c.getpid()});
    defer allocator.free(tmp_path);
    writeFile(tmp_path, body) catch return null;
    defer deleteFile(tmp_path);

    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);
    const data_arg = try std.fmt.allocPrint(allocator, "@{s}", .{tmp_path});
    defer allocator.free(data_arg);
    const max_time = try std.fmt.allocPrint(allocator, "{d}", .{(cfg.timeout_ms + 999) / 1000});
    defer allocator.free(max_time);
    const anthropic_key = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{key});
    defer allocator.free(anthropic_key);

    const argv = [_][]const u8{
        "curl",                           "-sS",
        "-m",                             max_time,
        "-X",                             "POST",
        cfg.endpoint,                     "-H",
        "Content-Type: application/json", "-H",
        auth,                             "-H",
        anthropic_key,                    "-H",
        "anthropic-version: 2023-06-01",  "--data",
        data_arg,
    };

    const result = spawn.captureOutput(allocator, .{ .argv = &argv }) catch return null;
    defer result.deinit(allocator);
    if (result.exit_code != 0) return null;
    return extractContent(allocator, result.stdout);
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn deleteFile(path: []const u8) void {
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "escapeJson handles quotes and control chars" {
    const out = try escapeJson(testing.allocator, "a\"b\\c\nd");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\\\"b\\\\c\\nd", out);
}

test "buildRequestBody embeds model and escaped prompt" {
    const body = try buildRequestBody(testing.allocator, "gpt-4o-mini", "list \"big\" files", 64);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o-mini\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "list \\\"big\\\" files") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":64") != null);
}

test "extractContent parses OpenAI shape" {
    const resp =
        \\{"choices":[{"message":{"role":"assistant","content":"ls -la"}}]}
    ;
    const out = (try extractContent(testing.allocator, resp)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ls -la", out);
}

test "extractContent parses Anthropic shape and strips fences" {
    const resp =
        \\{"content":[{"type":"text","text":"```\nfind . -name '*.zig'\n```"}]}
    ;
    const out = (try extractContent(testing.allocator, resp)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("find . -name '*.zig'", out);
}

test "extractContent returns null on junk" {
    try testing.expect((try extractContent(testing.allocator, "not json")) == null);
    try testing.expect((try extractContent(testing.allocator, "{}")) == null);
}

test "suggest returns null when disabled or keyless" {
    const cfg = AiConfig{ .enabled = false };
    try testing.expect((try suggest(testing.allocator, cfg, "key", "x")) == null);
    const cfg2 = AiConfig{ .enabled = true };
    try testing.expect((try suggest(testing.allocator, cfg2, null, "x")) == null);
}
