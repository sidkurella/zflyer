# Router API

The `Router` provides route registration, parameterized paths, route groups, and middleware attachment for building expressive HTTP routes in `httpx.zig`.

## Overview

- Supports static routes (e.g., `/about`) and parameterized routes (e.g., `/users/:id`).
- Path parameters are captured and available via `ctx.param("name")`.
- Route groups allow shared prefixes and middleware.
- Middleware attached to a router or route executes in registration order.

## Route Registration

```zig
// Register routes on the main server router
try server.get("/", homePage);
try server.get("/users", listUsers);
try server.get("/users/:id", getUser);
try server.post("/users", createUser);
```

### Methods

| Method | Description |
|--------|-------------|
| `get(path, handler)` | Register a GET route |
| `post(path, handler)` | Register a POST route |
| `put(path, handler)` | Register a PUT route |
| `delete(path, handler)` | Register a DELETE route |
| `patch(path, handler)` | Register a PATCH route |
| `head(path, handler)` | Register a HEAD route |
| `options(path, handler)` | Register an OPTIONS route |
| `route(method, path, handler)` | Register for any HTTP method |

## Parameterized Paths

- Define parameters with `:name` (single segment) or `*name` (wildcard rest-of-path, optional).
- Parameters are provided as strings via `ctx.param("name")`.

```zig
try server.get("/files/*path", func(ctx: *httpx.Context) !httpx.Response {
    const requested = ctx.param("path") orelse "";
    return ctx.text(requested);
});
```

## Route Groups

Group routes under a common prefix and attach middleware to the group.

```zig
var api = server.router.group("/api/v1");
try api.use(httpx.middleware.auth());
try api.get("/users", listUsers);
try api.post("/users", createUser);
```

A group's middleware runs before the route's middleware and handler.

## Middleware Interaction

- Middleware may be registered globally (`server.use()`), per-group (`group.use()`), or per-route via helper wrappers.
- Middleware receive the same `*Context` passed to handlers and may short-circuit the chain by returning a response.

```zig
// Logging middleware
fn logger(next: httpx.Handler) httpx.Handler {
    return fn (ctx: *httpx.Context) anyerror!httpx.Response {
        std.debug.print("{} {}\n", .{ctx.request.method_name(), ctx.request.path});
        return next(ctx);
    };
}

try server.use(logger);
```

## Route Parameters & Validation

- `ctx.param("id")` returns `?[]const u8` for path parameters.
- Use helper validators in your handler to parse numeric IDs or validate formats.

```zig
fn getUser(ctx: *httpx.Context) !httpx.Response {
    const id_str = ctx.param("id") orelse return ctx.status(400).json(.{ .error = "missing id" });
    const id = std.fmt.parseInt(u32, id_str, 10) catch return ctx.status(400).json(.{ .error = "invalid id" });
    // ...
}
```

## Route Listing & Introspection

The router exposes helpers to list registered routes (useful for debugging and generating documentation).

```zig
for (server.router.listRoutes()) |r| {
    std.debug.print("{s} {s}\n", .{ r.method, r.path });
}
```

## Error Handling

- When no route matches, the router invokes the configured `NotFound` handler (`server.router.setNotFound()`).
- If a handler returns an error, the server's error handler is invoked if configured.

## Performance

- The router uses linear or trie-based matching depending on configuration and path complexity. Typical route lookup is O(k) where k is the number of path segments.

## See Also
- [Server API](/api/server) - Server integration and examples
- [Middleware API](/api/middleware) - Built-in middleware helpers

