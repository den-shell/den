const std = @import("std");
const builtin = @import("builtin");

const repository = "den-shell/den";
const latest_release_url = "https://api.github.com/repos/" ++ repository ++ "/releases/latest";
const max_release_metadata_bytes = 1024 * 1024;
const max_checksums_bytes = 1024 * 1024;
const max_archive_bytes = 64 * 1024 * 1024;

const Asset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const Release = struct {
    tag_name: []const u8,
    draft: bool,
    prerelease: bool,
    assets: []const Asset,
};

const Platform = struct {
    os: []const u8,
    arch: []const u8,
    extension: []const u8,
    executable: []const u8,
};

pub const Options = struct {
    check_only: bool = false,
    force: bool = false,
};

pub fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            options.check_only = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else {
            return error.InvalidUpgradeOption;
        }
    }
    return options;
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, current_version_text: []const u8) !void {
    const options = parseOptions(args) catch {
        std.debug.print("Usage: den upgrade [--check] [--force]\n", .{});
        return error.InvalidUpgradeOption;
    };

    const platform = try currentPlatform();
    const current_version = try std.SemanticVersion.parse(current_version_text);
    var threaded_io = std.Io.Threaded.init(std.heap.c_allocator, .{
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
        .environ = std.Options.debug_threaded_io.?.environ.process_environ,
    });
    defer threaded_io.deinit();
    const runtime_io = threaded_io.io();

    std.debug.print("Checking GitHub Releases for updates...\n", .{});

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = runtime_io,
    };
    var client_active = true;
    defer if (client_active) client.deinit();

    const metadata = try fetchAlloc(allocator, &client, latest_release_url, max_release_metadata_bytes);
    defer allocator.free(metadata);

    const parsed = try std.json.parseFromSlice(Release, allocator, metadata, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const release = parsed.value;
    if (release.draft or release.prerelease) return error.InvalidLatestRelease;

    const release_version_text = if (std.mem.startsWith(u8, release.tag_name, "v"))
        release.tag_name[1..]
    else
        release.tag_name;
    const release_version = try std.SemanticVersion.parse(release_version_text);
    const order = current_version.order(release_version);

    if (order == .gt and !options.force) {
        std.debug.print(
            "Installed Den v{s} is newer than the latest release (v{s}).\n",
            .{ current_version_text, release_version_text },
        );
        return;
    }
    if (order == .eq and !options.force) {
        std.debug.print("Den v{s} is already up to date.\n", .{current_version_text});
        return;
    }
    if (options.check_only) {
        std.debug.print(
            "Den v{s} is available (installed: v{s}).\n",
            .{ release_version_text, current_version_text },
        );
        return;
    }

    const archive_name = try assetName(allocator, platform, release_version_text);
    defer allocator.free(archive_name);
    const archive_asset = findAsset(release.assets, archive_name) orelse
        return error.ReleaseAssetNotFound;
    const checksums_asset = findAsset(release.assets, "checksums.txt") orelse
        return error.ReleaseChecksumsNotFound;

    std.debug.print("Downloading {s}...\n", .{archive_name});
    const archive = try fetchAlloc(allocator, &client, archive_asset.browser_download_url, max_archive_bytes);
    defer allocator.free(archive);
    const checksums = try fetchAlloc(allocator, &client, checksums_asset.browser_download_url, max_checksums_bytes);
    defer allocator.free(checksums);
    client.deinit();
    client_active = false;

    const expected_checksum = checksumForAsset(checksums, archive_name) orelse
        return error.ReleaseChecksumNotFound;
    try verifyChecksum(archive, expected_checksum);
    std.debug.print("Verified SHA-256 checksum.\n", .{});

    const executable_path = try std.process.executablePathAlloc(runtime_io, allocator);
    defer allocator.free(executable_path);
    const parent_path = std.fs.path.dirname(executable_path) orelse
        return error.InvalidExecutablePath;
    const executable_name = std.fs.path.basename(executable_path);

    var parent_dir = try std.Io.Dir.cwd().openDir(runtime_io, parent_path, .{});
    defer parent_dir.close(runtime_io);

    const unique_id = std.Thread.getCurrentId();
    const staging_name = try std.fmt.allocPrint(allocator, ".den-upgrade-{d}", .{unique_id});
    defer allocator.free(staging_name);
    try parent_dir.createDir(runtime_io, staging_name, .default_dir);
    defer parent_dir.deleteTree(runtime_io, staging_name) catch {};

    const staging_path = try std.fs.path.join(allocator, &.{ parent_path, staging_name });
    defer allocator.free(staging_path);
    const archive_path = try std.fs.path.join(allocator, &.{ staging_path, archive_name });
    defer allocator.free(archive_path);
    try writeFile(runtime_io, archive_path, archive);

    try extractArchive(allocator, runtime_io, archive_path, staging_path);

    var staging_dir = try parent_dir.openDir(runtime_io, staging_name, .{});
    defer staging_dir.close(runtime_io);
    try makeExecutable(runtime_io, staging_dir, platform.executable);
    try validateBinary(allocator, runtime_io, staging_path, platform.executable, release_version_text);

    const replacement_name = try std.fmt.allocPrint(allocator, ".den-replacement-{d}", .{unique_id});
    defer allocator.free(replacement_name);
    defer parent_dir.deleteFile(runtime_io, replacement_name) catch {};

    try staging_dir.copyFile(platform.executable, parent_dir, replacement_name, runtime_io, .{
        .permissions = if (builtin.os.tag == .windows)
            .default_file
        else
            std.Io.File.Permissions.fromMode(0o755),
    });

    // Renaming a fully validated file from the same directory gives Unix an
    // atomic replacement and leaves the running process's inode intact.
    try parent_dir.rename(replacement_name, parent_dir, executable_name, runtime_io);
    std.debug.print("Updated Den from v{s} to v{s}.\n", .{ current_version_text, release_version_text });
}

