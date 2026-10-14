#!/usr/bin/env python3
"""Local HTTP server for the QML suites (started by tests/run.sh).

data: URLs have opaque origins, so per-origin features (site settings,
permissions, Storage.clearDataForOrigin) need real http origins. This binds
127.0.0.1 on a free port, writes the port to argv[1] and serves until killed.
http://127.0.0.1:<port> and http://localhost:<port> are distinct origins and
both are secure contexts, so permission APIs are available on them.

GET <any path>?html=<markup>  serves <markup> as text/html.
GET <any path>                serves a page titled with the path.
Stdlib only.
"""
import http.server
import sys
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/favicon.ico":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if "html" in query:
            body = query["html"][0]
        else:
            body = "<title>%s</title><p>%s</p>" % (url.path, url.path)
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    with open(sys.argv[1] + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    import os
    os.replace(sys.argv[1] + ".tmp", sys.argv[1])
    server.serve_forever()


if __name__ == "__main__":
    main()
