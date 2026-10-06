// JavaScript Runtime Bridge for Mnemezigot Starter
// Handles: 1) WASM Interop, 2) REST API (JSON), 3) gRPC-Web Binary Framing, 4) Auth & 2FA

let wasmInstance = null;
let currentAuthToken = localStorage.getItem("mnemezigot_token") || null;
let currentPreAuthToken = null;

// DOM Elements
const wasmText = document.getElementById("wasm-text");
const btnWasm = document.getElementById("btn-wasm");
const formRest = document.getElementById("form-rest");
const inputMessage = document.getElementById("input-message");
const btnRest = document.getElementById("btn-rest");
const jsonResult = document.getElementById("json-result");
const grpcText = document.getElementById("grpc-text");
const btnGrpc = document.getElementById("btn-grpc");
const logEntries = document.getElementById("log-entries");

// Auth DOM Elements
const formRegister = document.getElementById("form-register");
const regUsername = document.getElementById("reg-username");
const regPassword = document.getElementById("reg-password");

const formLogin = document.getElementById("form-login");
const loginUsername = document.getElementById("login-username");
const loginPassword = document.getElementById("login-password");

const panel2faLogin = document.getElementById("panel-2fa-login");
const form2faLogin = document.getElementById("form-2fa-login");
const login2faCode = document.getElementById("login-2fa-code");

const btnSetup2fa = document.getElementById("btn-setup-2fa");
const setup2faBox = document.getElementById("setup-2fa-box");
const totpSecretKey = document.getElementById("totp-secret-key");
const totpUri = document.getElementById("totp-uri");
const formVerifySetup2fa = document.getElementById("form-verify-setup-2fa");
const setup2faCode = document.getElementById("setup-2fa-code");

const btnGetMe = document.getElementById("btn-get-me");
const btnLogout = document.getElementById("btn-logout");
const authResult = document.getElementById("auth-result");

// Logging Helper
function addLog(msg) {
  const time = new Date().toLocaleTimeString();
  const entry = document.createElement("div");
  entry.className = "log-line";
  entry.innerHTML = `<span class="log-time">[${time}]</span> ${msg}`;
  if (logEntries) {
    logEntries.appendChild(entry);
    logEntries.scrollTop = logEntries.scrollHeight;
  }
}

function updateAuthDisplay(data) {
  if (authResult) {
    const payload = {
      ...data,
      active_token: currentAuthToken ? `${currentAuthToken.substring(0, 10)}...` : null,
    };
    authResult.textContent = JSON.stringify(payload, null, 2);
  }
}

// Memory Helpers for WASM Boundary
function readString(ptr, len) {
  const memory = new Uint8Array(wasmInstance.exports.memory.buffer, ptr, len);
  return new TextDecoder("utf-8").decode(memory);
}

function copyToWasm(bytes) {
  const ptr = wasmInstance.exports.alloc(bytes.length);
  if (!ptr) throw new Error("Gagal mengalokasikan memory WASM");
  const wasmBuffer = new Uint8Array(wasmInstance.exports.memory.buffer, ptr, bytes.length);
  wasmBuffer.set(bytes);
  return { ptr, len: bytes.length };
}

// Helper fetch with Auth Bearer header
async function authFetch(url, options = {}) {
  options.headers = options.headers || {};
  if (currentAuthToken) {
    options.headers["Authorization"] = `Bearer ${currentAuthToken}`;
  }
  return fetch(url, options);
}

