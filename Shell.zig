const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

io: Io,
arena: Allocator,

const Shell = @This();

fn init(io: Io, arena: Allocator) Shell {
    return .{
        .io = io,
        .arena = arena,
    };
}

fn run(shell: Shell, comptime fmt: []const u8, args: anytype) !void {
    const command = try std.fmt.allocPrint(shell.arena, fmt, args);

    var it = std.mem.tokenizeScalar(u8, command, ' ');
    var argv: std.ArrayList([]const u8) = .empty;
    while (it.next()) |item| {
        try argv.append(shell.arena, item);
    }

    var child = try std.process.spawn(shell.io, .{
        .argv = argv.items,
    });
    _ = try child.wait(shell.io);
}
