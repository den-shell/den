//! Distributed shell sessions.
//!
//! `den --serve [addr]` listens on a TCP socket and runs a Den shell session
//! for each client over the connection. `den --connect addr` attaches the local
//! terminal to a remote session. The transport is a raw byte stream (like
//! telnet/rsh), so the existing shell REPL is reused verbatim once the socket
//! is wired to stdin/stdout/stderr.
//!
//! SECURITY: the server is an UNAUTHENTICATED remote shell. It binds to
//! 127.0.0.1 by default and refuses to start on a non-loopback address unless
//! `DEN_ALLOW_REMOTE=1` is set in the environment. Never expose it on an
//! untrusted network.

const std = @import("std");
const builtin = @import("builtin");
const networking = @import("../executor/networking.zig");

pub const default_host = "127.0.0.1";
pub const default_port: u16 = 7878;

pub const Address = struct {
    host: []const u8,
    port: u16,
    ip: [4]u8,
};

/// Parse "host:port", "host", or ":port" into an Address (IPv4 only).
pub fn parseAddress(spec: []const u8) ?Address {
    var host: []const u8 = default_host;
    var port: u16 = default_port;

    if (spec.len > 0) {
        if (std.mem.lastIndexOfScalar(u8, spec, ':')) |colon| {
            if (colon > 0) host = spec[0..colon];
            const port_str = spec[colon + 1 ..];
            if (port_str.len > 0) {
                port = std.fmt.parseInt(u16, port_str, 10) catch return null;
            }
        } else {
            host = spec;
        }
    }

    const ip = networking.parseIPv4(host) orelse return null;
    return .{ .host = host, .port = port, .ip = ip };
}

/// Is the given IPv4 address a loopback address (127.0.0.0/8)?
pub fn isLoopback(ip: [4]u8) bool {
    return ip[0] == 127;
}

/// Create, bind, and listen on a TCP socket. Returns the listening fd.
pub fn bindListen(ip: [4]u8, port: u16) !std.posix.socket_t {
    if (comptime builtin.os.tag == .windows) {
        return error.UnsupportedPlatform;
    }

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return error.SocketCreateFailed;
    errdefer _ = std.c.close(sock);

    // Allow quick rebinding after restart.
    const one: c_int = 1;
    _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int));

    var addr: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
    if (@hasField(std.c.sockaddr.in, "len")) {
        addr.len = @sizeOf(std.c.sockaddr.in);
    }
    addr.family = std.c.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = @bitCast(ip);

    if (std.c.bind(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) {
        return error.BindFailed;
    }
    if (std.c.listen(sock, 8) != 0) {
        return error.ListenFailed;
    }
    return sock;
}

/// Accept a single incoming connection. Returns the connected fd.
pub fn acceptConn(listener: std.posix.socket_t) !std.posix.socket_t {
    if (comptime builtin.os.tag == .windows) {
        return error.UnsupportedPlatform;
    }

    const conn = std.c.accept(listener, null, null);
    if (conn < 0) return error.AcceptFailed;
    return conn;
}

/// Connect the local terminal to a remote session: pump stdin -> socket and
/// socket -> stdout until either side closes.
pub fn runClient(host: []const u8, port: u16) !void {
    if (comptime builtin.os.tag == .windows) {
        return error.UnsupportedPlatform;
    }

    const sock = networking.connectToAddress(host, port, true) orelse return error.ConnectionFailed;
    defer _ = std.c.close(sock);

    const stdin_fd: std.posix.fd_t = 0;
    const stdout_fd: std.posix.fd_t = 1;

    var fds = [_]std.posix.pollfd{
        .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = sock, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var buf: [4096]u8 = undefined;
    while (true) {
        _ = std.posix.poll(&fds, -1) catch break;

        // Data from the terminal -> remote.
        if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            const n = std.posix.read(stdin_fd, &buf) catch 0;
            if (n == 0) {
                // Local EOF: stop sending but keep reading remote output.
                // SHUT_WR == 1 on all POSIX systems.
                _ = std.c.shutdown(sock, 1);
                fds[0].fd = -1;
            } else {
                writeAll(sock, buf[0..n]) catch break;
            }
        }

        // Data from remote -> terminal.
        if (fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            const n = std.posix.read(sock, &buf) catch 0;
            if (n == 0) break; // remote closed
            writeAll(stdout_fd, buf[0..n]) catch break;
        }
    }
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

const testing = std.testing;

test "parseAddress variants" {
    const a = parseAddress("127.0.0.1:9000").?;
    try testing.expectEqual(@as(u16, 9000), a.port);
    try testing.expectEqualStrings("127.0.0.1", a.host);

    const b = parseAddress("").?;
    try testing.expectEqual(default_port, b.port);
    try testing.expectEqualStrings(default_host, b.host);

    const c = parseAddress(":1234").?;
    try testing.expectEqual(@as(u16, 1234), c.port);

    try testing.expect(parseAddress("not-an-ip:1") == null);
}

test "isLoopback" {
    try testing.expect(isLoopback(.{ 127, 0, 0, 1 }));
    try testing.expect(!isLoopback(.{ 192, 168, 1, 1 }));
}
