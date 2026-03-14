const std = @import("std");
const zz = @import("deps/zigzag/src/root.zig");
const args = @import("deps/args/src/args.zig");
const status_client = @import("src/status_client.zig");
const location_client = @import("src/location_client.zig");
const Env = @import("deps/dotenv-zig/src/root.zig");
const zeit = @import("deps/zeit/src/zeit.zig");

const Model = struct {
    allocator: std.mem.Allocator,
    flight_number: []const u8,
    status_client: *status_client.FlightStatusClient,
    location_client: *location_client.LocationClient,
    local_zone: *const zeit.TimeZone,

    flight_status: ?status_client.FlightStatus = null,
    location_result: ?location_client.LocationResult = null,
    loading: bool = false,
    pending_refresh: bool = false,
    refresh_armed: bool = false,
    error_text: ?[]const u8 = null,
    spinner: zz.Spinner = zz.Spinner.init(),

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
        refresh,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.loading = true;
        self.pending_refresh = true;
        self.refresh_armed = false;
        self.error_text = null;
        self.spinner.setFrames(zz.Spinner.Styles.arc);
        self.spinner.setStyle((zz.Style{}).fg(zz.Color.hex("#f59e0b")).inline_style(true));
        return zz.Cmd(Msg).everyMs(10);
    }

    pub fn deinit(self: *Model) void {
        if (self.flight_status) |*status| {
            status.deinit(self.allocator);
            self.flight_status = null;
        }
        if (self.location_result) |*location| {
            location.deinit();
            self.location_result = null;
        }
        self.allocator.free(self.flight_number);
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .char => |c| {
                    if (c == 'q') return .quit;
                    if (c == 'r') return .{ .msg = .refresh };
                },
                .escape => return .quit,
                .f5 => return .{ .msg = .refresh },
                else => {},
            },
            .tick => |tick_msg| {
                _ = self.spinner.update(tick_msg.timestamp);
                if (self.pending_refresh) {
                    if (!self.refresh_armed) {
                        self.refresh_armed = true;
                    } else {
                        self.performRefresh();
                    }
                }
            },
            .refresh => {
                self.loading = true;
                self.pending_refresh = true;
                self.refresh_armed = false;
                self.error_text = null;
            },
        }

        return .none;
    }

    fn performRefresh(self: *Model) void {
        const status = self.status_client.checkStatus(self.flight_number) catch |err| {
            self.loading = false;
            self.pending_refresh = false;
            self.error_text = @errorName(err);
            return;
        };

        if (self.flight_status) |*old_status| {
            old_status.deinit(self.allocator);
        }
        self.flight_status = status;

        if (self.location_result) |*old_location| {
            old_location.deinit();
        }
        self.location_result = null;

        if (status.in_flight_params.latitude) |lat| {
            if (status.in_flight_params.longitude) |lng| {
                self.location_result = self.location_client.checkLocation(lat, lng) catch |err| blk: {
                    self.error_text = @errorName(err);
                    break :blk null;
                };
            }
        }

        self.loading = false;
        self.pending_refresh = false;
        self.refresh_armed = false;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(ctx.allocator);
        const writer = output.writer(ctx.allocator);

        self.renderView(ctx, writer) catch return "render error";
        return output.toOwnedSlice(ctx.allocator) catch "render error";
    }

    fn renderView(self: *const Model, ctx: *const zz.Context, writer: anytype) !void {
        const title_style = (zz.Style{}).fg(zz.Color.hex("#7dd3fc")).bold(true);
        const hint_style = (zz.Style{}).fg(zz.Color.gray(14));
        const section_style = (zz.Style{}).fg(zz.Color.hex("#fbbf24")).bold(true);
        const label_style = (zz.Style{}).fg(zz.Color.hex("#93c5fd")).bold(true);
        const value_style = (zz.Style{}).fg(zz.Color.hex("#e5e7eb"));
        const scheduled_time_style = (zz.Style{}).fg(zz.Color.hex("#38bdf8")).bold(true);
        const ok_style = (zz.Style{}).fg(zz.Color.hex("#34d399")).bold(true);
        const warn_style = (zz.Style{}).fg(zz.Color.hex("#f59e0b")).bold(true);
        const error_style = (zz.Style{}).fg(zz.Color.hex("#f87171")).bold(true);

        try writer.print("{s}\n", .{try title_style.render(ctx.allocator, "zflyer - flight tracker")});
        try writer.print("{s}\n\n", .{try hint_style.render(ctx.allocator, "Press q to quit, r/F5 to refresh")});

        if (self.loading) {
            const spinner_line = try self.spinner.viewWithTitle(ctx.allocator, "Loading latest flight data...");
            try writer.print("{s}\n", .{spinner_line});
            return;
        }

        if (self.error_text) |err| {
            const message = try std.fmt.allocPrint(ctx.allocator, "Error: {s}", .{err});
            try writer.print("{s}\n\n", .{try error_style.render(ctx.allocator, message)});
        }

        const status = self.flight_status orelse {
            try writer.print("{s}\n", .{try hint_style.render(ctx.allocator, "No flight data loaded yet")});
            return;
        };

        try writer.print("{s}\n", .{try section_style.render(ctx.allocator, "STATUS")});
        const flight_title = try std.fmt.allocPrint(ctx.allocator, "{s} {s} ({s})", .{ status.airline_name, status.flight_number, status.flight_iata });
        try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Flight", flight_title);

        const route = try std.fmt.allocPrint(ctx.allocator, "{s} -> {s}", .{ status.departure_airport.iata_code, status.arrival_airport.iata_code });
        try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Route", route);

        const departure_status_style = styleForDepartedStatus(status.departed_status, scheduled_time_style, warn_style, ok_style, error_style, hint_style);
        try writeLabeledValue(writer, ctx.allocator, label_style, departure_status_style, "Departure", status.departed_status.toString());

        const delay_status_style = switch (status.delay_status) {
            .OnTime => ok_style,
            .Delayed => warn_style,
            .Canceled => error_style,
            .Unknown => hint_style,
        };
        try writeLabeledValue(writer, ctx.allocator, label_style, delay_status_style, "Delay", status.delay_status.toString());

        if (status.delay_info.departure_delay_minutes != null or status.delay_info.arrival_delay_minutes != null) {
            try writer.print("\n{s}\n", .{try section_style.render(ctx.allocator, "DELAYS")});
            if (status.delay_info.departure_delay_minutes) |departure_delay| {
                const prefix = if (status.departed_status == .Departed) "Departed" else "Departing";
                const text = try std.fmt.allocPrint(ctx.allocator, "{s} {s} late", .{ prefix, try formatDurationHM(ctx.allocator, departure_delay) });
                try writeLabeledValue(writer, ctx.allocator, label_style, warn_style, "Departure", text);
            }
            if (status.delay_info.arrival_delay_minutes) |arrival_delay| {
                const prefix = if (status.departed_status == .Arrived) "Arrived" else "Arriving";
                const text = try std.fmt.allocPrint(ctx.allocator, "{s} {s} late", .{ prefix, try formatDurationHM(ctx.allocator, arrival_delay) });
                try writeLabeledValue(writer, ctx.allocator, label_style, warn_style, "Arrival", text);
            }
        }

        try writer.print("\n{s}\n", .{try section_style.render(ctx.allocator, "AIRPORTS")});
        const dep_airport = try std.fmt.allocPrint(
            ctx.allocator,
            "{s} ({s}), {s}, {s}",
            .{ status.departure_airport.name, status.departure_airport.iata_code, status.departure_airport.city, status.departure_airport.country },
        );
        try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Departure", dep_airport);

        if (status.departure_gate.terminal != null or status.departure_gate.gate != null) {
            const gate_info = try std.fmt.allocPrint(
                ctx.allocator,
                "Terminal {s} | Gate {s}",
                .{ status.departure_gate.terminal orelse "-", status.departure_gate.gate orelse "-" },
            );
            try writeLabeledValue(writer, ctx.allocator, label_style, hint_style, "Dep Gate", gate_info);
        }
        if (status.departure_gate.baggage_claim) |baggage| {
            try writeLabeledValue(writer, ctx.allocator, label_style, hint_style, "Dep Baggage", baggage);
        }

        const arr_airport = try std.fmt.allocPrint(
            ctx.allocator,
            "{s} ({s}), {s}, {s}",
            .{ status.arrival_airport.name, status.arrival_airport.iata_code, status.arrival_airport.city, status.arrival_airport.country },
        );
        try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Arrival", arr_airport);

        if (status.arrival_gate.terminal != null or status.arrival_gate.gate != null) {
            const gate_info = try std.fmt.allocPrint(
                ctx.allocator,
                "Terminal {s} | Gate {s}",
                .{ status.arrival_gate.terminal orelse "-", status.arrival_gate.gate orelse "-" },
            );
            try writeLabeledValue(writer, ctx.allocator, label_style, hint_style, "Arr Gate", gate_info);
        }
        if (status.arrival_gate.baggage_claim) |baggage| {
            try writeLabeledValue(writer, ctx.allocator, label_style, hint_style, "Arr Baggage", baggage);
        }

        try writer.print("\n{s}\n", .{try section_style.render(ctx.allocator, "TIMING")});
        const departure_actual_style = if (hasDelay(status.delay_info.departure_delay_minutes)) warn_style else ok_style;
        const arrival_actual_style = if (hasDelay(status.delay_info.arrival_delay_minutes)) warn_style else ok_style;
        const departure_estimated_style = if (hasDelay(status.delay_info.departure_delay_minutes)) warn_style else scheduled_time_style;
        const arrival_estimated_style = if (hasDelay(status.delay_info.arrival_delay_minutes)) warn_style else scheduled_time_style;

        const dep_scheduled_local = if (status.departure_time.scheduled_utc) |value| value.in(self.local_zone) else null;
        const dep_actual_local = if (status.departure_time.actual_utc) |value| value.in(self.local_zone) else null;
        const dep_estimated_local = if (status.departure_time.estimated_utc) |value| value.in(self.local_zone) else null;

        const arr_scheduled_local = if (status.arrival_time.scheduled_utc) |value| value.in(self.local_zone) else null;
        const arr_actual_local = if (status.arrival_time.actual_utc) |value| value.in(self.local_zone) else null;
        const arr_estimated_local = if (status.arrival_time.estimated_utc) |value| value.in(self.local_zone) else null;

        if (ctx.width >= 115) {
            var airport_block: std.ArrayList(u8) = .empty;
            defer airport_block.deinit(ctx.allocator);
            const airport_writer = airport_block.writer(ctx.allocator);
            try airport_writer.print("{s}\n", .{try label_style.render(ctx.allocator, "Airport Time")});
            try renderTimeLine(
                airport_writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                departure_actual_style,
                departure_estimated_style,
                hint_style,
                "Departure",
                status.departure_time.scheduled_local,
                status.departure_time.actual_local,
                status.departure_time.estimated_local,
            );
            try renderTimeLine(
                airport_writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                arrival_actual_style,
                arrival_estimated_style,
                hint_style,
                "Arrival",
                status.arrival_time.scheduled_local,
                status.arrival_time.actual_local,
                status.arrival_time.estimated_local,
            );

            var local_block: std.ArrayList(u8) = .empty;
            defer local_block.deinit(ctx.allocator);
            const local_writer = local_block.writer(ctx.allocator);
            try local_writer.print("{s}\n", .{try label_style.render(ctx.allocator, "Local Time")});
            try renderTimeLine(
                local_writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                departure_actual_style,
                departure_estimated_style,
                hint_style,
                "Departure",
                dep_scheduled_local,
                dep_actual_local,
                dep_estimated_local,
            );
            try renderTimeLine(
                local_writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                arrival_actual_style,
                arrival_estimated_style,
                hint_style,
                "Arrival",
                arr_scheduled_local,
                arr_actual_local,
                arr_estimated_local,
            );

            const airport_text = try airport_block.toOwnedSlice(ctx.allocator);
            const local_text = try local_block.toOwnedSlice(ctx.allocator);
            const timing_columns = try zz.join.horizontalSep(ctx.allocator, .top, "   ", &.{ airport_text, local_text });
            try writer.print("{s}\n", .{timing_columns});
        } else {
            try renderTimeLine(
                writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                departure_actual_style,
                departure_estimated_style,
                hint_style,
                "Departure (airport)",
                status.departure_time.scheduled_local,
                status.departure_time.actual_local,
                status.departure_time.estimated_local,
            );
            try renderTimeLine(
                writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                arrival_actual_style,
                arrival_estimated_style,
                hint_style,
                "Arrival (airport)",
                status.arrival_time.scheduled_local,
                status.arrival_time.actual_local,
                status.arrival_time.estimated_local,
            );
            try renderTimeLine(
                writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                departure_actual_style,
                departure_estimated_style,
                hint_style,
                "Departure (local)",
                dep_scheduled_local,
                dep_actual_local,
                dep_estimated_local,
            );
            try renderTimeLine(
                writer,
                ctx.allocator,
                label_style,
                scheduled_time_style,
                arrival_actual_style,
                arrival_estimated_style,
                hint_style,
                "Arrival (local)",
                arr_scheduled_local,
                arr_actual_local,
                arr_estimated_local,
            );
        }

        const has_live_data =
            status.in_flight_params.altitude != null or
            status.in_flight_params.speed != null or
            status.in_flight_params.heading != null or
            (status.in_flight_params.latitude != null and status.in_flight_params.longitude != null);

        if (has_live_data) {
            try writer.print("\n{s}\n", .{try section_style.render(ctx.allocator, "LIVE")});
            if (status.in_flight_params.altitude) |altitude| {
                const value = try std.fmt.allocPrint(ctx.allocator, "{d} ft", .{roundToI64(altitude)});
                try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Altitude", value);
            }
            if (status.in_flight_params.speed) |speed| {
                const value = try std.fmt.allocPrint(ctx.allocator, "{d} mph", .{roundToI64(speed)});
                try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Speed", value);
            }
            if (status.in_flight_params.heading) |heading| {
                const value = try std.fmt.allocPrint(ctx.allocator, "{d} deg", .{roundToI64(heading)});
                try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Heading", value);
            }
            if (status.in_flight_params.latitude) |lat| {
                if (status.in_flight_params.longitude) |lng| {
                    const position = try std.fmt.allocPrint(ctx.allocator, "{d}, {d}", .{ lat, lng });
                    try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Position", position);

                    if (self.location_result) |location| {
                        try writeLabeledValue(writer, ctx.allocator, label_style, ok_style, "Overflying", location.formatted_address);
                    } else {
                        try writeLabeledValue(writer, ctx.allocator, label_style, hint_style, "Overflying", "Unknown location");
                    }
                }
            }
        }

        if (status.percentage_completed) |percent| {
            if (percent != 0) {
                try writer.print("\n{s}\n", .{try section_style.render(ctx.allocator, "PROGRESS")});
                var progress = zz.Progress.init();
                progress.setGradient(zz.Color.hex("#0ea5e9"), zz.Color.hex("#22c55e"));
                progress.setWidth(progressBarWidth(ctx.width));
                progress.setPercent(@as(f64, @floatFromInt(percent)));
                progress.percent_style = (zz.Style{}).fg(zz.Color.hex("#34d399")).bold(true).inline_style(true);
                const progress_bar = try progress.view(ctx.allocator);
                try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Completion", progress_bar);
            }
        }

        if (status.total_duration != null or status.remaining_duration != null) {
            try writer.print("\n{s}\n", .{try section_style.render(ctx.allocator, "DURATION")});
            if (status.total_duration) |total| {
                try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Total", try formatDurationHM(ctx.allocator, total));
            } else {
                try writeLabeledValue(writer, ctx.allocator, label_style, hint_style, "Total", "N/A");
            }

            if (status.remaining_duration) |remaining| {
                try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Remaining", try formatDurationHM(ctx.allocator, remaining));
            }
        }
    }
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

    const owned_flight_number = try allocator.dupe(u8, flight_number.?);
    errdefer allocator.free(owned_flight_number);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var local_zone = try zeit.local(allocator, &env_map);
    defer local_zone.deinit();

    var program = try zz.Program(Model).initWithOptions(allocator, .{
        .title = "zflyer",
        .alt_screen = true,
    });
    defer program.deinit();

    program.model = .{
        .allocator = allocator,
        .flight_number = owned_flight_number,
        .status_client = &sc,
        .location_client = &lc,
        .local_zone = &local_zone,
    };

    try program.run();
}

