const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

const HelpEntry = struct {
    name: []const u8,
    category: []const u8,
    usage: []const u8,
    description: []const u8,
    examples: []const []const u8,
    related: []const []const u8,
};

const help_entries = [_]HelpEntry{
    // Data format commands
    .{
        .name = "from",
        .category = "data",
        .usage = "from <format> [input]",
        .description = "Parse structured data from text. Supported formats: json, csv, toml, yaml",
        .examples = &.{ "cat data.json | from json", "from csv < data.csv", "echo '{\"key\": 1}' | from json" },
        .related = &.{ "to", "table", "where", "select" },
    },
    .{
        .name = "to",
        .category = "data",
        .usage = "to <format>",
        .description = "Convert structured data to text format. Supported formats: json, csv, toml, yaml",
        .examples = &.{ "ls | to json", "data | to csv" },
        .related = &.{ "from", "table" },
    },
    // Pipeline commands
    .{
        .name = "where",
        .category = "pipeline",
        .usage = "where <field> <op> <value>",
        .description = "Filter rows matching a condition. Operators: ==, !=, >, <, >=, <=, =~",
        .examples = &.{ "ls | where size > 1000", "from json | where status == active" },
        .related = &.{ "select", "reject", "find", "first", "last" },
    },
    .{
        .name = "select",
        .category = "pipeline",
        .usage = "select <col1> [col2...]",
        .description = "Select specific columns from a table",
        .examples = &.{ "ls | select name size", "from csv | select id name" },
        .related = &.{ "reject", "get", "where" },
    },
    .{
        .name = "get",
        .category = "pipeline",
        .usage = "get <field>",
        .description = "Get a specific field from a record or index from a list",
        .examples = &.{ "from json | get name", "ls | get 0" },
        .related = &.{ "select", "first" },
    },
    .{
        .name = "length",
        .category = "pipeline",
        .usage = "length",
        .description = "Count the number of items in a list, rows in a table, or characters in a string",
        .examples = &.{"ls | length"},
        .related = &.{ "first", "last", "skip" },
    },
    // String commands
    .{
        .name = "str",
        .category = "string",
        .usage = "str <subcommand> [args...]",
        .description = "String manipulation commands",
        .examples = &.{ "echo hello | str upcase", "str replace old new input", "str split , data" },
        .related = &.{ "str trim", "str replace", "str split", "str join" },
    },
    // Math commands
    .{
        .name = "math",
        .category = "math",
        .usage = "math <subcommand> [args...]",
        .description = "Mathematical operations and statistics",
        .examples = &.{ "echo '1 2 3 4 5' | math sum", "echo '1 2 3' | math avg", "math sqrt 16" },
        .related = &.{ "math sum", "math avg", "math min", "math max" },
    },
    // Path commands
    .{
        .name = "path",
        .category = "path",
        .usage = "path <subcommand> [args...]",
        .description = "Path manipulation commands",
        .examples = &.{ "path parse /home/user/file.txt", "path basename /home/user/file.txt", "path exists ./file" },
        .related = &.{ "path parse", "path join", "path exists" },
    },
    // Conversion
    .{
        .name = "into",
        .category = "conversion",
        .usage = "into <type> [input]",
        .description = "Convert between types: int, string, float, bool, datetime, duration, filesize, binary",
        .examples = &.{ "echo 42 | into float", "into int 0xff", "echo yes | into bool" },
        .related = &.{ "from", "to" },
    },
    // Encoding
    .{
        .name = "encode",
        .category = "encoding",
        .usage = "encode <format> [input]",
        .description = "Encode data. Formats: base64, hex, url",
        .examples = &.{ "echo hello | encode base64", "encode hex data" },
        .related = &.{"decode"},
    },
    .{
        .name = "decode",
        .category = "encoding",
        .usage = "decode <format> [input]",
        .description = "Decode data. Formats: base64, hex, url",
        .examples = &.{ "echo aGVsbG8= | decode base64", "decode url hello%20world" },
        .related = &.{"encode"},
    },
    .{
        .name = "detect",
        .category = "data",
        .usage = "detect columns",
        .description = "Auto-detect columns from whitespace-aligned text output",
        .examples = &.{ "ps aux | detect columns", "df -h | detect columns" },
        .related = &.{ "from", "table" },
    },
    .{
        .name = "bench",
        .category = "utility",
        .usage = "bench [--rounds N] <command...>",
        .description = "Benchmark a command by running it multiple times",
        .examples = &.{"bench --rounds 100 echo hello"},
        .related = &.{"time"},
    },
    .{
        .name = "http",
        .category = "utility",
        .usage = "http <method> <url> [--body <data>] [--header <key:value>] [--content-type <type>]",
        .description = "HTTP client supporting GET, POST, PUT, DELETE, and HEAD requests (via curl)",
        .examples = &.{ "http get https://api.example.com/users", "http post https://api.example.com/data --body 'payload' --content-type application/json" },
        .related = &.{"bench"},
    },
    .{
        .name = "table",
        .category = "display",
        .usage = "table",
        .description = "Display piped data as a formatted table",
        .examples = &.{ "from json < data.json | table", "ls | table" },
        .related = &.{ "grid", "from" },
    },
    .{
        .name = "grid",
        .category = "display",
        .usage = "grid",
        .description = "Display piped data in a compact grid format",
        .examples = &.{ "ls | grid", "seq 1 20 | grid" },
        .related = &.{ "table", "from" },
    },
};