// WASM Import Object
const importObject = {
  env: {
    js_update_text: (ptr, len) => {
      const text = readString(ptr, len);
      if (text.includes("gRPC")) {
        if (grpcText) grpcText.textContent = text;
      } else {
        if (wasmText) wasmText.textContent = text;
      }
      addLog(`UI di-update: <strong>${text}</strong>`);
    },
    js_log: (ptr, len) => {
      const msg = readString(ptr, len);
      addLog(`[WASM] ${msg}`);
    },
    js_send_grpc: async (endpointPtr, endpointLen, bodyPtr, bodyLen) => {
      const endpoint = readString(endpointPtr, endpointLen);
      const bodyBytes = new Uint8Array(wasmInstance.exports.memory.buffer, bodyPtr, bodyLen);

      if (btnGrpc) btnGrpc.disabled = true;

      try {
        addLog(`[gRPC-Web] Mengirim frame biner ke <code>${endpoint}</code>...`);
        const response = await fetch(endpoint, {
          method: "POST",
          headers: {
            "Content-Type": "application/grpc-web+proto",
            "X-Grpc-Web": "1",
          },
          body: bodyBytes,
        });

        if (!response.ok) {
          throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        const respBuffer = await response.arrayBuffer();
        const respBytes = new Uint8Array(respBuffer);

        const { ptr, len } = copyToWasm(respBytes);
        wasmInstance.exports.on_grpc_response(ptr, len);
        wasmInstance.exports.free(ptr, len);
      } catch (err) {
        addLog(`❌ [gRPC Error]: ${err.message}`);
        if (grpcText) grpcText.textContent = `Error: ${err.message}`;
      } finally {
        if (btnGrpc) btnGrpc.disabled = false;
      }
    },
  },
};

// [AUTH HANDLERS]
if (formRegister) {
  formRegister.addEventListener("submit", async (e) => {
    e.preventDefault();
    const username = regUsername.value.trim();
    const password = regPassword.value;
    if (!username || !password) return;

    try {
      addLog(`[Auth] Mengirim registrasi pengguna <code>${username}</code>...`);
      const res = await fetch("/api/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });
      const data = await res.json();
      updateAuthDisplay(data);
      if (res.ok) {
        addLog(`✅ [Register Sukses]: Akun <strong>${username}</strong> berhasil dibuat!`);
        regPassword.value = "";
      } else {
        addLog(`❌ [Register Gagal]: ${data.error || "Gagal mendaftar"}`);
      }
    } catch (err) {
      addLog(`❌ [Register Error]: ${err.message}`);
    }
  });
}

if (formLogin) {
  formLogin.addEventListener("submit", async (e) => {
    e.preventDefault();
    const username = loginUsername.value.trim();
    const password = loginPassword.value;
    if (!username || !password) return;

    try {
      addLog(`[Auth] Mencoba login pengguna <code>${username}</code>...`);
      const res = await fetch("/api/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });
      const data = await res.json();
      updateAuthDisplay(data);

      if (res.ok) {
        if (data.status === "2fa_required") {
          currentPreAuthToken = data.pre_auth_token;
          if (panel2faLogin) panel2faLogin.style.display = "block";
          addLog(`⚠️ [2FA Required]: Masukkan kode TOTP 6-digit Google Authenticator.`);
        } else if (data.status === "authenticated") {
          currentAuthToken = data.token;
          localStorage.setItem("mnemezigot_token", data.token);
          if (panel2faLogin) panel2faLogin.style.display = "none";
          addLog(`✅ [Login Sukses]: Selamat datang, <strong>${data.user.username}</strong>!`);
        }
      } else {
        addLog(`❌ [Login Gagal]: ${data.error || "Gagal login"}`);
      }
    } catch (err) {
      addLog(`❌ [Login Error]: ${err.message}`);
    }
  });
}

if (form2faLogin) {
  form2faLogin.addEventListener("submit", async (e) => {
    e.preventDefault();
    const code = login2faCode.value.trim();
    if (!code || !currentPreAuthToken) return;

    try {
      addLog(`[Auth 2FA] Verifikasi kode 6-digit TOTP...`);
      const res = await fetch("/api/login/2fa", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code, pre_auth_token: currentPreAuthToken }),
      });
      const data = await res.json();
      updateAuthDisplay(data);

      if (res.ok && data.token) {
        currentAuthToken = data.token;
        localStorage.setItem("mnemezigot_token", data.token);
        if (panel2faLogin) panel2faLogin.style.display = "none";
        login2faCode.value = "";
        addLog(`🎉 [2FA Verified]: Login sukses dengan 2FA Google Authenticator!`);
      } else {
        addLog(`❌ [2FA Gagal]: ${data.error || "Kode 2FA salah"}`);
      }
    } catch (err) {
      addLog(`❌ [2FA Error]: ${err.message}`);
    }
  });
}

if (btnSetup2fa) {
  btnSetup2fa.addEventListener("click", async () => {
    try {
      addLog(`[Auth Setup 2FA] Meminta secret key 2FA baru...`);
      const res = await authFetch("/api/2fa/setup", { method: "POST" });
      const data = await res.json();
      updateAuthDisplay(data);

      if (res.ok) {
        if (totpSecretKey) totpSecretKey.textContent = data.secret;
        if (totpUri) totpUri.textContent = data.otpauth_uri;
        if (setup2faBox) setup2faBox.style.display = "block";
        addLog(`🔑 [Secret 2FA]: Secret Base32 dihasilkan (<code>${data.secret}</code>).`);
      } else {
        addLog(`❌ [Setup 2FA Gagal]: ${data.error || "Login terlebih dahulu"}`);
      }
    } catch (err) {
      addLog(`❌ [Setup 2FA Error]: ${err.message}`);
    }
  });
}

