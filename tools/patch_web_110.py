from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIN = ROOT / "current_source" / "windows"
SERVER = WIN / "server.py"
GUI = WIN / "gui.py"
WEB = WIN / "web"
INDEX = WEB / "index.html"
APP = WEB / "app.js"
CSS = WEB / "styles.css"
SW = WEB / "sw.js"

def replace_once(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: anchor not found")
    return text.replace(old, new, 1)

# server
s = SERVER.read_text(encoding="utf-8")
s = s.replace('PCREMOTE_VERSION = "6.4.0"', 'PCREMOTE_VERSION = "6.5.0"')
if 'TAILSCALE_SERVE_CACHE' not in s:
    s = replace_once(
        s,
        'TAILSCALE_CACHE_LOCK = threading.Lock()\n',
        'TAILSCALE_CACHE_LOCK = threading.Lock()\n'
        'TAILSCALE_SERVE_CACHE = {"time": 0.0, "value": None}\n'
        'TAILSCALE_SERVE_LOCK = threading.Lock()\n',
        "serve globals",
    )

serve_code = r"""
def _tailscale_serve_cache(value):
    with TAILSCALE_SERVE_LOCK:
        TAILSCALE_SERVE_CACHE["time"] = time.time()
        TAILSCALE_SERVE_CACHE["value"] = dict(value)
    return value


def _tailscale_serve_status(force=False):
    # Return safe status for Tailscale Serve HTTPS -> local PCRemoteServer.
    now = time.time()
    with TAILSCALE_SERVE_LOCK:
        cached = TAILSCALE_SERVE_CACHE.get("value")
        if not force and cached is not None and now - float(TAILSCALE_SERVE_CACHE.get("time", 0.0)) < 5.0:
            return dict(cached)

    runtime = _tailscale_runtime_status(force=force)
    port = int(CONFIG.get("port", 8765))
    backend = f"http://127.0.0.1:{port}"
    base = {
        "installed": bool(runtime.get("installed")),
        "enabled": bool(runtime.get("enabled")),
        "online": bool(runtime.get("online")),
        "dns": runtime.get("dns"),
        "ip": runtime.get("ip"),
        "backend": backend,
        "configured": False,
        "conflict": False,
        "supported": True,
        "https_url": None,
        "root_url": f"https://{runtime.get('dns')}/" if runtime.get("dns") else None,
        "detail": None,
    }
    exe = _tailscale_executable()
    if not exe:
        base["supported"] = False
        base["detail"] = "Tailscale не установлен на ПК."
        return _tailscale_serve_cache(base)

    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW") else 0
    try:
        result = subprocess.run(
            [exe, "serve", "status", "--json"],
            capture_output=True,
            text=True,
            timeout=5.0,
            creationflags=flags,
            check=False,
        )
    except Exception as exc:
        base["supported"] = False
        base["detail"] = str(exc)
        return _tailscale_serve_cache(base)

    raw = (result.stdout or "").strip()
    err = (result.stderr or "").strip()
    if result.returncode != 0:
        combined = (err or raw or f"tailscale serve status: code {result.returncode}").strip()
        low = combined.lower()
        if "unknown command" in low or "not a command" in low or "flag provided but not defined" in low:
            base["supported"] = False
        base["detail"] = combined
        return _tailscale_serve_cache(base)

    try:
        config = json.loads(raw) if raw else {}
    except Exception:
        config = {}

    strings = []
    def collect(value):
        if isinstance(value, dict):
            for key, item in value.items():
                strings.append(str(key))
                collect(item)
        elif isinstance(value, list):
            for item in value:
                collect(item)
        elif isinstance(value, str):
            strings.append(value)
    collect(config)
    lower_strings = [item.lower().rstrip("/") for item in strings]
    backend_tokens = {
        backend.lower().rstrip("/"),
        f"127.0.0.1:{port}",
        f"localhost:{port}",
        f"http://localhost:{port}",
    }
    configured = any(any(token in item for token in backend_tokens) for item in lower_strings)
    base["configured"] = configured
    base["conflict"] = bool(config and not configured)
    if configured and base.get("dns"):
        base["https_url"] = f"https://{base['dns']}/web/"
    if base["conflict"]:
        base["detail"] = "На Tailscale Serve уже есть другая конфигурация. Comfy Remote не будет перезаписывать её автоматически."
    return _tailscale_serve_cache(base)


def _tailscale_serve_enable():
    runtime = _tailscale_runtime_status(force=True)
    if not runtime.get("installed"):
        raise ValueError("Tailscale не установлен на ПК.")
    if not runtime.get("enabled") or not runtime.get("online"):
        raise ValueError("Сначала включите Tailscale и дождитесь статуса Online.")
    if not runtime.get("dns"):
        raise ValueError("Tailscale MagicDNS/HTTPS имя ещё не доступно.")

    current = _tailscale_serve_status(force=True)
    if current.get("configured"):
        return current
    if current.get("conflict"):
        raise ValueError(current.get("detail") or "Tailscale Serve уже используется.")
    if not current.get("supported", True):
        raise ValueError(current.get("detail") or "Эта версия Tailscale не поддерживает Serve.")

    exe = _tailscale_executable()
    port = int(CONFIG.get("port", 8765))
    backend = f"http://127.0.0.1:{port}"
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW") else 0
    result = subprocess.run(
        [exe, "serve", "--bg", "--yes", backend],
        capture_output=True,
        text=True,
        timeout=30,
        creationflags=flags,
        check=False,
    )
    if result.returncode != 0:
        details = (result.stderr or result.stdout or "").strip()
        raise ValueError(details or f"tailscale serve завершился с кодом {result.returncode}.")

    with TAILSCALE_SERVE_LOCK:
        TAILSCALE_SERVE_CACHE["time"] = 0.0
        TAILSCALE_SERVE_CACHE["value"] = None
    status = _tailscale_serve_status(force=True)
    if not status.get("configured"):
        details = (result.stdout or result.stderr or "").strip()
        raise ValueError(details or "Tailscale Serve запустился, но прокси PC Remote не найден.")
    return status

"""
if 'def _tailscale_serve_status(' not in s:
    s = replace_once(s, '\ndef _tailscale_down_delayed():\n', '\n' + serve_code + '\ndef _tailscale_down_delayed():\n', "serve funcs")

routes = r"""
@app.get("/api/tailscale/serve-status")
def tailscale_serve_status():
    value = _tailscale_serve_status(force=request.args.get("force") in {"1", "true", "yes"})
    return jsonify({"ok": True, **value})


@app.post("/api/tailscale/serve-enable")
def tailscale_serve_enable():
    try:
        value = _tailscale_serve_enable()
        return jsonify({"ok": True, **value})
    except ValueError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 409
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500


"""
if 'def tailscale_serve_status()' not in s:
    s = replace_once(s, '\n@app.get("/api/web/info")\n', '\n' + routes + '@app.get("/api/web/info")\n', "serve routes")

s = s.replace('"web_version": "1.0.0"', '"web_version": "1.1.0"')
if '"tailscale_https_serve": True' not in s:
    s = s.replace('"tailscale_control": True,\n', '"tailscale_control": True,\n            "tailscale_https_serve": True,\n')
SERVER.write_text(s, encoding="utf-8")

# index
h = INDEX.read_text(encoding="utf-8")
h = h.replace('Web 1.0.0 · управление ComfyUI через PCRemoteServer', 'Web 1.1.0 · ComfyUI + защищённый Tailscale HTTPS')
remote_card = r"""
          <section id="remoteAccessCard" class="card glass remote-card">
            <div class="section-head">
              <div><div class="eyebrow">REMOTE ACCESS</div><h2>Tailscale HTTPS</h2></div>
              <span id="tailscaleServeState" class="badge">Проверка…</span>
            </div>
            <p id="tailscaleServeDetail" class="muted small">Проверяем защищённый доступ вне дома.</p>
            <div id="tailscaleServeUrl" class="remote-url hidden"></div>
            <div class="remote-actions">
              <button id="tailscaleServeSetupBtn" class="button primary">Настроить HTTPS</button>
              <button id="tailscaleServeOpenBtn" class="button secondary hidden">Открыть через Tailscale HTTPS</button>
              <button id="tailscaleServeCopyBtn" class="pill hidden">Copy link</button>
            </div>
          </section>

"""
if 'id="remoteAccessCard"' not in h:
    h = replace_once(h, '        <aside class="side-column">\n', '        <aside class="side-column">\n' + remote_card, "remote card")
INDEX.write_text(h, encoding="utf-8")

# css
c = CSS.read_text(encoding="utf-8")
remote_css = r"""

/* Web 1.1.0 — Tailscale HTTPS */
.remote-card{border-color:rgba(74,222,128,.16)}
.remote-url{margin-top:10px;padding:12px 14px;border-radius:14px;background:rgba(2,8,23,.46);border:1px solid rgba(125,211,252,.18);font:600 12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all;color:#aee7ff}
.remote-actions{display:flex;flex-wrap:wrap;gap:9px;margin-top:12px}
.remote-actions .button{flex:1 1 180px}
.badge.secure{color:#9ef0bb;border-color:rgba(74,222,128,.25);background:rgba(34,197,94,.1)}
.badge.warning{color:#ffd59a;border-color:rgba(251,191,36,.24);background:rgba(245,158,11,.1)}
"""
if 'Web 1.1.0 — Tailscale HTTPS' not in c:
    c += remote_css
CSS.write_text(c, encoding="utf-8")

# app.js
j = APP.read_text(encoding="utf-8")
if 'serve: null,' not in j:
    j = replace_once(j, '    dashboard: null,\n', '    dashboard: null,\n    serve: null,\n', "state")

if "tailscaleServeState:" not in j:
    j = replace_once(
        j,
        "    connectionDot: $('connectionDot'), connectionText: $('connectionText'), systemStats: $('systemStats'),\n",
        "    connectionDot: $('connectionDot'), connectionText: $('connectionText'), systemStats: $('systemStats'),\n"
        "    tailscaleServeState: $('tailscaleServeState'), tailscaleServeDetail: $('tailscaleServeDetail'), tailscaleServeUrl: $('tailscaleServeUrl'),\n"
        "    tailscaleServeSetupBtn: $('tailscaleServeSetupBtn'), tailscaleServeOpenBtn: $('tailscaleServeOpenBtn'), tailscaleServeCopyBtn: $('tailscaleServeCopyBtn'),\n",
        "elements",
    )

remote_js = r"""
  function renderRemoteAccess(value) {
    state.serve = value || null;
    if (!els.tailscaleServeState) return;
    const installed = !!value?.installed;
    const online = !!value?.online;
    const configured = !!value?.configured;
    const conflict = !!value?.conflict;
    const secureHere = location.protocol === 'https:' && value?.dns && location.hostname.toLowerCase() === String(value.dns).toLowerCase();

    els.tailscaleServeState.className = 'badge';
    els.tailscaleServeSetupBtn.classList.remove('hidden');
    els.tailscaleServeOpenBtn.classList.add('hidden');
    els.tailscaleServeCopyBtn.classList.add('hidden');
    els.tailscaleServeUrl.classList.add('hidden');

    if (!installed) {
      els.tailscaleServeState.textContent = 'Не установлен';
      els.tailscaleServeState.classList.add('warning');
      els.tailscaleServeDetail.textContent = 'Установите Tailscale на ПК и войдите в tailnet.';
      els.tailscaleServeSetupBtn.disabled = true;
      return;
    }
    if (!online) {
      els.tailscaleServeState.textContent = 'Offline';
      els.tailscaleServeState.classList.add('warning');
      els.tailscaleServeDetail.textContent = 'Tailscale установлен, но сейчас не подключён.';
      els.tailscaleServeSetupBtn.disabled = true;
      return;
    }
    if (conflict) {
      els.tailscaleServeState.textContent = 'Занято';
      els.tailscaleServeState.classList.add('warning');
      els.tailscaleServeDetail.textContent = value?.detail || 'Tailscale Serve уже используется другой конфигурацией.';
      els.tailscaleServeSetupBtn.disabled = true;
      return;
    }

    els.tailscaleServeSetupBtn.disabled = false;
    if (configured && value?.https_url) {
      els.tailscaleServeState.textContent = secureHere ? 'HTTPS активен' : 'Готово';
      els.tailscaleServeState.classList.add('secure');
      els.tailscaleServeDetail.textContent = secureHere
        ? 'Вы уже используете защищённое Tailscale HTTPS-подключение.'
        : 'Защищённый адрес доступен внутри вашего tailnet и подходит для PWA.';
      els.tailscaleServeUrl.textContent = value.https_url;
      els.tailscaleServeUrl.classList.remove('hidden');
      els.tailscaleServeSetupBtn.classList.add('hidden');
      if (!secureHere) els.tailscaleServeOpenBtn.classList.remove('hidden');
      els.tailscaleServeCopyBtn.classList.remove('hidden');
      return;
    }

    els.tailscaleServeState.textContent = 'Не настроен';
    els.tailscaleServeDetail.textContent = value?.dns
      ? `Готово к настройке для ${value.dns}.`
      : 'Tailscale подключён. Настройте HTTPS одним нажатием.';
  }

  async function refreshRemoteAccess(force = false) {
    if (!state.token || !els.tailscaleServeState) return;
    try {
      const value = await api(`/api/tailscale/serve-status${force ? '?force=1' : ''}`);
      renderRemoteAccess(value);
    } catch (error) {
      els.tailscaleServeState.textContent = 'Ошибка';
      els.tailscaleServeState.className = 'badge warning';
      els.tailscaleServeDetail.textContent = error.message;
    }
  }

  async function enableTailscaleHTTPS() {
    if (!els.tailscaleServeSetupBtn) return;
    els.tailscaleServeSetupBtn.disabled = true;
    els.tailscaleServeSetupBtn.textContent = 'Настройка…';
    try {
      const value = await api('/api/tailscale/serve-enable', { method: 'POST' });
      renderRemoteAccess(value);
      toast('Tailscale HTTPS настроен');
    } catch (error) {
      toast(error.message);
      els.tailscaleServeDetail.textContent = error.message;
      await refreshRemoteAccess(true);
    } finally {
      els.tailscaleServeSetupBtn.textContent = 'Настроить HTTPS';
      if (!state.serve?.configured && !state.serve?.conflict) els.tailscaleServeSetupBtn.disabled = false;
    }
  }

  function openTailscaleHTTPS() {
    const url = state.serve?.https_url;
    if (url) window.location.assign(url);
  }

  async function copyTailscaleHTTPS() {
    const url = state.serve?.https_url;
    if (!url) return;
    try {
      await navigator.clipboard.writeText(url);
      toast('HTTPS-ссылка скопирована');
    } catch {
      toast('Скопируйте ссылку из карточки');
    }
  }

"""
if 'function renderRemoteAccess(value)' not in j:
    j = replace_once(j, "  function formatMetric(value, suffix = '')", remote_js + "  function formatMetric(value, suffix = '')", "remote js")

old_show = """  function showApp() {
    els.loginScreen.classList.add('hidden');
    els.app.classList.remove('hidden');
  }
"""
new_show = """  function showApp() {
    els.loginScreen.classList.add('hidden');
    els.app.classList.remove('hidden');
    refreshRemoteAccess(true);
  }
"""
j = replace_once(j, old_show, new_show, "showApp")

if "tailscaleServeSetupBtn?.addEventListener" not in j:
    anchor = "    els.loginBtn.addEventListener('click',loginWithPassword);els.password.addEventListener('keydown',e=>{if(e.key==='Enter')loginWithPassword();});els.connectionIdBtn.addEventListener('click',loginWithConnectionID);\n"
    j = replace_once(
        j,
        anchor,
        anchor + "    els.tailscaleServeSetupBtn?.addEventListener('click',enableTailscaleHTTPS);els.tailscaleServeOpenBtn?.addEventListener('click',openTailscaleHTTPS);els.tailscaleServeCopyBtn?.addEventListener('click',copyTailscaleHTTPS);\n",
        "bind remote",
    )

j = j.replace(
    "if(!document.hidden&&state.token)refreshDashboard({loadParameters:false});",
    "if(!document.hidden&&state.token){refreshDashboard({loadParameters:false});refreshRemoteAccess();}",
)
APP.write_text(j, encoding="utf-8")

# service worker
w = SW.read_text(encoding="utf-8")
w = w.replace("comfy-remote-web-v1.0.0", "comfy-remote-web-v1.1.0")
SW.write_text(w, encoding="utf-8")

# gui
g = GUI.read_text(encoding="utf-8")
g = g.replace('root.geometry("660x690")', 'root.geometry("660x780")')
g = g.replace('card.place(x=22, y=18, width=616, height=654)', 'card.place(x=22, y=18, width=616, height=744)')

gui_funcs = r"""
def refresh_https_access():
    try:
        value = server._tailscale_serve_status(force=True)
        if not value.get("installed"):
            https_var.set("Tailscale HTTPS: Tailscale не установлен")
            https_setup_btn.config(state="disabled")
            https_open_btn.config(state="disabled")
        elif not value.get("online"):
            https_var.set("Tailscale HTTPS: Tailscale Offline")
            https_setup_btn.config(state="disabled")
            https_open_btn.config(state="disabled")
        elif value.get("conflict"):
            https_var.set("Tailscale HTTPS: Serve уже занят другой конфигурацией")
            https_setup_btn.config(state="disabled")
            https_open_btn.config(state="disabled")
        elif value.get("configured") and value.get("https_url"):
            https_var.set("Tailscale HTTPS: " + value["https_url"])
            https_setup_btn.config(state="disabled")
            https_open_btn.config(state="normal")
        else:
            https_var.set("Tailscale HTTPS: не настроен")
            https_setup_btn.config(state="normal")
            https_open_btn.config(state="disabled")
    except Exception as exc:
        https_var.set(f"Tailscale HTTPS: {exc}")


def configure_https_access():
    https_setup_btn.config(state="disabled")
    https_var.set("Tailscale HTTPS: настройка…")
    def work():
        try:
            value = server._tailscale_serve_enable()
            message = "Tailscale HTTPS: " + str(value.get("https_url") or "готово")
        except Exception as exc:
            message = f"Tailscale HTTPS: ошибка — {exc}"
        root.after(0, lambda: (https_var.set(message), refresh_https_access()))
    threading.Thread(target=work, daemon=True).start()


def open_https_access():
    try:
        value = server._tailscale_serve_status(force=True)
        url = value.get("https_url")
        if not url:
            refresh_https_access()
            return
        os.startfile(url)
    except Exception:
        refresh_https_access()


"""
if 'def refresh_https_access()' not in g:
    g = replace_once(g, '\ndef configure_network():\n', '\n' + gui_funcs + '\ndef configure_network():\n', "gui funcs")

gui_panel = r"""
https_frame = tk.Frame(card, bg="white")
https_frame.pack(fill="x", padx=30, pady=(4, 4))
https_var = tk.StringVar(value="Tailscale HTTPS: проверка…")
tk.Label(https_frame, textvariable=https_var, bg="white", fg="#2450a6", font=("Segoe UI", 9, "bold"), wraplength=540, justify="left").pack(anchor="w")
https_buttons = tk.Frame(https_frame, bg="white")
https_buttons.pack(anchor="w", pady=(6, 0))
https_setup_btn = tk.Button(https_buttons, text="Настроить Tailscale HTTPS", width=25, command=configure_https_access)
https_setup_btn.grid(row=0, column=0, padx=(0, 8))
https_open_btn = tk.Button(https_buttons, text="Открыть HTTPS", width=18, command=open_https_access, state="disabled")
https_open_btn.grid(row=0, column=1)

"""
if 'https_var = tk.StringVar' not in g:
    g = replace_once(g, 'network_frame = tk.Frame(card, bg="white")\n', gui_panel + 'network_frame = tk.Frame(card, bg="white")\n', "gui panel")

if 'refresh_https_access()\n' not in g.split('def refresh_labels():',1)[1].split('\ndef ',1)[0]:
    anchor = '    password_state.config(\n        text="Пароль задан ✓" if server.password_is_set() else "Пароль ещё не задан",\n        fg="#16803c" if server.password_is_set() else "#b15a00",\n    )\n'
    g = replace_once(g, anchor, anchor + '    try:\n        refresh_https_access()\n    except Exception:\n        pass\n', "gui refresh")

g = g.replace(
    "Для доступа вне дома используйте ZeroTier или Tailscale; сервер должен оставаться запущенным.",
    "Для доступа вне дома используйте Tailscale HTTPS: нажмите «Настроить Tailscale HTTPS». Сервер должен оставаться запущенным.",
)
GUI.write_text(g, encoding="utf-8")

print("Comfy Remote Web 1.1.0 / PCRemoteServer 6.5.0 patch applied")
