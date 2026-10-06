const std = @import("std");
const mn = @import("mnemezigot");
const auth = @import("auth.zig");

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
// DATABASE MODEL (Message)
// =============================================================================

pub const Message = struct {
    id: ?i64 = null,
    text: []const u8,
    created_at: ?[]const u8 = null,

    pub const table_name = "messages";
};

// =============================================================================
// AUTHENTICATION HANDLERS & HELPERS
// =============================================================================

const RegisterInput = struct {
    username: []const u8,
    password: []const u8,
};

const LoginInput = struct {
    username: []const u8,
    password: []const u8,
};

const Verify2faInput = struct {
    code: []const u8,
    pre_auth_token: ?[]const u8 = null,
};

fn getCurrentUser(ctx: *mn.Context) !?auth.User {
    const token = auth.extractAuthToken(ctx, auth.g_auth_config) orelse return null;

    const sessions = try ctx.db.from(auth.Session).all(ctx.arena);
    const now = std.time.timestamp();

    var valid_user_id: ?i64 = null;
    for (sessions) |sess| {
        if (std.mem.eql(u8, sess.token, token) and !sess.pre_auth and sess.expires_at > now) {
            valid_user_id = sess.user_id;
            break;
        }
    }

    const target_id = valid_user_id orelse return null;
    const users = try ctx.db.from(auth.User).all(ctx.arena);
    for (users) |u| {
        if (u.id) |uid| {
            if (uid == target_id) return u;
        }
    }
    return null;
}

fn handleRegister(ctx: *mn.Context) !void {
    const parsed = ctx.bindJson(RegisterInput) catch {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Invalid payload" });
    };
    defer parsed.deinit();

    const username = std.mem.trim(u8, parsed.value.username, " ");
    const password = parsed.value.password;

    if (username.len == 0 or password.len == 0) {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Username and password cannot be empty" });
    }

    const users = try ctx.db.from(auth.User).all(ctx.arena);
    for (users) |u| {
        if (std.mem.eql(u8, u.username, username)) {
            ctx.status(400);
            return ctx.json(.{ .success = false, .error = "Username is already taken" });
        }
    }

    const hashed_password = try auth.hashPassword(ctx.arena, password);
    const new_id = try ctx.db.from(auth.User).insert(.{
        .username = username,
        .password_hash = hashed_password,
        .two_factor_enabled = false,
    });

    ctx.status(201);
    try ctx.json(.{
        .success = true,
        .message = "Pengguna berhasil terdaftar",
        .user_id = new_id,
        .username = username,
    });
}

fn handleLogin(ctx: *mn.Context) !void {
    const parsed = ctx.bindJson(LoginInput) catch {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Invalid payload" });
    };
    defer parsed.deinit();

    const username = std.mem.trim(u8, parsed.value.username, " ");
    const password = parsed.value.password;

    const users = try ctx.db.from(auth.User).all(ctx.arena);
    var matched_user: ?auth.User = null;
    for (users) |u| {
        if (std.mem.eql(u8, u.username, username)) {
            matched_user = u;
            break;
        }
    }

    const user = matched_user orelse {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Username atau password salah" });
    };

    if (!auth.verifyPassword(password, user.password_hash)) {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Username atau password salah" });
    }

    const token = try auth.generateRandomToken(ctx.arena);
    const now = std.time.timestamp();

    const requires_2fa = user.two_factor_enabled or auth.g_auth_config.require_2fa;

    if (requires_2fa) {
        _ = try ctx.db.from(auth.Session).insert(.{
            .user_id = user.id.?,
            .token = token,
            .pre_auth = true,
            .expires_at = now + 300,
        });

        try ctx.json(.{
            .success = true,
            .status = "2fa_required",
            .pre_auth_token = token,
            .message = "Verifikasi 2FA TOTP diperlukan untuk menyelesaikan login",
        });
    } else {
        _ = try ctx.db.from(auth.Session).insert(.{
            .user_id = user.id.?,
            .token = token,
            .pre_auth = false,
            .expires_at = now + auth.g_auth_config.session_ttl_seconds,
        });

        if (auth.g_auth_config.mode == .cookie or auth.g_auth_config.mode == .both) {
            var cookie_hdr: [256]u8 = undefined;
            const cookie_str = try std.fmt.bufPrint(&cookie_hdr, "session_id={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}", .{ token, auth.g_auth_config.session_ttl_seconds });
            ctx.header("Set-Cookie", cookie_str);
        }

        try ctx.json(.{
            .success = true,
            .status = "authenticated",
            .token = token,
            .user = .{
                .id = user.id,
                .username = user.username,
                .two_factor_enabled = user.two_factor_enabled,
            },
            .message = "Login berhasil",
        });
    }
}

