//! OhSnap! A Prettified Snapshot Testing Library.
//!
//! Based on a core of TigerBeetle's snaptest.zig[^1].
//!
//! Integrates @timfayz's pretty-printing library, pretty[^2], in order
//! to have general-purpose printing of data structures, and for diffs,
//! diffz[^3].  Last, but not least, for the regex library: the Minimum
//! Viable Zig Regex[^4].
//!
//! [^1]: https://github.com/tigerbeetle/tigerbeetle/blob/main/src/testing/snaptest.zig.
//! [^2]: https://github.com/timfayz/pretty
//! [^3]: https://github.com/ziglibs/diffz
//! [^4]: https://github.com/mnemnion/mvzr

const std = @import("std");
const builtin = @import("builtin");
const pretty = @import("pretty");
const diffz = @import("diffz");
const mvzr = @import("mvzr");
const testing = std.testing;

const assert = std.debug.assert;

const Diff = @TypeOf(diffz.Diff.default.edits);
const Edit = diffz.Edit;

// Generous limits for user regexen
const UserRegex = mvzr.SizedRegex(128, 16);

// Intended for use in test mode only.
comptime {
    assert(builtin.is_test);
}

/// OhSnap specialized to use the default options.
pub const default = OhSnap(default_pretty_options);

pub const default_pretty_options = pretty.Options{
    .max_depth = 0,
    .struct_max_len = 0,
    .array_max_len = 0,
    .array_show_prim_type_info = true,
    .type_name_max_len = 0,
    .type_name_fold_parens = 0,
    .str_max_len = 0,
    .show_tree_lines = true,
};

/// Builds a snapshot type which formats values with `pretty_options`.
///
/// The test binary must contain debug info, so build tests in Debug mode.
/// The update logic uses the debug info to find the source file.
pub fn OhSnap(comptime pretty_options: pretty.Options) type {
    return struct {
        /// Starts a snapshot which holds `text`.
        ///
        /// Write the snap text as a multi-line string. The text must start on
        /// the line below the call:
        ///
        /// ```
        /// try oh.snap(
        ///     \\Text of the snapshot.
        /// ).expectEqual(val);
        /// ```
        ///
        /// `snap` records the return address of its caller. The update logic
        /// resolves that address to the source file and line.
        pub fn snap(text: []const u8) Snap(pretty_options) {
            return .{
                .text = text,
                .return_address = @returnAddress(),
            };
        }
    };
}

// Regex for detecting embedded regexen
const ignore_regex_string = "<\\^[^\n]+?\\$>";
const regex_finder = mvzr.compile(ignore_regex_string).?;

