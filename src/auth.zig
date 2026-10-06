const std = @import("std");
const mn = @import("mnemezigot");

// =============================================================================
// AUTH CONFIGURATION
// =============================================================================

pub const AuthMode = enum {
    token, // Bearer Token in Authorization header
    cookie, // session_id in Cookie header
    both, // Accepts either Bearer token or Cookie
};

pub const AuthConfig = struct {
    mode: AuthMode = .both,
    require_2fa: bool = false,
    session_ttl_seconds: i64 = 86400, // 24 hours
};

// Global application auth config
pub var g_auth_config: AuthConfig = .{};

// =============================================================================
// DATABASE MODELS
// =============================================================================

pub const User = struct {
    id: ?i64 = null,
    username: []const u8,
    password_hash: []const u8,
    two_factor_secret: ?[]const u8 = null,
    two_factor_enabled: bool = false,
    created_at: ?[]const u8 = null,

    pub const table_name = "users";
};

pub const Session = struct {
    id: ?i64 = null,
    user_id: i64,
    token: []const u8,
    pre_auth: bool = false, // true if waiting for 2FA verification
    expires_at: i64,
    created_at: ?[]const u8 = null,

    pub const table_name = "sessions";
};

// =============================================================================
// CRYPTO & PASSWORD HASHING HELPERS (Integrates Framework Native mn.crypto)
// =============================================================================

pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    if (@hasDecl(mn, "crypto") and @hasDecl(mn.crypto, "hashPassword")) {
        return mn.crypto.hashPassword(allocator, password);
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("mnemezigot_salt_v2_");
    hasher.update(password);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var hex_buf: [64]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
    return allocator.dupe(u8, hex);
}

pub fn verifyPassword(password: []const u8, expected_hash: []const u8) bool {
    if (@hasDecl(mn, "crypto") and @hasDecl(mn.crypto, "verifyPassword")) {
        return mn.crypto.verifyPassword(password, expected_hash);
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("mnemezigot_salt_v2_");
    hasher.update(password);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var hex_buf: [64]u8 = undefined;
    const computed_hex = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch return false;
    return std.mem.eql(u8, computed_hex, expected_hash);
}

pub fn generateRandomToken(allocator: std.mem.Allocator) ![]u8 {
    var rand_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    var hex_buf: [64]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&rand_bytes)});
    return allocator.dupe(u8, hex);
}

// =============================================================================
// BASE32 & TOTP 2FA (Integrates Framework Native mn.security & mn.security.totp)
// =============================================================================

pub fn generateBase32Secret(allocator: std.mem.Allocator) ![]u8 {
    if (@hasDecl(mn, "security")) {
        if (@hasDecl(mn.security, "totp") and @hasDecl(mn.security.totp, "generateSecret")) {
            return mn.security.totp.generateSecret(allocator);
        } else if (@hasDecl(mn.security, "generateSecret")) {
            return mn.security.generateSecret(allocator);
        }
    }
    var raw_bytes: [10]u8 = undefined;
    std.crypto.random.bytes(&raw_bytes);
    const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    var secret = try allocator.alloc(u8, 16);
    errdefer allocator.free(secret);

    var bit_buffer: u64 = 0;
    var bits_count: usize = 0;
    var out_idx: usize = 0;

    for (raw_bytes) |byte| {
        bit_buffer = (bit_buffer << 8) | byte;
        bits_count += 8;
        while (bits_count >= 5) {
            bits_count -= 5;
            const index: usize = @intCast((bit_buffer >> @intCast(bits_count)) & 0x1F);
            if (out_idx < 16) {
                secret[out_idx] = BASE32_ALPHABET[index];
                out_idx += 1;
            }
        }
    }
    while (out_idx < 16) {
        secret[out_idx] = BASE32_ALPHABET[0];
        out_idx += 1;
    }
    return secret;
}