fn handleVerify2faLogin(ctx: *mn.Context) !void {
    const parsed = ctx.bindJson(Verify2faInput) catch {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Invalid payload" });
    };
    defer parsed.deinit();

    const code_str = std.mem.trim(u8, parsed.value.code, " ");
    const code = std.fmt.parseInt(u32, code_str, 10) catch {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Kode 2FA harus berupa 6 angka" });
    };

    const token = parsed.value.pre_auth_token orelse auth.extractAuthToken(ctx, auth.g_auth_config) orelse {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Pre-auth token tidak ditemukan" });
    };

    const sessions = try ctx.db.from(auth.Session).all(ctx.arena);
    const now = std.time.timestamp();

    var matched_session: ?auth.Session = null;
    for (sessions) |s| {
        if (std.mem.eql(u8, s.token, token) and s.pre_auth and s.expires_at > now) {
            matched_session = s;
            break;
        }
    }

    const sess = matched_session orelse {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Sesi pre-auth kadaluarsa atau tidak valid" });
    };

    const users = try ctx.db.from(auth.User).all(ctx.arena);
    var target_user: ?auth.User = null;
    for (users) |u| {
        if (u.id) |uid| {
            if (uid == sess.user_id) {
                target_user = u;
                break;
            }
        }
    }

    const user = target_user orelse {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Pengguna tidak ditemukan" });
    };

    const secret = user.two_factor_secret orelse {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "2FA belum disiapkan untuk akun ini" });
    };

    if (!auth.verifyTOTPCode(secret, code, @intCast(now))) {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Kode 2FA TOTP salah atau kadaluarsa" });
    }

    const full_token = try auth.generateRandomToken(ctx.arena);
    _ = try ctx.db.from(auth.Session).insert(.{
        .user_id = user.id.?,
        .token = full_token,
        .pre_auth = false,
        .expires_at = now + auth.g_auth_config.session_ttl_seconds,
    });

    if (auth.g_auth_config.mode == .cookie or auth.g_auth_config.mode == .both) {
        var cookie_hdr: [256]u8 = undefined;
        const cookie_str = try std.fmt.bufPrint(&cookie_hdr, "session_id={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}", .{ full_token, auth.g_auth_config.session_ttl_seconds });
        ctx.header("Set-Cookie", cookie_str);
    }

    try ctx.json(.{
        .success = true,
        .status = "authenticated",
        .token = full_token,
        .user = .{
            .id = user.id,
            .username = user.username,
            .two_factor_enabled = user.two_factor_enabled,
        },
        .message = "Verifikasi 2FA berhasil! Login sukses.",
    });
}

fn handleSetup2fa(ctx: *mn.Context) !void {
    const user = (try getCurrentUser(ctx)) orelse {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Unauthorized" });
    };

    const secret = try auth.generateBase32Secret(ctx.arena);
    const otpauth_uri = try auth.generateOtpAuthUri(ctx.arena, "MnemezigotAuth", user.username, secret);

    _ = try ctx.db.from(auth.User).insert(.{
        .id = user.id,
        .username = user.username,
        .password_hash = user.password_hash,
        .two_factor_secret = secret,
        .two_factor_enabled = user.two_factor_enabled,
    });

    try ctx.json(.{
        .success = true,
        .secret = secret,
        .otpauth_uri = otpauth_uri,
        .message = "Secret 2FA berhasil dibuat. Masukkan secret ke Google Authenticator dan lakukan verifikasi.",
    });
}

