const std = @import("std");

/// Main configuration for the Den shell
pub const DenConfig = struct {
    verbose: bool = false,
    stream_output: ?bool = null,
    /// Enable automatic config reload when config file changes
    hot_reload: bool = false,

    prompt: PromptConfig = .{},
    history: HistoryConfig = .{},
    completion: CompletionConfig = .{},
    theme: ThemeConfig = .{},
    expansion: ExpansionConfig = .{},
    aliases: AliasConfig = .{},
    keybindings: KeybindingConfig = .{},
    environment: EnvironmentConfig = .{},
    line_editor: LineEditorConfig = .{},
    zsh: ZshCompatConfig = .{},
    ai: AiConfig = .{},
};

/// Interactive line-editor configuration (syntax highlighting, autosuggestions)
pub const LineEditorConfig = struct {
    /// Colorize the command line as you type
    syntax_highlighting: bool = true,
    /// Fish-style inline suggestions sourced from history
    autosuggestions: bool = true,
    /// Minimum number of characters typed before a suggestion is offered
    suggestion_min_chars: u32 = 1,
};

/// zsh compatibility layer configuration
pub const ZshCompatConfig = struct {
    /// Master toggle for zsh-compatible behaviors
    enabled: bool = true,
    /// Honor zsh glob qualifiers like *(.) *(/) *(x)
    glob_qualifiers: bool = true,
    /// Expand zsh %-style prompt escapes (%n %m %~ %# ...)
    prompt_escapes: bool = true,
    /// Accept `setopt`/`unsetopt` with zsh option names
    setopt: bool = true,
};

/// AI-assisted completion configuration
pub const AiConfig = struct {
    /// Enable AI-assisted command suggestions
    enabled: bool = false,
    /// OpenAI-compatible chat-completions endpoint
    endpoint: []const u8 = "https://api.openai.com/v1/chat/completions",
    /// Model identifier to request
    model: []const u8 = "gpt-4o-mini",
    /// Name of the environment variable holding the API key
    api_key_env: []const u8 = "OPENAI_API_KEY",
    /// Maximum tokens to request for a suggestion
    max_tokens: u32 = 64,
    /// Request timeout in milliseconds
    timeout_ms: u32 = 4000,
};

/// Environment configuration - default environment variables
pub const EnvironmentConfig = struct {
    /// Enable loading environment from config
    enabled: bool = true,
    /// Custom environment variables (loaded at startup)
    variables: ?[]const EnvEntry = null,

    pub const EnvEntry = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Default environment variables (always set if not already defined)
    pub const defaults = [_]EnvEntry{
        .{ .name = "EDITOR", .value = "vim" },
        .{ .name = "VISUAL", .value = "vim" },
        .{ .name = "PAGER", .value = "less" },
        .{ .name = "LESS", .value = "-R" },
        .{ .name = "GREP_OPTIONS", .value = "--color=auto" },
        .{ .name = "CLICOLOR", .value = "1" },
        .{ .name = "LSCOLORS", .value = "GxFxCxDxBxegedabagaced" },
        .{ .name = "HISTCONTROL", .value = "ignoreboth" },
    };
};

/// Alias configuration - predefined shell aliases
pub const AliasConfig = struct {
    /// Enable loading aliases from config
    enabled: bool = true,
    /// Custom aliases map (loaded at runtime)
    custom: ?[]const AliasEntry = null,
    /// Suffix aliases (zsh-style: maps file extensions to commands)
    /// Example: { "extension": "ts", "command": "bun" } allows typing "hello.ts" to run "bun hello.ts"
    suffix: ?[]const SuffixAliasEntry = null,

    pub const AliasEntry = struct {
        name: []const u8,
        command: []const u8,
    };

    pub const SuffixAliasEntry = struct {
        extension: []const u8,
        command: []const u8,
    };
};

/// Keybinding configuration
pub const KeybindingConfig = struct {
    /// Editing mode: emacs or vi
    mode: EditMode = .emacs,
    /// Custom keybindings
    custom: ?[]const KeybindEntry = null,

    pub const EditMode = enum {
        emacs,
        vi,
    };

    pub const KeybindEntry = struct {
        key: []const u8,
        action: []const u8,
    };
};

pub const PromptConfig = struct {
    format: []const u8 = "{symbol} {path}{git}{modules} ",
    /// How {path} renders the working directory
    path_style: PathStyle = .full,
    /// How {git} renders branch and working-tree state
    git_style: GitStyle = .compact,
    show_git: bool = true,
    show_time: bool = false,
    show_user: bool = false,
    show_host: bool = false,
    show_path: bool = true,
    show_exit_code: bool = true,
    right_prompt: ?[]const u8 = null,
    transient: bool = false,
    simple_when_not_tty: bool = true,

    pub const PathStyle = enum {
        /// Only the current directory name: ~/Documents/Projects/den -> den
        basename,
        /// The whole home-relative path: ~/Documents/Projects/den
        full,
    };

    pub const GitStyle = enum {
        /// git:(main) !32 ?85 $1
        compact,
        /// on 🌱 main ✓ !32 ?85 $1
        verbose,
    };
};

pub const HistoryConfig = struct {
    max_entries: u32 = 50000,
    file: []const u8 = "~/.den_history",
    ignore_duplicates: bool = true,
    ignore_space: bool = true,
    search_mode: SearchMode = .fuzzy,
    search_limit: ?u32 = null,

    pub const SearchMode = enum {
        fuzzy,
        exact,
        startswith,
        regex,
    };
};

pub const CompletionConfig = struct {
    enabled: bool = true,
    case_sensitive: bool = false,
    show_descriptions: bool = true,
    max_suggestions: u32 = 15,
    cache: CompletionCacheConfig = .{},
};

pub const CompletionCacheConfig = struct {
    enabled: bool = true,
    ttl: u32 = 3600000, // 1 hour in milliseconds
    max_entries: u32 = 1000,
};

pub const ThemeConfig = struct {
    name: []const u8 = "default",
    auto_detect_color_scheme: bool = true,
    enable_right_prompt: bool = true,
    colors: ColorConfig = .{},
    symbols: SymbolConfig = .{},
};

pub const ColorConfig = struct {
    primary: []const u8 = "#00D9FF",
    secondary: []const u8 = "#FF6B9D",
    success: []const u8 = "#00FF88",
    warning: []const u8 = "#FFD700",
    err: []const u8 = "#FF4757",
    info: []const u8 = "#74B9FF",
};

pub const SymbolConfig = struct {
    prompt: []const u8 = "➜",
    continuation: []const u8 = "…",
};

pub const ExpansionConfig = struct {
    cache_limits: CacheLimits = .{},

    pub const CacheLimits = struct {
        arg: u32 = 200,
        exec: u32 = 500,
        arithmetic: u32 = 500,
        glob: u32 = 256,
        variable: u32 = 256,
    };
};

test "DenConfig default values" {
    const config = DenConfig{};
    try std.testing.expect(config.verbose == false);
    try std.testing.expect(config.history.max_entries == 50000);
    try std.testing.expectEqualStrings("~/.den_history", config.history.file);
}
