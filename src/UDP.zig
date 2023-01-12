/// UDP client and server.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub const UDP = @This();

const std = @import("std");
const assert = std.debug.assert;
const os = std.os;
const xev = @import("main.zig");

socket: os.socket_t,

/// UDP requires some extra state to perform operations. The state is
/// opaque. This isn't part of xev.Completion because it is relatively
/// large and would force ALL operations (not just UDP) to have a relatively
/// large structure size and we didn't want to pay that cost.
pub const State = struct {
    userdata: ?*anyopaque = null,
    op: union {
        recv: struct {
            buf: xev.ReadBuffer,
            addr: ?*std.net.Address,
            msghdr: std.os.msghdr,
            iov: [1]std.os.iovec,
        },

        send: struct {
            buf: xev.WriteBuffer,
            addr: std.net.Address,
            msghdr: std.os.msghdr_const,
            iov: [1]std.os.iovec_const,
        },
    },
};

/// Initialize a new UDP with the family from the given address. Only
/// the family is used, the actual address has no impact on the created
/// resource.
pub fn init(addr: std.net.Address) !UDP {
    return .{
        .socket = try os.socket(addr.any.family, os.SOCK.DGRAM, 0),
    };
}

/// Initialize a UDP socket from a file descriptor.
pub fn initFd(fd: os.socket_t) UDP {
    return .{
        .socket = fd,
    };
}

/// Bind the address to the socket.
pub fn bind(self: UDP, addr: std.net.Address) !void {
    try os.setsockopt(self.socket, os.SOL.SOCKET, os.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    try os.setsockopt(self.socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try os.bind(self.socket, &addr.any, addr.getOsSockLen());
}

/// Read from the socket. This performs a single read. The callback must
/// requeue the read if additional reads want to be performed. Additional
/// reads simultaneously can be queued by calling this multiple times. Note
/// that depending on the backend, the reads can happen out of order.
pub fn read(
    self: UDP,
    loop: *xev.Loop,
    c: *xev.Completion,
    s: *State,
    buf: xev.ReadBuffer,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        l: *xev.Loop,
        c: *xev.Completion,
        s: *State,
        s: UDP,
        b: xev.ReadBuffer,
        r: ReadError!usize,
    ) xev.CallbackAction,
) void {
    s.op = .{ .recv = undefined };
    s.* = .{
        .userdata = userdata,
        .op = .{
            .recv = .{
                .addr = null,
                .buf = buf,
                .msghdr = .{
                    .name = null,
                    .namelen = 0,
                    .iov = &s.op.recv.iov,
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                },
                .iov = undefined,
            },
        },
    };

    switch (s.op.recv.buf) {
        .slice => |v| {
            s.op.recv.iov[0] = .{
                .iov_base = v.ptr,
                .iov_len = v.len,
            };
        },

        .array => |*arr| {
            s.op.recv.iov[0] = .{
                .iov_base = arr,
                .iov_len = arr.len,
            };
        },
    }

    c.* = .{
        .op = .{
            .recvmsg = .{
                .fd = self.socket,
                .msghdr = &s.op.recv.msghdr,
            },
        },

        .userdata = s,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l_inner: *xev.Loop,
                c_inner: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const s_inner = @ptrCast(?*State, @alignCast(@alignOf(State), ud)).?;
                return @call(.always_inline, cb, .{
                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), s_inner.userdata)),
                    l_inner,
                    c_inner,
                    s_inner,
                    initFd(c_inner.op.recvmsg.fd),
                    s_inner.op.recv.buf,
                    if (r.recvmsg) |v| v else |err| err,
                });
            }
        }).callback,
    };

    loop.add(c);
}

/// Write to the socket. This performs a single write. Additional writes
/// can be queued by calling this multiple times. Note that depending on the
/// backend, writes can happen out of order.
pub fn write(
    self: UDP,
    loop: *xev.Loop,
    c: *xev.Completion,
    s: *State,
    addr: std.net.Address,
    buf: xev.WriteBuffer,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime cb: *const fn (
        ud: ?*Userdata,
        l: *xev.Loop,
        c: *xev.Completion,
        s: *State,
        s: UDP,
        b: xev.WriteBuffer,
        r: WriteError!usize,
    ) xev.CallbackAction,
) void {
    // Set the active field for runtime safety
    s.op = .{ .send = undefined };
    s.* = .{
        .userdata = userdata,
        .op = .{
            .send = .{
                .addr = addr,
                .buf = buf,
                .msghdr = .{
                    .name = &s.op.send.addr.any,
                    .namelen = addr.getOsSockLen(),
                    .iov = &s.op.send.iov,
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                },
                .iov = undefined,
            },
        },
    };

    switch (s.op.send.buf) {
        .slice => |v| {
            s.op.send.iov[0] = .{
                .iov_base = v.ptr,
                .iov_len = v.len,
            };
        },

        .array => |*arr| {
            s.op.send.iov[0] = .{
                .iov_base = &arr.array,
                .iov_len = arr.len,
            };
        },
    }

    c.* = .{
        .op = .{
            .sendmsg = .{
                .fd = self.socket,
                .msghdr = &s.op.send.msghdr,
            },
        },

        .userdata = s,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l_inner: *xev.Loop,
                c_inner: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const s_inner = @ptrCast(?*State, @alignCast(@alignOf(State), ud)).?;
                return @call(.always_inline, cb, .{
                    @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), s_inner.userdata)),
                    l_inner,
                    c_inner,
                    s_inner,
                    initFd(c_inner.op.sendmsg.fd),
                    s_inner.op.send.buf,
                    if (r.sendmsg) |v| v else |err| err,
                });
            }
        }).callback,
    };

    loop.add(c);
}

pub const ReadError = xev.Loop.ReadError;
pub const WriteError = xev.Loop.WriteError;

test "UDP: read/write" {
    const testing = std.testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 3131);
    const server = try UDP.init(address);
    const client = try UDP.init(address);

    // Bind and recv
    try server.bind(address);
    var c_read: xev.Completion = undefined;
    var s_read: State = undefined;
    var recv_buf: [128]u8 = undefined;
    var recv_len: usize = 0;
    server.read(&loop, &c_read, &s_read, .{ .slice = &recv_buf }, usize, &recv_len, (struct {
        fn callback(
            ud: ?*usize,
            _: *xev.Loop,
            _: *xev.Completion,
            _: *State,
            _: UDP,
            _: xev.ReadBuffer,
            r: ReadError!usize,
        ) xev.CallbackAction {
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).callback);

    // Send
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    var c_write: xev.Completion = undefined;
    var s_write: State = undefined;
    client.write(&loop, &c_write, &s_write, address, .{ .slice = &send_buf }, void, null, (struct {
        fn callback(
            _: ?*void,
            _: *xev.Loop,
            _: *xev.Completion,
            _: *State,
            _: UDP,
            _: xev.WriteBuffer,
            r: WriteError!usize,
        ) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).callback);

    // Wait for the send/receive
    try loop.run(.until_done);
    try testing.expect(recv_len > 0);
    try testing.expectEqualSlices(u8, &send_buf, recv_buf[0..recv_len]);
}