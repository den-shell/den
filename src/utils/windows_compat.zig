const std = @import("std");
const windows = std.os.windows;

pub const STD_INPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: windows.DWORD = @bitCast(@as(i32, -12));
pub const WAIT_OBJECT_0: windows.DWORD = 0;
pub const WAIT_TIMEOUT: windows.DWORD = 258;

pub const COORD = extern struct {
    X: i16,
    Y: i16,
};

pub const SMALL_RECT = extern struct {
    Left: i16,
    Top: i16,
    Right: i16,
    Bottom: i16,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

const readFile = struct {
    extern "kernel32" fn ReadFile(
        handle: windows.HANDLE,
        buffer: [*]u8,
        bytes_to_read: windows.DWORD,
        bytes_read: *windows.DWORD,
        overlapped: ?*anyopaque,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
}.ReadFile;

const writeFile = struct {
    extern "kernel32" fn WriteFile(
        handle: windows.HANDLE,
        buffer: [*]const u8,
        bytes_to_write: windows.DWORD,
        bytes_written: *windows.DWORD,
        overlapped: ?*anyopaque,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
}.WriteFile;

const kernel32 = struct {
    extern "kernel32" fn CreatePipe(
        read_pipe: *windows.HANDLE,
        write_pipe: *windows.HANDLE,
        pipe_attributes: ?*windows.SECURITY_ATTRIBUTES,
        size: windows.DWORD,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    extern "kernel32" fn DuplicateHandle(
        source_process: windows.HANDLE,
        source_handle: windows.HANDLE,
        target_process: windows.HANDLE,
        target_handle: *windows.HANDLE,
        desired_access: windows.DWORD,
        inherit_handle: windows.BOOL,
        options: windows.DWORD,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        console_output: windows.HANDLE,
        info: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    extern "kernel32" fn GetConsoleMode(
        console: windows.HANDLE,
        mode: *windows.DWORD,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleMode(
        console: windows.HANDLE,
        mode: windows.DWORD,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(std.builtin.CallingConvention.winapi) windows.HANDLE;
    extern "kernel32" fn GetExitCodeProcess(
        process: windows.HANDLE,
        exit_code: *windows.DWORD,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    extern "kernel32" fn TerminateProcess(
        process: windows.HANDLE,
        exit_code: windows.UINT,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(
        handle: windows.HANDLE,
        milliseconds: windows.DWORD,
    ) callconv(std.builtin.CallingConvention.winapi) windows.DWORD;
};

pub fn ReadFile(
    handle: windows.HANDLE,
    buffer: [*]u8,
    bytes_to_read: windows.DWORD,
    bytes_read: *windows.DWORD,
    overlapped: ?*anyopaque,
) c_int {
    return @intFromBool(readFile(handle, buffer, bytes_to_read, bytes_read, overlapped).toBool());
}

pub fn WriteFile(
    handle: windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: windows.DWORD,
    bytes_written: *windows.DWORD,
    overlapped: ?*anyopaque,
) c_int {
    return @intFromBool(writeFile(handle, buffer, bytes_to_write, bytes_written, overlapped).toBool());
}

pub fn GetStdHandle(id: windows.DWORD) ?windows.HANDLE {
    const params = windows.peb().ProcessParameters;
    return switch (id) {
        STD_INPUT_HANDLE => params.hStdInput,
        STD_OUTPUT_HANDLE => params.hStdOutput,
        STD_ERROR_HANDLE => params.hStdError,
        else => null,
    };
}

pub fn CreatePipe(
    read_pipe: *windows.HANDLE,
    write_pipe: *windows.HANDLE,
    pipe_attributes: ?*windows.SECURITY_ATTRIBUTES,
    size: windows.DWORD,
) c_int {
    return @intFromBool(kernel32.CreatePipe(read_pipe, write_pipe, pipe_attributes, size).toBool());
}

pub fn DuplicateHandle(
    source_process: windows.HANDLE,
    source_handle: windows.HANDLE,
    target_process: windows.HANDLE,
    target_handle: *windows.HANDLE,
    desired_access: windows.DWORD,
    inherit_handle: bool,
    options: windows.DWORD,
) c_int {
    return @intFromBool(kernel32.DuplicateHandle(
        source_process,
        source_handle,
        target_process,
        target_handle,
        desired_access,
        @enumFromInt(@intFromBool(inherit_handle)),
        options,
    ).toBool());
}

pub fn GetConsoleScreenBufferInfo(
    console_output: windows.HANDLE,
    info: *CONSOLE_SCREEN_BUFFER_INFO,
) c_int {
    return @intFromBool(kernel32.GetConsoleScreenBufferInfo(console_output, info).toBool());
}

pub fn GetConsoleMode(console: windows.HANDLE, mode: *windows.DWORD) c_int {
    return @intFromBool(kernel32.GetConsoleMode(console, mode).toBool());
}

pub fn SetConsoleMode(console: windows.HANDLE, mode: windows.DWORD) c_int {
    return @intFromBool(kernel32.SetConsoleMode(console, mode).toBool());
}

pub fn GetCurrentProcess() windows.HANDLE {
    return kernel32.GetCurrentProcess();
}

pub fn GetExitCodeProcess(process: windows.HANDLE, exit_code: *windows.DWORD) c_int {
    return @intFromBool(kernel32.GetExitCodeProcess(process, exit_code).toBool());
}

pub fn TerminateProcess(process: windows.HANDLE, exit_code: windows.UINT) c_int {
    return @intFromBool(kernel32.TerminateProcess(process, exit_code).toBool());
}

pub fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) windows.DWORD {
    return kernel32.WaitForSingleObject(handle, milliseconds);
}
