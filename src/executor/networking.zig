const std = @import("std");
const IO = @import("../utils/io.zig").IO;

/// Network path error types for better diagnostics
pub const DevNetError = error{
    NotNetworkPath, // Not a /dev/tcp or /dev/udp path
    MissingHost, // No host specified
    MissingPort, // No port specified
    InvalidPort, // Port not a valid number or out of range
    InvalidIPv4, // Malformed IPv4 address
    InvalidIPv6, // Malformed IPv6 address
    InvalidHost, // Host is neither valid IPv4 nor IPv6
    ConnectionFailed, // Socket connection failed
    SocketError, // Socket creation failed
};

/// Parsed /dev/tcp or /dev/udp path components
pub const DevNetPath = struct {
    host: []const u8,
    port: u16,
    is_tcp: bool,
};

/// Open a /dev/tcp/host/port or /dev/udp/host/port virtual path as a socket.
/// Bash-compatible virtual device paths for network I/O.
///
/// Supported formats:
///   /dev/tcp/127.0.0.1/80      - IPv4 TCP connection
///   /dev/udp/192.168.1.1/53    - IPv4 UDP connection
///   /dev/tcp/[::1]/8080        - IPv6 TCP connection
///   /dev/udp/[fe80::1]/1234    - IPv6 UDP connection
///
/// Security considerations:
/// - This feature allows connecting to arbitrary IP addresses, which poses an
///   SSRF (Server-Side Request Forgery) risk in automated or scripted contexts.
/// - Only literal IP addresses are accepted; no DNS resolution is performed.
/// - Port 0 is rejected as invalid.
/// - Consider disabling this feature in security-sensitive deployments via
///   restricted mode.
///
/// Returns the socket fd on success, null if path is not a /dev/tcp or /dev/udp path
/// or if the connection fails.
pub fn openDevNet(path: []const u8) ?std.posix.socket_t {
    return openDevNetWithError(path) catch |err| {
        // Print helpful error messages for network paths
        if (err != DevNetError.NotNetworkPath) {
            const msg = switch (err) {
                DevNetError.MissingHost => "missing host in network path",
                DevNetError.MissingPort => "missing port in network path",
                DevNetError.InvalidPort => "invalid port number (must be 1-65535)",
                DevNetError.InvalidIPv4 => "invalid IPv4 address format",
                DevNetError.InvalidIPv6 => "invalid IPv6 address format (use [::1] notation)",
                DevNetError.InvalidHost => "host must be a valid IPv4 or IPv6 address",
                DevNetError.ConnectionFailed => "connection failed",
                DevNetError.SocketError => "failed to create socket",
                else => "network error",
            };
            IO.eprint("den: {s}: {s}\n", .{ path, msg }) catch {};
        }
        return null;
    };
}

/// Internal version that returns detailed errors
fn openDevNetWithError(path: []const u8) DevNetError!std.posix.socket_t {
    const parsed = try parseDevNetPathWithError(path);
    return connectToAddressWithError(parsed.host, parsed.port, parsed.is_tcp);
}

/// Parse a /dev/tcp/host/port or /dev/udp/host/port path (legacy null-returning version)
pub fn parseDevNetPath(path: []const u8) ?DevNetPath {
    return parseDevNetPathWithError(path) catch return null;
}

