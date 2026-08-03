const std = @import("std");

/// Module information
pub const ModuleInfo = struct {
    name: []const u8,
    version: ?[]const u8,
    icon: ?[]const u8,
    color: ?[]const u8,
    enabled: bool,

    pub fn init(name: []const u8) ModuleInfo {
        return .{
            .name = name,
            .version = null,
            .icon = null,
            .color = null,
            .enabled = true,
        };
    }

    pub fn deinit(self: *const ModuleInfo, allocator: std.mem.Allocator) void {
        if (self.version) |v| allocator.free(v);
    }
};

/// Module detector function signature
pub const DetectorFn = *const fn (allocator: std.mem.Allocator, cwd: []const u8) anyerror!?ModuleInfo;

/// Module configuration
pub const ModuleConfig = struct {
    enabled: bool,
    icon: ?[]const u8,
    color: ?[]const u8,
    show_version: bool,
    format: ?[]const u8, // Format string like "via {symbol} {version}"

    pub fn initDefault() ModuleConfig {
        return .{
            .enabled = true,
            .icon = null,
            .color = null,
            .show_version = true,
            .format = null,
        };
    }

    pub fn withFormat(format: []const u8) ModuleConfig {
        return .{
            .enabled = true,
            .icon = null,
            .color = null,
            .show_version = true,
            .format = format,
        };
    }
};

/// Language module information
pub const LanguageModule = struct {
    name: []const u8,
    command: []const u8,
    version_flag: []const u8,
    icon: []const u8,
    color: []const u8,
    file_patterns: []const []const u8,

    pub const Bun = LanguageModule{
        .name = "bun",
        .command = "bun",
        .version_flag = "--version",
        .icon = "🐰",
        .color = "#fbf0df",
        .file_patterns = &[_][]const u8{ "bun.lockb", "bunfig.toml" },
    };

    pub const Node = LanguageModule{
        .name = "node",
        .command = "node",
        .version_flag = "--version",
        .icon = "⬢",
        .color = "#339933",
        .file_patterns = &[_][]const u8{ "package.json", ".nvmrc", ".node-version" },
    };

    pub const Python = LanguageModule{
        .name = "python",
        .command = "python",
        .version_flag = "--version",
        .icon = "🐍",
        .color = "#3776ab",
        .file_patterns = &[_][]const u8{ "requirements.txt", "setup.py", "pyproject.toml", ".python-version", "Pipfile" },
    };

    pub const Go = LanguageModule{
        .name = "go",
        .command = "go",
        .version_flag = "version",
        .icon = "🐹",
        .color = "#00add8",
        .file_patterns = &[_][]const u8{ "go.mod", "go.sum" },
    };

    pub const Zig = LanguageModule{
        .name = "zig",
        .command = "zig",
        .version_flag = "version",
        .icon = "⚡",
        .color = "#f7a41d",
        .file_patterns = &[_][]const u8{ "build.zig", "build.zig.zon" },
    };

    pub const Rust = LanguageModule{
        .name = "rust",
        .command = "rustc",
        .version_flag = "--version",
        .icon = "🦀",
        .color = "#dea584",
        .file_patterns = &[_][]const u8{ "Cargo.toml", "Cargo.lock" },
    };

    pub const Java = LanguageModule{
        .name = "java",
        .command = "java",
        .version_flag = "-version",
        .icon = "☕",
        .color = "#007396",
        .file_patterns = &[_][]const u8{ "pom.xml", "build.gradle", "build.gradle.kts", ".java-version" },
    };

    pub const Ruby = LanguageModule{
        .name = "ruby",
        .command = "ruby",
        .version_flag = "--version",
        .icon = "💎",
        .color = "#cc342d",
        .file_patterns = &[_][]const u8{ "Gemfile", ".ruby-version" },
    };

    pub const PHP = LanguageModule{
        .name = "php",
        .command = "php",
        .version_flag = "--version",
        .icon = "🐘",
        .color = "#777bb4",
        .file_patterns = &[_][]const u8{ "composer.json", ".php-version" },
    };
};

/// Cloud provider information
pub const CloudProvider = struct {
    name: []const u8,
    icon: []const u8,
    color: []const u8,
    env_vars: []const []const u8,
    config_paths: []const []const u8,

    pub const AWS = CloudProvider{
        .name = "aws",
        .icon = "☁️",
        .color = "#ff9900",
        .env_vars = &[_][]const u8{ "AWS_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION" },
        .config_paths = &[_][]const u8{ ".aws/config", ".aws/credentials" },
    };

    pub const Azure = CloudProvider{
        .name = "azure",
        .icon = "󰠅",
        .color = "#0078d4",
        .env_vars = &[_][]const u8{ "AZURE_SUBSCRIPTION_ID", "AZURE_TENANT_ID" },
        .config_paths = &[_][]const u8{".azure/azureProfile.json"},
    };

    pub const GCP = CloudProvider{
        .name = "gcp",
        .icon = "󱇶",
        .color = "#4285f4",
        .env_vars = &[_][]const u8{ "GOOGLE_CLOUD_PROJECT", "GCP_PROJECT", "GCLOUD_PROJECT" },
        .config_paths = &[_][]const u8{".config/gcloud/configurations/config_default"},
    };
};

/// Battery information
pub const BatteryInfo = struct {
    percentage: u8,
    is_charging: bool,
};

/// Memory information
pub const MemoryInfo = struct {
    used_bytes: u64,
    total_bytes: u64,
    percentage: u8,
};

/// Cloud context information
pub const CloudContext = struct {
    provider: []const u8,
    profile: ?[]const u8,
    region: ?[]const u8,
    project: ?[]const u8,
    icon: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, provider: []const u8, icon: []const u8) CloudContext {
        return .{
            .provider = provider,
            .profile = null,
            .region = null,
            .project = null,
            .icon = icon,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const CloudContext) void {
        if (self.profile) |p| self.allocator.free(p);
        if (self.region) |r| self.allocator.free(r);
        if (self.project) |p| self.allocator.free(p);
    }
};
