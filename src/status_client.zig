const std = @import("std");
const httpx = @import("../deps/httpx/src/httpx.zig");
const zeit = @import("../deps/zeit/src/zeit.zig");

pub const Errors = error{
    ConnectionFailed,
    InvalidResponse,
    UnexpectedStatusCode,
    InvalidDateTimeFormat,
};

pub const DelayStatus = enum {
    OnTime,
    Delayed,
    Canceled,
    Unknown,

    pub fn fromResponse(delay: ?zeit.Duration, departed_status: DepartedStatus) DelayStatus {
        if (departed_status == .Canceled) {
            return .Canceled;
        }

        if (delay) |d| {
            const has_delay = d.days > 0 or d.hours > 0 or d.minutes > 0 or d.seconds > 0 or d.milliseconds > 0 or d.microseconds > 0 or d.nanoseconds > 0;
            return if (has_delay) .Delayed else .OnTime;
        }

        return .OnTime;
    }

    pub fn toString(self: DelayStatus) []const u8 {
        return switch (self) {
            .OnTime => "On Time",
            .Delayed => "Delayed",
            .Canceled => "Canceled",
            .Unknown => "Unknown",
        };
    }
};

pub const DelayInfo = struct {
    departure_delay_minutes: ?zeit.Duration,
    arrival_delay_minutes: ?zeit.Duration,
};

pub const DepartedStatus = enum {
    Scheduled,
    Departed,
    Arrived,
    Canceled,
    Unknown,

    pub fn fromResponse(status: []const u8) DepartedStatus {
        if (std.mem.eql(u8, status, "scheduled")) {
            return DepartedStatus.Scheduled;
        } else if (std.mem.eql(u8, status, "en-route") or std.mem.eql(u8, status, "active")) {
            return DepartedStatus.Departed;
        } else if (std.mem.eql(u8, status, "landed")) {
            return DepartedStatus.Arrived;
        } else if (std.mem.eql(u8, status, "cancelled") or std.mem.eql(u8, status, "canceled")) {
            return DepartedStatus.Canceled;
        } else {
            return DepartedStatus.Unknown;
        }
    }

    pub fn toString(self: DepartedStatus) []const u8 {
        return switch (self) {
            .Scheduled => "Scheduled",
            .Departed => "Departed",
            .Arrived => "Arrived",
            .Canceled => "Canceled",
            .Unknown => "Unknown",
        };
    }
};

pub const Airport = struct {
    iata_code: []const u8,
    name: []const u8,
    city: []const u8,
    country: []const u8,
};

pub const Aircraft = struct {
    model: []const u8,
    registration: []const u8,
};

pub const InFlightParams = struct {
    altitude: ?f64,
    speed: ?f64,
    latitude: ?f64,
    longitude: ?f64,
    heading: ?f64,
};

pub const GateInfo = struct {
    terminal: ?[]const u8,
    gate: ?[]const u8,
    baggage_claim: ?[]const u8,
};

pub const TimeInfo = struct {
    scheduled_local: ?zeit.Instant,
    scheduled_utc: ?zeit.Instant,

    actual_local: ?zeit.Instant,
    actual_utc: ?zeit.Instant,
};

pub const FlightStatus = struct {
    flight_iata: []const u8,
    airline_name: []const u8,
    flight_number: []const u8,
    delay_status: DelayStatus,
    delay_info: DelayInfo,
    departed_status: DepartedStatus,
    departure_airport: Airport,
    departure_gate: GateInfo,
    arrival_airport: Airport,
    arrival_gate: GateInfo,
    in_flight_params: InFlightParams,
    departure_time: TimeInfo,
    arrival_time: TimeInfo,
    percentage_completed: ?i64,
    total_duration: ?zeit.Duration,
    remaining_duration: ?zeit.Duration,

    pub fn deinit(self: *FlightStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.flight_iata);
        allocator.free(self.airline_name);
        allocator.free(self.flight_number);

        allocator.free(self.departure_airport.iata_code);
        allocator.free(self.departure_airport.name);
        allocator.free(self.departure_airport.city);
        allocator.free(self.departure_airport.country);

        if (self.departure_gate.terminal) |terminal| allocator.free(terminal);
        if (self.departure_gate.gate) |gate| allocator.free(gate);
        if (self.departure_gate.baggage_claim) |baggage_claim| allocator.free(baggage_claim);

        allocator.free(self.arrival_airport.iata_code);
        allocator.free(self.arrival_airport.name);
        allocator.free(self.arrival_airport.city);
        allocator.free(self.arrival_airport.country);

        if (self.arrival_gate.terminal) |terminal| allocator.free(terminal);
        if (self.arrival_gate.gate) |gate| allocator.free(gate);
        if (self.arrival_gate.baggage_claim) |baggage_claim| allocator.free(baggage_claim);
    }
};