/// Parse a /dev/tcp/host/port or /dev/udp/host/port path with detailed errors
pub fn parseDevNetPathWithError(path: []const u8) DevNetError!DevNetPath {
    const is_tcp = std.mem.startsWith(u8, path, "/dev/tcp/");
    const is_udp = std.mem.startsWith(u8, path, "/dev/udp/");

    if (!is_tcp and !is_udp) return DevNetError.NotNetworkPath;

    // Parse host/port from path: /dev/tcp/host/port or /dev/udp/host/port
    const prefix_len: usize = 9; // "/dev/tcp/" or "/dev/udp/"
    const rest = path[prefix_len..];

    if (rest.len == 0) return DevNetError.MissingHost;

    // Handle IPv6 addresses in brackets: [::1]/port
    if (rest[0] == '[') {
        const bracket_end = std.mem.indexOf(u8, rest, "]") orelse return DevNetError.InvalidIPv6;
        if (bracket_end + 1 >= rest.len) return DevNetError.MissingPort;
        if (rest[bracket_end + 1] != '/') return DevNetError.MissingPort;
        if (bracket_end + 2 >= rest.len) return DevNetError.MissingPort;

        const host = rest[1..bracket_end];
        if (host.len == 0) return DevNetError.MissingHost;

        // Validate IPv6 format
        if (parseIPv6(host) == null) return DevNetError.InvalidIPv6;

        const port_str = rest[bracket_end + 2 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return DevNetError.InvalidPort;
        if (port == 0) return DevNetError.InvalidPort; // Port 0 is not valid

        return DevNetPath{ .host = host, .port = port, .is_tcp = is_tcp };
    }

    // IPv4 format: host/port
    const port_sep = std.mem.lastIndexOf(u8, rest, "/") orelse return DevNetError.MissingPort;
    if (port_sep == 0) return DevNetError.MissingHost;
    if (port_sep >= rest.len - 1) return DevNetError.MissingPort;

    const host = rest[0..port_sep];
    const port_str = rest[port_sep + 1 ..];

    // Validate host is not empty
    if (host.len == 0) return DevNetError.MissingHost;

    // Validate IPv4 format
    if (parseIPv4(host) == null) return DevNetError.InvalidIPv4;

    // Validate port
    const port = std.fmt.parseInt(u16, port_str, 10) catch return DevNetError.InvalidPort;
    if (port == 0) return DevNetError.InvalidPort; // Port 0 is not valid

    return DevNetPath{ .host = host, .port = port, .is_tcp = is_tcp };
}

/// Parse an IPv4 address string into bytes
pub fn parseIPv4(host: []const u8) ?[4]u8 {
    if (host.len == 0 or host.len > 15) return null;

    var ip_bytes: [4]u8 = undefined;
    var byte_idx: usize = 0;
    var num: u16 = 0;
    var digit_count: usize = 0;

    for (host) |c| {
        if (c == '.') {
            if (byte_idx >= 3 or digit_count == 0) return null;
            // Safety: num validated <= 255 above
            ip_bytes[byte_idx] = @intCast(num);
            byte_idx += 1;
            num = 0;
            digit_count = 0;
        } else if (c >= '0' and c <= '9') {
            num = num * 10 + (c - '0');
            digit_count += 1;
            if (num > 255 or digit_count > 3) return null;
        } else {
            return null;
        }
    }

    if (byte_idx != 3 or digit_count == 0) return null;
    // Safety: num validated <= 255 above
    ip_bytes[byte_idx] = @intCast(num);

    return ip_bytes;
}

/// Connect to a host:port using TCP or UDP
pub fn connectToAddress(host: []const u8, port: u16, is_tcp: bool) ?std.posix.socket_t {
    return connectToAddressWithError(host, port, is_tcp) catch return null;
}

/// Connect to a host:port using TCP or UDP with detailed errors
pub fn connectToAddressWithError(host: []const u8, port: u16, is_tcp: bool) DevNetError!std.posix.socket_t {
    // Try IPv4 first
    if (parseIPv4(host)) |ip_bytes| {
        return connectIPv4(ip_bytes, port, is_tcp) orelse return DevNetError.ConnectionFailed;
    }

    // Try IPv6
    if (parseIPv6(host)) |ip6_bytes| {
        return connectIPv6(ip6_bytes, port, is_tcp) orelse return DevNetError.ConnectionFailed;
    }

    return DevNetError.InvalidHost;
}

/// Parse an IPv6 address string into bytes.
/// Supports full form (2001:db8::1) and loopback (::1).
pub fn parseIPv6(host: []const u8) ?[16]u8 {
    if (host.len == 0 or host.len > 45) return null;

    var result: [16]u8 = std.mem.zeroes([16]u8);
    var groups: [8]u16 = undefined;
    var group_count: usize = 0;
    var double_colon_pos: ?usize = null;
    var current_group: u16 = 0;
    var digit_count: usize = 0;
    var i: usize = 0;

    // Handle leading ::
    if (host.len >= 2 and host[0] == ':' and host[1] == ':') {
        double_colon_pos = 0;
        i = 2;
        if (i >= host.len) {
            // Just "::" - all zeros
            return result;
        }
    }

    while (i < host.len) {
        const c = host[i];
        if (c == ':') {
            if (digit_count == 0) {
                // Double colon
                if (double_colon_pos != null) return null; // Only one :: allowed
                double_colon_pos = group_count;
                i += 1;
                if (i < host.len and host[i] == ':') {
                    i += 1; // Skip second colon of ::
                }
                continue;
            }
            if (group_count >= 8) return null;
            groups[group_count] = current_group;
            group_count += 1;
            current_group = 0;
            digit_count = 0;
            i += 1;
        } else if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            const val: u16 = if (c >= '0' and c <= '9')
                c - '0'
            else if (c >= 'a' and c <= 'f')
                c - 'a' + 10
            else
                c - 'A' + 10;
            current_group = current_group * 16 + val;
            digit_count += 1;
            if (digit_count > 4) return null;
            i += 1;
        } else {
            return null;
        }
    }

    // Handle last group
    if (digit_count > 0) {
        if (group_count >= 8) return null;
        groups[group_count] = current_group;
        group_count += 1;
    }

    // Expand :: (double colon)
    if (double_colon_pos) |pos| {
        if (group_count > 8) return null;
        const zeros_needed = 8 - group_count;
        // Shift groups after :: to the right position
        var j: usize = 7;
        var src: usize = group_count;
        while (src > pos) {
            src -= 1;
            groups[j] = groups[src];
            j -= 1;
        }
        // Fill zeros
        var k: usize = pos;
        while (k < pos + zeros_needed) {
            groups[k] = 0;
            k += 1;
        }
    } else {
        if (group_count != 8) return null;
    }

    // Convert groups to bytes (big-endian)
    for (groups, 0..) |group, idx| {
        result[idx * 2] = @intCast(group >> 8);
        result[idx * 2 + 1] = @intCast(group & 0xFF);
    }

    return result;
}