fn handleVerify2faSetup(ctx: *mn.Context) !void {
    const user = (try getCurrentUser(ctx)) orelse {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Unauthorized" });
    };

    const parsed = ctx.bindJson(Verify2faInput) catch {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Invalid payload" });
    };
    defer parsed.deinit();

    const code_str = std.mem.trim(u8, parsed.value.code, " ");
    const code = std.fmt.parseInt(u32, code_str, 10) catch {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Kode 2FA harus berupa 6 angka" });
    };

    const secret = user.two_factor_secret orelse {
        ctx.status(400);
        return ctx.json(.{ .success = false, .error = "Silakan jalankan Setup 2FA terlebih dahulu" });
    };

    const now = std.time.timestamp();
    if (!auth.verifyTOTPCode(secret, code, @intCast(now))) {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Kode 2FA TOTP salah. Coba lagi." });
    }

    _ = try ctx.db.from(auth.User).insert(.{
        .id = user.id,
        .username = user.username,
        .password_hash = user.password_hash,
        .two_factor_secret = secret,
        .two_factor_enabled = true,
    });

    try ctx.json(.{
        .success = true,
        .message = "2FA TOTP Google Authenticator berhasil diaktifkan!",
    });
}

fn handleGetMe(ctx: *mn.Context) !void {
    const user = (try getCurrentUser(ctx)) orelse {
        ctx.status(401);
        return ctx.json(.{ .success = false, .error = "Sesi tidak valid atau telah kadaluarsa" });
    };

    try ctx.json(.{
        .success = true,
        .auth_mode = @tagName(auth.g_auth_config.mode),
        .user = .{
            .id = user.id,
            .username = user.username,
            .two_factor_enabled = user.two_factor_enabled,
        },
    });
}

fn handleLogout(ctx: *mn.Context) !void {
    ctx.header("Set-Cookie", "session_id=; Path=/; HttpOnly; Expires=Thu, 01 Jan 1970 00:00:00 GMT");

    try ctx.json(.{
        .success = true,
        .message = "Berhasil keluar (logout)",
    });
}

// =============================================================================
// KELUARAN 2: REST API & HTMX / SSE STREAMING HELPERS
// =============================================================================

const MessageInput = struct {
    text: []const u8,
};

fn handleGetMessagesJson(ctx: *mn.Context) !void {
    const total = try ctx.db.from(Message).count();
    const messages = try ctx.db.from(Message).all(ctx.arena);

    try ctx.json(.{
        .status = "success",
        .output_type = "JSON (REST API)",
        .database = "SQLite WAL Mode (Zero-Config Migration & ORM)",
        .auth_mode = @tagName(auth.g_auth_config.mode),
        .total_messages = total,
        .items = messages,
    });
}

fn handleCreateMessageJson(ctx: *mn.Context) !void {
    const parsed = try ctx.bindJson(MessageInput);
    defer parsed.deinit();

    const new_id = try ctx.db.from(Message).insert(.{
        .text = parsed.value.text,
    });
    const new_total = try ctx.db.from(Message).count();

    ctx.status(201);
    try ctx.json(.{
        .success = true,
        .id = new_id,
        .message = "Data tersimpan di SQLite via Model!",
        .saved_text = parsed.value.text,
        .total = new_total,
    });
}

fn handleStreamSseEvents(ctx: *mn.Context) !void {
    ctx.header("Content-Type", "text/event-stream");
    ctx.header("Cache-Control", "no-cache");
    ctx.header("Connection", "keep-alive");

    const event_data = "data: {\"event\": \"ping\", \"timestamp\": 1690000000}\n\n";
    ctx.res.body = event_data;
}

