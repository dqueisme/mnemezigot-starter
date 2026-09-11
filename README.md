# Mnemezigot Starter Template

Starter template resmi untuk [Mnemezigot Framework](https://github.com/dqueisme/mnemezigot) — Framework web fullstack ultra-ringan berbasis **Zig 0.16 + SQLite WAL + WebAssembly (WASM) + gRPC-Web**.

---

## 🚀 Fitur Utama

1. **Zero-Config SQLite (HANYA WAL Mode)**:
   - Database otomatis diinisialisasi dengan `PRAGMA journal_mode = WAL;` dan `busy_timeout = 5000ms`.
   - Tidak perlu konfigurasi connection string atau setup daemon external.
2. **Hanya 3 Bentuk Keluaran**:
   - **Keluaran 1: Web UI (HTML, CSS & WebAssembly)**: Antarmuka modern tanpa framework JavaScript berat, logika frontend dikompilasi dari Zig ke `app.wasm` (< 10 KB).
   - **Keluaran 2: REST API (JSON)**: Endpoint JSON terstruktur (`ctx.json`, `ctx.bindJson`) untuk integrasi mobile atau microservice.
   - **Keluaran 3: gRPC (gRPC-Web / Protobuf Framing)**: Framing biner performa tinggi langsung via HTTP (`ctx.grpcResponse`).
3. **Single File Entry Point**:
   - Seluruh inisialisasi aplikasi, migrasi tabel SQLite, dan registrasi routing berada dalam satu file yang ringkas: [`src/main.zig`](src/main.zig).

---

## 📁 Struktur Folder

```text
mnemezigot-starter/
├── build.zig          # Build script untuk server backend & client WASM
├── build.zig.zon      # Package manifest & dependensi mnemezigot
├── public/            # Static assets (HTML, CSS, JS runtime bridge)
│   ├── index.html     # Semantic HTML UI
│   ├── style.css      # CSS variabel terpusat (No utility-soup)
│   └── bridge.js      # Runtime JS bridge penghubung WASM, REST, dan gRPC
└── src/
    ├── main.zig       # Single-entry backend & routes (3 Bentuk Keluaran)
    └── client.zig     # Logika frontend dikompilasi ke WebAssembly
```

---

## 🛠️ Cara Menjalankan

### 1. Prasyarat
- **Zig 0.16** terinstal di sistem Anda.

### 2. Jalankan Server Langsung
```bash
zig build run
```
Server akan mengompilasi backend dan client WASM, lalu mendengarkan di:
👉 **`http://127.0.0.1:8080/`**

### 3. Build untuk Produksi
```bash
zig build -Doptimize=ReleaseSmall
```
Hasil binary server dan seluruh static assets terkumpul siap di-distribusikan di folder `zig-out/`.

---

## 📡 Pengujian 3 Bentuk Keluaran

### 1. Web UI (WASM & HTML)
Buka browser pada `http://127.0.0.1:8080/` untuk melihat live interaksi WebAssembly.

### 2. REST API (JSON)
```bash
# Ambil data statistik pesan
curl -s http://127.0.0.1:8080/api/messages

# Simpan pesan baru ke SQLite
curl -s -X POST http://127.0.0.1:8080/api/messages \
  -H "Content-Type: application/json" \
  -d '{"text":"Halo dari cURL"}'
```

### 3. gRPC-Web (Protobuf Framing Biner)
```bash
curl -s -X POST http://127.0.0.1:8080/api/grpc \
  -H "Content-Type: application/grpc-web+proto" \
  --data-binary $'\x00\x00\x00\x00\x00' | xxd
```