/// Enhanced help command with structured help data
/// Whether `help <topic>` has an entry for this name.
///
/// Lets a caller decide between showing the entry and falling back to the full
/// listing, rather than finding out only after "No help found" has been printed.
pub fn hasTopic(topic: []const u8) bool {
    for (help_entries) |entry| {
        if (std.mem.eql(u8, entry.name, topic)) return true;
    }
    for (help_entries) |entry| {
        if (std.mem.indexOf(u8, entry.name, topic) != null) return true;
    }
    return false;
}

pub fn helpCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        return helpOverview();
    }
    const topic = command.args[0];

    // Search for help entry
    for (help_entries) |entry| {
        if (std.mem.eql(u8, entry.name, topic)) {
            return displayHelpEntry(allocator, entry);
        }
    }

    // No exact match - try partial match
    for (help_entries) |entry| {
        if (std.mem.indexOf(u8, entry.name, topic) != null) {
            return displayHelpEntry(allocator, entry);
        }
    }

    try IO.eprint("No help found for: {s}\n", .{topic});
    try IO.eprint("Try: help (for overview)\n", .{});
    return 1;
}

fn helpOverview() !i32 {
    try IO.print("\x1b[1mDen Shell - Command Reference\x1b[0m\n\n", .{});
    try IO.print("\x1b[1;36mData Formats:\x1b[0m\n", .{});
    try IO.print("  from json|csv|toml|yaml   Parse structured data\n", .{});
    try IO.print("  to json|csv|toml|yaml     Convert to text format\n", .{});
    try IO.print("  table                     Display as formatted table\n", .{});
    try IO.print("  grid                      Display in grid format\n", .{});
    try IO.print("  detect columns            Auto-detect columns from text\n\n", .{});

    try IO.print("\x1b[1;36mPipeline Operations:\x1b[0m\n", .{});
    try IO.print("  where <field> <op> <val>  Filter rows\n", .{});
    try IO.print("  select <col1> [col2...]   Select columns\n", .{});
    try IO.print("  reject <col1> [col2...]   Remove columns\n", .{});
    try IO.print("  get <field>               Get field value\n", .{});
    try IO.print("  first [N]                 First N items\n", .{});
    try IO.print("  last [N]                  Last N items\n", .{});
    try IO.print("  skip [N]                  Skip N items\n", .{});
    try IO.print("  length                    Count items\n", .{});
    try IO.print("  sort-by [col]             Sort items\n", .{});
    try IO.print("  uniq                      Remove duplicates\n", .{});
    try IO.print("  reverse                   Reverse order\n", .{});
    try IO.print("  flatten                   Flatten nested lists\n", .{});
    try IO.print("  group-by <col>            Group by column\n", .{});
    try IO.print("  transpose                 Transpose record/table\n", .{});
    try IO.print("  enumerate                 Add index to items\n", .{});
    try IO.print("  wrap <col>                Wrap value in record\n", .{});
    try IO.print("  compact                   Remove nulls\n", .{});
    try IO.print("  rename <old> <new>        Rename column\n", .{});
    try IO.print("  append <val>              Append to list\n", .{});
    try IO.print("  prepend <val>             Prepend to list\n", .{});
    try IO.print("  columns                   List column names\n", .{});
    try IO.print("  values                    List record values\n\n", .{});

    try IO.print("\x1b[1;36mString Commands:\x1b[0m\n", .{});
    try IO.print("  str trim|upcase|downcase|capitalize|replace|split|join\n", .{});
    try IO.print("  str starts-with|ends-with|contains|length|substring\n", .{});
    try IO.print("  str reverse|pad-left|pad-right|distance\n\n", .{});

    try IO.print("\x1b[1;36mMath Commands:\x1b[0m\n", .{});
    try IO.print("  math sum|avg|min|max|product|median|mode|stddev|variance\n", .{});
    try IO.print("  math abs|ceil|floor|round|sqrt|log\n\n", .{});

    try IO.print("\x1b[1;36mPath Commands:\x1b[0m\n", .{});
    try IO.print("  path join|parse|split|type|exists|expand|basename|dirname|extension\n\n", .{});

    try IO.print("\x1b[1;36mConversion:\x1b[0m\n", .{});
    try IO.print("  into int|string|float|bool|datetime|duration|filesize|binary\n", .{});
    try IO.print("  encode|decode base64|hex|url\n\n", .{});

    try IO.print("\x1b[1;36mUtilities:\x1b[0m\n", .{});
    try IO.print("  bench [--rounds N] <cmd>  Benchmark command\n", .{});
    try IO.print("  date now|format|to-record|humanize  Date operations\n\n", .{});

    try IO.print("Type 'help <command>' for detailed help on a specific command.\n", .{});
    return 0;
}

fn displayHelpEntry(allocator: std.mem.Allocator, entry: HelpEntry) !i32 {
    _ = allocator;
    try IO.print("\x1b[1m{s}\x1b[0m", .{entry.name});
    try IO.print("  [{s}]\n\n", .{entry.category});
    try IO.print("\x1b[1;36mUsage:\x1b[0m {s}\n\n", .{entry.usage});
    try IO.print("\x1b[1;36mDescription:\x1b[0m\n  {s}\n", .{entry.description});

    if (entry.examples.len > 0) {
        try IO.print("\n\x1b[1;36mExamples:\x1b[0m\n", .{});
        for (entry.examples) |example| {
            try IO.print("  > {s}\n", .{example});
        }
    }

    if (entry.related.len > 0) {
        try IO.print("\n\x1b[1;36mRelated:\x1b[0m ", .{});
        for (entry.related, 0..) |rel, i| {
            if (i > 0) try IO.print(", ", .{});
            try IO.print("{s}", .{rel});
        }
        try IO.print("\n", .{});
    }
    return 0;
}
