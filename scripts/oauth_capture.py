"""Temporary script to capture YouTube OAuth authorization code."""
import http.server
import urllib.parse
import webbrowser
import threading
import sys
import os

CODE_FILE = os.path.join(os.environ.get("TEMP", "/tmp"), "yt_oauth_code.txt")
CLIENT_ID = "973282908459-csdar2hgu7thg2j8uikgdq0pm2bvpv08.apps.googleusercontent.com"
SCOPE = "https://www.googleapis.com/auth/youtube"
PORT = 19876

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if "code" in qs:
            code = qs["code"][0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<h1>YouTube authorization successful!</h1><p>You can close this tab now.</p>")
            with open(CODE_FILE, "w") as f:
                f.write(code)
            print(f"GOT_CODE={code}")
            threading.Timer(1, lambda: os._exit(0)).start()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Waiting for OAuth callback...")

    def log_message(self, format, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
redirect = f"http://127.0.0.1:{PORT}"
auth_url = (
    f"https://accounts.google.com/o/oauth2/v2/auth"
    f"?client_id={CLIENT_ID}"
    f"&redirect_uri={urllib.parse.quote(redirect, safe='')}"
    f"&response_type=code"
    f"&scope={urllib.parse.quote(SCOPE, safe='')}"
    f"&access_type=offline"
    f"&prompt=consent"
)
print(f"Listening on {redirect}")
print(f"Opening browser for Google consent...")
webbrowser.open(auth_url)
server.serve_forever()