pub fn Snap(comptime pretty_options: pretty.Options) type {
    return struct {
        text: []const u8,
        /// Address inside the caller of `snap`. The update logic resolves it to
        /// a source file and line.
        return_address: usize,

        const Self = @This();
        const allocator = std.testing.allocator;

        /// Compare the snapshot with a pretty-printed string.
        pub fn expectEqual(snapshot: *const Self, args: anytype) !void {
            const got = try pretty.dump(
                allocator,
                args,
                pretty_options,
            );
            defer allocator.free(got);
            try snapshot.diff(got, true);
        }

        /// Compare the snapshot with a .fmt printed string.
        pub fn expectEqualFmt(snapshot: *const Self, args: anytype) !void {
            const got = try std.fmt.allocPrint(allocator, "{f}", .{args});
            defer allocator.free(got);
            try snapshot.diff(got, true);
        }

        /// Show the snapshot diff without testing
        pub fn show(snapshot: *const Self, args: anytype) !void {
            const got = try pretty.dump(
                allocator,
                args,
                pretty_options,
            );
            defer allocator.free(got);
            try snapshot.diff(got, false);
        }

        /// Show a diff with the .fmt string without testing.
        pub fn showFmt(snapshot: *const Self, args: anytype) !void {
            const got = try std.fmt.allocPrint(allocator, "{f}", .{args});
            defer allocator.free(got);
            try snapshot.diff(got, false);
        }

        /// Compare the snapshot with a given string.
        pub fn diff(snapshot: *const Self, got: []const u8, test_it: bool) !void {
            // Check for an update first
            const update_idx = std.mem.indexOf(u8, snapshot.text, "<!update>");
            if (update_idx) |idx| {
                if (idx == 0) {
                    const match = regex_finder.match(snapshot.text);
                    if (match) |_| {
                        return try patchAndUpdate(snapshot, got);
                    } else {
                        return try updateSnap(snapshot, got);
                    }
                } else {
                    // Probably a user mistake but the diff logic will surface that
                }
            }

            var dmp = diffz.Diff.init(.{
                .timeout = 0,
                .edit_cost = diffz.DiffConfig.default.edit_cost,
                .check_lines = diffz.DiffConfig.default.check_lines,
                .check_line_threshold = diffz.DiffConfig.default.check_line_threshold,
            });
            defer dmp.deinit(allocator);
            _ = try dmp.diff(allocator, snapshot.text, got);
            var diffs = dmp.edits;
            dmp.edits = .empty;
            defer deinitDiffList(allocator, &diffs);
            if (diffDiffers(diffs) or !test_it) {
                var cleaned = diffz.Diff{ .config = dmp.config, .edits = diffs };
                _ = try cleaned.cleanupSemantic(allocator);
                diffs = cleaned.edits;
                cleaned.edits = .empty;
                // Check if we have a regex in the snapshot
                const match = regex_finder.match(snapshot.text);
                if (match) |_| {
                    diffs = try regexFixup(&diffs, snapshot, got);
                    if (test_it)
                        if (!diffDiffers(diffs)) return;
                }
                const diff_string = try (diffz.Diff{ .config = dmp.config, .edits = diffs }).prettyFormat(
                    allocator,
                    diffz.DiffDecorations.xterm_classic,
                );
                defer allocator.free(diff_string);
                const differs = if (test_it) " differs" else "";
                printSnapshotHeader(snapshot.return_address, differs, diff_string);
                if (test_it) {
                    if (snapshot.text.len == 0 or snapshot.text.len == 1 and snapshot.text[0] == '\n') {
                        std.debug.print("your snap:", .{});
                        var split = std.mem.splitScalar(u8, got, '\n');
                        while (split.next()) |line| {
                            std.debug.print("\n        \\\\{s}", .{line});
                        }
                        std.debug.print("\n", .{});
                    } else {
                        std.debug.print("\n\nTo replace contents, add <!update> as the first line of the snap text.\n", .{});
                    }
                    return try std.testing.expect(false);
                } else return;
            }
        }

        fn updateSnap(snapshot: *const Self, got: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();

            const arena_allocator = arena.allocator();
            const io = std.Options.debug_io;

            const call_site = resolveCallSite(snapshot.return_address, arena_allocator) catch |err| {
                printUpdateFailure(err);
                return err;
            };
            const file_name = call_site.file_name;

            // Updates which already ran in this process changed the file. The
            // compiled line stays fixed, so correct it by the recorded shifts.
            const shifted = @as(i64, @intCast(call_site.line)) + shifts.lineDelta(file_name, call_site.line);
            const adjusted_line: u64 = @intCast(@max(shifted, 1));

            const dir_path = std.fs.path.dirname(file_name) orelse ".";
            const base_name = std.fs.path.basename(file_name);

            var mod_dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err| {
                std.debug.print("Problem opening directory {s}, bailing out\n", .{dir_path});
                return err;
            };
            defer mod_dir.close(io);

            const file_text =
                mod_dir.readFileAlloc(io, base_name, arena_allocator, .limited(1024 * 1024)) catch |err| {
                    std.debug.print("Problem opening file {s}, bailing out\n", .{file_name});
                    return err;
                };

            const range = try snapshotRange(file_text, adjusted_line);
            const snapshot_text = file_text[range.start..range.end];
            if (!blockMatches(snapshot_text, snapshot.text)) {
                std.debug.print(
                    \\The snapshot at {s}:{d} does not match the file text.
                    \\Run the tests again. A previous update may have changed the file.
                    \\
                , .{ file_name, call_site.line });
                return error.SnapshotMismatch;
            }

            const indent = getIndent(snapshot_text);
            const old_lines = std.mem.count(u8, snapshot_text, "\n");
            const new_lines = std.mem.count(u8, got, "\n") + 1;

            var file_text_updated = try std.ArrayList(u8).initCapacity(arena_allocator, file_text.len);
            try file_text_updated.appendSlice(arena_allocator, file_text[0..range.start]);
            {
                var allocating = std.Io.Writer.Allocating.fromArrayList(arena_allocator, &file_text_updated);
                defer file_text_updated = allocating.toArrayList();
                var lines = std.mem.splitScalar(u8, got, '\n');
                while (lines.next()) |line| {
                    try allocating.writer.print("{s}\\\\{s}\n", .{ indent, line });
                }
            }
            try file_text_updated.appendSlice(arena_allocator, file_text[range.end..]);

            try mod_dir.writeFile(io, .{
                .sub_path = base_name,
                .data = file_text_updated.items,
            });

            try shifts.record(
                file_name,
                call_site.line,
                @as(i64, @intCast(new_lines)) - @as(i64, @intCast(old_lines)),
            );

            std.debug.print("Updated {s}:{d}\n", .{ file_name, call_site.line });
            return error.SnapUpdated;
        }

        /// Find regex matches and modify the diff accordingly.
        fn regexFixup(
            diffs: *Diff,
            snapshot: *const Self,
            got: []const u8,
        ) !Diff {
            defer deinitDiffList(allocator, diffs);
            var regex_find = regex_finder.iterator(snapshot.text);
            var diffs_idx: usize = 0;
            var snap_idx: usize = 0;
            var got_idx: usize = 0;
            var new_diffs: Diff = .empty;
            errdefer deinitDiffList(allocator, &new_diffs);
            const dummy_diff = Edit.asBorrow(.equal, "");
            regex_while: while (regex_find.next()) |found| {
                // Find this location in the got string.
                const snap_start = found.start;
                const snap_end = found.end;
                const diff_obj = diffz.Diff{ .config = diffz.DiffConfig.default, .edits = diffs.* };
                const got_start = diff_obj.index(snap_start);
                const got_end = diff_obj.index(snap_end);
                // Check if these are identical (use/mention distinction!)
                if (std.mem.eql(u8, found.slice, got[got_start..got_end])) {
                    // That's fine then
                    continue :regex_while;
                }
                // Trim the angle brackets off the regex.
                const exclude_regex = found.slice[1 .. found.slice.len - 1];
                const maybe_matcher = UserRegex.compile(exclude_regex);
                if (maybe_matcher == null) {
                    std.debug.print("Issue with mvzr or regex, hard to say. Regex string: {s}\n", .{exclude_regex});
                    continue :regex_while;
                }
                const matcher = maybe_matcher.?;
                const maybe_match = matcher.match(got[got_start..got_end]);
                // Either way, we zero out the patches, the difference being
                // how we represent the match or not-match in the diff list.
                while (diffs_idx < diffs.items.len) : (diffs_idx += 1) {
                    const d = diffs.items[diffs_idx];
                    // All patches which are inside one or the other are set to nothing
                    const in_snap = snap_start <= snap_idx and snap_start < snap_end;
                    const in_got = got_start <= got_idx and got_idx < got_end;
                    switch (d.operation) {
                        .equal => {
                            // Could easily be in common between the regex and the match.
                            snap_idx += d.text.len;
                            got_idx += d.text.len;
                            if (in_snap and in_got) {
                                try new_diffs.append(allocator, dummy_diff);
                            } else {
                                try new_diffs.append(allocator, try dupe(d));
                            }
                        },
                        .insert => {
                            // Are we in the match?
                            got_idx += d.text.len;
                            if (in_got) {
                                // Yes, replace with dummy equal
                                try new_diffs.append(allocator, dummy_diff);
                            } else {
                                try new_diffs.append(allocator, try dupe(d));
                            }
                        },
                        .delete => {
                            snap_idx += d.text.len;
                            // Same deal, are we in the match?
                            if (in_snap) {
                                try new_diffs.append(allocator, dummy_diff);
                            } else {
                                try new_diffs.append(allocator, try dupe(d));
                            }
                        },
                    }

                    if (got_idx >= got_end and snap_idx >= snap_end) break;
                }
                // Should always mean we have at least two (but we care about
                // having one) diffs rubbed out.
                var formatted = try std.ArrayList(u8).initCapacity(allocator, 10);
                defer formatted.deinit(allocator);
                assert(new_diffs.items[diffs_idx].operation == .equal and new_diffs.items[diffs_idx].text.len == 0);
                if (maybe_match) |_| {
                    // Decorate with cyan for a match.
                    try formatted.appendSlice(allocator, "\x1b[36m");
                    try formatted.appendSlice(allocator, got[got_start..got_end]);
                    try formatted.appendSlice(allocator, "\x1b[m");
                    new_diffs.items[diffs_idx] = Edit{
                        .operation = .equal,
                        .owned = true,
                        .text = try formatted.toOwnedSlice(allocator),
                    };
                } else {
                    // Decorate magenta for no match, and make it an insert (hence, error)
                    try formatted.appendSlice(allocator, "\x1b[35m");
                    try formatted.appendSlice(allocator, got[got_start..got_end]);
                    try formatted.appendSlice(allocator, "\x1b[m");
                    new_diffs.items[diffs_idx] = Edit{
                        .operation = .insert,
                        .owned = true,
                        .text = try formatted.toOwnedSlice(allocator),
                    };
                }
                diffs_idx += 1;
            } // end regex while
            while (diffs_idx < diffs.items.len) : (diffs_idx += 1) {
                const d = diffs.items[diffs_idx];
                try new_diffs.append(allocator, try dupe(d));
            }
            return new_diffs;
        }

        fn patchAndUpdate(snapshot: *const Self, got: []const u8) !void {
            var dmp = diffz.Diff.init(.{
                .timeout = 0,
                .edit_cost = diffz.DiffConfig.default.edit_cost,
                .check_lines = diffz.DiffConfig.default.check_lines,
                .check_line_threshold = diffz.DiffConfig.default.check_line_threshold,
            });
            defer dmp.deinit(allocator);
            _ = try dmp.diff(allocator, snapshot.text, got);
            // Very similar to `regexFixup`, but here we clean up the diffed region,
            // then add a paired delete/insert, and use it to patch `got`.
            var regex_find = regex_finder.iterator(snapshot.text);
            var got_idx: usize = 0;
            var new_diffs: Diff = .empty;
            defer deinitDiffList(allocator, &new_diffs);
            var new_got = try std.ArrayList(u8).initCapacity(allocator, @max(got.len, snapshot.text.len));
            defer new_got.deinit(allocator);
            while (regex_find.next()) |found| {
                // Find this location in the got string.
                const snap_start = found.start;
                const snap_end = found.end;
                const got_start = dmp.index(snap_start);
                const got_end = dmp.index(snap_end);
                try new_got.appendSlice(allocator, got[got_idx..got_start]);
                try new_got.appendSlice(allocator, found.slice);
                got_idx = got_end;
            }
            try new_got.appendSlice(allocator, got[got_idx..]);
        }

        fn dupe(d: Edit) !Edit {
            return Edit.asOwn(allocator, d.operation, d.text);
        }
    };
}

