const std = @import("std");
const httpx = @import("../deps/httpx/src/httpx.zig");

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

    pub fn checkStatus(self: *FlightStatusClient, flight_number: []const u8) !void {
        // Placeholder for actual API call to check flight status
        std.debug.print("Checking status for flight: {s}\n", .{flight_number});

        var query_params = std.StringHashMap([]const u8).init(self.allocator);
        defer query_params.deinit();

        try query_params.put("api_key", self.api_key);
        try query_params.put("flight_iata", flight_number);

        const url = try queryParamsToURL(self.allocator, "/flight", query_params);
        defer self.allocator.free(url);

        var resp = self.http_client.get(url, .{}) catch |err| switch (err) {
            httpx.HttpError.ConnectionFailed => {
                std.debug.print("Connection failed when trying to check flight status\n", .{});
                return;
            },
            else => {
                std.debug.print("Error checking flight status: {s}\n", .{@errorName(err)});
                return;
            },
        };
        defer resp.deinit();

        if (!resp.status.isSuccess()) {
            std.debug.print("Failed to check flight status, HTTP status: {d}\n", .{resp.status.code});
            return;
        }
        std.debug.print("Received response: {s}\n", .{resp.body orelse ""});
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
            try url.appendSlice(allocator, entry.key_ptr.*);
            try url.append(allocator, '=');
            try url.appendSlice(allocator, entry.value_ptr.*);
        }
    }
    return url.toOwnedSlice(allocator);
}
