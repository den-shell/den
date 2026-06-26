const std = @import("std");

pub const config = @import("config.zig");
pub const command = @import("command.zig");
pub const variable = @import("variable.zig");
pub const shell_options = @import("shell_options.zig");
pub const value = @import("value.zig");
pub const value_format = @import("value_format.zig");
pub const closure = @import("closure.zig");
pub const metadata = @import("metadata.zig");

// Re-export commonly used types
pub const DenConfig = config.DenConfig;
pub const PromptConfig = config.PromptConfig;
pub const HistoryConfig = config.HistoryConfig;
pub const CompletionConfig = config.CompletionConfig;
pub const ThemeConfig = config.ThemeConfig;
pub const EnvironmentConfig = config.EnvironmentConfig;

pub const ParsedCommand = command.ParsedCommand;
pub const CommandType = command.CommandType;
pub const Operator = command.Operator;
pub const Redirection = command.Redirection;
pub const CommandChain = command.CommandChain;

pub const Variable = variable.Variable;
pub const VarAttributes = variable.VarAttributes;
pub const IndexedArray = variable.IndexedArray;

pub const Value = value.Value;

pub const Closure = closure.Closure;

pub const ShellOptions = shell_options.ShellOptions;
pub const SetOptions = shell_options.SetOptions;
pub const ShoptOptions = shell_options.ShoptOptions;

pub const PipelineMetadata = metadata.PipelineMetadata;
pub const ContentType = metadata.ContentType;

test {
    std.testing.refAllDecls(@This());
}