fn currentPlatform() !Platform {
    const os = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        .freebsd => "freebsd",
        else => return error.UnsupportedUpgradePlatform,
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return error.UnsupportedUpgradeArchitecture,
    };
    return .{
        .os = os,
        .arch = arch,
        .extension = if (builtin.os.tag == .windows) "zip" else "tar.gz",
        .executable = if (builtin.os.tag == .windows) "den.exe" else "den",
    };
}

fn assetName(allocator: std.mem.Allocator, platform: Platform, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "den-{s}-{s}-{s}.{s}",
        .{ platform.os, platform.arch, version, platform.extension },
    );
}

fn findAsset(assets: []const Asset, name: []const u8) ?Asset {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset;
    }
    return null;
}

fn fetchAlloc(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    max_bytes: usize,
) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .headers = .{
            .user_agent = .{ .override = "den-updater" },
            .accept_encoding = .{ .override = "gzip, deflate" },
        },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
    });
    if (result.status != .ok) return error.GitHubRequestFailed;
    if (body.written().len > max_bytes) return error.ReleaseDownloadTooLarge;
    return try body.toOwnedSlice();
}

fn checksumForAsset(checksums: []const u8, asset_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, checksums, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const checksum = fields.next() orelse continue;
        var filename = fields.next() orelse continue;
        if (filename.len > 0 and filename[0] == '*') filename = filename[1..];
        if (std.mem.eql(u8, filename, asset_name)) return checksum;
    }
    return null;
}

fn verifyChecksum(contents: []const u8, expected: []const u8) !void {
    if (expected.len != std.crypto.hash.sha2.Sha256.digest_length * 2)
        return error.InvalidReleaseChecksum;
    for (expected) |char| {
        if (!std.ascii.isHex(char)) return error.InvalidReleaseChecksum;
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual, expected)) return error.ReleaseChecksumMismatch;
}

fn writeFile(runtime_io: std.Io, path: []const u8, contents: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(runtime_io, path, .{ .truncate = true });
    defer file.close(runtime_io);
    try file.writeStreamingAll(runtime_io, contents);
}

fn extractArchive(
    allocator: std.mem.Allocator,
    runtime_io: std.Io,
    archive_path: []const u8,
    staging_path: []const u8,
) !void {
    const result = try std.process.run(allocator, runtime_io, .{
        .argv = &.{ "tar", "-xf", archive_path, "-C", staging_path },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term.exited != 0) {
        if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
        return error.ReleaseExtractionFailed;
    }
}

fn makeExecutable(runtime_io: std.Io, dir: std.Io.Dir, executable_name: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const file = try dir.openFile(runtime_io, executable_name, .{ .mode = .read_write });
    defer file.close(runtime_io);
    try file.setPermissions(runtime_io, std.Io.File.Permissions.fromMode(0o755));
}

fn validateBinary(
    allocator: std.mem.Allocator,
    runtime_io: std.Io,
    staging_path: []const u8,
    executable_name: []const u8,
    expected_version: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ staging_path, executable_name });
    defer allocator.free(path);
    const result = try std.process.run(allocator, runtime_io, .{
        .argv = &.{ path, "version" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term.exited != 0) return error.InvalidReleaseBinary;

    const expected = try std.fmt.allocPrint(allocator, "Den Shell v{s}", .{expected_version});
    defer allocator.free(expected);
    const actual = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (!std.mem.eql(u8, actual, expected)) return error.ReleaseVersionMismatch;
}

test "parse upgrade options" {
    const check = try parseOptions(&.{ "--check", "--force" });
    try std.testing.expect(check.check_only);
    try std.testing.expect(check.force);
    try std.testing.expectError(error.InvalidUpgradeOption, parseOptions(&.{"--unknown"}));
}

test "release asset naming follows Pantry archives" {
    const name = try assetName(std.testing.allocator, .{
        .os = "darwin",
        .arch = "arm64",
        .extension = "tar.gz",
        .executable = "den",
    }, "0.2.1");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("den-darwin-arm64-0.2.1.tar.gz", name);
}

test "checksum manifest lookup accepts GNU and binary formats" {
    const manifest =
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  first.tar.gz
        \\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *second.zip
    ;
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        checksumForAsset(manifest, "first.tar.gz").?,
    );
    try std.testing.expectEqualStrings(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        checksumForAsset(manifest, "second.zip").?,
    );
    try std.testing.expect(checksumForAsset(manifest, "missing") == null);
}

test "checksum verification rejects corrupt contents" {
    const checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try verifyChecksum("abc", checksum);
    try std.testing.expectError(error.ReleaseChecksumMismatch, verifyChecksum("abd", checksum));
    try std.testing.expectError(error.InvalidReleaseChecksum, verifyChecksum("abc", "invalid"));
}
