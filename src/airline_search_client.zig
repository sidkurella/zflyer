const std = @import("std");
const httpx = @import("../deps/httpx/src/httpx.zig");
const hutils = @import("http_utils.zig");

pub const Errors = error{
    ConnectionFailed,
    InvalidResponse,
    UnexpectedStatusCode,
};

pub const Airline = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    iata_code: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, iata_code: []const u8) !Airline {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .iata_code = try allocator.dupe(u8, iata_code),
        };
    }

    pub fn deinit(self: *Airline) void {
        self.allocator.free(self.name);
        self.allocator.free(self.iata_code);
    }
};

pub const AirlineSearchResult = struct {
    allocator: std.mem.Allocator,
    airlines: []Airline,

    pub fn init(allocator: std.mem.Allocator, airlines: []Airline) AirlineSearchResult {
        return .{ .allocator = allocator, .airlines = airlines };
    }

    pub fn deinit(self: *AirlineSearchResult) void {
        for (self.airlines) |*airline| {
            airline.deinit();
        }
        self.allocator.free(self.airlines);
    }
};

pub const AirlineSearchClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    http_client: httpx.Client,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) AirlineSearchClient {
        const http_client = httpx.Client.initWithConfig(allocator, .{
            .base_url = "https://airlabs.co/api/v9",
        });

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .http_client = http_client,
        };
    }

    pub fn deinit(self: *AirlineSearchClient) void {
        self.http_client.deinit();
    }

    pub fn searchAirlines(self: *AirlineSearchClient, name: []const u8) !AirlineSearchResult {
        var params = std.StringHashMap([]const u8).init(self.allocator);
        defer params.deinit();

        try params.put("api_key", self.api_key);
        try params.put("name", name);

        const url = try hutils.queryParamsToURL(self.allocator, "/airlines", params);
        defer self.allocator.free(url);

        var response = self.http_client.get(url, .{}) catch |err| switch (err) {
            httpx.HttpError.ConnectionFailed => return Errors.ConnectionFailed,
            else => return Errors.InvalidResponse,
        };
        defer response.deinit();

        if (response.status.code == httpx.status.StatusCode.NOT_FOUND) {
            return AirlineSearchResult.init(self.allocator, &.{});
        }

        if (!response.status.isSuccess()) {
            return Errors.UnexpectedStatusCode;
        }

        const body = response.body orelse return Errors.InvalidResponse;
        var parsed = std.json.parseFromSlice(ApiResponse, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return Errors.InvalidResponse;
        };
        defer parsed.deinit();

        var airlines = std.array_list.Managed(Airline).init(self.allocator);
        errdefer {
            for (airlines.items) |*airline| {
                airline.deinit();
            }
            airlines.deinit();
        }

        for (parsed.value.response) |api_airline| {
            const airline_name = api_airline.name orelse continue;
            const iata = api_airline.iata_code orelse continue;
            if (iata.len == 0) continue;

            try airlines.append(try Airline.init(self.allocator, airline_name, iata));
        }

        return AirlineSearchResult.init(self.allocator, try airlines.toOwnedSlice());
    }
};

const ApiAirline = struct {
    name: ?[]const u8 = null,
    iata_code: ?[]const u8 = null,
};

const ApiResponse = struct {
    response: []ApiAirline = &.{},
};