const CallSite = struct {
    file_name: []const u8,
    line: u64,
};

/// Resolves an address to a source file and line with the debug info of the
/// test binary. `file_name` is allocated with `allocator`.
fn resolveCallSite(address: usize, allocator: std.mem.Allocator) !CallSite {
    const io = std.Options.debug_io;
    const debug_info = try std.debug.getSelfDebugInfo();

    var text_arena: std.heap.ArenaAllocator = .init(std.debug.getDebugInfoAllocator());
    defer text_arena.deinit();

    var fallback = std.heap.stackFallback(
        @sizeOf(std.debug.Symbol) + @alignOf(std.debug.Symbol) - 1,
        std.debug.getDebugInfoAllocator(),
    );
    const symbol_allocator = fallback.get();
    var symbols = try std.ArrayList(std.debug.Symbol).initCapacity(symbol_allocator, 1);
    defer symbols.deinit(symbol_allocator);

    // The return address is after the call instruction. Step back one byte
    // into the call, so the line table reports the call site line.
    const call_address = address -| 1;
    try debug_info.getSymbols(io, symbol_allocator, text_arena.allocator(), call_address, false, &symbols);
    for (symbols.items) |symbol| {
        if (symbol.source_location) |location| {
            return .{
                .file_name = try allocator.dupe(u8, location.file_name),
                .line = location.line,
            };
        }
    }
    return error.NoSourceLocation;
}

