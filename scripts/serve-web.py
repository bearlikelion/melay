#!/usr/bin/env python3
"""Serve a Godot web export locally with cross-origin isolation headers.

Python's http.server does not send COOP and COEP, so a threaded Godot export loaded
from it dies with a SharedArrayBuffer error. This adds those headers, and the correct
MIME types for .wasm and .pck, so both threaded and single-threaded builds work.

    scripts/serve-web.py                       # serves demo/build/web on :8000
    scripts/serve-web.py --dir path --port 9000

Open http://localhost:8000, not http://<your LAN ip>:8000. SharedArrayBuffer needs a
secure context, which means localhost or https and nothing else.
"""

import argparse
import functools
import http.server
import pathlib
import socketserver
import sys

DEFAULT_DIR = pathlib.Path(__file__).resolve().parent.parent / "demo" / "build" / "web"


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".pck": "application/octet-stream",
        ".js": "text/javascript",
    }

    def send_head(self):
        # Serve foo.wasm.gz in place of foo.wasm when the client accepts it, matching
        # what the relay does in production so local testing exercises the same path.
        if "gzip" in self.headers.get("Accept-Encoding", ""):
            path = self.translate_path(self.path)
            if path.endswith("/"):
                path += "index.html"
            gz = path + ".gz"
            if pathlib.Path(gz).is_file():
                ctype = self.guess_type(path)
                try:
                    handle = open(gz, "rb")
                except OSError:
                    return super().send_head()
                size = pathlib.Path(gz).stat().st_size
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Encoding", "gzip")
                self.send_header("Vary", "Accept-Encoding")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                return handle
        return super().send_head()

    def end_headers(self):
        # Both are required, and they must be on the HTML document response, not just
        # on the wasm and pck files.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", default=str(DEFAULT_DIR), help="folder to serve")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    root = pathlib.Path(args.dir).resolve()
    if not root.is_dir():
        print(f"no such directory: {root}", file=sys.stderr)
        print("export the project first, for example:", file=sys.stderr)
        print('  cd demo && godot --headless --export-release "Web" build/web/index.html',
              file=sys.stderr)
        return 1
    if not (root / "index.html").exists():
        print(f"{root} has no index.html, so it is not a web export", file=sys.stderr)
        return 1

    handler = functools.partial(Handler, directory=str(root))
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", args.port), handler) as httpd:
        print(f"serving {root}")
        print(f"open http://localhost:{args.port}  (not the LAN address)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