pub const FlightStatusClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    http_client: httpx.Client,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) FlightStatusClient {
        const http_client = httpx.Client.initWithConfig(allocator, .{
            .base_url = "https://airlabs.co/api/v9",
        });
        return FlightStatusClient{
            .allocator = allocator,
            .api_key = api_key,
            .http_client = http_client,
        };
    }

    pub fn checkStatus(self: *FlightStatusClient, flight_number: []const u8) !FlightStatus {
        var query_params = std.StringHashMap([]const u8).init(self.allocator);
        defer query_params.deinit();

        try query_params.put("api_key", self.api_key);
        try query_params.put("flight_iata", flight_number);

        const url = try queryParamsToURL(self.allocator, "/flight", query_params);
        defer self.allocator.free(url);

        var resp = self.http_client.get(url, .{}) catch |err| switch (err) {
            httpx.HttpError.ConnectionFailed => {
                std.debug.print("Connection failed when trying to check flight status\n", .{});
                return Errors.ConnectionFailed;
            },
            else => {
                std.debug.print("Error checking flight status: {s}\n", .{@errorName(err)});
                return Errors.InvalidResponse;
            },
        };
        defer resp.deinit();

        if (!resp.status.isSuccess()) {
            std.debug.print("Failed to check flight status, HTTP status: {d}\n", .{resp.status.code});
            return Errors.UnexpectedStatusCode;
        }

        if (resp.body == null) {
            std.debug.print("Received empty response when checking flight status\n", .{});
            return Errors.InvalidResponse;
        }

        return parseFlightStatus(self.allocator, resp.body.?, flight_number);
    }

    pub fn deinit(self: *FlightStatusClient) void {
        self.http_client.deinit();
    }
};

