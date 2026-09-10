import json
import os
import shutil
import subprocess
import sys
import threading
import tempfile
import time
import tkinter as tk
import urllib.request
from pathlib import Path

STABLE_SERVER_DIRNAME = "PCRemoteServer"
STABLE_SERVER_EXE = "PCRemoteServer.exe"
STABLE_SERVER_PORT = 8765
FIREWALL_MARKER = f"firewall_{STABLE_SERVER_PORT}.ok"


def _same_path(a, b):
    try:
        return os.path.normcase(os.path.abspath(str(a))) == os.path.normcase(os.path.abspath(str(b)))
    except Exception:
        return False


def _write_startup_shortcut(target_exe, target_dir):
    """Create/update the per-user Startup shortcut without requiring admin."""
    try:
        startup = Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "PC Remote Server.lnk"
        ps = (
            '$ws = New-Object -ComObject WScript.Shell; '
            + f'$s = $ws.CreateShortcut("{str(startup).replace(chr(34), chr(39))}"); '
            + f'$s.TargetPath = "{str(target_exe).replace(chr(34), chr(39))}"; '
            + f'$s.WorkingDirectory = "{str(target_dir).replace(chr(34), chr(39))}"; '
            + '$s.WindowStyle = 7; $s.Save()'
        )
        subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except Exception:
        pass


def _ensure_firewall_rule(target_dir, port=STABLE_SERVER_PORT):
    """Create one port-based inbound firewall rule. UAC is requested only once."""
    marker = Path(target_dir) / FIREWALL_MARKER
    if marker.exists():
        return True
    rule_name = f"PC Remote Stable TCP {int(port)}"
    script = Path(tempfile.gettempdir()) / "PCRemote_Firewall_SelfInstall.ps1"
    script.write_text(
        "$ErrorActionPreference = 'Stop'\n"
        f"Get-NetFirewallRule -DisplayName '{rule_name}' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue\n"
        f"New-NetFirewallRule -DisplayName '{rule_name}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {int(port)} -Profile Any | Out-Null\n",
        encoding="utf-8-sig",
    )
    launcher = f'Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList \'-NoProfile -ExecutionPolicy Bypass -File "{script}"\''
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", launcher],
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        if result.returncode == 0:
            marker.write_text("ok", encoding="utf-8")
            return True
    except Exception:
        pass
    return False


def _stop_other_server_copies(current_pid):
    """Stop older PCRemoteServer copies before replacing the stable binary."""
    try:
        ps = (
            "Get-Process PCRemoteServer -ErrorAction SilentlyContinue | "
            + f"Where-Object {{ $_.Id -ne {int(current_pid)} }} | "
            + "Stop-Process -Force -ErrorAction SilentlyContinue"
        )
        subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        time.sleep(0.35)
    except Exception:
        pass


def bootstrap_stable_server():
    """Make a directly launched EXE behave like INSTALL_STABLE_SERVER.bat.

    Any downloaded/built PCRemoteServer.exe copies itself to the stable
    %LOCALAPPDATA% location, ensures the TCP firewall rule, relaunches the
    stable copy and exits. This removes the old requirement to run a BAT first.
    """
    if not getattr(sys, "frozen", False):
        return
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        return
    current = Path(sys.executable).resolve()
    target_dir = Path(local) / STABLE_SERVER_DIRNAME
    target_exe = target_dir / STABLE_SERVER_EXE
    if _same_path(current, target_exe):
        return

    try:
        target_dir.mkdir(parents=True, exist_ok=True)
        _stop_other_server_copies(os.getpid())

        # Preserve the last working password/settings in the stable directory.
        source_config = current.parent / "config.json"
        target_config = target_dir / "config.json"
        if source_config.exists() and not target_config.exists():
            shutil.copy2(source_config, target_config)

        shutil.copy2(current, target_exe)
        _ensure_firewall_rule(target_dir, STABLE_SERVER_PORT)
        _write_startup_shortcut(target_exe, target_dir)
        subprocess.Popen(
            [str(target_exe)],
            cwd=str(target_dir),
            creationflags=getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
        )
        raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        # If Windows blocks self-install for any reason, continue running this
        # copy so the GUI can still offer manual network repair.
        return


