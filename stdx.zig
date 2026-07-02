const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SourceLocation = std.builtin.SourceLocation;

fn maybe(ok: bool) void {
    assert(ok or !ok);
}

pub const Shell = struct {
    io: Io,
    arena: Allocator,

    pub fn init(io: Io, arena: Allocator) Shell {
        return .{
            .io = io,
            .arena = arena,
        };
    }

    pub fn spawn(shell: Shell, comptime fmt: []const u8, args: anytype) !void {
        const command = try std.fmt.allocPrint(shell.arena, fmt, args);

        var it = std.mem.tokenizeScalar(u8, command, ' ');
        var argv: std.ArrayList([]const u8) = .empty;
        while (it.next()) |item| {
            try argv.append(shell.arena, item);
        }

        var child = try std.process.spawn(shell.io, .{ .argv = argv.items });
        _ = try child.wait(shell.io);
    }

    pub fn spawn_raw(shell: Shell, argv: []const []const u8) !void {
        var child = try std.process.spawn(shell.io, .{ .argv = argv });
        _ = try child.wait(shell.io);
    }

    pub fn run(
        shell: Shell,
        comptime fmt: []const u8,
        args: anytype,
    ) !std.process.RunResult {
        const command = try std.fmt.allocPrint(shell.arena, fmt, args);

        var it = std.mem.tokenizeScalar(u8, command, ' ');
        var argv: std.ArrayList([]const u8) = .empty;
        while (it.next()) |item| {
            try argv.append(shell.arena, item);
        }
        return try std.process.run(shell.arena, shell.io, .{ .argv = argv.items });
    }

    pub fn run_raw(shell: Shell, argv: []const []const u8) !std.process.RunResult {
        return try std.process.run(shell.arena, shell.io, .{ .argv = argv });
    }

    pub const Pipeline = struct {
        shell: Shell,
        source_argv: []const []const u8,
        output_text: []const u8,

        pub fn pipe(p: Pipeline, argv: []const []const u8) Pipeline {
            var producer = std.process.spawn(p.shell.io, .{
                .argv = p.source_argv,
                .stdout = .pipe,
            }) catch std.process.exit(1);

            var consumer = std.process.spawn(p.shell.io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
            }) catch std.process.exit(1);

            var producer_stdout_buffer: [4096]u8 = undefined;
            var consumer_stdout_buffer: [4096]u8 = undefined;
            var consumer_stdin_buffer: [4096]u8 = undefined;

            var producer_reader = producer.stdout.?.reader(p.shell.io, &producer_stdout_buffer);
            var consumer_reader = consumer.stdout.?.reader(p.shell.io, &consumer_stdout_buffer);
            var consumer_writer = consumer.stdin.?.writer(p.shell.io, &consumer_stdin_buffer);

            _ = producer_reader.interface.streamRemaining(
                &consumer_writer.interface,
            ) catch std.process.exit(1);
            consumer_writer.interface.flush() catch std.process.exit(1);
            consumer.stdin.?.close(p.shell.io);
            consumer.stdin = null;

            const output_text = consumer_reader.interface.allocRemaining(
                p.shell.arena,
                .unlimited,
            ) catch std.process.exit(1);
            _ = producer.wait(p.shell.io) catch std.process.exit(1);
            _ = consumer.wait(p.shell.io) catch std.process.exit(1);

            return .{
                .shell = p.shell,
                .source_argv = p.source_argv,
                .output_text = output_text,
            };
        }

        pub fn text(p: Pipeline) []const u8 {
            return p.output_text;
        }
    };

    pub fn pipeline(shell: Shell, argv: []const []const u8) Pipeline {
        return .{
            .shell = shell,
            .source_argv = argv,
            .output_text = "",
        };
    }
};

pub const Snapshot = struct {
    location: SourceLocation,
    text: []const u8,
    update_this: bool = false,

    pub fn snap(location: SourceLocation, text: []const u8) Snapshot {
        return .{
            .location = location,
            .text = text,
        };
    }

    pub fn update(snapshot: *const Snapshot) Snapshot {
        return .{
            .location = snapshot.location,
            .text = snapshot.text,
            .update_this = true,
        };
    }

    fn should_update(snapshot: Snapshot) bool {
        return snapshot.update_this;
    }

    pub fn diff(snapshot: *const Snapshot, got: []const u8) !void {
        if (std.mem.eql(u8, snapshot.text, got)) return;

        std.debug.print(
            \\Snapshot differs.
            \\Want:
            \\----
            \\{s}
            \\----
            \\Got:
            \\----
            \\{s}
            \\----
            \\
        , .{ snapshot.text, got });

        if (!snapshot.should_update()) return error.SnapDiff;

        var io_threaded: Io.Threaded = .init(std.testing.allocator, .{});
        defer io_threaded.deinit();
        const io = io_threaded.io();

        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const file_text = try std.Io.Dir.cwd().readFileAlloc(
            io,
            snapshot.location.file,
            allocator,
            .limited(1024 * 1024),
        );
        var file_text_updated: ArrayList(u8) = try .initCapacity(allocator, file_text.len);

        const line_zero_based = snapshot.location.line - 1;
        const range = snap_range(file_text, line_zero_based);

        const snapshot_prefix = file_text[0..range.start];
        const snapshot_text = file_text[range.start..range.end];
        const snapshot_suffix = file_text[range.end..];

        const indent = get_indent(snapshot_text);

        try file_text_updated.appendSlice(allocator, snapshot_prefix);
        {
            var lines = std.mem.splitScalar(u8, got, '\n');
            while (lines.next()) |line| {
                try file_text_updated.print(allocator, "{s}\\\\{s}\n", .{ indent, line });
            }
        }
        try file_text_updated.appendSlice(allocator, snapshot_suffix);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = snapshot.location.file,
            .data = file_text_updated.items,
        });

        std.debug.print("Updated {s}\n", .{snapshot.location.file});
        return error.SnapUpdated;
    }

    pub fn diff_fmt(want: *const Snapshot, comptime fmt: []const u8, fmt_args: anytype) !void {
        const got = try std.fmt.allocPrint(testing.allocator, fmt, fmt_args);
        defer testing.allocator.free(got);
        try want.diff(got);
    }
};

const Range = struct {
    start: usize,
    end: usize,
};

fn snap_range(text: []const u8, src_line: u32) Range {
    var offset: usize = 0;
    var line_number: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    const snap_start = while (lines.next()) |line| : (line_number += 1) {
        if (line_number == src_line) {
            assert(std.mem.indexOf(u8, line, "@src()") != null);
        }
        if (line_number == src_line + 1) {
            assert(is_multiline_string(line));
            break offset;
        }
        offset += line.len + 1; // 1 for \n
    } else unreachable;

    lines = std.mem.splitScalar(u8, text[snap_start..], '\n');
    const snap_end = while (lines.next()) |line| {
        if (!is_multiline_string(line)) {
            break offset;
        }
        offset += line.len + 1; // 1 for \n
    } else unreachable;

    return Range{ .start = snap_start, .end = snap_end };
}

fn is_multiline_string(line: []const u8) bool {
    for (line, 0..) |c, i| {
        switch (c) {
            ' ' => {},
            '\\' => return (i + 1 < line.len and line[i + 1] == '\\'),
            else => return false,
        }
    }
    return false;
}

fn get_indent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ') return line[0..i];
    }
    return line;
}
