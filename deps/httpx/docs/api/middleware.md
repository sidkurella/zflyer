# Middleware API

Middleware functions sit between the incoming request and your route handlers. They are useful for logging, authentication, CORS, compression, and more.

## Usage

Global middleware is added using `server.use()`.

```zig
// Add logging middleware
try server.use(httpx.middleware.logger());

// Add CORS middleware
try server.use(httpx.middleware.cors(.{}));
```

## Built-in Middleware

`httpx.zig` comes with several built-in middlewares in `httpx.middleware`.

### `logger`

Logs request method, path, and detailed timing information to `std.debug`.

```zig
server.use(httpx.middleware.logger());
```

### `cors`

Handles Cross-Origin Resource Sharing (CORS) headers.

```zig
const corsConfig = httpx.middleware.CorsConfig{
    .allowed_origins = &[_][]const u8{"https://example.com"},
    .allowed_methods = &[_]Method{.GET, .POST},
};
server.use(httpx.middleware.cors(corsConfig));
```

### `rateLimit`

Basic in-memory rate limiting.

```zig
const config = httpx.middleware.RateLimitConfig{
    .max_requests = 100, // requests per window
    .window_ms = 60_000, // 1 minute
};
server.use(httpx.middleware.rateLimit(config));
```

### `basicAuth`

Implements HTTP Basic Authentication.

```zig
fn validateUser(user: []const u8, pass: []const u8) bool {
    // Check credentials...
    return true;
}

server.use(httpx.middleware.basicAuth("My Realm", validateUser));
```

### `compression`

Handles `Accept-Encoding` negotiation (implementation internal).

```zig
server.use(httpx.middleware.compression());
```

### `helmet`

Adds various security headers (like HSTS, X-Frame-Options, etc.).

```zig
server.use(httpx.middleware.helmet());
```

### `requestId`

Generates and attaches a unique `X-Request-ID` to every request.

```zig
server.use(httpx.middleware.requestId());
```

## Creating Custom Middleware

A middleware is a struct with a `handler` function.

```zig
const httpx = @import("httpx");

pub fn myMiddleware() httpx.Middleware {
    return .{
        .name = "my_middleware",
        .handler = struct {
            fn handler(ctx: *httpx.Context, next: httpx.server.middleware.Next) anyerror!httpx.Response {
                // Pre-processing
                std.debug.print("Before request\n", .{});

                // Call next middleware
                const response = try next(ctx);

                // Post-processing
                std.debug.print("After request\n", .{});

                return response;
            }
        }.handler,
    };
}
```