if (formVerifySetup2fa) {
  formVerifySetup2fa.addEventListener("submit", async (e) => {
    e.preventDefault();
    const code = setup2faCode.value.trim();
    if (!code) return;

    try {
      addLog(`[Auth Setup 2FA] Mengonfirmasi kode 2FA...`);
      const res = await authFetch("/api/2fa/verify", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code }),
      });
      const data = await res.json();
      updateAuthDisplay(data);

      if (res.ok) {
        setup2faCode.value = "";
        addLog(`🛡️ [2FA Aktif]: Google Authenticator berhasil diaktifkan!`);
      } else {
        addLog(`❌ [Konfirmasi 2FA Gagal]: ${data.error || "Kode salah"}`);
      }
    } catch (err) {
      addLog(`❌ [2FA Verify Error]: ${err.message}`);
    }
  });
}

if (btnGetMe) {
  btnGetMe.addEventListener("click", async () => {
    try {
      addLog(`[Auth] Mengakses protected endpoint <code>GET /api/me</code>...`);
      const res = await authFetch("/api/me");
      const data = await res.json();
      updateAuthDisplay(data);

      if (res.ok) {
        addLog(`👤 [Profil Terverifikasi]: Logged as <strong>${data.user.username}</strong> (2FA: ${data.user.two_factor_enabled ? "Aktif" : "Non-aktif"})`);
      } else {
        addLog(`🔒 [Unauthorized]: ${data.error || "Sesi tidak valid"}`);
      }
    } catch (err) {
      addLog(`❌ [/api/me Error]: ${err.message}`);
    }
  });
}

if (btnLogout) {
  btnLogout.addEventListener("click", async () => {
    try {
      addLog(`[Auth] Mengirim request logout...`);
      const res = await authFetch("/api/logout", { method: "POST" });
      const data = await res.json();

      currentAuthToken = null;
      currentPreAuthToken = null;
      localStorage.removeItem("mnemezigot_token");
      updateAuthDisplay(data);

      addLog(`🚪 [Logout]: Pengguna berhasil keluar dari sistem.`);
    } catch (err) {
      addLog(`❌ [Logout Error]: ${err.message}`);
    }
  });
}

// [KELUARAN 1]: WASM Click Handler
if (btnWasm) {
  btnWasm.addEventListener("click", () => {
    if (wasmInstance && wasmInstance.exports.on_wasm_click) {
      wasmInstance.exports.on_wasm_click();
    }
  });
}

// [KELUARAN 2]: REST API Handlers
async function fetchMessages() {
  try {
    const res = await fetch("/api/messages");
    if (res.ok) {
      const data = await res.json();
      if (jsonResult) jsonResult.textContent = JSON.stringify(data, null, 2);
      addLog(`[REST GET] Data termuat. Total baris SQLite: <strong>${data.total_messages}</strong>.`);
    }
  } catch (err) {
    addLog(`❌ [REST Error]: ${err.message}`);
  }
}

if (formRest) {
  formRest.addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = inputMessage.value.trim();
    if (!text) return;

    if (btnRest) btnRest.disabled = true;
    try {
      addLog(`[REST POST] Mengirim JSON ke <code>/api/messages</code>...`);
      const res = await fetch("/api/messages", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
      const data = await res.json();
      if (jsonResult) jsonResult.textContent = JSON.stringify(data, null, 2);
      inputMessage.value = "";
      addLog(`[SQLite INSERT] Pesan tersimpan: "${text}" (Total: ${data.total}).`);
    } catch (err) {
      addLog(`❌ [REST POST Error]: ${err.message}`);
    } finally {
      if (btnRest) btnRest.disabled = false;
    }
  });
}

// [KELUARAN 3]: gRPC-Web Click Handler
if (btnGrpc) {
  btnGrpc.addEventListener("click", () => {
    if (wasmInstance && wasmInstance.exports.on_grpc_click) {
      wasmInstance.exports.on_grpc_click();
    }
  });
}

// Initialize Application
async function init() {
  addLog("Memulai inisialisasi runtime...");
  try {
    const response = await fetch("app.wasm");
    const bytes = await response.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, importObject);
    wasmInstance = instance;
    wasmInstance.exports.init();
    await fetchMessages();
  } catch (err) {
    addLog(`❌ Gagal memuat WASM: ${err.message}`);
    console.error("WASM load error:", err);
  }
}

init();
