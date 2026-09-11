const std = @import("std");
const mn = @import("mnemezigot");

// In-Memory cache for static assets (Zero Disk I/O during web requests)
var g_index_html: []const u8 = "";
var g_style_css: []const u8 = "";
var g_bridge_js: []const u8 = "";
var g_app_wasm: []const u8 = "";

fn readFile(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const io = std.Io.Threaded.global_single_threaded.io();
    const candidates = [_][]const u8{ "zig-out/public", "public", "." };
    var path_buf: [256]u8 = undefined;

    for (candidates) |prefix| {
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ prefix, filename }) catch continue;
        if (cwd.openFile(io, full_path, .{})) |file| {
            defer file.close(io);
            const size = try file.length(io);
            const buf = try allocator.alloc(u8, @intCast(size));
            errdefer allocator.free(buf);
            _ = try file.readPositionalAll(io, buf, 0);
            return buf;
        } else |_| {}
    }
    return error.FileNotFound;
}

// =============================================================================
// KELUARAN 1: Web UI (HTML, CSS & WebAssembly)
// =============================================================================

fn handleIndex(ctx: *mn.Context) !void {
    try ctx.html(g_index_html);
}

fn handleCss(ctx: *mn.Context) !void {
    try ctx.css(g_style_css);
}

fn handleBridgeJs(ctx: *mn.Context) !void {
    ctx.header("Content-Type", "application/javascript");
    ctx.res.body = g_bridge_js;
}

fn handleWasm(ctx: *mn.Context) !void {
    try ctx.wasm(g_app_wasm);
}

// =============================================================================
// KELUARAN 2: REST API (JSON)
// =============================================================================

const MessageInput = struct {
    text: []const u8,
};

fn handleGetMessagesJson(ctx: *mn.Context) !void {
    const total = try ctx.db.queryScalarInt("SELECT COUNT(*) FROM messages;");
    try ctx.json(.{
        .status = "success",
        .output_type = "JSON (REST API)",
        .database = "SQLite WAL Mode (Zero-Config)",
        .total_messages = total,
    });
}

fn handleCreateMessageJson(ctx: *mn.Context) !void {
    const parsed = try ctx.bindJson(MessageInput);
    defer parsed.deinit();

    try ctx.db.insertText("INSERT INTO messages (text) VALUES (?);", parsed.value.text);
    const new_total = try ctx.db.queryScalarInt("SELECT COUNT(*) FROM messages;");

    ctx.status(201);
    try ctx.json(.{
        .success = true,
        .message = "Data tersimpan di SQLite!",
        .saved_text = parsed.value.text,
        .total = new_total,
    });
}

// =============================================================================
// KELUARAN 3: gRPC (gRPC-Web / Protobuf Framing)
// =============================================================================

fn handleGrpcEcho(ctx: *mn.Context) !void {
    const total = try ctx.db.queryScalarInt("SELECT COUNT(*) FROM messages;");

    // Encode standard protobuf: message EchoResponse { string info = 1; int64 total = 2; }
    var proto_buf: [256]u8 = undefined;
    var offset: usize = 0;

    const info_str = "Mnemezigot gRPC-Web via SQLite WAL";
    mn.grpc.writeStringField(&proto_buf, &offset, 1, info_str);
    mn.grpc.writeIntField(&proto_buf, &offset, 2, @intCast(total));

    // Wrap protobuf payload with standard 5-byte data header + trailer headers
    try ctx.grpcResponse(proto_buf[0..offset]);
}

// =============================================================================
// SINGLE FILE ENTRY POINT
// =============================================================================

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // 1. Inisialisasi Framework: SQLite WAL Mode Otomatis Aktif (Zero-Config)!
    var app = try mn.App.init(allocator, .{
        .port = 8080,
        .db_path = "data/app.db",
    });
    defer app.deinit();

    // 2. Setup skema database awal
    try app.db.exec(
        \\CREATE TABLE IF NOT EXISTS messages (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    text TEXT NOT NULL,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\);
    );
    try app.db.exec("INSERT OR IGNORE INTO messages (id, text) VALUES (1, 'Inisialisasi Mnemezigot Framework'), (2, 'SQLite WAL Mode Siap');");

    // 3. Pre-load static assets ke memori
    g_index_html = readFile(allocator, "index.html") catch "<h1>Mnemezigot Starter</h1>";
    g_style_css = readFile(allocator, "style.css") catch "";
    g_bridge_js = readFile(allocator, "bridge.js") catch "";
    g_app_wasm = readFile(allocator, "app.wasm") catch "";

    // 4. Daftarkan Routes untuk 3 Bentuk Keluaran:

    // [KELUARAN 1] Web UI (HTML, CSS & WASM)
    try app.get("/", handleIndex);
    try app.get("/style.css", handleCss);
    try app.get("/bridge.js", handleBridgeJs);
    try app.get("/app.wasm", handleWasm);

    // [KELUARAN 2] REST API (JSON)
    try app.get("/api/messages", handleGetMessagesJson);
    try app.post("/api/messages", handleCreateMessageJson);

    // [KELUARAN 3] gRPC (gRPC-Web / Protobuf)
    try app.post("/api/grpc", handleGrpcEcho);

    // 5. Jalankan Server!
    try app.listen();
}
