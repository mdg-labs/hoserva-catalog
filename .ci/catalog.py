#!/usr/bin/env python3
"""Reads the x-hoserva block of catalog templates; applies none of the
checker's rules (`hoserva template lint` has already passed by the time
either command runs), except that `check-description` enforces the rule
only this catalog has: every template carries a short description."""

import datetime
import hashlib
import json
import os
import re
import sys

import yaml

MAX_SUMMARY = 300

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


def description_problem(compose_path):
    """Returns why the template's description does not meet the catalog's
    rule, or None. The first paragraph is the description with surrounding
    whitespace stripped, up to the first blank line (a line holding only
    spaces or tabs), measured in characters."""
    try:
        with open(compose_path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as e:
        return f"cannot read {compose_path}: {e}"
    b = doc.get("x-hoserva") if isinstance(doc, dict) else None
    if not isinstance(b, dict):
        return "compose.yaml has no x-hoserva block"
    description = b.get("description")
    if description is None:
        return "x-hoserva.description is missing"
    if not isinstance(description, str):
        return "x-hoserva.description is not text"
    description = description.strip()
    if not description:
        return "x-hoserva.description is empty"
    first = re.split(r"\n[ \t\r]*\n", description, maxsplit=1)[0].strip()
    if len(first) > MAX_SUMMARY:
        return (
            f"the first paragraph of x-hoserva.description is {len(first)} characters, "
            f"more than the {MAX_SUMMARY} allowed; end it at a blank line"
        )
    return None


def check_description(catalog_dir, ids):
    """Prints one line per template that fails, naming its id; exits non-zero
    if any does."""
    failed = False
    for template_id in ids:
        problem = description_problem(os.path.join(catalog_dir, template_id, "compose.yaml"))
        if problem:
            print(f"{template_id}: {problem}", file=sys.stderr)
            failed = True
    if failed:
        sys.exit(1)


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
    elif len(argv) >= 4 and argv[1] == "check-description":
        check_description(argv[2], argv[3:])
    else:
        sys.exit(
            "usage: catalog.py env <compose.yaml> | index <catalog-dir> <serial> [<id>...]"
            " | check-description <catalog-dir> <id>..."
        )


main(sys.argv)