fn writeLabeledValue(
    writer: anytype,
    allocator: std.mem.Allocator,
    label_style: zz.Style,
    value_style: zz.Style,
    label: []const u8,
    value: []const u8,
) !void {
    const styled_label = try label_style.render(allocator, label);
    const styled_value = try value_style.render(allocator, value);
    try writer.print("  {s}: {s}\n", .{ styled_label, styled_value });
}

fn renderTimeLine(
    writer: anytype,
    allocator: std.mem.Allocator,
    label_style: zz.Style,
    scheduled_style: zz.Style,
    actual_style: zz.Style,
    estimated_style: zz.Style,
    fallback_style: zz.Style,
    label: []const u8,
    scheduled: ?zeit.Instant,
    actual: ?zeit.Instant,
    estimated: ?zeit.Instant,
) !void {
    if (scheduled) |value| {
        const text = try std.fmt.allocPrint(allocator, "Scheduled: {s}", .{try formatInstant(allocator, value)});
        try writeLabeledValue(writer, allocator, label_style, scheduled_style, label, text);
    }

    if (actual) |value| {
        const delta = try formatDeltaFromScheduled(allocator, scheduled, value);
        const text = try std.fmt.allocPrint(allocator, "Actual: {s}{s}", .{ try formatInstant(allocator, value), delta });
        const live_label = if (scheduled != null) "  update" else label;
        try writeLabeledValue(writer, allocator, label_style, actual_style, live_label, text);
        return;
    }

    if (estimated) |value| {
        const delta = try formatDeltaFromScheduled(allocator, scheduled, value);
        const text = try std.fmt.allocPrint(allocator, "Estimated: {s}{s}", .{ try formatInstant(allocator, value), delta });
        const live_label = if (scheduled != null) "  update" else label;
        try writeLabeledValue(writer, allocator, label_style, estimated_style, live_label, text);
        return;
    }

    if (scheduled == null) {
        try writeLabeledValue(writer, allocator, label_style, fallback_style, label, "Unknown");
    }
}

