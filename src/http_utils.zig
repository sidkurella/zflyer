const std = @import("std");
const encoding = @import("../deps/httpx/src/util/encoding.zig");

pub fn queryParamsToURL(
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

            const encoded_key = try encoding.PercentEncoding.encode(allocator, entry.key_ptr.*);
            defer allocator.free(encoded_key);

            const encoded_value = try encoding.PercentEncoding.encode(allocator, entry.value_ptr.*);
            defer allocator.free(encoded_value);

            try url.print(allocator, "{s}={s}", .{ encoded_key, encoded_value });
        }
    }
    return url.toOwnedSlice(allocator);
}