/// Connect to an IPv4 address
fn connectIPv4(ip_bytes: [4]u8, port: u16, is_tcp: bool) ?std.posix.socket_t {
    const sock_type: c_uint = if (is_tcp) std.c.SOCK.STREAM else std.c.SOCK.DGRAM;
    const sock = std.c.socket(std.c.AF.INET, sock_type, 0);
    if (sock < 0) return null;

    // Set send timeout (30s) so connect() doesn't hang indefinitely
    setSocketTimeouts(sock) catch {
        _ = std.c.close(sock);
        return null;
    };

    var addr: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
    if (@hasField(std.c.sockaddr.in, "len")) {
        addr.len = @sizeOf(std.c.sockaddr.in);
    }
    addr.family = std.c.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = @bitCast(ip_bytes);

    if (!doConnect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in))) {
        _ = std.c.close(sock);
        return null;
    }

    return sock;
}

/// Connect to an IPv6 address
fn connectIPv6(ip_bytes: [16]u8, port: u16, is_tcp: bool) ?std.posix.socket_t {
    const sock_type: c_uint = if (is_tcp) std.c.SOCK.STREAM else std.c.SOCK.DGRAM;
    const sock = std.c.socket(std.c.AF.INET6, sock_type, 0);
    if (sock < 0) return null;

    // Set send timeout (30s) so connect() doesn't hang indefinitely
    setSocketTimeouts(sock) catch {
        _ = std.c.close(sock);
        return null;
    };

    var addr: std.c.sockaddr.in6 = std.mem.zeroes(std.c.sockaddr.in6);
    if (@hasField(std.c.sockaddr.in6, "len")) {
        addr.len = @sizeOf(std.c.sockaddr.in6);
    }
    addr.family = std.c.AF.INET6;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = ip_bytes;

    if (!doConnect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in6))) {
        _ = std.c.close(sock);
        return null;
    }

    return sock;
}

/// Connection timeout in seconds for /dev/tcp and /dev/udp sockets.
const socket_timeout_sec = 30;