fn printSnapshotHeader(return_address: usize, differs: []const u8, diff_string: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(std.debug.getDebugInfoAllocator());
    defer arena.deinit();

    const call_site = resolveCallSite(return_address, arena.allocator()) catch {
        std.debug.print(
            \\Snapshot at an unknown location{s}:
            \\
            \\{s}
            \\
        , .{ differs, diff_string });
        return;
    };

    std.debug.print(
        \\Snapshot at {s}{s}:{d}{s}{s}:
        \\
        \\{s}
        \\
    , .{
        "\x1b[33m",
        call_site.file_name,
        call_site.line,
        "\x1b[m",
        differs,
        diff_string,
    });
}

fn printUpdateFailure(err: anyerror) void {
    std.debug.print(
        \\OhSnap cannot update this snapshot.
        \\The return address of the snap call does not resolve to a source file ({s}).
        \\Snapshot updates need debug info. Build the tests in Debug mode and run again.
        \\
    , .{@errorName(err)});
}

const Shift = struct {
    /// One-based line of the snap call in the compiled source.
    line: u64,
    /// Line count difference of the update.
    delta: i64,
};

/// Tracks the line shifts which updates applied earlier in this test process.
/// The source line of a snap stays fixed at compile time, but each update
/// changes the file. A later update corrects its line with these values, so one
/// test run can update any number of snapshots.
const ShiftTracker = struct {
    const Shifts = std.ArrayListUnmanaged(Shift);
    const Tracker = std.StringHashMapUnmanaged(Shifts);

    map: Tracker = .empty,

    fn lineDelta(self: *const ShiftTracker, path: []const u8, line: u64) i64 {
        var total: i64 = 0;
        if (self.map.get(path)) |entries| {
            for (entries.items) |shift| {
                if (shift.line < line) total += shift.delta;
            }
        }
        return total;
    }

    fn record(self: *ShiftTracker, path: []const u8, line: u64, delta: i64) !void {
        const a = std.heap.page_allocator;
        const entry = try self.map.getOrPut(a, path);
        if (!entry.found_existing) {
            entry.key_ptr.* = try a.dupe(u8, path);
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(a, .{ .line = line, .delta = delta });
    }

    fn deinit(self: *ShiftTracker) void {
        const a = std.heap.page_allocator;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            a.free(entry.key_ptr.*);
            entry.value_ptr.deinit(a);
        }
        self.map.deinit(a);
        self.* = .{};
    }
};

