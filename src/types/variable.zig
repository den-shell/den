const std = @import("std");

/// Sparse indexed array (bash semantics).
///
/// Values are stored contiguously in ascending-subscript order, with a parallel
/// `indices` slice giving each value's logical subscript. A dense array (the
/// common `arr=(a b c)` case) is just the special case where `indices[k] == k`.
/// Storing only the elements that were actually set lets `arr[5]=x` behave like
/// bash (length 1, key list "5") instead of materialising indices 0..5.
///
/// Both `values` and `indices` are always heap-allocated (possibly length 0) so
/// that every stored array can be freed uniformly via `deinit`.
pub const IndexedArray = struct {
    values: [][]const u8,
    indices: []usize,

    /// Number of elements actually set.
    pub fn len(self: IndexedArray) usize {
        return self.values.len;
    }

    /// Storage slot holding logical subscript `idx`, or null if unset.
    /// `indices` is kept sorted ascending, so this binary-searches.
    pub fn slotOf(self: IndexedArray, idx: usize) ?usize {
        var lo: usize = 0;
        var hi: usize = self.indices.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = self.indices[mid];
            if (v == idx) return mid;
            if (v < idx) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Value at logical subscript `idx`, or null if that subscript is unset.
    pub fn getIndex(self: IndexedArray, idx: usize) ?[]const u8 {
        return if (self.slotOf(idx)) |s| self.values[s] else null;
    }

    /// Free value strings plus the backing slices.
    pub fn deinit(self: IndexedArray, allocator: std.mem.Allocator) void {
        for (self.values) |v| allocator.free(v);
        allocator.free(self.values);
        allocator.free(self.indices);
    }

    /// Free only the backing slices, leaving the value strings alive (used when
    /// ownership of the strings has moved into a newly built array).
    pub fn deinitShallow(self: IndexedArray, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        allocator.free(self.indices);
    }

    /// Build an empty array with heap-allocated (length 0) backing slices.
    pub fn initEmpty(allocator: std.mem.Allocator) !IndexedArray {
        return .{
            .values = try allocator.alloc([]const u8, 0),
            .indices = try allocator.alloc(usize, 0),
        };
    }

    /// Take ownership of `values` and assign dense subscripts 0..N-1.
    pub fn fromOwnedDense(allocator: std.mem.Allocator, values: [][]const u8) !IndexedArray {
        const indices = try allocator.alloc(usize, values.len);
        errdefer allocator.free(indices);
        for (indices, 0..) |*p, i| p.* = i;
        return .{ .values = values, .indices = indices };
    }

    /// Set logical subscript `idx` to a copy of `value`, inserting sparsely so
    /// that gaps stay unset (matching bash). Existing subscripts are replaced
    /// in place.
    pub fn setIndex(self: *IndexedArray, allocator: std.mem.Allocator, idx: usize, value: []const u8) !void {
        if (self.slotOf(idx)) |s| {
            const dup = try allocator.dupe(u8, value);
            allocator.free(self.values[s]);
            self.values[s] = dup;
            return;
        }
        // Find the ascending insertion slot (first existing subscript > idx).
        var ins: usize = self.indices.len;
        for (self.indices, 0..) |existing, k| {
            if (existing > idx) {
                ins = k;
                break;
            }
        }
        const n = self.values.len;
        const new_vals = try allocator.alloc([]const u8, n + 1);
        errdefer allocator.free(new_vals);
        const new_idx = try allocator.alloc(usize, n + 1);
        errdefer allocator.free(new_idx);
        const dup = try allocator.dupe(u8, value);
        @memcpy(new_vals[0..ins], self.values[0..ins]);
        @memcpy(new_idx[0..ins], self.indices[0..ins]);
        new_vals[ins] = dup;
        new_idx[ins] = idx;
        @memcpy(new_vals[ins + 1 ..], self.values[ins..]);
        @memcpy(new_idx[ins + 1 ..], self.indices[ins..]);
        allocator.free(self.values);
        allocator.free(self.indices);
        self.values = new_vals;
        self.indices = new_idx;
    }

    /// Append `value` after the current highest subscript (used by `arr+=(v)`).
    pub fn appendValue(self: *IndexedArray, allocator: std.mem.Allocator, value: []const u8) !void {
        const next: usize = if (self.indices.len == 0) 0 else self.indices[self.indices.len - 1] + 1;
        try self.setIndex(allocator, next, value);
    }

    /// Remove the value at logical subscript `idx`, leaving a gap (bash's
    /// `unset arr[i]` does not renumber). No-op if the subscript is unset.
    pub fn removeIndex(self: *IndexedArray, allocator: std.mem.Allocator, idx: usize) !void {
        const s = self.slotOf(idx) orelse return;
        allocator.free(self.values[s]);
        const n = self.values.len;
        const new_vals = try allocator.alloc([]const u8, n - 1);
        errdefer allocator.free(new_vals);
        const new_idx = try allocator.alloc(usize, n - 1);
        errdefer allocator.free(new_idx);
        @memcpy(new_vals[0..s], self.values[0..s]);
        @memcpy(new_idx[0..s], self.indices[0..s]);
        @memcpy(new_vals[s..], self.values[s + 1 ..]);
        @memcpy(new_idx[s..], self.indices[s + 1 ..]);
        allocator.free(self.values);
        allocator.free(self.indices);
        self.values = new_vals;
        self.indices = new_idx;
    }
};

/// Variable attributes for declare/typeset
pub const VarAttributes = packed struct {
    readonly: bool = false, // -r: readonly
    integer: bool = false, // -i: integer attribute
    exported: bool = false, // -x: export to environment
    lowercase: bool = false, // -l: convert to lowercase
    uppercase: bool = false, // -u: convert to uppercase
    nameref: bool = false, // -n: name reference
    indexed_array: bool = false, // -a: indexed array
    assoc_array: bool = false, // -A: associative array
    immutable: bool = false, // let binding (immutable by default)
};

/// Variable type - can be a string, indexed array, or associative array
pub const Variable = union(enum) {
    string: []const u8,
    array: [][]const u8,
    assoc: std.StringHashMap([]const u8),

    pub fn deinit(self: *Variable, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |item| {
                    allocator.free(item);
                }
                allocator.free(arr);
            },
            .assoc => |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                map.deinit();
            },
        }
    }

    pub fn clone(self: Variable, allocator: std.mem.Allocator) !Variable {
        return switch (self) {
            .string => |s| Variable{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                const new_arr = try allocator.alloc([]const u8, arr.len);
                errdefer allocator.free(new_arr);
                var filled: usize = 0;
                errdefer for (new_arr[0..filled]) |item| allocator.free(item);

                for (arr, 0..) |item, i| {
                    new_arr[i] = try allocator.dupe(u8, item);
                    filled = i + 1;
                }
                break :blk Variable{ .array = new_arr };
            },
            .assoc => |map| blk: {
                var new_map = std.StringHashMap([]const u8).init(allocator);
                errdefer {
                    var cleanup_it = new_map.iterator();
                    while (cleanup_it.next()) |e| {
                        allocator.free(e.key_ptr.*);
                        allocator.free(e.value_ptr.*);
                    }
                    new_map.deinit();
                }

                var it = map.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    const value = try allocator.dupe(u8, entry.value_ptr.*);
                    errdefer allocator.free(value);
                    try new_map.put(key, value);
                }
                break :blk Variable{ .assoc = new_map };
            },
        };
    }

    /// Get as string - arrays join with spaces, assoc returns keys
    pub fn asString(self: Variable, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| try allocator.dupe(u8, s),
            .array => |arr| {
                if (arr.len == 0) return try allocator.dupe(u8, "");
                if (arr.len == 1) return try allocator.dupe(u8, arr[0]);

                // Calculate total length
                var total_len: usize = 0;
                for (arr) |item| {
                    total_len += item.len;
                }
                total_len += arr.len - 1; // spaces between elements

                // Join with spaces
                const result = try allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (arr, 0..) |item, i| {
                    @memcpy(result[pos..][0..item.len], item);
                    pos += item.len;
                    if (i < arr.len - 1) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
                return result;
            },
            .assoc => |map| {
                // Return space-separated keys
                var total_len: usize = 0;
                var count: usize = 0;
                var it = map.iterator();
                while (it.next()) |entry| {
                    total_len += entry.key_ptr.*.len;
                    count += 1;
                }
                if (count == 0) return try allocator.dupe(u8, "");
                total_len += count - 1; // spaces

                const result = try allocator.alloc(u8, total_len);
                var pos: usize = 0;
                var first = true;
                it = map.iterator();
                while (it.next()) |entry| {
                    if (!first) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                    first = false;
                    const key = entry.key_ptr.*;
                    @memcpy(result[pos..][0..key.len], key);
                    pos += key.len;
                }
                return result;
            },
        };
    }

    /// Get length - 1 for strings, array.len for arrays, map.count for assoc
    pub fn length(self: Variable) usize {
        return switch (self) {
            .string => 1,
            .array => |arr| arr.len,
            .assoc => |map| map.count(),
        };
    }
};
