const std = @import("std");

pub const std_options = .{
    .keep_sigpipe = true,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var flavor: Flavor = .pretty;
    var line_buffered = false;
    var wasm_path: []const u8 = "stage1/zig1.wasm";

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pretty")) {
            flavor = .pretty;
        } else if (std.mem.eql(u8, arg, "--c")) {
            flavor = .c;
        } else if (std.mem.eql(u8, arg, "--std-c")) {
            flavor = .std_c;
        } else if (std.mem.eql(u8, arg, "--line")) {
            line_buffered = true;
        } else {
            wasm_path = arg;
        }
    }

    var fn_names = std.ArrayList([]const u8).init(allocator);
    defer {
        for (fn_names.items) |fn_name| allocator.free(fn_name);
        fn_names.deinit();
    }

    var line = std.ArrayList(u8).init(allocator);
    defer line.deinit();

    {
        var wasm_dis = std.process.Child.init(&.{ "wasm-dis", wasm_path }, allocator);
        wasm_dis.stdout_behavior = .Pipe;
        try wasm_dis.spawn();
        var wat_buf = std.io.bufferedReader(wasm_dis.stdout.?.reader());
        while (wat_buf.reader().streamUntilDelimiter(line.writer(), '\n', 1 << 20)) {
            defer line.clearRetainingCapacity();
            const prefix = " (func $";
            if (!std.mem.startsWith(u8, line.items, prefix)) continue;
            const suffix = line.items[prefix.len..];
            const fn_name = suffix[0 .. std.mem.indexOfScalar(u8, suffix, ' ') orelse suffix.len];
            try fn_names.ensureUnusedCapacity(1);
            fn_names.appendAssumeCapacity(try std.fmt.allocPrint(allocator, "{}", .{
                fmtFnName(flavor, fn_name),
            }));
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        switch (try wasm_dis.wait()) {
            .Exited => |status| if (status != 0) std.process.exit(status),
            else => std.process.exit(1),
        }
    }

    {
        var stdin_buf = std.io.bufferedReader(std.io.getStdIn().reader());
        const stdin = stdin_buf.reader();
        var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
        const stdout = stdout_buf.writer();
        while (stdin.readByte()) |c| {
            if (c != 'f') {
                try stdout.writeByte(c);
                if (line_buffered and c == '\n') try stdout_buf.flush();
                continue;
            }
            var index: ?usize = null;
            var leading_zero = false;
            while (true) {
                const digit = stdin.readByte() catch |err| switch (err) {
                    error.EndOfStream => null,
                    else => |e| return e,
                };
                if (digit) |d| if (!leading_zero and d >= '0' and d <= '9') {
                    leading_zero = index == null and d == '0';
                    index = (index orelse 0) * 10 + d - '0';
                    continue;
                };
                if (index) |i| {
                    if (i >= fn_names.items.len or (if (digit) |d|
                        std.ascii.isAlphanumeric(d) or d == '_'
                    else
                        false))
                        try stdout.print("f{d}", .{i})
                    else
                        try stdout.writeAll(fn_names.items[i]);
                } else try stdout.writeByte('f');
                if (digit) |d| {
                    try stdout.writeByte(d);
                    if (line_buffered and d == '\n') try stdout_buf.flush();
                    break;
                }
            } else break;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try stdout_buf.flush();
    }

    std.process.cleanExit();
}

const Flavor = enum { pretty, c, std_c };
const FormatFnName = struct { flavor: Flavor, fn_name: []const u8 };
fn formatFnName(
    formatter: FormatFnName,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    switch (formatter.flavor) {
        .pretty => {},
        .c => try writer.writeByte('$'),
        .std_c => try writer.writeAll("f_"),
    }
    var index: usize = 0;
    while (index < formatter.fn_name.len) : (index += 1) {
        const c: u8 = switch (formatter.fn_name[index]) {
            '.' => switch (formatter.flavor) {
                .pretty => '.',
                .c, .std_c => '_',
            },
            '\\' => c: {
                const trailing = formatter.fn_name[index + 1 ..];
                if (trailing.len < 2) break :c '\\';
                index += 2;
                break :c std.fmt.parseInt(u8, trailing[0..2], 16) catch '\\';
            },
            else => |c| c,
        };
        if (switch (formatter.flavor) {
            .pretty => std.ascii.isPrint(c),
            .c, .std_c => std.ascii.isAlphanumeric(c) or c == '_',
        }) try writer.writeByte(c) else try writer.print("{s}{x:0>2}", .{
            switch (formatter.flavor) {
                .pretty => "\\x",
                .c => "$",
                .std_c => "_",
            },
            c,
        });
    }
}
fn fmtFnName(flavor: Flavor, fn_name: []const u8) std.fmt.Formatter(formatFnName) {
    return .{ .data = .{ .flavor = flavor, .fn_name = fn_name } };
}