fn formatInstant(allocator: std.mem.Allocator, instant: zeit.Instant) ![]const u8 {
    const t = instant.time();
    const hour24: u8 = @intCast(t.hour);
    const hour12: u8 = if (hour24 % 12 == 0) 12 else hour24 % 12;
    const period = if (hour24 < 12) "am" else "pm";
    return std.fmt.allocPrint(
        allocator,
        "{s} {d}, {d} {d}:{d:0>2} {s}",
        .{ t.month.shortName(), t.day, t.year, hour12, t.minute, period },
    );
}

fn roundToI64(value: f64) i64 {
    return @as(i64, @intFromFloat(std.math.round(value)));
}

fn durationMinutes(duration: zeit.Duration) usize {
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

fn formatDurationHM(allocator: std.mem.Allocator, duration: zeit.Duration) ![]const u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    const writer = output.writer();
    try printDurationHM(writer, duration);
    return output.toOwnedSlice();
}

fn formatDeltaFromScheduled(allocator: std.mem.Allocator, scheduled: ?zeit.Instant, observed: zeit.Instant) ![]const u8 {
    const base = scheduled orelse return "";
    const delta_seconds = observed.unixTimestamp() - base.unixTimestamp();
    if (delta_seconds == 0) return "";

    const sign: u8 = if (delta_seconds >= 0) '+' else '-';
    const abs_seconds = if (delta_seconds >= 0) delta_seconds else -delta_seconds;
    const minutes = @divFloor(abs_seconds, 60);

    if (minutes == 0) return "";

    if (minutes >= 60) {
        const hours = @divFloor(minutes, 60);
        const rem_minutes = @mod(minutes, 60);
        if (rem_minutes == 0) {
            return std.fmt.allocPrint(allocator, " ({c}{d}h)", .{ sign, hours });
        }
        return std.fmt.allocPrint(allocator, " ({c}{d}h {d}m)", .{ sign, hours, rem_minutes });
    }

    return std.fmt.allocPrint(allocator, " ({c}{d}m)", .{ sign, minutes });
}

fn hasDelay(delay: ?zeit.Duration) bool {
    const value = delay orelse return false;
    return durationMinutes(value) > 0;
}

fn styleForDepartedStatus(
    departed_status: status_client.DepartedStatus,
    scheduled_style: zz.Style,
    departed_style: zz.Style,
    arrived_style: zz.Style,
    canceled_style: zz.Style,
    unknown_style: zz.Style,
) zz.Style {
    return switch (departed_status) {
        .Scheduled => scheduled_style,
        .Departed => departed_style,
        .Arrived => arrived_style,
        .Canceled => canceled_style,
        .Unknown => unknown_style,
    };
}

fn progressBarWidth(term_width: u16) u16 {
    if (term_width <= 70) return 20;
    if (term_width <= 100) return 28;
    return 36;
}
