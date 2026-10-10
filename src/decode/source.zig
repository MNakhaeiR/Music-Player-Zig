//! Byte source for the decoders.
//!
//! Media files are memory-mapped rather than read into a buffer. That keeps
//! the decoders as pure functions over a `[]const u8` — trivially testable and
//! with free random access for seeking — while letting the operating system
//! page the file in on demand instead of committing the whole thing to RAM up
//! front. If mapping is unavailable, the file is read into a heap buffer and
//! everything above this layer behaves identically.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const Error = error{
    FileNotFound,
    AccessDenied,
    IsDirectory,
    ReadFailed,
    FileTooBig,
    OutOfMemory,
};

/// Refuse anything implausible for a music file, so a stray argument cannot
/// make the player try to map a 40 GB disk image.
pub const max_file_bytes: usize = 2 * 1024 * 1024 * 1024;

pub const Source = struct {
    /// The whole file, as bytes.
    bytes: []const u8,
    backing: Backing,

    pub const Backing = union(enum) {
        /// Memory-mapped, with the file handle kept open behind it.
        mapped: struct { map: File.MemoryMap, file: File, io: Io },
        /// Read into a heap buffer.
        owned: struct { buf: []u8, gpa: Allocator },
        /// Someone else's memory; we only borrow it.
        borrowed,
    };

    /// Wrap an existing buffer without taking ownership.
    pub fn fromBytes(bytes: []const u8) Source {
        return .{ .bytes = bytes, .backing = .borrowed };
    }

    pub fn open(gpa: Allocator, io: Io, path: []const u8) Error!Source {
        const dir: Dir = .cwd();
        const file = dir.openFile(io, path, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.IsDir => error.IsDirectory,
            else => error.ReadFailed,
        };

        const size = file.length(io) catch {
            file.close(io);
            return error.ReadFailed;
        };
        if (size == 0) {
            file.close(io);
            return error.ReadFailed;
        }
        if (size > max_file_bytes) {
            file.close(io);
            return error.FileTooBig;
        }
        const byte_len: usize = @intCast(size);

        // Preferred path: map it.
        if (File.MemoryMap.create(io, file, .{
            .len = byte_len,
            .protection = .{ .read = true },
            // Let the pages fault in as the decoder walks the file instead of
            // stalling on open.
            .populate = false,
        })) |map| {
            var m = map;
            return .{
                .bytes = m.memory[0..byte_len],
                .backing = .{ .mapped = .{ .map = m, .file = file, .io = io } },
            };
        } else |_| {}

        // Fallback: plain read.
        defer file.close(io);
        var reader_buf: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &reader_buf);
        const buf = file_reader.interface.allocRemaining(gpa, .limited(max_file_bytes)) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.StreamTooLong => error.FileTooBig,
                error.ReadFailed => error.ReadFailed,
            };
        };
        return .{
            .bytes = buf,
            .backing = .{ .owned = .{ .buf = buf, .gpa = gpa } },
        };
    }

    pub fn deinit(self: *Source) void {
        switch (self.backing) {
            .mapped => |*m| {
                m.map.destroy(m.io);
                m.file.close(m.io);
            },
            .owned => |o| o.gpa.free(o.buf),
            .borrowed => {},
        }
        self.* = undefined;
    }

    pub fn len(self: *const Source) usize {
        return self.bytes.len;
    }

    /// True when the bytes came from a mapping rather than a copy.
    pub fn isMapped(self: *const Source) bool {
        return self.backing == .mapped;
    }
};

const testing = std.testing;

test "borrowed sources do not own their memory" {
    const data = "hello";
    var src = Source.fromBytes(data);
    try testing.expectEqual(@as(usize, 5), src.len());
    try testing.expect(!src.isMapped());
    src.deinit(); // must not free the string literal
}