fn queryParamsToURL(
    allocator: std.mem.Allocator,
    base: []const u8,
    params: std.StringHashMap([]const u8),
) ![]const u8 {
    var url = try std.ArrayList(u8).initCapacity(allocator, base.len);
    errdefer url.deinit(allocator);

    try url.appendSlice(allocator, base);
    if (params.count() > 0) {
        try url.append(allocator, '?');
        var first = true;
        var it = params.iterator();
        while (it.next()) |entry| {
            if (!first) {
                try url.append(allocator, '&');
            }
            first = false;
            try url.print(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
    return url.toOwnedSlice(allocator);
}

const ApiFlightResponse = struct {
    response: ?ApiFlight = null,
};

const ApiFlight = struct {
    flight_iata: ?[]const u8 = null,
    airline_name: ?[]const u8 = null,
    flight_number: ?[]const u8 = null,
    status: ?[]const u8 = null,

    dep_delayed: ?f64 = null,
    arr_delayed: ?f64 = null,

    dep_iata: ?[]const u8 = null,
    dep_name: ?[]const u8 = null,
    dep_city: ?[]const u8 = null,
    dep_country: ?[]const u8 = null,
    dep_terminal: ?[]const u8 = null,
    dep_gate: ?[]const u8 = null,
    dep_baggage: ?[]const u8 = null,

    arr_iata: ?[]const u8 = null,
    arr_name: ?[]const u8 = null,
    arr_city: ?[]const u8 = null,
    arr_country: ?[]const u8 = null,
    arr_terminal: ?[]const u8 = null,
    arr_gate: ?[]const u8 = null,
    arr_baggage: ?[]const u8 = null,

    alt: ?f64 = null,
    speed: ?f64 = null,
    lat: ?f64 = null,
    lng: ?f64 = null,
    dir: ?f64 = null,

    dep_time: ?[]const u8 = null, // Scheduled departure time, airport local time
    dep_time_ts: ?i64 = null, // Scheduled departure time, UNIX timestamp
    dep_actual: ?[]const u8 = null, // Actual departure time, airport local time
    dep_actual_ts: ?i64 = null, // Actual departure time, UNIX timestamp

    arr_time: ?[]const u8 = null, // Scheduled arrival time, airport local time
    arr_time_ts: ?i64 = null, // Scheduled arrival time, UNIX timestamp
    arr_actual: ?[]const u8 = null, // Actual arrival time, airport local time
    arr_actual_ts: ?i64 = null, // Actual arrival time, UNIX timestamp

    percent: ?i64 = null, // Percentage of flight completed
    duration: ?usize = null, // Total flight duration in minutes
    eta: ?usize = null, // Remaining flight duration in minutes
};

fn parseFlightStatus(allocator: std.mem.Allocator, body: []const u8, fallback_flight_number: []const u8) !FlightStatus {
    var parsed = std.json.parseFromSlice(ApiFlightResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return Errors.InvalidResponse;
    };
    defer parsed.deinit();

    const flight = parsed.value.response orelse return Errors.InvalidResponse;
    return toFlightStatus(allocator, flight, fallback_flight_number);
}

fn toFlightStatus(allocator: std.mem.Allocator, api_flight: ApiFlight, fallback_flight_number: []const u8) !FlightStatus {
    const departed_status = DepartedStatus.fromResponse(api_flight.status orelse "");
    const departure_delay_duration = minutesToDuration(api_flight.dep_delayed);
    const arrival_delay_duration = minutesToDuration(api_flight.arr_delayed);

    const flight_iata = try dupeOrDefault(allocator, api_flight.flight_iata, fallback_flight_number);
    errdefer allocator.free(flight_iata);

    const airline_name = try dupeOrDefault(allocator, api_flight.airline_name, "Unknown");
    errdefer allocator.free(airline_name);

    const flight_number = try dupeOrDefault(allocator, api_flight.flight_number, fallback_flight_number);
    errdefer allocator.free(flight_number);

    const departure_iata = try dupeOrDefault(allocator, api_flight.dep_iata, "Unknown");
    errdefer allocator.free(departure_iata);

    const departure_name = try dupeOrDefault(allocator, api_flight.dep_name, "Unknown");
    errdefer allocator.free(departure_name);

    const departure_city = try dupeOrDefault(allocator, api_flight.dep_city, "Unknown");
    errdefer allocator.free(departure_city);

    const departure_country = try dupeOrDefault(allocator, api_flight.dep_country, "Unknown");
    errdefer allocator.free(departure_country);

    const dep_terminal = try dupeOptional(allocator, api_flight.dep_terminal);
    errdefer if (dep_terminal) |terminal| allocator.free(terminal);

    const dep_gate = try dupeOptional(allocator, api_flight.dep_gate);
    errdefer if (dep_gate) |gate| allocator.free(gate);

    const dep_baggage = try dupeOptional(allocator, api_flight.dep_baggage);
    errdefer if (dep_baggage) |baggage| allocator.free(baggage);

    const arrival_iata = try dupeOrDefault(allocator, api_flight.arr_iata, "Unknown");
    errdefer allocator.free(arrival_iata);

    const arrival_name = try dupeOrDefault(allocator, api_flight.arr_name, "Unknown");
    errdefer allocator.free(arrival_name);

    const arrival_city = try dupeOrDefault(allocator, api_flight.arr_city, "Unknown");
    errdefer allocator.free(arrival_city);

    const arrival_country = try dupeOrDefault(allocator, api_flight.arr_country, "Unknown");
    errdefer allocator.free(arrival_country);

    const arr_terminal = try dupeOptional(allocator, api_flight.arr_terminal);
    errdefer if (arr_terminal) |terminal| allocator.free(terminal);

    const arr_gate = try dupeOptional(allocator, api_flight.arr_gate);
    errdefer if (arr_gate) |gate| allocator.free(gate);

    const arr_baggage = try dupeOptional(allocator, api_flight.arr_baggage);
    errdefer if (arr_baggage) |baggage| allocator.free(baggage);

    const total_duration = if (api_flight.duration) |d| zeit.Duration{ .minutes = d } else null;
    const remaining_duration = if (api_flight.eta) |d| zeit.Duration{ .minutes = d } else null;

    return FlightStatus{
        .flight_iata = flight_iata,
        .airline_name = airline_name,
        .flight_number = flight_number,
        .delay_status = DelayStatus.fromResponse(arrival_delay_duration, departed_status),
        .delay_info = .{
            .departure_delay_minutes = departure_delay_duration,
            .arrival_delay_minutes = arrival_delay_duration,
        },
        .departed_status = departed_status,
        .departure_airport = .{
            .iata_code = departure_iata,
            .name = departure_name,
            .city = departure_city,
            .country = departure_country,
        },
        .departure_gate = .{
            .terminal = dep_terminal,
            .gate = dep_gate,
            .baggage_claim = dep_baggage,
        },
        .arrival_airport = .{
            .iata_code = arrival_iata,
            .name = arrival_name,
            .city = arrival_city,
            .country = arrival_country,
        },
        .arrival_gate = .{
            .terminal = arr_terminal,
            .gate = arr_gate,
            .baggage_claim = arr_baggage,
        },
        .in_flight_params = .{
            .altitude = metersToFeet(api_flight.alt),
            .speed = kmhToMph(api_flight.speed),
            .latitude = api_flight.lat,
            .longitude = api_flight.lng,
            .heading = api_flight.dir,
        },
        .departure_time = .{
            .scheduled_local = if (api_flight.dep_time) |dep_time_str| try zeit.instant(.{ .source = .{ .iso8601 = dep_time_str } }) else null,
            .scheduled_utc = if (api_flight.dep_time_ts) |ts| try zeit.instant(.{ .source = .{ .unix_timestamp = ts } }) else null,
            .actual_local = if (api_flight.dep_actual) |dep_actual_str| try zeit.instant(.{ .source = .{ .iso8601 = dep_actual_str } }) else null,
            .actual_utc = if (api_flight.dep_actual_ts) |ts| try zeit.instant(.{ .source = .{ .unix_timestamp = ts } }) else null,
        },
        .arrival_time = .{
            .scheduled_local = if (api_flight.arr_time) |arr_time_str| try zeit.instant(.{ .source = .{ .iso8601 = arr_time_str } }) else null,
            .scheduled_utc = if (api_flight.arr_time_ts) |ts| try zeit.instant(.{ .source = .{ .unix_timestamp = ts } }) else null,
            .actual_local = if (api_flight.arr_actual) |arr_actual_str| try zeit.instant(.{ .source = .{ .iso8601 = arr_actual_str } }) else null,
            .actual_utc = if (api_flight.arr_actual_ts) |ts| try zeit.instant(.{ .source = .{ .unix_timestamp = ts } }) else null,
        },
        .percentage_completed = api_flight.percent,
        .total_duration = total_duration,
        .remaining_duration = remaining_duration,
    };
}

fn minutesToDuration(value: ?f64) ?zeit.Duration {
    const raw = value orelse return null;
    if (raw < 0) {
        return null;
    }

    const rounded = std.math.round(raw);
    if (rounded > @as(f64, @floatFromInt(std.math.maxInt(usize)))) {
        return null;
    }

    return .{ .minutes = @as(usize, @intFromFloat(rounded)) };
}

fn metersToFeet(value: ?f64) ?f64 {
    const meters = value orelse return null;
    return meters * 3.280839895;
}

fn kmhToMph(value: ?f64) ?f64 {
    const kmh = value orelse return null;
    return kmh * 0.621371192;
}

fn dupeOrDefault(allocator: std.mem.Allocator, value: ?[]const u8, fallback: []const u8) ![]const u8 {
    return allocator.dupe(u8, value orelse fallback);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const existing = value orelse return null;
    const duplicated = try allocator.dupe(u8, existing);
    return duplicated;
}
