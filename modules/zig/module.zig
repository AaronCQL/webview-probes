// Zig implementation of probe_module.h (written against Zig 0.14).
// No std allocator: malloc/free are plain undefined symbols resolved by the
// final link, so the static library needs no SDK / libc at build time.

extern fn malloc(n: usize) callconv(.c) ?[*]u8;
extern fn free(p: ?*anyopaque) callconv(.c) void;

const Callback = *const fn (?*anyopaque, u64, i64) callconv(.c) void;

const Host = extern struct {
    version: u32,
    ctx: ?*anyopaque,
    callback: Callback,
};

const Module = extern struct {
    version: u32,
    name: [*:0]const u8,
    add: *const fn (i64, i64) callconv(.c) i64,
    reverse: *const fn ([*]const u8, usize, *?[*]u8, *usize) callconv(.c) i32,
    free_bytes: *const fn (?[*]u8, usize) callconv(.c) void,
    counter_new: *const fn (i64) callconv(.c) ?*anyopaque,
    count_to: *const fn (?*anyopaque, i64, *const Host, u64) callconv(.c) i64,
    counter_free: *const fn (?*anyopaque) callconv(.c) void,
};

fn add(a: i64, b: i64) callconv(.c) i64 {
    return a +% b;
}

fn reverse(s: [*]const u8, len: usize, out: *?[*]u8, out_len: *usize) callconv(.c) i32 {
    const buf = malloc(if (len == 0) 1 else len) orelse return 1;
    var w: usize = 0;
    var end: usize = len;
    while (end > 0) {
        var start: usize = end - 1;
        while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
        var i: usize = start;
        while (i < end) : (i += 1) {
            buf[w] = s[i];
            w += 1;
        }
        end = start;
    }
    out.* = buf;
    out_len.* = w;
    return 0;
}

fn freeBytes(p: ?[*]u8, len: usize) callconv(.c) void {
    _ = len;
    free(@ptrCast(p));
}

fn counterNew(start: i64) callconv(.c) ?*anyopaque {
    const raw = malloc(@sizeOf(i64)) orelse return null;
    const c: *i64 = @ptrCast(@alignCast(raw));
    c.* = start;
    return @ptrCast(c);
}

fn countTo(counter: ?*anyopaque, target: i64, host: *const Host, cb_id: u64) callconv(.c) i64 {
    const c: *i64 = @ptrCast(@alignCast(counter.?));
    var calls: i64 = 0;
    while (c.* < target) {
        c.* += 1;
        host.callback(host.ctx, cb_id, c.*);
        calls += 1;
    }
    return calls;
}

fn counterFree(counter: ?*anyopaque) callconv(.c) void {
    free(counter);
}

const module = Module{
    .version = 1,
    .name = "zig",
    .add = &add,
    .reverse = &reverse,
    .free_bytes = &freeBytes,
    .counter_new = &counterNew,
    .count_to = &countTo,
    .counter_free = &counterFree,
};

export fn probe_zig_module() callconv(.c) *const Module {
    return &module;
}