var shifts: ShiftTracker = .{};

/// Answer whether the diffs differ (pre-regex, if any)
fn diffDiffers(diffs: Diff) bool {
    var all_equal = true;
    for (diffs.items) |d| {
        switch (d.operation) {
            .equal => {},
            .insert, .delete => {
                all_equal = false;
                break;
            },
        }
    }
    return !all_equal;
}

fn deinitDiffList(allocator: std.mem.Allocator, diffs: *Diff) void {
    for (diffs.items) |*d| d.deinit(allocator);
    diffs.deinit(allocator);
    diffs.* = .empty;
}

const Range = struct { start: usize, end: usize };

/// Returns the byte range of the snapshot text which starts on the line below
/// the `snap` call. `call_line` is the one-based line of the call.
///
/// ```
/// try oh.snap(
///     \\first line
///     \\second line
/// ).expectEqual(val);
/// ```
fn snapshotRange(text: []const u8, call_line: u64) !Range {
    var offset: usize = 0;
    var line_number: u64 = 0;

    // The multi-line string starts one line below the call. A zero-based line
    // number equal to the one-based call line addresses that line.
    var start: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        if (line_number == call_line) {
            if (!isMultilineString(line)) {
                std.debug.print(
                    "Expected the snapshot string on line {d}.  Try running tests again.\n",
                    .{line_number + 1},
                );
                try testing.expect(false);
            }
            start = offset;
            break;
        }
        offset += line.len + 1; // 1 for \n
    }
    const snap_start = start orelse {
        std.debug.print("No snapshot string found at line {d}.  Try running tests again.\n", .{call_line});
        return error.SnapshotNotFound;
    };

    lines = std.mem.splitScalar(u8, text[snap_start..], '\n');
    const snap_end = while (lines.next()) |line| {
        if (!isMultilineString(line)) break offset;
        offset += line.len + 1; // 1 for \n
    } else offset;

    return Range{ .start = snap_start, .end = @min(snap_end, text.len) };
}

