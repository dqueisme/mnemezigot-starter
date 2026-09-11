// JavaScript Runtime Bridge for Mnemezigot Starter
// Handles: 1) WASM Interop, 2) REST API (JSON), 3) gRPC-Web Binary Framing

let wasmInstance = null;

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