/// Set SO_SNDTIMEO and SO_RCVTIMEO on a socket to prevent indefinite hangs.
/// SO_SNDTIMEO bounds the connect() call, SO_RCVTIMEO bounds subsequent reads.
fn setSocketTimeouts(sock: std.posix.socket_t) !void {
    const timeout = std.c.timeval{ .sec = socket_timeout_sec, .usec = 0 };
    const timeout_ptr: *const anyopaque = @ptrCast(&timeout);
    const timeout_len: std.c.socklen_t = @sizeOf(std.c.timeval);

    if (std.c.setsockopt(sock, @intCast(std.c.SOL.SOCKET), std.c.SO.SNDTIMEO, timeout_ptr, timeout_len) < 0) {
        return error.SetSockOptFailed;
    }
    if (std.c.setsockopt(sock, @intCast(std.c.SOL.SOCKET), std.c.SO.RCVTIMEO, timeout_ptr, timeout_len) < 0) {
        return error.SetSockOptFailed;
    }
}

/// Perform connect with retry on EINTR
fn doConnect(sock: std.posix.socket_t, addr: *const std.c.sockaddr, addrlen: std.c.socklen_t) bool {
    var retry_count: u32 = 0;
    while (retry_count < 5) : (retry_count += 1) {
        const connect_result = std.c.connect(sock, addr, addrlen);
        if (connect_result >= 0) return true;

        const errno = std.c._errno().*;
        if (errno == @backingInt(std.c.E.INTR)) continue; // EINTR - retry
        if (errno == @backingInt(std.c.E.ISCONN)) return true; // EISCONN - already connected
        return false;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "parseIPv4 valid addresses" {
    const result1 = parseIPv4("127.0.0.1");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, result1.?);

    const result2 = parseIPv4("192.168.1.1");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, result2.?);

    const result3 = parseIPv4("0.0.0.0");
    try std.testing.expect(result3 != null);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, result3.?);

    const result4 = parseIPv4("255.255.255.255");
    try std.testing.expect(result4 != null);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, result4.?);
}

test "parseIPv4 invalid addresses" {
    try std.testing.expect(parseIPv4("") == null);
    try std.testing.expect(parseIPv4("256.0.0.1") == null);
    try std.testing.expect(parseIPv4("1.2.3") == null);
    try std.testing.expect(parseIPv4("1.2.3.4.5") == null);
    try std.testing.expect(parseIPv4("abc.def.ghi.jkl") == null);
    try std.testing.expect(parseIPv4("1.2.3.") == null);
    try std.testing.expect(parseIPv4(".1.2.3") == null);
}

test "parseIPv6 valid addresses" {
    // Loopback
    const result1 = parseIPv6("::1");
    try std.testing.expect(result1 != null);

    // All zeros
    const result2 = parseIPv6("::");
    try std.testing.expect(result2 != null);

    // Full address
    const result3 = parseIPv6("2001:0db8:0000:0000:0000:0000:0000:0001");
    try std.testing.expect(result3 != null);
}

test "parseDevNetPath valid paths" {
    const tcp_path = parseDevNetPath("/dev/tcp/127.0.0.1/80");
    try std.testing.expect(tcp_path != null);
    try std.testing.expect(tcp_path.?.is_tcp);
    try std.testing.expectEqual(@as(u16, 80), tcp_path.?.port);

    const udp_path = parseDevNetPath("/dev/udp/192.168.1.1/53");
    try std.testing.expect(udp_path != null);
    try std.testing.expect(!udp_path.?.is_tcp);
    try std.testing.expectEqual(@as(u16, 53), udp_path.?.port);
}

test "parseDevNetPath invalid paths" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/abc") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/0") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/99999") == null);
    try std.testing.expect(parseDevNetPath("/some/other/path") == null);
}

test "parseDevNetPath IPv6" {
    const ipv6_path = parseDevNetPath("/dev/tcp/[::1]/8080");
    try std.testing.expect(ipv6_path != null);
    try std.testing.expect(ipv6_path.?.is_tcp);
    try std.testing.expectEqual(@as(u16, 8080), ipv6_path.?.port);
}