/// Answer whether the snapshot block holds `expected`. The comparison ignores
/// the indentation and the `\\` markers.
fn blockMatches(block: []const u8, expected: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, block, "\n");
    var block_lines = std.mem.splitScalar(u8, trimmed, '\n');
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');

    while (true) {
        const block_line = block_lines.next();
        const expected_line = expected_lines.next();
        if (block_line == null and expected_line == null) return true;
        if (block_line == null or expected_line == null) return false;
        if (!std.mem.eql(u8, snapshotLineContent(block_line.?), expected_line.?)) return false;
    }
}

/// Returns the text after the leading spaces and the `\\` marker.
fn snapshotLineContent(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i + 1 < line.len and line[i] == '\\' and line[i + 1] == '\\') i += 2;
    return line[i..];
}

fn isMultilineString(line: []const u8) bool {
    for (line, 0..) |c, i| {
        switch (c) {
            ' ' => {},
            '\\' => return (i + 1 < line.len and line[i + 1] == '\\'),
            else => return false,
        }
    }
    return false;
}

fn getIndent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ') return line[0..i];
    }
    return line;
}

test "snapshotRange finds the block below the call" {
    const text =
        \\fn f() void {
        \\    try oh.snap(
        \\        \\first
        \\        \\second
        \\    ).expectEqual(val);
        \\}
        \\
    ;
    const range = try snapshotRange(text, 2);
    try testing.expectEqualStrings(
        "        \\\\first\n        \\\\second\n",
        text[range.start..range.end],
    );
}

test "blockMatches ignores indentation and markers" {
    try testing.expect(blockMatches(
        "    \\\\first\n    \\\\second\n",
        "first\nsecond",
    ));
    try testing.expect(blockMatches("    \\\\\n", ""));
    try testing.expect(!blockMatches(
        "    \\\\first\n    \\\\second\n",
        "first\nother",
    ));
}

test "ShiftTracker corrects lines which earlier updates moved" {
    var tracker: ShiftTracker = .{};
    defer tracker.deinit();

    try tracker.record("f.zig", 10, 3);
    try tracker.record("f.zig", 20, -1);

    try testing.expectEqual(@as(i64, 0), tracker.lineDelta("f.zig", 10));
    try testing.expectEqual(@as(i64, 3), tracker.lineDelta("f.zig", 15));
    try testing.expectEqual(@as(i64, 2), tracker.lineDelta("f.zig", 25));
    try testing.expectEqual(@as(i64, 0), tracker.lineDelta("g.zig", 100));
}

