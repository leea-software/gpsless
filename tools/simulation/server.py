"""Loopback-only UI/API. One bounded simulation job runs at a time."""
import json
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
from urllib.parse import unquote, urlparse

from sim import DATA, HERE, GRAPH_PATH, catalog, create_simulation, write_json
from world import KyivGraph

JOB = {"state": "idle", "completed": 0, "total": 0, "results": [], "error": None}
LOCK = threading.Lock()
GRAPH = None


def run_job(options, count):
    global GRAPH
    try:
        if GRAPH is None:
            GRAPH = KyivGraph(GRAPH_PATH)
        fit = None
        if (DATA / "field-profile.json").exists():
            fit = json.loads((DATA / "field-profile.json").read_text())
        results = []
        for index in range(count):
            item = dict(options)
            if count > 1:
                item["seed"] = int(options.get("seed", 42)) + index // 3
                item["profile"] = ["ideal", "nominal", "stress"][index % 3]
                starts = [217386, 244659, 105914, 14702]
                item["startEdge"] = starts[(index // 3) % len(starts)]
            try:
                result = create_simulation(GRAPH, item, fit=fit)
            except Exception as error:
                result = {"error": str(error), "options": item}
            results.append(result)
            with LOCK:
                JOB.update({"completed": index + 1, "results": list(results)})
        write_json(DATA / "last-batch.json", results)
        with LOCK:
            state = "complete"
            if any("error" in result for result in results):
                state = "completed_with_errors"
            JOB["state"] = state
    except Exception as error:
        with LOCK:
            JOB.update({"state": "failed", "error": str(error)})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def valid_host(self):
        host = self.headers.get("Host", "")
        return host in (f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}")

    def reply(self, value, status=200):
        body = json.dumps(value, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.valid_host():
            self.reply({"error": "Invalid local host"}, 403)
            return
        path = unquote(urlparse(self.path).path)
        if path == "/api/runs":
            self.reply(catalog())
            return
        if path == "/api/job":
            with LOCK:
                snapshot = dict(JOB)
            self.reply(snapshot)
            return
        if path.startswith("/runs/"):
            root = DATA / "runs"
            relative = path.removeprefix("/runs/")
            allowed = ("replay.json", "summary.json", "scenario.json", "sensors.jsonl.gz", "engine.jsonl.gz", "truth.npz")
            if Path(relative).name not in allowed:
                self.reply({"error": "Unknown artifact"}, 404)
                return
        elif path.startswith("/vendor/three/"):
            root = HERE / "web/node_modules/three"
            relative = path.removeprefix("/vendor/three/")
        else:
            root = HERE / "web"
            relative = path.lstrip("/")
            if not relative:
                relative = "index.html"
            if relative not in ("index.html", "style.css", "app.js", "scene.js", "charts.js", "driving.js"):
                self.reply({"error": "Unknown page"}, 404)
                return
        file = (root / relative).resolve()
        if not file.is_relative_to(root.resolve()) or not file.is_file():
            self.reply({"error": "Artifact not found"}, 404)
            return
        content_type = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
        if file.name.endswith(".gz"):
            content_type = "application/gzip"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(file.stat().st_size))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            with file.open("rb") as stream:
                while chunk := stream.read(65536):
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_POST(self):
        origin = self.headers.get("Origin", "")
        expected = f"http://{self.headers.get('Host', '')}"
        if not self.valid_host() or origin != expected:
            self.reply({"error": "Only the local simulation page may create runs"}, 403)
            return
        if self.path != "/api/run" or self.headers.get("Content-Type") != "application/json":
            self.reply({"error": "Expected a simulation JSON request"}, 400)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                raise ValueError("Request too large or empty")
            options = json.loads(self.rfile.read(length))
            allowed = {"seed", "profile", "length", "speedKmh", "startEdge", "startOffset", "count"}
            if not isinstance(options, dict) or set(options) - allowed:
                raise ValueError("Unknown simulation options")
            count = int(options.pop("count", 1))
            if not 1 <= count <= 12:
                raise ValueError("Choose 1–12 trials")
            usage = sum(file.stat().st_size for file in (DATA / "runs").rglob("*") if file.is_file())
            if usage > 2_000_000_000:
                raise ValueError("Simulation storage exceeds 2 GB. Archive old build/simulation/runs folders before generating more.")
            with LOCK:
                if JOB["state"] == "running":
                    self.reply({"error": "A simulation job is already running"}, 409)
                    return
                JOB.update({"state": "running", "completed": 0, "total": count, "results": [], "error": None})
            threading.Thread(target=run_job, args=(options, count), daemon=True).start()
            self.reply({"state": "running"}, 202)
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            self.reply({"error": str(error)}, 400)


def serve(port):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"GPSLess Simulation Lab: http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
    finally:
        server.server_close()
