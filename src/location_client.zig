const std = @import("std");
const httpx = @import("../deps/httpx/src/httpx.zig");
const hutils = @import("http_utils.zig");

pub const Errors = error{
    ConnectionFailed,
    InvalidResponse,
    UnexpectedStatusCode,
};

pub const LocationResult = struct {
    allocator: std.mem.Allocator, // We need the allocator to free the formatted address when we're done with it
    formatted_address: []const u8,

    pub fn init(allocator: std.mem.Allocator, formatted_address: []const u8) !LocationResult {
        return LocationResult{
            .formatted_address = try allocator.dupe(u8, formatted_address),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LocationResult) void {
        self.allocator.free(self.formatted_address);
    }
};

pub const LocationClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    http_client: httpx.Client,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) LocationClient {
        const http_client = httpx.Client.initWithConfig(allocator, .{
            .base_url = "https://api.geoapify.com/v1",
        });
        return LocationClient{
            .allocator = allocator,
            .api_key = api_key,
            .http_client = http_client,
        };
    }

    pub fn checkLocation(self: *LocationClient, lat: f64, lon: f64) !?LocationResult {
        var params = std.StringHashMap([]const u8).init(self.allocator);
        defer params.deinit();

        const lat_str = try std.fmt.allocPrint(self.allocator, "{d}", .{lat});
        defer self.allocator.free(lat_str);
        const lon_str = try std.fmt.allocPrint(self.allocator, "{d}", .{lon});
        defer self.allocator.free(lon_str);

        try params.put("lat", lat_str);
        try params.put("lon", lon_str);
        try params.put("apiKey", self.api_key);

        const url = try hutils.queryParamsToURL(self.allocator, "/geocode/reverse", params);
        defer self.allocator.free(url);

        var response = self.http_client.get(url, .{}) catch |err| switch (err) {
            httpx.HttpError.ConnectionFailed => {
                std.debug.print("Connection failed when trying to check location\n", .{});
                return Errors.ConnectionFailed;
            },
            else => {
                std.debug.print("Error checking location: {s}\n", .{@errorName(err)});
                return Errors.InvalidResponse;
            },
        };
        defer response.deinit();

        if (!response.status.isSuccess()) {
            return Errors.UnexpectedStatusCode;
        }

        if (response.body == null) {
            return Errors.InvalidResponse;
        }

        const parsed = std.json.parseFromSlice(ApiResponse, self.allocator, response.body.?, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("Error parsing location API response: {s}\n", .{@errorName(err)});
            return Errors.InvalidResponse;
        };
        defer parsed.deinit();

        const api_response = parsed.value;

        if (api_response.features.len == 0) {
            return null; // No results found for this location
        }

        const ret = try LocationResult.init(self.allocator, api_response.features[0].properties.formatted);
        return ret;
    }

    pub fn deinit(self: *LocationClient) void {
        self.http_client.deinit();
    }
};

const ApiResponse = struct {
    features: []const struct {
        properties: struct {
            formatted: []const u8, // We only care about the formatted address for now
        },
    },

    pub fn deinit(self: *ApiResponse, allocator: std.mem.Allocator) void {
        for (self.results) |result| {
            allocator.free(result.formatted);
        }
    }
};