bootstrap_stable_server()

import server

server_thread = None


def copy(text):
    root.clipboard_clear()
    root.clipboard_append(text)
    root.update()


def refresh_labels():
    ip_value.config(text=server.get_local_ip())
    tail_ip, tail_dns, tail_online = server._tailscale_identity()
    tail_text = tail_ip or tail_dns or "не подключён"
    if tail_online and tail_text != "не подключён":
        tail_text += "  ✓"
    tailscale_value.config(text=tail_text)
    zero_ip, zero_online = server._zerotier_identity()
    zero_text = zero_ip or "не подключён"
    if zero_online and zero_text != "не подключён":
        zero_text += "  ✓"
    zerotier_value.config(text=zero_text)
    port_value.config(text=str(server.CONFIG["port"]))
    password_state.config(
        text="Пароль задан ✓" if server.password_is_set() else "Пароль ещё не задан",
        fg="#16803c" if server.password_is_set() else "#b15a00",
    )
    try:
        refresh_https_access()
    except Exception:
        pass


def save_password():
    value = password_entry.get()
    confirm = password_confirm_entry.get()
    if value != confirm:
        password_message.config(text="Пароли не совпадают", fg="#b3261e")
        return
    try:
        server.set_connection_password(value)
    except Exception as exc:
        password_message.config(text=str(exc), fg="#b3261e")
        return
    password_entry.delete(0, "end")
    password_confirm_entry.delete(0, "end")
    password_message.config(text="Пароль сохранён. Старые сессии отключены.", fg="#16803c")
    refresh_labels()


