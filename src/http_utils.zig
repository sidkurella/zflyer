const std = @import("std");

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
            try url.print(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
    return url.toOwnedSlice(allocator);
}
