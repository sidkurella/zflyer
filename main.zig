const std = @import("std");
const zz = @import("deps/zigzag/src/root.zig");
const args = @import("deps/args/src/args.zig");
const status_client = @import("src/status_client.zig");
const location_client = @import("src/location_client.zig");
const airline_client = @import("src/airline_search_client.zig");
const Env = @import("deps/dotenv-zig/src/root.zig");
const zeit = @import("deps/zeit/src/zeit.zig");

const Screen = enum {
    airline_query,
    airline_results,
    flight_number_query,
    status,
};

const Model = struct {
    allocator: std.mem.Allocator,
    flight_number: ?[]const u8,
    status_client: *status_client.FlightStatusClient,
    location_client: *location_client.LocationClient,
    airline_search_client: *airline_client.AirlineSearchClient,
    local_zone: *const zeit.TimeZone,

    screen: Screen = .airline_query,
    selected_airline_name: ?[]const u8 = null,
    selected_airline_iata: ?[]const u8 = null,

    flight_status: ?status_client.FlightStatus = null,
    location_result: ?location_client.LocationResult = null,
    loading: bool = false,
    pending_refresh: bool = false,
    refresh_armed: bool = false,
    error_text: ?[]const u8 = null,
    spinner: zz.Spinner = zz.Spinner.init(),

    airline_input: zz.TextInput = undefined,
    flight_number_input: zz.TextInput = undefined,
    airline_suggestions: ?airline_client.AirlineSearchResult = null,
    airline_result_list: zz.List(airline_client.Airline) = undefined,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
        refresh,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.loading = false;
        self.pending_refresh = false;
        self.refresh_armed = false;
        self.error_text = null;

        self.spinner.setFrames(zz.Spinner.Styles.arc);
        self.spinner.setStyle((zz.Style{}).fg(zz.Color.hex("#f59e0b")).inline_style(true));

        self.airline_input = zz.TextInput.init(self.allocator);
        self.airline_input.setPrompt("Airline: ");
        self.airline_input.setPlaceholder("Enter airline name (e.g. American Airlines)...");

        self.flight_number_input = zz.TextInput.init(self.allocator);
        self.flight_number_input.setPrompt("Flight #: ");
        self.flight_number_input.setPlaceholder("Type number (e.g. 123)...");

        self.airline_result_list = zz.List(airline_client.Airline).init(self.allocator);
        self.airline_result_list.multi_select = false;
        self.airline_result_list.height = 8;
        self.airline_result_list.show_item_count = true;

        if (self.flight_number != null) {
            self.screen = .status;
            self.startRefresh();
        } else {
            self.screen = .airline_query;
            self.airline_input.focus();
            self.flight_number_input.blur();
            self.airline_result_list.blur();
        }

        return zz.Cmd(Msg).everyMs(16);
    }

    pub fn deinit(self: *Model) void {
        self.clearStatusData();

        if (self.flight_number) |flight| {
            self.allocator.free(flight);
            self.flight_number = null;
        }

        if (self.selected_airline_name) |name| {
            self.allocator.free(name);
            self.selected_airline_name = null;
        }
        if (self.selected_airline_iata) |iata| {
            self.allocator.free(iata);
            self.selected_airline_iata = null;
        }

        if (self.airline_suggestions) |*results| {
            results.deinit();
            self.airline_suggestions = null;
        }

        self.airline_input.deinit();
        self.flight_number_input.deinit();
        self.airline_result_list.deinit();
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| return self.handleKey(k),
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
                if (self.screen == .status and self.flight_number != null) {
                    self.startRefresh();
                }
            },
        }

        return .none;
    }

    fn handleKey(self: *Model, key_event: zz.KeyEvent) zz.Cmd(Msg) {
        switch (self.screen) {
            .airline_query => {
                switch (key_event.key) {
                    .escape => return .quit,
                    .enter => self.submitAirlineSearch(),
                    else => self.airline_input.handleKey(key_event),
                }
            },
            .airline_results => {
                switch (key_event.key) {
                    .escape => {
                        self.screen = .airline_query;
                        self.airline_result_list.blur();
                        self.airline_input.focus();
                    },
                    .enter => {
                        self.airline_result_list.handleKey(key_event);
                        self.acceptSelectedAirline();
                    },
                    else => self.airline_result_list.handleKey(key_event),
                }
            },
            .flight_number_query => {
                switch (key_event.key) {
                    .escape => {
                        self.screen = .airline_results;
                        self.flight_number_input.blur();
                        self.airline_result_list.focus();
                    },
                    .enter => self.submitFlightNumber(),
                    else => self.flight_number_input.handleKey(key_event),
                }
            },
            .status => {
                switch (key_event.key) {
                    .escape => return .quit,
                    .f5 => return .{ .msg = .refresh },
                    .char => |c| {
                        if (c == 'q') return .quit;
                        if (c == 'r') return .{ .msg = .refresh };
                    },
                    else => {},
                }
            },
        }

        return .none;
    }

    fn submitAirlineSearch(self: *Model) void {
        const raw = self.airline_input.getValue();
        const query = std.mem.trim(u8, raw, " \t\r\n");

        if (query.len == 0) {
            self.error_text = "Please enter an airline name";
            return;
        }

        var results = self.airline_search_client.searchAirlines(query) catch |err| {
            self.error_text = @errorName(err);
            return;
        };

        if (results.airlines.len == 0) {
            results.deinit();
            self.error_text = "No matching airlines found";
            return;
        }

        self.airline_result_list.clear();
        if (self.airline_suggestions) |*existing| {
            existing.deinit();
            self.airline_suggestions = null;
        }

        self.airline_suggestions = results;
        if (self.airline_suggestions) |stored| {
            for (stored.airlines) |airline| {
                const item = zz.List(airline_client.Airline).Item.withDescription(airline, airline.name, airline.iata_code);
                self.airline_result_list.addItem(item) catch {
                    self.error_text = "Failed to load airline list";
                    return;
                };
            }
        }

        self.airline_result_list.gotoFirst();
        self.airline_input.blur();
        self.airline_result_list.focus();
        self.screen = .airline_results;
        self.error_text = null;
    }

    fn acceptSelectedAirline(self: *Model) void {
        const selected = self.airline_result_list.selectedValue() orelse {
            self.error_text = "Select an airline before continuing";
            return;
        };

        self.replaceSelectedAirline(selected) catch {
            self.error_text = "Failed to store selected airline";
            return;
        };

        self.flight_number_input.setValue("") catch {};
        self.airline_result_list.blur();
        self.flight_number_input.focus();
        self.screen = .flight_number_query;
        self.error_text = null;
    }

    fn replaceSelectedAirline(self: *Model, selected: airline_client.Airline) !void {
        if (self.selected_airline_name) |name| {
            self.allocator.free(name);
            self.selected_airline_name = null;
        }
        if (self.selected_airline_iata) |iata| {
            self.allocator.free(iata);
            self.selected_airline_iata = null;
        }

        self.selected_airline_name = try self.allocator.dupe(u8, selected.name);
        errdefer {
            if (self.selected_airline_name) |name| {
                self.allocator.free(name);
                self.selected_airline_name = null;
            }
        }

        self.selected_airline_iata = try self.allocator.dupe(u8, selected.iata_code);
    }

    fn submitFlightNumber(self: *Model) void {
        const iata = self.selected_airline_iata orelse {
            self.error_text = "Pick an airline first";
            self.screen = .airline_query;
            self.airline_input.focus();
            self.flight_number_input.blur();
            return;
        };

        const raw_flight = self.flight_number_input.getValue();
        const flight_number_part = std.mem.trim(u8, raw_flight, " \t\r\n");
        if (flight_number_part.len == 0) {
            self.error_text = "Please enter a flight number";
            return;
        }

        const full_flight_iata = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ iata, flight_number_part }) catch {
            self.error_text = "Failed to build flight code";
            return;
        };

        if (self.flight_number) |existing| {
            self.allocator.free(existing);
        }
        self.flight_number = full_flight_iata;

        self.clearStatusData();
        self.screen = .status;
        self.startRefresh();
    }

    fn startRefresh(self: *Model) void {
        self.loading = true;
        self.pending_refresh = true;
        self.refresh_armed = false;
        self.error_text = null;
    }

    fn clearStatusData(self: *Model) void {
        if (self.flight_status) |*status| {
            status.deinit(self.allocator);
            self.flight_status = null;
        }

        if (self.location_result) |*location| {
            location.deinit();
            self.location_result = null;
        }
    }

    fn performRefresh(self: *Model) void {
        const flight = self.flight_number orelse {
            self.loading = false;
            self.pending_refresh = false;
            self.refresh_armed = false;
            self.error_text = "Missing flight number";
            return;
        };

        const status = self.status_client.checkStatus(flight) catch |err| {
            self.loading = false;
            self.pending_refresh = false;
            self.refresh_armed = false;
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

        switch (self.screen) {
            .airline_query => {
                try writer.print("{s}\n\n", .{try hint_style.render(ctx.allocator, "Enter airline name, then press Enter")});
                try writer.print("{s}\n", .{try section_style.render(ctx.allocator, "SETUP")});
                const input_text = try self.airline_input.view(ctx.allocator);
                try writer.print("{s}\n", .{input_text});
                try writer.print("{s}\n", .{try hint_style.render(ctx.allocator, "Esc to quit")});

                if (self.error_text) |err| {
                    const message = try std.fmt.allocPrint(ctx.allocator, "Error: {s}", .{err});
                    try writer.print("\n{s}\n", .{try error_style.render(ctx.allocator, message)});
                }
                return;
            },
            .airline_results => {
                try writer.print("{s}\n\n", .{try hint_style.render(ctx.allocator, "Pick airline with arrows + Enter")});
                try writer.print("{s}\n", .{try section_style.render(ctx.allocator, "AIRLINE RESULTS")});

                const list_text = try self.airline_result_list.view(ctx.allocator);
                try writer.print("{s}\n", .{list_text});
                try writer.print("{s}\n", .{try hint_style.render(ctx.allocator, "Esc to go back")});

                if (self.error_text) |err| {
                    const message = try std.fmt.allocPrint(ctx.allocator, "Error: {s}", .{err});
                    try writer.print("\n{s}\n", .{try error_style.render(ctx.allocator, message)});
                }
                return;
            },
            .flight_number_query => {
                try writer.print("{s}\n\n", .{try hint_style.render(ctx.allocator, "Enter flight number and press Enter")});
                try writer.print("{s}\n", .{try section_style.render(ctx.allocator, "FLIGHT")});

                if (self.selected_airline_name) |name| {
                    try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "Airline", name);
                }
                if (self.selected_airline_iata) |iata| {
                    try writeLabeledValue(writer, ctx.allocator, label_style, value_style, "IATA Code", iata);
                }

                const input_text = try self.flight_number_input.view(ctx.allocator);
                try writer.print("{s}\n", .{input_text});
                try writer.print("{s}\n", .{try hint_style.render(ctx.allocator, "Esc to go back")});

                if (self.error_text) |err| {
                    const message = try std.fmt.allocPrint(ctx.allocator, "Error: {s}", .{err});
                    try writer.print("\n{s}\n", .{try error_style.render(ctx.allocator, message)});
                }
                return;
            },
            .status => {},
        }

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

        if (statusProviderLabel(ctx.allocator, status)) |label| {
            try writer.print("{s}\n\n", .{try hint_style.render(ctx.allocator, label)});
        }

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
            if (percent > 0 and percent <= 100) {
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

    var ac = airline_client.AirlineSearchClient.init(allocator, try env.getRequired("AIRLABS_API_KEY"));
    defer ac.deinit();

    const flight_number_arg = result.getString("flight_number");
    var owned_flight_number: ?[]const u8 = null;
    if (flight_number_arg) |flight| {
        owned_flight_number = try allocator.dupe(u8, flight);
        errdefer if (owned_flight_number) |owned| allocator.free(owned);
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var local_zone = try zeit.local(allocator, &env_map);
    defer local_zone.deinit();

    var program = try zz.Program(Model).initWithOptions(allocator, .{
        .title = "zflyer",
        .alt_screen = true,
        .bracketed_paste = false,
        .kitty_keyboard = false,
        .mouse = false,
    });
    defer program.deinit();

    program.model = .{
        .allocator = allocator,
        .flight_number = owned_flight_number,
        .status_client = &sc,
        .location_client = &lc,
        .airline_search_client = &ac,
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

fn statusProviderLabel(allocator: std.mem.Allocator, status: status_client.FlightStatus) ?[]const u8 {
    const updated = status.updated_at_utc orelse return "ETA source: AirLabs";
    const now = zeit.instant(.{ .source = .now, .timezone = &zeit.utc }) catch return "ETA source: AirLabs";

    var age_seconds = now.unixTimestamp() - updated.unixTimestamp();
    if (age_seconds < 0) age_seconds = 0;

    if (age_seconds < 60) {
        return std.fmt.allocPrint(allocator, "ETA source: AirLabs (updated {d}s ago)", .{age_seconds}) catch "ETA source: AirLabs";
    }

    const age_minutes = @divFloor(age_seconds, 60);
    if (age_minutes < 60) {
        return std.fmt.allocPrint(allocator, "ETA source: AirLabs (updated {d}m ago)", .{age_minutes}) catch "ETA source: AirLabs";
    }

    const hours = @divFloor(age_minutes, 60);
    const minutes = @mod(age_minutes, 60);
    return std.fmt.allocPrint(allocator, "ETA source: AirLabs (updated {d}h {d}m ago)", .{ hours, minutes }) catch "ETA source: AirLabs";
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