test "parseDevNetPathWithError detailed errors" {
    // NotNetworkPath for non-matching paths
    try std.testing.expectError(DevNetError.NotNetworkPath, parseDevNetPathWithError("/some/other/path"));
    try std.testing.expectError(DevNetError.NotNetworkPath, parseDevNetPathWithError(""));
    try std.testing.expectError(DevNetError.NotNetworkPath, parseDevNetPathWithError("/dev/tcp"));

    // MissingHost
    try std.testing.expectError(DevNetError.MissingHost, parseDevNetPathWithError("/dev/tcp/"));

    // MissingPort - host but no port separator or empty port
    try std.testing.expectError(DevNetError.MissingPort, parseDevNetPathWithError("/dev/tcp/127.0.0.1"));
    try std.testing.expectError(DevNetError.MissingPort, parseDevNetPathWithError("/dev/tcp/127.0.0.1/"));

    // InvalidPort
    try std.testing.expectError(DevNetError.InvalidPort, parseDevNetPathWithError("/dev/tcp/127.0.0.1/abc"));
    try std.testing.expectError(DevNetError.InvalidPort, parseDevNetPathWithError("/dev/tcp/127.0.0.1/0")); // Port 0 rejected
    try std.testing.expectError(DevNetError.InvalidPort, parseDevNetPathWithError("/dev/tcp/127.0.0.1/99999")); // > u16 max

    // InvalidIPv4
    try std.testing.expectError(DevNetError.InvalidIPv4, parseDevNetPathWithError("/dev/tcp/999.0.0.1/80"));
    try std.testing.expectError(DevNetError.InvalidIPv4, parseDevNetPathWithError("/dev/tcp/abc/80"));

    // InvalidIPv6
    try std.testing.expectError(DevNetError.InvalidIPv6, parseDevNetPathWithError("/dev/tcp/[invalid]/80"));
    try std.testing.expectError(DevNetError.MissingHost, parseDevNetPathWithError("/dev/tcp/[]/80"));
}

test "parseDevNetPath edge cases" {
    // UDP path
    const udp = parseDevNetPath("/dev/udp/10.0.0.1/1234");
    try std.testing.expect(udp != null);
    try std.testing.expect(!udp.?.is_tcp);
    try std.testing.expectEqual(@as(u16, 1234), udp.?.port);

    // Max valid port
    const max_port = parseDevNetPath("/dev/tcp/127.0.0.1/65535");
    try std.testing.expect(max_port != null);
    try std.testing.expectEqual(@as(u16, 65535), max_port.?.port);

    // Min valid port
    const min_port = parseDevNetPath("/dev/tcp/127.0.0.1/1");
    try std.testing.expect(min_port != null);
    try std.testing.expectEqual(@as(u16, 1), min_port.?.port);

    // Port 0 is invalid
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/0") == null);
}

test "parseIPv6 edge cases" {
    // Short forms
    try std.testing.expect(parseIPv6("::1") != null);
    try std.testing.expect(parseIPv6("::") != null);
    try std.testing.expect(parseIPv6("fe80::1") != null);

    // Invalid: multiple double colons
    try std.testing.expect(parseIPv6("::1::2") == null);

    // Invalid: too many groups
    try std.testing.expect(parseIPv6("1:2:3:4:5:6:7:8:9") == null);

    // Invalid: empty string
    try std.testing.expect(parseIPv6("") == null);

    // Invalid: non-hex character
    try std.testing.expect(parseIPv6("gggg::1") == null);

    // Verify loopback bytes
    const loopback = parseIPv6("::1").?;
    try std.testing.expectEqual(@as(u8, 0), loopback[14]);
    try std.testing.expectEqual(@as(u8, 1), loopback[15]);
}

test "errno constants are portable" {
    // Verify the errno values we use are properly defined
    // This test ensures the fix from magic numbers (4, 56) to portable enums works
    const eintr = @backingInt(std.c.E.INTR);
    const eisconn = @backingInt(std.c.E.ISCONN);
    try std.testing.expect(eintr > 0);
    try std.testing.expect(eisconn > 0);
    try std.testing.expect(eintr != eisconn);
}
