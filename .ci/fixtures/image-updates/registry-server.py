#!/usr/bin/env python3
"""A registry for the tooling tests: serves the tag lists, manifest digests and
token flow described by a JSON file, re-read on every request.

  {"<host>": {"<repo>": {"tags": [...], "pageSize": 3, "status": 500,
                         "throttle": 2, "retryAfter": "0",
                         "anonymous": true, "digests": {"<tag>": "sha256:..." | "=<other tag>"}}}}

throttle answers that many authenticated requests per repository with HTTP 429
(and a Retry-After header when retryAfter is set) before serving normally.

A tag with no entry in digests gets a digest derived from its name. URLs are
/<host>/v2/<repo>/..., so one server stands in for every registry host."""

import hashlib
import http.server
import json
import re
import sys
import urllib.parse

DATA = sys.argv[1]
THROTTLED = {}
ROUTE = re.compile(r"^/([^/]+)/v2/(.+)/(tags/list|manifests/(.+))$")


def digest_of(repo, name, tag):
    digests = repo.get("digests", {})
    target = digests.get(tag, "")
    if target.startswith("="):
        return digest_of(repo, name, target[1:])
    return target or "sha256:" + hashlib.sha256(f"{name}:{tag}".encode()).hexdigest()


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b"", headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, code, doc, headers=None):
        self.reply(code, json.dumps(doc).encode(), {"Content-Type": "application/json", **(headers or {})})

    def serve(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        with open(DATA, encoding="utf-8") as f:
            registry = json.load(f)
        parts = url.path.split("/")
        if len(parts) == 3 and parts[2] == "token":
            repo = query.get("scope", [""])[0].removeprefix("repository:").removesuffix(":pull")
            return self.json(200, {"token": "t-" + repo})
        route = ROUTE.match(url.path)
        if not route or route.group(1) not in registry:
            return self.json(404, {"errors": [{"code": "NAME_UNKNOWN"}]})
        host, name = route.group(1), route.group(2)
        repo = registry[host].get(name)
        if repo is None:
            return self.json(404, {"errors": [{"code": "NAME_UNKNOWN"}]})
        if not repo.get("anonymous") and self.headers.get("Authorization") != "Bearer t-" + name:
            realm = f"http://{self.headers['Host']}/{host}/token"
            challenge = f'Bearer realm="{realm}",service="stub",scope="repository:{name}:pull"'
            return self.json(401, {"errors": [{"code": "UNAUTHORIZED"}]}, {"WWW-Authenticate": challenge})
        if THROTTLED.get(name, 0) < repo.get("throttle", 0):
            THROTTLED[name] = THROTTLED.get(name, 0) + 1
            wait = {"Retry-After": repo["retryAfter"]} if "retryAfter" in repo else {}
            return self.json(429, {"errors": [{"code": "TOOMANYREQUESTS"}]}, wait)
        if repo.get("status"):
            return self.json(repo["status"], {"errors": [{"code": "UNAVAILABLE"}]})
        tags = repo["tags"]
        if route.group(3) == "tags/list":
            last = query.get("last", [None])[0]
            start = tags.index(last) + 1 if last else 0
            size = repo.get("pageSize", len(tags))
            page = tags[start : start + size]
            headers = {}
            if start + size < len(tags):
                more = urllib.parse.urlencode({"last": page[-1], "n": query.get("n", ["1000"])[0]})
                headers["Link"] = f'</{host}/v2/{name}/tags/list?{more}>; rel="next"'
            return self.json(200, {"name": name, "tags": page}, headers)
        tag = route.group(4)
        if tag not in tags and tag not in repo.get("digests", {}):
            return self.json(404, {"errors": [{"code": "MANIFEST_UNKNOWN"}]})
        return self.reply(200, b"", {"Docker-Content-Digest": digest_of(repo, name, tag)})

    do_GET = do_HEAD = serve

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(f"port {server.server_address[1]}", flush=True)
server.serve_forever()
