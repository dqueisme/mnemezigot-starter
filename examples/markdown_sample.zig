const std = @import("std");
const mn = @import("mnemezigot");
const tui = mn.tui;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const stdout = tui.stdoutWriter();

    // 1. Bersihkan layar terminal
    try tui.Screen.clear(stdout);

    // 2. Siapkan dokumen contoh Markdown
    const sample_md =
        \\# 💅 Glow-Style Markdown di Mnemezigot
        \\
        \\Komponen **MarkdownViewer** native Zig ini terinspirasi dari arsitektur Glamour & Glow miliki Charmbracelet.
        \\
        \\## 🚀 Fitur Unggulan
        \\- *Word-wrapping* adaptif berbasis lebar kolom terminal
        \\- Heading bergaya visual terminal modern
        \\- Pemformatan inline: **tebal**, *miring*, dan `kode monospaced`
        \\- Tautan web interaktif: [Dokumentasi Zig](https://ziglang.org)
        \\
        \\### 📋 Daftar Tugas & Checklist
        \\- [x] Rancang parser AST blok dan pemecah baris
        \\- [x] Implementasi viewport dan navigasi scroll
        \\- [ ] Integrasi penuh syntax highlighting Chroma
        \\
        \\> "The best code is the code never written. Solusi paling ringkas yang bekerja."
        \\> — Aturan Ponytail (YAGNI & Lean)
        \\
        \\```zig
        \\pub fn render(buf: *tui.Buffer, rect: tui.Rect) void {
        \\    viewer.draw(buf, rect);
        \\}
        \\```
        \\
        \\---
        \\
        \\| Fitur | Status | Keterangan |
        \\|---|---|---|
        \\| Double-Buffering | Aktif | Bebas kedipan (flicker-free) |
        \\| Unicode Width | Aktif | Dukungan CJK & Emoji presisi |
        \\| Glow Pager | Aktif | Scroll vertikal responsif |
    ;

    // 3. Inisialisasi MarkdownViewer
    var viewer = tui.MarkdownViewer.init(allocator);
    defer viewer.deinit();

    // Dapatkan ukuran terminal saat ini
    const win_size = tui.getWindowSize();
    const content_width: u16 = @intCast(@min(win_size.cols -| 4, 80));

    // Parse dan tata letak Markdown ke lebar terminal
    try viewer.load(sample_md, content_width);

    // 4. Render ke ANSI string untuk dicetak langsung ke terminal
    const ansi_rendered = try viewer.renderToAnsi(allocator);
    defer allocator.free(ansi_rendered);

    try stdout.print("{s}", .{ansi_rendered});

    try stdout.print("\n\x1b[38;2;122;162;247m[INFO]\x1b[0m Dokumen Markdown berhasil dirender ({d} baris terformat).\n", .{viewer.doc.lines.items.len});
}
