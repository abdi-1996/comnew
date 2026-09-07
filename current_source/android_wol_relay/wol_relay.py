from http.server import BaseHTTPRequestHandler, HTTPServer
import socket
import urllib.parse

MAC = "FC:9D:05:2A:5F:D4"
BROADCAST = "192.168.8.255"
WOL_PORT = 9
TOKEN = "pcremote-wake-2026"
LISTEN_PORT = 8877


def wake():
    mac = bytes.fromhex(MAC.replace(":", "").replace("-", ""))
    packet = b"\xff" * 6 + mac * 16
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(packet, (BROADCAST, WOL_PORT))
    finally:
        sock.close()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/ping":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"PC Remote WoL Relay OK")
            return
        if url.path == "/wake" and query.get("token", [""])[0] == TOKEN:
            wake()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Wake packet sent")
            return
        self.send_response(403)
        self.end_headers()
        self.wfile.write(b"Forbidden")

    def log_message(self, fmt, *args):
        return


print(f"PC Remote WoL Relay: 0.0.0.0:{LISTEN_PORT}")
HTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