test "snap test" {
    // Change either the snapshot or the struct to make these tests fail
    const oh = OhSnap(default_pretty_options);
    // Simple anon struct
    try oh.snap(
        \\ohsnap.test.snap test__struct_<^\d+$>
        \\  .foo: *const [10:0]u8
        \\    "bazbuxquux"
        \\  .baz: comptime_int = 27
    ).expectEqual(.{ .foo = "bazbuxquux", .baz = 27 });
    // Type
    try oh.snap(
        \\builtin.Type
        \\  .struct: builtin.Type.Struct
        \\    .layout: builtin.Type.ContainerLayout
        \\      .auto
        \\    .backing_integer: ?type
        \\      null
        \\    .fields: []const builtin.Type.StructField
        \\      (empty)
        \\    .decls: []const builtin.Type.Declaration
        \\      [0]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "default"
        \\      [1]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "default_pretty_options"
        \\      [2]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "OhSnap"
        \\      [3]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "Snap"
        \\    .is_tuple: bool = false
        ,
    ).expectEqual(@typeInfo(@This()));
}
test "snap regex" {
    const RandomField = struct {
        const RF = @This();
        str: []const u8 = "arglebargle",
        pi: f64 = 3.14159,
        rand: u64,
        xtra: u16 = 1571,
        fn init(rand: u64) RF {
            return RF{ .rand = rand };
        }
    };
    var test_threaded_io: std.Io.Threaded = .init_single_threaded;
    defer test_threaded_io.deinit();
    const test_io = test_threaded_io.io();
    var seed: u64 = undefined;
    test_io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const an_rf = RandomField.init(rand.int(u64));
    const oh = OhSnap(default_pretty_options);
    try oh.snap(
        \\ohsnap.test.snap regex.RandomField
        \\  .str: []const u8
        \\    "argle<^\w+?$>gle"
        \\  .pi: f64 = 3.14159
        \\  .rand: u64 = <^[0-9]+$>
        \\  .xtra: u16 = 1571
        ,
    ).expectEqual(an_rf);
}

const StampedStruct = struct {
    message: []const u8,
    tag: u64,
    timestamp: isize,
    pub fn init(msg: []const u8, tag: u64) StampedStruct {
        var threaded_io: std.Io.Threaded = .init_single_threaded;
        defer threaded_io.deinit();
        const io = threaded_io.io();
        return StampedStruct{
            .message = msg,
            .tag = tag,
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        };
    }
};

test "snap with timestamp" {
    const oh = OhSnap(default_pretty_options);
    const with_stamp = StampedStruct.init(
        "frobnicate the turbo-encabulator",
        37337,
    );
    try oh.snap(
        \\ohsnap.StampedStruct
        \\  .message: []const u8
        \\    "frobnicate the turbo-<^\w+$>"
        \\  .tag: u64 = 37337
        \\  .timestamp: isize = <^\d+$>
        ,
    ).expectEqual(with_stamp);
}

const CustomStruct = struct {
    foo: u64,
    bar: u66,
    pub fn format(
        self: CustomStruct,
        writer: anytype,
    ) !void {
        try writer.print("foo! <<{d}>>, bar! <<{d}>>", .{ self.foo, self.bar });
    }
};

test "expectEqualFmt" {
    const oh = OhSnap(default_pretty_options);
    const foobar = CustomStruct{ .foo = 42, .bar = 23 };
    try oh.snap(
        \\foo! <<42>>, bar! <<23>>
        ,
    ).expectEqualFmt(foobar);
}

test "regex match" {
    const oh = OhSnap(default_pretty_options);
    try oh.snap(
        \\?mvzr.Match
        \\  .slice: []const u8
        \\    "<^ $\d\.\d{2}$>"
        \\  .start: usize = 0
        \\  .end: usize = 15
    ).expectEqual(regex_finder.match(
        \\<^ $\d\.\d{2}$>
    ));
}
