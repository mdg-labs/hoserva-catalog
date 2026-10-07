#!/usr/bin/env python3
"""Reads the x-hoserva block of catalog templates; applies none of the
checker's rules (`hoserva template lint` has already passed by the time
either command runs)."""

import datetime
import hashlib
import json
import os
import sys

import yaml

PLACEHOLDERS = {
    "path": "/placeholder",
    "port": "8080",
    "string": "placeholder",
    "secret": "placeholder",
    "timezone": "UTC",
    "device": "/dev/null",
}


def block(compose_path):
    with open(compose_path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    return doc["x-hoserva"]


def env_file(compose_path):
    """Prints NAME='value' for every input: its default, else a placeholder,
    so `docker compose config` can interpolate the file."""
    lines = []
    for name, spec in (block(compose_path).get("inputs") or {}).items():
        value = spec.get("default")
        if value is None:
            value = PLACEHOLDERS.get(spec.get("kind"), "placeholder")
        if isinstance(value, bool) or not isinstance(value, (str, int)):
            sys.exit(f"{compose_path}: input {name} has a default that is not a string or integer")
        value = str(value)
        if "'" in value or "\n" in value:
            sys.exit(f"{compose_path}: input {name} has a default an env file cannot hold")
        lines.append(f"{name}='{value}'")
    print("\n".join(lines))


def content_hash(template_dir):
    """SHA-256 over every file in the directory, sorted by path: for each
    one the relative path, NUL, the decimal length, NUL and the contents."""
    files = []
    for root, _, names in os.walk(template_dir):
        for name in names:
            full = os.path.join(root, name)
            files.append((os.path.relpath(full, template_dir).replace(os.sep, "/"), full))
    h = hashlib.sha256()
    for rel, full in sorted(files, key=lambda f: f[0].encode("utf-8")):
        with open(full, "rb") as f:
            data = f.read()
        h.update(rel.encode("utf-8") + b"\0" + str(len(data)).encode() + b"\0" + data)
    return h.hexdigest()


def index(catalog_dir, serial, ids):
    templates = []
    for template_id in sorted(ids):
        template_dir = os.path.join(catalog_dir, template_id)
        b = block(os.path.join(template_dir, "compose.yaml"))
        entry = {
            "id": b["id"],
            "revision": b["revision"],
            "title": b["title"],
            "categories": b["categories"],
        }
        if b.get("icon"):
            entry["icon"] = b["icon"]
        entry["docs"] = b["docs"]
        entry["contentHash"] = content_hash(template_dir)
        for key in ("maintainer", "description"):
            if b.get(key):
                entry[key] = b[key]
        templates.append(entry)
    generated = datetime.datetime.fromtimestamp(serial, datetime.timezone.utc)
    json.dump(
        {
            "schema": 1,
            "serial": serial,
            "generatedAt": generated.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "templates": templates,
        },
        sys.stdout,
        indent=2,
        ensure_ascii=False,
    )
    print()


def main(argv):
    if len(argv) == 3 and argv[1] == "env":
        env_file(argv[2])
    elif len(argv) >= 4 and argv[1] == "index":
        index(argv[2], int(argv[3]), argv[4:])
    else:
        sys.exit("usage: catalog.py env <compose.yaml> | index <catalog-dir> <serial> [<id>...]")


main(sys.argv)
