from pathlib import Path

root = Path('current_source')
server_path = root / 'windows' / 'server.py'
version_path = root / 'VERSION.txt'
server = server_path.read_text(encoding='utf-8')

old_import = 'from flask import Flask, jsonify, request, abort, send_file, Response\n'
new_import = 'from flask import Flask, jsonify, request, abort, send_file, send_from_directory, redirect, Response\n'
if old_import in server:
    server = server.replace(old_import, new_import, 1)
elif new_import not in server:
    raise SystemExit('Flask import marker missing')

app_marker = 'APP_DIR = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent\n'
resource_block = app_marker + 'RESOURCE_DIR = Path(getattr(sys, "_MEIPASS", APP_DIR))\nWEB_DIR = RESOURCE_DIR / "web"\n'
if 'WEB_DIR = RESOURCE_DIR / "web"' not in server:
    if app_marker not in server:
        raise SystemExit('APP_DIR marker missing')
    server = server.replace(app_marker, resource_block, 1)

if 'PCREMOTE_VERSION = "6.3.2"' in server:
    server = server.replace('PCREMOTE_VERSION = "6.3.2"', 'PCREMOTE_VERSION = "6.4.0"', 1)
elif 'PCREMOTE_VERSION = "6.4.0"' not in server:
    raise SystemExit('server version marker missing')

route_marker = '\ndef _status_payload():\n'
web_routes = r'''
# ---------------------------------------------------------------------------
# Comfy Remote Web / PWA 1.0.0
# ---------------------------------------------------------------------------

@app.get("/")
def comfy_web_root():
    return redirect("/web/", code=302)


@app.get("/web")
def comfy_web_redirect():
    return redirect("/web/", code=302)


@app.get("/web/")
def comfy_web_index():
    if not WEB_DIR.is_dir():
        return Response("Comfy Remote Web assets are missing.", status=503, content_type="text/plain; charset=utf-8")
    response = send_from_directory(WEB_DIR, "index.html", max_age=0)
    response.headers["Cache-Control"] = "no-cache"
    return response


@app.get("/web/<path:filename>")
def comfy_web_asset(filename):
    if not WEB_DIR.is_dir():
        abort(404)
    clean = str(filename or "").replace("\\", "/").lstrip("/")
    parts = Path(clean).parts
    if not clean or ".." in parts:
        abort(404)
    response = send_from_directory(WEB_DIR, clean, max_age=300)
    if clean in {"app.js", "styles.css", "sw.js", "manifest.webmanifest"}:
        response.headers["Cache-Control"] = "no-cache"
    if clean == "sw.js":
        response.headers["Service-Worker-Allowed"] = "/web/"
    return response


@app.get("/api/web/info")
def comfy_web_info():
    return jsonify({
        "ok": True,
        "web_version": "1.0.0",
        "server_version": PCREMOTE_VERSION,
        "path": "/web/",
        "pwa": True,
    })


@app.get("/api/comfy/result")
def comfy_web_result():
    """Authenticated streaming proxy for ComfyUI image/video/audio results.

    Browser media tags cannot attach the Bearer header themselves, so the web
    client fetches this endpoint as a protected blob. Range headers are passed
    through for large media files.
    """
    filename = Path(str(request.args.get("filename") or "")).name
    subfolder = str(request.args.get("subfolder") or "").replace("\\", "/").strip("/")
    folder_type = str(request.args.get("type") or "output").lower()
    if not filename or ".." in Path(subfolder).parts or folder_type not in {"input", "output", "temp"}:
        abort(400)

    url = _comfy_http_url("/view", {"filename": filename, "subfolder": subfolder, "type": folder_type})
    headers = {"Accept": "*/*", "Accept-Encoding": "identity", "User-Agent": "ComfyRemote-Web/1.0.0"}
    range_header = request.headers.get("Range")
    if range_header:
        headers["Range"] = range_header
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        upstream = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as exc:
        return jsonify({"ok": False, "error": f"ComfyUI media HTTP {exc.code}"}), exc.code
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)}), 502

    content_type = upstream.headers.get("Content-Type") or "application/octet-stream"
    status = int(getattr(upstream, "status", 200) or 200)
    passthrough = {}
    for key in ("Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"):
        value = upstream.headers.get(key)
        if value:
            passthrough[key] = value
    passthrough["Cache-Control"] = "private, max-age=60"

    def generate():
        try:
            while True:
                chunk = upstream.read(256 * 1024)
                if not chunk:
                    break
                yield chunk
        finally:
            try:
                upstream.close()
            except Exception:
                pass

    return Response(generate(), status=status, content_type=content_type, headers=passthrough)


'''
if 'def comfy_web_index()' not in server:
    if route_marker not in server:
        raise SystemExit('status route marker missing')
    server = server.replace(route_marker, '\n' + web_routes + route_marker, 1)

# Expose the web capability to existing clients without removing older flags.
server = server.replace('"aitoolkit_bridge": True,\n        },', '"aitoolkit_bridge": True,\n            "web_app": True,\n        },')
server = server.replace('"aitoolkit_bridge": True,\n        },\n    })', '"aitoolkit_bridge": True,\n            "web_app": True,\n        },\n    })')
server = server.replace('"api_version": 8', '"api_version": 9')

server_path.write_text(server, encoding='utf-8')

version = version_path.read_text(encoding='utf-8') if version_path.exists() else ''
lines = [line for line in version.splitlines() if not line.startswith('PCRemoteServer ') and not line.startswith('ComfyRemote Web ')]
lines += ['PCRemoteServer 6.4.0', 'ComfyRemote Web 1.0.0']
version_path.write_text('\n'.join(lines).strip() + '\n', encoding='utf-8')

changelog = root / 'CHANGELOG.md'
old = changelog.read_text(encoding='utf-8') if changelog.exists() else '# CHANGELOG\n\n'
entry = '''## ComfyRemote Web 1.0.0 / PCRemoteServer 6.4.0\n\n### Добавлено\n- PWA web-клиент по адресу `/web/`.\n- Вход тем же паролем PC Remote Server или через Connection ID.\n- Workflow picker, импорт JSON, image/video/audio inputs, output target.\n- Positive/Negative Prompt с live-синхронизацией в реальные workflow-ноды.\n- Advanced параметры, Generate, Stop, Random Seed, live progress/queue.\n- Галерея image/video/audio через защищённый streaming proxy.\n- Адаптивный Node Editor для scalar inputs.\n- Адаптация iPhone/iPad/desktop и установка на домашний экран как PWA.\n\n'''
if '## ComfyRemote Web 1.0.0' not in old:
    old = old.replace('# CHANGELOG\n\n', '# CHANGELOG\n\n' + entry, 1)
changelog.write_text(old, encoding='utf-8')
print('Integrated Comfy Remote Web 1.0.0 / PCRemoteServer 6.4.0')