pub fn verifyTOTPCode(secret_base32: []const u8, input_code: u32, timestamp_seconds: u64) bool {
    if (@hasDecl(mn, "security")) {
        if (@hasDecl(mn.security, "totp") and @hasDecl(mn.security.totp, "verifyCode")) {
            return mn.security.totp.verifyCode(secret_base32, input_code, timestamp_seconds);
        } else if (@hasDecl(mn.security, "verifyTotp")) {
            return mn.security.verifyTotp(secret_base32, input_code, timestamp_seconds);
        }
    }

    const windows = [_]i64{ 0, -30, 30 };
    for (windows) |delta| {
        const adjusted_ts: u64 = if (delta < 0)
            timestamp_seconds -| @as(u64, @intCast(-delta))
        else
            timestamp_seconds + @as(u64, @intCast(delta));

        if (generateTOTPCodeFallback(secret_base32, adjusted_ts)) |expected_code| {
            if (expected_code == input_code) return true;
        } else |_| {}
    }
    return false;
}

fn generateTOTPCodeFallback(secret_base32: []const u8, timestamp_seconds: u64) !u32 {
    var key_buf: [32]u8 = undefined;
    var bit_buffer: u32 = 0;
    var bits_count: usize = 0;
    var out_idx: usize = 0;

    for (secret_base32) |char| {
        var val: u32 = 0;
        if (char >= 'A' and char <= 'Z') {
            val = char - 'A';
        } else if (char >= 'a' and char <= 'z') {
            val = char - 'a';
        } else if (char >= '2' and char <= '7') {
            val = char - '2' + 26;
        } else {
            continue;
        }

        bit_buffer = (bit_buffer << 5) | val;
        bits_count += 5;

        if (bits_count >= 8) {
            bits_count -= 8;
            if (out_idx < key_buf.len) {
                key_buf[out_idx] = @intCast((bit_buffer >> @intCast(bits_count)) & 0xFF);
                out_idx += 1;
            }
        }
    }
    const key = key_buf[0..out_idx];

    const time_step = timestamp_seconds / 30;
    var counter_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_bytes, time_step, .big);

    var hmac_out: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.auth.hmac.Hmac(std.crypto.hash.Sha1).create(&hmac_out, &counter_bytes, key);

    const offset = hmac_out[hmac_out.len - 1] & 0x0F;
    const truncated_hash = (@as(u32, hmac_out[offset] & 0x7F) << 24) |
        (@as(u32, hmac_out[offset + 1]) << 16) |
        (@as(u32, hmac_out[offset + 2]) << 8) |
        @as(u32, hmac_out[offset + 3]);

    return truncated_hash % 1_000_000;
}

pub fn generateOtpAuthUri(allocator: std.mem.Allocator, issuer: []const u8, username: []const u8, secret: []const u8) ![]u8 {
    if (@hasDecl(mn, "security")) {
        if (@hasDecl(mn.security, "totp") and @hasDecl(mn.security.totp, "getOtpAuthUri")) {
            return mn.security.totp.getOtpAuthUri(allocator, issuer, username, secret);
        } else if (@hasDecl(mn.security, "getOtpAuthUri")) {
            return mn.security.getOtpAuthUri(allocator, issuer, username, secret);
        }
    }
    return std.fmt.allocPrint(allocator, "otpauth://totp/{s}:{s}?secret={s}&issuer={s}", .{ issuer, username, secret, issuer });
}

pub fn extractAuthToken(ctx: *mn.Context, config: AuthConfig) ?[]const u8 {
    if (config.mode == .token or config.mode == .both) {
        if (ctx.req.headers.get("authorization")) |auth_hdr| {
            if (std.mem.startsWith(u8, auth_hdr, "Bearer ") or std.mem.startsWith(u8, auth_hdr, "bearer ")) {
                const token = std.mem.trim(u8, auth_hdr[7..], " ");
                if (token.len > 0) return token;
            }
        }
    }

    if (config.mode == .cookie or config.mode == .both) {
        if (ctx.req.headers.get("cookie")) |cookie_hdr| {
            var iter = std.mem.splitSequence(u8, cookie_hdr, ";");
            while (iter.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " ");
                if (std.mem.startsWith(u8, trimmed, "session_id=")) {
                    const token = trimmed["session_id=".len..];
                    if (token.len > 0) return token;
                }
            }
        }
    }

    return null;
}
