//! Static File Server Example
//!
//! Demonstrates serving static files using httpx.zig.

const std = @import("std");
const httpx = @import("httpx");

fn fileHandler(ctx: *httpx.Context) anyerror!httpx.Response {
    // In a real router, you might extract the path from params
    // For this example, we'll just serve a specific file

    // Create a dummy file for demonstration
    const dummy_file = "public/test.txt";
    std.fs.cwd().makeDir("public") catch {};
    const f = try std.fs.cwd().createFile(dummy_file, .{});
    try f.writeAll("This is a static file served by httpx.zig!");
    f.close();

    return ctx.file(dummy_file);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Static File Server Example ===\n\n", .{});

    var server = httpx.Server.init(allocator);
    defer server.deinit();

    try server.get("/files/test.txt", fileHandler);

    std.debug.print("Registered route:\n", .{});
    std.debug.print("  GET /files/test.txt -> serves 'public/test.txt'\n", .{});

    std.debug.print("\nTo start the server, uncomment: try server.listen();\n", .{});
}
