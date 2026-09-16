const std = @import("std");
const client = @import("mnemezigot_client");

// Memory allocator exports for JS runtime
export fn alloc(len: usize) ?[*]u8 {
    return client.wasmAlloc(len);
}

export fn free(ptr: [*]u8, len: usize) void {
    client.wasmFree(ptr, len);
}

// Called on web page load
export fn init() void {
    client.updateText("⚡ WASM Frontend Aktif & Terhubung ke Zig!");
    client.log("WebAssembly runtime initialized in browser!");
}

// Triggered when user clicks the WASM demo button
export fn on_wasm_click() void {
    client.log("[WASM Event] Button diklik di dalam WebAssembly!");
    client.updateText("🚀 Logika WebAssembly Berjalan Mulus!");
}

// Triggered when user clicks gRPC-Web test
export fn on_grpc_click() void {
    client.log("[WASM Event] Menyiapkan frame gRPC-Web biner ke backend...");
    const dummy_frame = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00 };
    client.sendGrpc("/api/grpc", &dummy_frame);
}

// Called when gRPC-Web response arrives
export fn on_grpc_response(ptr: [*]const u8, len: usize) void {
    const payload = client.decodeGrpcFrame(ptr[0..len]) orelse return;
    const info_text = client.decodeProtobufString(payload) orelse "gRPC Response OK";

    var buf: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "📡 gRPC: {s}", .{info_text}) catch "gRPC OK";
    client.updateText(formatted);
    client.log("DOM berhasil diperbarui dari data gRPC biner via WASM!");
}
