# PC Remote WoL Relay — Mi Pad 6

Текущая схема:

**iPhone → Tailscale → Mi Pad 6 → Wake-on-LAN → HOME-PC**

Параметры этой конфигурации:
- Tailscale Mi Pad: `100.125.69.37`
- Relay port: `8877`
- ПК MAC: `FC:9D:05:2A:5F:D4`
- Broadcast: `192.168.8.255`
- WoL UDP: `9`

## Запуск в Termux

```bash
pkg update
pkg install python -y
python wol_relay.py
```

Для проверки с iPhone при включённом Tailscale:

```text
http://100.125.69.37:8877/ping
```

В PC Remote 5.0 эти же данные можно изменить в **Настройки → Пробуждение ПК вне дома**.

Не публикуйте relay token. Для постоянной работы отключите ограничения батареи для Termux и Tailscale на Mi Pad.
