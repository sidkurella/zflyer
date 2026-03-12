# Concurrency API

The concurrency module provides tools for parallel execution and task management.

## Functions

These functions are available under `httpx.concurrency.*` and also as top-level helpers:

- `httpx.all`
- `httpx.any`
- `httpx.race`
- `httpx.allSettled`

### `all`

Executes multiple requests in parallel and waits for all to complete.

```zig
pub fn all(allocator: Allocator, client: *Client, specs: []const RequestSpec) ![]RequestResult
```

### `allSettled`

Executes multiple requests in parallel and returns a result for **each** request.

- Successful requests are returned as `RequestResult.success`.
- Failed requests are returned as `RequestResult.err`.

```zig
pub fn allSettled(allocator: Allocator, client: *Client, specs: []const RequestSpec) ![]RequestResult
```

### `any`

Executes multiple requests and returns the first **successful (2xx)** response.

```zig
pub fn any(allocator: Allocator, client: *Client, specs: []const RequestSpec) !?Response
```

### `race`

Executes multiple requests and returns the result of the first one to complete (success or error).

```zig
pub fn race(allocator: Allocator, client: *Client, specs: []const RequestSpec) !RequestResult
```

## Executor

A thread-pool based task executor.

```zig
const httpx = @import("httpx");
var executor = httpx.Executor.init(allocator);
defer executor.deinit();
```

### Configuration

```zig
pub const ExecutorConfig = struct {
    num_threads: u32 = 0,       // 0 = auto-detect
    task_queue_size: usize = 1024,
    idle_timeout_ms: u64 = 60_000,
};
```

### Methods

#### `execute`

Submits a function for execution.

```zig
pub fn execute(self: *Self, func: TaskFn, context: ?*anyopaque) !void
```

#### `submit`

Submits a `Task` struct.

```zig
pub fn submit(self: *Self, task: Task) !void
```

#### `runAll`

Runs all pending tasks synchronously (useful for testing).

```zig
pub fn runAll(self: *Self) void
```

## Types

### `Task`

represents a unit of work.

```zig
pub const Task = struct {
    func: TaskFn,
    context: ?*anyopaque = null,
    priority: u8 = 0,
};
```

### `TaskFn`

```zig
pub const TaskFn = *const fn (?*anyopaque) void;
```

### `RequestSpec`

Specification for a request in a batch operation.

```zig
pub const RequestSpec = struct {
    method: Method = .GET,
    url: []const u8,
    body: ?[]const u8 = null,
    headers: ?[]const [2][]const u8 = null,
};
```

### `RequestResult`

Result wrapper for parallel requests.

```zig
pub const RequestResult = union(enum) {
    success: Response,
    err: anyerror,
    
    // Helper methods
    pub fn isSuccess(self: RequestResult) bool
    pub fn getResponse(self: *RequestResult) ?*Response
    pub fn deinit(self: *RequestResult) void
};
```
