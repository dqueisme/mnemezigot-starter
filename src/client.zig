const std = @import("std");

// Imports from JS runtime bridge
extern fn js_update_text(ptr: [*]const u8, len: usize) void;
extern fn js_send_grpc(endpoint_ptr: [*]const u8, endpoint_len: usize, body_ptr: [*]const u8, body_len: usize) void;
extern fn js_log(ptr: [*]const u8, len: usize) void;

fn log(msg: []const u8) void {
    js_log(msg.ptr, msg.len);
}

// Memory allocator exports for WASM <-> JS boundary
export fn alloc(len: usize) ?[*]u8 {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

// Called on web page load
export fn init() void {
    const msg = "⚡ WASM Frontend Aktif & Terhubung ke Zig!";
    js_update_text(msg.ptr, msg.len);
    log("WebAssembly runtime initialized in browser!");
}

// Triggered when user clicks the WASM demo button
export fn on_wasm_click() void {
    log("[WASM Event] Button diklik di dalam WebAssembly!");
    const msg = "🚀 Logika WebAssembly Berjalan Mulus!";
    js_update_text(msg.ptr, msg.len);
}

// Triggered when user clicks gRPC-Web test
export fn on_grpc_click() void {
    log("[WASM Event] Menyiapkan frame gRPC-Web biner ke backend...");
    const endpoint = "/api/grpc";
    const dummy_frame = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00 };
    js_send_grpc(endpoint.ptr, endpoint.len, &dummy_frame, dummy_frame.len);
}

// Called when gRPC-Web response arrives
export fn on_grpc_response(ptr: [*]const u8, len: usize) void {
    if (len < 5) return;
    const data = ptr[0..len];
    const msg_len = (@as(u32, data[1]) << 24) | (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 8) | @as(u32, data[4]);

    if (5 + msg_len > len) return;
    const payload = data[5 .. 5 + msg_len];

    // Decode protobuf: Field 1 (string info): tag 0x0A
    var info_text: []const u8 = "gRPC Response OK";
    if (payload.len >= 2 and payload[0] == 0x0a) {
        const str_len: usize = payload[1];
        if (2 + str_len <= payload.len) {
            info_text = payload[2 .. 2 + str_len];
        }
    }

    var buf: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "📡 gRPC: {s}", .{info_text}) catch "gRPC OK";
    js_update_text(formatted.ptr, formatted.len);
    log("DOM berhasil diperbarui dari data gRPC biner via WASM!");
}
