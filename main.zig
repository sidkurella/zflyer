const std = @import("std");
const zz = @import("deps/zigzag/src/root.zig");
const args = @import("deps/args/src/args.zig");
const status_client = @import("src/status_client.zig");
const location_client = @import("src/location_client.zig");
const Env = @import("deps/dotenv-zig/src/root.zig");
const zeit = @import("deps/zeit/src/zeit.zig");

const Model = struct {
    flight_number: []const u8,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        const deinit_result = gpa.deinit();
        if (deinit_result == .leak) {
            std.debug.print("Memory leak detected\n", .{});
        }
    }

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

    var lc = location_client.LocationClient.init(allocator, try env.getRequired("GEOAPIFY_API_KEY"));
    defer lc.deinit();

    const flight_number = result.getString("flight_number");
    if (flight_number == null) {
        std.debug.print("No flight number provided. Use --help for usage information.\n", .{});
        return;
    }

    var status = sc.checkStatus(flight_number.?) catch |err| {
        std.debug.print("Error checking flight status: {s}\n", .{@errorName(err)});
        return;
    };
    defer status.deinit(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout.interface.flush() catch {};

    try stdout.interface.writeAll("\n=== Flight Status ===\n");
    try stdout.interface.print("Flight: {s} {s} ({s})\n", .{ status.airline_name, status.flight_number, status.flight_iata });
    try stdout.interface.print("Route:  {s} -> {s}\n", .{ status.departure_airport.iata_code, status.arrival_airport.iata_code });
    try stdout.interface.print("State:  {s} | {s}\n", .{ status.departed_status.toString(), status.delay_status.toString() });

    if (status.delay_info.departure_delay_minutes != null or status.delay_info.arrival_delay_minutes != null) {
        try stdout.interface.writeAll("\nDelays\n");
        if (status.delay_info.departure_delay_minutes) |departure_delay| {
            try stdout.interface.writeAll("- Departed ");
            try printDurationHM(&stdout.interface, departure_delay);
            try stdout.interface.writeAll(" late\n");
        }
        if (status.delay_info.arrival_delay_minutes) |arrival_delay| {
            try stdout.interface.writeAll("- Arriving ");
            try printDurationHM(&stdout.interface, arrival_delay);
            try stdout.interface.writeAll(" late\n");
        }
    }

    try stdout.interface.writeAll("\nAirports\n");
    try stdout.interface.print(
        "- Departure: {s} ({s}), {s}, {s}\n",
        .{
            status.departure_airport.name,
            status.departure_airport.iata_code,
            status.departure_airport.city,
            status.departure_airport.country,
        },
    );
    if (status.departure_gate.terminal != null or status.departure_gate.gate != null) {
        try stdout.interface.writeAll("  ");
        if (status.departure_gate.terminal) |terminal| {
            try stdout.interface.print("Terminal: {s}", .{terminal});
            if (status.departure_gate.gate != null) {
                try stdout.interface.writeAll(" | ");
            }
        }
        if (status.departure_gate.gate) |gate| {
            try stdout.interface.print("Gate: {s}", .{gate});
        }
        try stdout.interface.writeAll("\n");
    }
    if (status.departure_gate.baggage_claim) |baggage| {
        try stdout.interface.print("  Baggage: {s}\n", .{baggage});
    }

    try stdout.interface.print(
        "- Arrival:   {s} ({s}), {s}, {s}\n",
        .{
            status.arrival_airport.name,
            status.arrival_airport.iata_code,
            status.arrival_airport.city,
            status.arrival_airport.country,
        },
    );
    if (status.arrival_gate.terminal != null or status.arrival_gate.gate != null) {
        try stdout.interface.writeAll("  ");
        if (status.arrival_gate.terminal) |terminal| {
            try stdout.interface.print("Terminal: {s}", .{terminal});
            if (status.arrival_gate.gate != null) {
                try stdout.interface.writeAll(" | ");
            }
        }
        if (status.arrival_gate.gate) |gate| {
            try stdout.interface.print("Gate: {s}", .{gate});
        }
        try stdout.interface.writeAll("\n");
    }
    if (status.arrival_gate.baggage_claim) |baggage| {
        try stdout.interface.print("  Baggage: {s}\n", .{baggage});
    }

    try stdout.interface.writeAll("\nTiming\n");
    try stdout.interface.writeAll("- Departure (airport time):    ");
    if (status.departure_time.actual_local) |departure_actual_local| {
        try printInstant(&stdout.interface, departure_actual_local);
    } else {
        try printOptionalInstant(&stdout.interface, status.departure_time.scheduled_local);
    }
    try stdout.interface.writeAll("\n");

    try stdout.interface.writeAll("- Arrival (airport time):      ");
    if (status.arrival_time.actual_local) |arrival_actual_local| {
        try printInstant(&stdout.interface, arrival_actual_local);
    } else {
        try printOptionalInstant(&stdout.interface, status.arrival_time.scheduled_local);
    }
    try stdout.interface.writeAll("\n");

    // TODO: Convert the UTC times to the local timezone of the computer

    const has_live_data =
        status.in_flight_params.altitude != null or
        status.in_flight_params.speed != null or
        status.in_flight_params.heading != null or
        (status.in_flight_params.latitude != null and status.in_flight_params.longitude != null);

    if (has_live_data) {
        try stdout.interface.writeAll("\nLive\n");
        if (status.in_flight_params.altitude) |altitude| {
            try stdout.interface.print("- Altitude: {d} ft\n", .{roundToI64(altitude)});
        }
        if (status.in_flight_params.speed) |speed| {
            try stdout.interface.print("- Speed:    {d} mph\n", .{roundToI64(speed)});
        }
        if (status.in_flight_params.heading) |heading| {
            try stdout.interface.print("- Heading:  {d} deg\n", .{roundToI64(heading)});
        }
        if (status.in_flight_params.latitude) |lat| {
            if (status.in_flight_params.longitude) |lng| {
                try stdout.interface.print("- Position: {d}, {d}\n", .{ lat, lng });

                var location_result = try lc.checkLocation(lat, lng);
                if (location_result != null) {
                    defer location_result.?.deinit();
                    try stdout.interface.print("Overflying: {s}\n", .{location_result.?.formatted_address});
                } else {
                    try stdout.interface.writeAll("Overflying an unknown location\n");
                }
            }
        }
    }

    if (status.percentage_completed) |percent| {
        if (percent != 0) {
            try stdout.interface.print("\nProgress: {d}%\n", .{percent});
        }
    }

    if (status.total_duration != null or status.remaining_duration != null) {
        try stdout.interface.writeAll("\nDuration\n");
        try stdout.interface.writeAll("- Total: ");
        if (status.total_duration) |total| {
            try printDurationHM(&stdout.interface, total);
        }
        try stdout.interface.writeAll("\n");

        if (status.remaining_duration) |remaining| {
            try stdout.interface.writeAll("- Remaining: ");
            try printDurationHM(&stdout.interface, remaining);
            try stdout.interface.writeAll("\n");
        }
    }

    try stdout.interface.writeAll("\n");
}

fn printOptionalInstant(writer: anytype, value: ?zeit.Instant) !void {
    if (value) |instant| {
        try printInstant(writer, instant);
    } else {
        try writer.writeAll("N/A");
    }
}

fn printInstant(writer: anytype, instant: zeit.Instant) !void {
    try instant.time().gofmt(writer, "Jan 2, 2006 3:04 pm");
}

fn roundToI64(value: f64) i64 {
    return @as(i64, @intFromFloat(std.math.round(value)));
}

fn durationMinutes(duration: zeit.Duration) usize {
    // TODO: Maybe this should use nanoseconds internally to avoid precision issues?
    // For now this should be good enough since the API only returns minute-level precision for delays
    return duration.days * 24 * 60 + duration.hours * 60 + duration.minutes + @divFloor(duration.seconds, 60);
}

fn printDurationHM(writer: anytype, duration: zeit.Duration) !void {
    const minutes = durationMinutes(duration);
    const hours = @divFloor(minutes, 60);
    const remaining_minutes = @mod(minutes, 60);

    if (hours > 0) {
        try writer.print("{d}h {d}m", .{ hours, remaining_minutes });
    } else {
        try writer.print("{d}m", .{remaining_minutes});
    }
}
