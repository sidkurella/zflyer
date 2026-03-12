const std = @import("std");
const zz = @import("deps/zigzag/src/root.zig");
const args = @import("deps/args/src/args.zig");
const status_client = @import("src/status_client.zig");
const Env = @import("deps/dotenv-zig/src/root.zig");

const Model = struct {
    flight_number: []const u8,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = try args.ArgumentParser.init(allocator, .{
        .name = "zflyer",
        .version = "0.0.0",
        .description = "Flight status CLI tool",
    });
    defer parser.deinit();

    try parser.addPositional("flight_number", .{
        .help = "The flight number to check the status of",
        .required = false,
    });

    var result = try parser.parseProcess();
    defer result.deinit();

    var env: Env = try Env.initWithPath(allocator, ".env", 1024, true);
    defer env.deinit();

    var sc = status_client.FlightStatusClient.init(allocator, try env.getRequired("AIRLABS_API_KEY"));
    defer sc.deinit();

    const flight_number = result.getString("flight_number");
    if (flight_number == null) {
        std.debug.print("No flight number provided. Use --help for usage information.\n", .{});
        return;
    }

    std.debug.print("Checking status for flight: {s}\n", .{flight_number.?});
    sc.checkStatus(flight_number.?) catch |err| {
        std.debug.print("Error checking flight status: {s}\n", .{@errorName(err)});
    };
}
