const state = await chrome.storage.local.get({ enabled: true, lastError: "", lastCapture: 0, lastTitle: "" });
document.querySelector("#enabled").checked = state.enabled;
document.querySelector("#enabled").addEventListener("change", e => chrome.storage.local.set({ enabled: e.target.checked }));
document.querySelector("#id").textContent = chrome.runtime.id;
document.querySelector("#status").textContent = state.lastError || (state.lastCapture ? `Last capture: ${new Date(state.lastCapture).toLocaleTimeString()} · ${state.lastTitle}` : "Waiting for Onward. Install the native host using the included setup script.");
