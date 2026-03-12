# Concurrency & Async Tasks

`httpx.zig` provides robust primitives for concurrent execution and background task management.

## Parallel Requests

Execute multiple HTTP requests simultaneously using the helpful wrapper functions.

### `all`

Waits for **all** requests to complete. Returns a list of `RequestResult`.

```zig
const httpx = @import("httpx");

var builder = httpx.concurrency.BatchBuilder.init(allocator);
defer builder.deinit();

try builder.get("https://site-a.com");
try builder.post("https://site-b.com", body);

// Execute all
const results = try httpx.concurrency.all(allocator, &client, builder.requests.items);
defer allocator.free(results);

for (results) |res| {
    if (res.isSuccess()) {
        const response = res.success;
        // ...
        response.deinit();
    }
}
```

### `race`

Returns the result of the **first** request to complete (success or failure).

```zig
const result = try httpx.concurrency.race(allocator, &client, specs);
if (result.isSuccess()) {
    // ...
}
```

### `any`

Returns the **first successful** (2xx) response.

```zig
if (try httpx.concurrency.any(allocator, &client, specs)) |success_response| {
    // ...
}
```

## Task Executor

The `Executor` provides a thread pool for running background tasks, useful for offloading heavy work from the main request thread in a server environment.

### Initialization

```zig
// Create an executor (defaults to CPU count)
var exec = httpx.executor.Executor.init(allocator);

// Start the worker threads
try exec.start();
defer exec.deinit(); // Stops threads cleanup
```

### Submitting Tasks

Tasks are functions that accept an optional context pointer.

```zig
fn heavyWork(ctx: ?*anyopaque) void {
    const data: *MyData = @ptrCast(@alignCast(ctx.?));
    // Do heavy computation...
}

var data = MyData{ .val = 123 };
try exec.execute(heavyWork, &data);
```

### Configuration

```zig
const config = httpx.executor.ExecutorConfig{
    .num_threads = 4,
    .task_queue_size = 2048,
};
var exec = httpx.executor.Executor.initWithConfig(allocator, config);
```