// =============================================================================
// KELUARAN 3: gRPC (gRPC-Web / Protobuf Framing)
// =============================================================================

fn handleGrpcEcho(ctx: *mn.Context) !void {
    const total = try ctx.db.from(Message).count();
    const users_count = try ctx.db.from(auth.User).count();

    var proto_buf: [256]u8 = undefined;
    var offset: usize = 0;

    var info_buf: [128]u8 = undefined;
    const info_str = try std.fmt.bufPrint(&info_buf, "Mnemezigot gRPC-Web (Users: {d}, Msg: {d})", .{ users_count, total });
    mn.grpc.writeStringField(&proto_buf, &offset, 1, info_str);
    mn.grpc.writeIntField(&proto_buf, &offset, 2, @intCast(total));

    try ctx.grpcResponse(proto_buf[0..offset]);
}

// =============================================================================
// SINGLE FILE ENTRY POINT & ROUTE GROUPING
// =============================================================================

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    auth.g_auth_config = .{
        .mode = .both,
        .require_2fa = false,
        .session_ttl_seconds = 86400,
    };

    var app = try mn.App.init(allocator, .{
        .port = 8080,
        .db_path = "data/app.db",
    });
    defer app.deinit();

    // Setup DB schema & migrations
    if (@hasDecl(mn.App, "migrate")) {
        try app.migrate();
    } else {
        try app.db.from(Message).createTableIfNotExists();
        try app.db.from(auth.User).createTableIfNotExists();
        try app.db.from(auth.Session).createTableIfNotExists();
    }

    if ((try app.db.from(Message).count()) == 0) {
        _ = try app.db.from(Message).insert(.{ .text = "Inisialisasi Mnemezigot Framework" });
        _ = try app.db.from(Message).insert(.{ .text = "SQLite WAL Mode Siap dengan Fitur Auth & 2FA" });
    }

    g_index_html = readFile(allocator, "index.html") catch "<h1>Mnemezigot Starter</h1>";
    g_style_css = readFile(allocator, "style.css") catch "";
    g_bridge_js = readFile(allocator, "bridge.js") catch "";
    g_app_wasm = readFile(allocator, "app.wasm") catch "";

    // [KELUARAN 1] Web UI
    try app.get("/", handleIndex);
    try app.get("/style.css", handleCss);
    try app.get("/bridge.js", handleBridgeJs);
    try app.get("/app.wasm", handleWasm);

    // [AUTHENTICATION & 2FA ENDPOINTS] (Supports standard and /api/v1 route group)
    try app.post("/api/register", handleRegister);
    try app.post("/api/login", handleLogin);
    try app.post("/api/login/2fa", handleVerify2faLogin);
    try app.post("/api/2fa/setup", handleSetup2fa);
    try app.post("/api/2fa/verify", handleVerify2faSetup);
    try app.get("/api/me", handleGetMe);
    try app.post("/api/logout", handleLogout);

    try app.post("/api/v1/register", handleRegister);
    try app.post("/api/v1/login", handleLogin);
    try app.post("/api/v1/login/2fa", handleVerify2faLogin);
    try app.post("/api/v1/2fa/setup", handleSetup2fa);
    try app.post("/api/v1/2fa/verify", handleVerify2faSetup);
    try app.get("/api/v1/me", handleGetMe);
    try app.post("/api/v1/logout", handleLogout);

    // [KELUARAN 2] REST API & SSE STREAMING
    try app.get("/api/messages", handleGetMessagesJson);
    try app.post("/api/messages", handleCreateMessageJson);
    try app.get("/api/v1/messages", handleGetMessagesJson);
    try app.post("/api/v1/messages", handleCreateMessageJson);
    try app.get("/api/v1/sse", handleStreamSseEvents);

    // [KELUARAN 3] gRPC
    try app.post("/api/grpc", handleGrpcEcho);
    try app.post("/api/v1/grpc", handleGrpcEcho);

    try app.listen();
}
