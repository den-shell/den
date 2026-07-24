const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

/// Drop-in replacement for the removed std.Thread.Mutex.
/// Uses pthread_mutex on POSIX platforms and a spinlock fallback elsewhere.
const use_pthreads = builtin.os.tag != .windows and
    (builtin.link_libc or builtin.os.tag == .macos or builtin.os.tag == .linux);

pub const Mutex = if (use_pthreads)
    PthreadMutex
else
    SpinMutex;

const PthreadMutex = struct {
    inner: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PthreadMutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *PthreadMutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }

    pub fn tryLock(self: *PthreadMutex) bool {
        return c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

const SpinMutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }

    pub fn tryLock(self: *SpinMutex) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }
};

/// Drop-in replacement for the removed std.Thread.Condition.
/// Uses pthread_cond on POSIX platforms.
pub const Condition = if (use_pthreads) PthreadCondition else SpinCondition;

const PthreadCondition = struct {
    inner: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        _ = c.pthread_cond_signal(&self.inner);
    }

    pub fn broadcast(self: *Condition) void {
        _ = c.pthread_cond_broadcast(&self.inner);
    }

    /// Timed wait: blocks until signaled or `timeout_ns` nanoseconds elapse.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.REALTIME, &ts);
        const nsec_total = @as(u64, @intCast(ts.nsec)) + timeout_ns;
        ts.sec += @intCast(nsec_total / 1_000_000_000);
        ts.nsec = @intCast(nsec_total % 1_000_000_000);
        const ret = c.pthread_cond_timedwait(&self.inner, &mutex.inner, &ts);
        if (ret == .TIMEDOUT) return error.Timeout;
    }
};

const SpinCondition = struct {
    epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn wait(self: *SpinCondition, mutex: *Mutex) void {
        const observed = self.epoch.load(.acquire);
        mutex.unlock();
        defer mutex.lock();
        while (self.epoch.load(.acquire) == observed) std.atomic.spinLoopHint();
    }

    pub fn signal(self: *SpinCondition) void {
        _ = self.epoch.fetchAdd(1, .release);
    }

    pub fn broadcast(self: *SpinCondition) void {
        _ = self.epoch.fetchAdd(1, .release);
    }

    pub fn timedWait(self: *SpinCondition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const observed = self.epoch.load(.acquire);
        const started = Instant.now() catch return error.Timeout;
        mutex.unlock();
        defer mutex.lock();

        while (self.epoch.load(.acquire) == observed) {
            const now = Instant.now() catch return error.Timeout;
            if (now.since(started) >= timeout_ns) return error.Timeout;
            std.atomic.spinLoopHint();
        }
    }
};

/// Drop-in replacement for the removed std.time.Instant.
/// Uses clock_gettime(MONOTONIC) on POSIX, or a fallback.
pub const Instant = struct {
    timestamp: if (builtin.os.tag == .windows) u64 else c.timespec,

    pub fn now() error{Unsupported}!Instant {
        if (comptime builtin.os.tag == .windows) {
            var file_time: std.os.windows.FILETIME = undefined;
            const getSystemTimeAsFileTime = struct {
                extern "kernel32" fn GetSystemTimeAsFileTime(
                    file_time: *std.os.windows.FILETIME,
                ) callconv(std.builtin.CallingConvention.winapi) void;
            }.GetSystemTimeAsFileTime;
            getSystemTimeAsFileTime(&file_time);
            return .{ .timestamp = (@as(u64, file_time.dwHighDateTime) << 32) | file_time.dwLowDateTime };
        }

        var ts: c.timespec = undefined;
        const ret = c.clock_gettime(.MONOTONIC, &ts);
        if (ret != 0) return error.Unsupported;
        return .{ .timestamp = ts };
    }

    /// Returns elapsed nanoseconds from `earlier` to `self`.
    pub fn since(self: Instant, earlier: Instant) u64 {
        if (comptime builtin.os.tag == .windows) {
            return (self.timestamp -| earlier.timestamp) * 100;
        }

        const sec_diff = self.timestamp.sec - earlier.timestamp.sec;
        const nsec_diff = self.timestamp.nsec - earlier.timestamp.nsec;
        const total_ns = @as(i128, sec_diff) * 1_000_000_000 + @as(i128, nsec_diff);
        if (total_ns < 0) return 0;
        return @intCast(@as(u128, @bitCast(total_ns)));
    }
};