def startup_link_path():
    appdata = os.environ.get("APPDATA", "")
    return Path(appdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "PC Remote Server.lnk"


def autostart_target():
    if getattr(sys, "frozen", False):
        return Path(sys.executable)
    return Path(__file__).resolve().parent / "RUN.bat"


def refresh_autostart():
    enabled = startup_link_path().exists()
    autostart_var.set("Автозапуск: включён" if enabled else "Автозапуск: выключен")
    autostart_btn.config(text="Выключить автозапуск" if enabled else "Включить автозапуск")


def toggle_autostart():
    link = startup_link_path()
    try:
        if link.exists():
            link.unlink()
        else:
            target = autostart_target()
            link.parent.mkdir(parents=True, exist_ok=True)
            ps = (
                '$ws = New-Object -ComObject WScript.Shell; '
                + f'$s = $ws.CreateShortcut("{str(link).replace(chr(34), chr(39))}"); '
                + f'$s.TargetPath = "{str(target).replace(chr(34), chr(39))}"; '
                + f'$s.WorkingDirectory = "{str(target.parent).replace(chr(34), chr(39))}"; '
                + '$s.WindowStyle = 7; $s.Save()'
            )
            subprocess.run(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
                check=True,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
    except Exception as exc:
        autostart_var.set(f"Ошибка автозапуска: {exc}")
        return
    refresh_autostart()



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



def configure_network():
    """Open an elevated PowerShell helper for LAN, Tailscale and ZeroTier."""
    port = int(server.CONFIG.get("port", 8765))
    script = f"""$ErrorActionPreference = 'Continue' 
Get-NetConnectionProfile | Where-Object {{ $_.InterfaceAlias -match 'ZeroTier|Tailscale' }} | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
$names = @('PC Remote LAN {port}', 'PC Remote Tailscale {port}', 'PC Remote ZeroTier {port}')
foreach ($n in $names) {{ Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }}
New-NetFirewallRule -DisplayName 'PC Remote LAN {port}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {port} -RemoteAddress LocalSubnet -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'PC Remote Tailscale {port}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {port} -RemoteAddress 100.64.0.0/10 -Profile Any | Out-Null
$zt = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -match 'ZeroTier' -or $_.InterfaceDescription -match 'ZeroTier' }}
if ($zt) {{
  foreach ($a in $zt) {{
    New-NetFirewallRule -DisplayName 'PC Remote ZeroTier {port}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {port} -InterfaceAlias $a.Name -Profile Any -ErrorAction SilentlyContinue | Out-Null
  }}
}}
Write-Host 'PC Remote network configuration completed.'
Write-Host 'Allowed TCP port {port} for LAN, Tailscale and ZeroTier.'
Read-Host 'Press Enter to close'
"""
    try:
        ps1 = Path(tempfile.gettempdir()) / "PCRemote_Network_Setup.ps1"
        ps1.write_text(script, encoding="utf-8-sig")
        arg = f'-NoProfile -ExecutionPolicy Bypass -File "{ps1}"'
        command = f"Start-Process powershell.exe -Verb RunAs -ArgumentList '{arg}'"
        subprocess.Popen(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        network_message.config(text="Подтвердите запрос администратора Windows. После настройки нажмите «Обновить адреса».", fg="#2450a6")
    except Exception as exc:
        network_message.config(text=f"Не удалось открыть настройку сети: {exc}", fg="#b3261e")

def _probe_local_server(timeout=0.65):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{int(server.CONFIG.get('port', 8765))}/api/ping", timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
        return bool(payload.get("ok")), payload
    except Exception as exc:
        return False, {"error": str(exc)}


def _verify_started(attempt=0):
    ok, payload = _probe_local_server()
    if ok:
        status_var.set(f"Сервер запущен ✓ • v{payload.get('server_version', server.PCREMOTE_VERSION)} • порт {payload.get('port', server.CONFIG.get('port', 8765))}")
        start_btn.config(state="disabled")
        return
    if server_thread is not None and not server_thread.is_alive():
        status_var.set(f"Ошибка запуска сервера • порт {server.CONFIG.get('port', 8765)} не слушается")
        start_btn.config(state="normal")
        return
    if attempt < 8:
        root.after(450, lambda: _verify_started(attempt + 1))
    else:
        status_var.set(f"Сервер не ответил на локальную проверку • нажмите «Запустить сервер»")
        start_btn.config(state="normal")


def start():
    global server_thread
    ok, payload = _probe_local_server(timeout=0.25)
    if ok:
        status_var.set(f"Сервер уже работает ✓ • v{payload.get('server_version', '?')} • порт {payload.get('port', server.CONFIG.get('port', 8765))}")
        start_btn.config(state="disabled")
        return
    if server_thread and server_thread.is_alive():
        return
    status_var.set("Запуск сервера…")
    start_btn.config(state="disabled")
    server_thread = threading.Thread(target=server.run_server, daemon=True)
    server_thread.start()
    root.after(350, lambda: _verify_started(0))


root = tk.Tk()
root.title(f"PC Remote Server {server.PCREMOTE_VERSION}")
root.geometry("660x780")
root.resizable(False, False)
root.configure(bg="#eef5ff")

card = tk.Frame(root, bg="white", highlightthickness=1, highlightbackground="#d5e5ff")
card.place(x=22, y=18, width=616, height=744)

tk.Label(card, text="PC Remote Server", bg="white", fg="#173569", font=("Segoe UI", 22, "bold")).pack(pady=(18, 3))
tk.Label(card, text="Задайте свой пароль — на iPhone для входа нужен только он.", bg="white", fg="#617493", font=("Segoe UI", 10)).pack()

info = tk.Frame(card, bg="white")
info.pack(fill="x", padx=30, pady=(16, 8))
for row, label in enumerate(("LAN", "Порт", "Tailscale", "ZeroTier")):
    tk.Label(info, text=label, bg="white", fg="#31445f", font=("Segoe UI", 10, "bold")).grid(row=row, column=0, sticky="w", pady=5)
ip_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
ip_value.grid(row=0, column=1, sticky="w", padx=18)
port_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
port_value.grid(row=1, column=1, sticky="w", padx=18)
tailscale_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
tailscale_value.grid(row=2, column=1, sticky="w", padx=18)
zerotier_value = tk.Label(info, text="", bg="white", fg="#31445f", font=("Consolas", 11))
zerotier_value.grid(row=3, column=1, sticky="w", padx=18)

password_card = tk.Frame(card, bg="#f4f8ff", highlightthickness=1, highlightbackground="#c8dbff")
password_card.pack(fill="x", padx=30, pady=(8, 8))

tk.Label(password_card, text="Пароль подключения", bg="#f4f8ff", fg="#173569", font=("Segoe UI", 11, "bold")).grid(row=0, column=0, sticky="w", padx=14, pady=(12, 4))
password_state = tk.Label(password_card, text="", bg="#f4f8ff", fg="#617493", font=("Segoe UI", 9, "bold"))
password_state.grid(row=0, column=1, sticky="e", padx=14, pady=(12, 4))

tk.Label(password_card, text="Новый пароль", bg="#f4f8ff", fg="#516780", font=("Segoe UI", 9)).grid(row=1, column=0, sticky="w", padx=14, pady=4)
password_entry = tk.Entry(password_card, show="•", width=30, font=("Segoe UI", 11))
password_entry.grid(row=1, column=1, sticky="ew", padx=14, pady=4)

tk.Label(password_card, text="Повторите", bg="#f4f8ff", fg="#516780", font=("Segoe UI", 9)).grid(row=2, column=0, sticky="w", padx=14, pady=4)
password_confirm_entry = tk.Entry(password_card, show="•", width=30, font=("Segoe UI", 11))
password_confirm_entry.grid(row=2, column=1, sticky="ew", padx=14, pady=4)

save_password_btn = tk.Button(password_card, text="Сохранить пароль", command=save_password, font=("Segoe UI", 10, "bold"))
save_password_btn.grid(row=3, column=1, sticky="e", padx=14, pady=(6, 8))
password_message = tk.Label(password_card, text="", bg="#f4f8ff", fg="#617493", font=("Segoe UI", 9), wraplength=500, justify="left")
password_message.grid(row=4, column=0, columnspan=2, sticky="w", padx=14, pady=(0, 10))
password_card.columnconfigure(1, weight=1)

buttons = tk.Frame(card, bg="white")
buttons.pack(pady=(8, 8))
start_btn = tk.Button(buttons, text="Запустить сервер", width=20, font=("Segoe UI", 10, "bold"), command=start)
start_btn.grid(row=0, column=0, padx=7)
tk.Button(buttons, text="Обновить адреса", width=20, command=refresh_labels).grid(row=0, column=1, padx=7)


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

network_frame = tk.Frame(card, bg="white")
network_frame.pack(pady=(2, 6))
tk.Button(network_frame, text="Настроить LAN / Tailscale / ZeroTier", width=36, command=configure_network).pack()
network_message = tk.Label(card, text="", bg="white", fg="#617493", font=("Segoe UI", 9), wraplength=540, justify="center")
network_message.pack(pady=(0, 5))

status_var = tk.StringVar(value=f"Сервер ещё не запущен • v{server.PCREMOTE_VERSION}")
tk.Label(card, textvariable=status_var, bg="white", fg="#2450a6", font=("Segoe UI", 10, "bold")).pack()

auto_frame = tk.Frame(card, bg="white")
auto_frame.pack(pady=(10, 2))
autostart_var = tk.StringVar(value="Автозапуск: проверка...")
tk.Label(auto_frame, textvariable=autostart_var, bg="white", fg="#506783", font=("Segoe UI", 9, "bold")).grid(row=0, column=0, padx=8)
autostart_btn = tk.Button(auto_frame, text="Включить автозапуск", command=toggle_autostart)
autostart_btn.grid(row=0, column=1, padx=8)

tk.Label(
    card,
    text="После смены пароля старые подключения автоматически перестают работать. Для доступа вне дома используйте Tailscale HTTPS: нажмите «Настроить Tailscale HTTPS». Сервер должен оставаться запущенным.",
    bg="white",
    fg="#6a7d9b",
    font=("Segoe UI", 9),
    wraplength=520,
    justify="center",
).pack(pady=12)

refresh_labels()
refresh_autostart()
start()
root.mainloop()
