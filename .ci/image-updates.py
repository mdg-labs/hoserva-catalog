#!/usr/bin/env python3
"""Compares the image every template pins with what its registry publishes and
keeps one open `image-update` issue per outdated template in
$GITHUB_REPOSITORY (CONTRIBUTING.md, "Image updates"). It only reports: writing
the update stays a human or agent change made from upstream documentation.

Exit status is non-zero when any lookup or GitHub call failed, after every
other template has been processed. A template it could not evaluate is never
opened, edited or closed."""

import fnmatch
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

LABEL = "image-update"
LABEL_COLOR = "0e8a16"
NO_UPDATE_COMMENT = "No newer version is reported any more for this template; closing."
TAGS_PAGE = 1000
LSIO_PROBES = 20
CHANNEL_PROBES = 20
SCHEMES = ("linuxserver", "semver", "calver")
TIMEOUT = 20
RETRY_STATUS = (429, 503)
MAX_RETRIES = 4
WAIT_CAP = 60
IMAGE_WAIT_CAP = 120
RUN_WAIT_CAP = 600


def setting(name, default):
    """A limit with a test seam: the environment may lower or replace it."""
    try:
        return type(default)(os.environ.get(name, default))
    except ValueError:
        sys.exit(f"image-updates.py: {name} must be a {type(default).__name__}")


# A registry's `last` is one of its own tags, so a list can only be walked from
# its start, and the linuxserver rule needs the end of it (newest pushes): the
# whole list is walked. immich's machine-learning image alone holds 210 pages of
# pr- and commit- builds.
MAX_PAGES = setting("IMAGE_UPDATES_MAX_PAGES", 500)
BACKOFF = setting("IMAGE_UPDATES_BACKOFF", 2.0)
RUN_BUDGET = setting("IMAGE_UPDATES_RUN_BUDGET", 2700.0)

ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
REPO_RE = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$")
DOTTED_RE = re.compile(r"^v?\d+(?:\.\d+)+")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SERVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
LS_RE = re.compile(r"^(.+)-ls(\d+)$")
MAJOR_ID_RE = re.compile(r"-\d+$")
MARKER_RE = re.compile(r"<!-- image-update id=(\S+) targets=(\S*)(?: majors=(\S*))? -->")
RULES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "image-updates-rules.yaml")
ARCH_PREFIXES = {"amd64", "arm64v8", "arm32v7", "arm64", "armhf", "arm"}
DOCKER_HOSTS = {"docker.io", "index.docker.io", "registry-1.docker.io"}


class Failure(Exception):
    """A lookup or GitHub call that failed; the template it belongs to is skipped."""


class HttpFailure(Failure):
    def __init__(self, message, code, headers):
        super().__init__(message)
        self.code, self.headers = code, headers


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Ref:
    def __init__(self, host, repo, tag, digest):
        self.host, self.repo, self.tag, self.digest = host, repo, tag, digest

    @property
    def pinned(self):
        return self.tag + ("@" + self.digest if self.digest else "")


class Change:
    def __init__(self, kind, target, pinned):
        self.kind, self.target, self.pinned = kind, target, pinned


class Template:
    def __init__(self, id_, docs, images):
        self.id, self.docs, self.images = id_, docs, images


class Rule:
    """One versioning rule: which images it covers, the scheme that decides what
    is newer, and the tag filters applied before any comparison."""

    def __init__(self, match, scheme, include, exclude, majors, versions, channel, lookup):
        self.match, self.scheme, self.include, self.exclude, self.majors = match, scheme, include, exclude, majors
        self.versions, self.channel, self.lookup = versions, channel, lookup

    def covers(self, ref):
        return fnmatch.fnmatchcase(f"{ref.host}/{ref.repo}", self.match)


class Rules:
    def __init__(self, rules, default):
        self.rules, self.default = rules, default

    def for_ref(self, ref):
        return next((r for r in self.rules if r.covers(ref)), self.default)


def filters(where, items):
    if items is None:
        return []
    if not isinstance(items, list) or not all(isinstance(i, str) for i in items):
        raise ValueError(f"{where}: must be a list of regular expressions")
    out = []
    for item in items:
        try:
            out.append(re.compile(item))
        except re.error as e:
            raise ValueError(f"{where}: {item!r} is not a regular expression: {e}") from e
    return out


def lookup_of(where, spec, match):
    """The registry image a rule reads tags and manifests from instead of the
    pinned one, as (host, repository)."""
    lookup = spec.get("lookup")
    if lookup is None:
        return None
    if where == "defaults":
        raise ValueError(f"{where}.lookup: is set per rule, not in the defaults")
    if any(c in match for c in "*?["):
        raise ValueError(f"{where}.lookup: needs a `match` naming one image, not the pattern {match!r}")
    try:
        if not isinstance(lookup, str):
            raise Failure("not a string")
        ref = parse_ref(lookup + ":x")
    except Failure as e:
        raise ValueError(f"{where}.lookup: must be a registry image without a tag, such as docker.io/org/app ({e})") from e
    return ref.host, ref.repo


def build_rule(where, spec, match, fallback):
    if not isinstance(spec, dict):
        raise ValueError(f"{where}: must be a mapping")
    unknown = set(spec) - {"match", "scheme", "include", "exclude", "majors", "versions", "channel", "lookup"}
    if unknown:
        raise ValueError(f"{where}: unknown keys {sorted(unknown)}")
    scheme = spec.get("scheme", fallback.scheme if fallback else "semver")
    if scheme not in SCHEMES:
        raise ValueError(f"{where}: scheme {scheme!r} is none of {', '.join(SCHEMES)}")
    include = filters(f"{where}.include", spec.get("include")) or (fallback.include if fallback else [])
    exclude = (fallback.exclude if fallback else []) + filters(f"{where}.exclude", spec.get("exclude"))
    majors = spec.get("majors", fallback.majors if fallback else True)
    if not isinstance(majors, bool):
        raise ValueError(f"{where}.majors: must be true or false")
    versions = spec.get("versions", fallback.versions if fallback else True)
    if not isinstance(versions, bool):
        raise ValueError(f"{where}.versions: must be true or false")
    channel = spec.get("channel")
    if channel is not None:
        if where == "defaults":
            raise ValueError(f"{where}.channel: is set per rule, not in the defaults")
        if not isinstance(channel, str) or not TAG_RE.match(channel):
            raise ValueError(f"{where}.channel: must be a tag name")
        if scheme != "semver":
            raise ValueError(f"{where}.channel: only the semver scheme follows a channel, not {scheme}")
    return Rule(match, scheme, include, exclude, majors, versions, channel, lookup_of(where, spec, match))


def load_rules(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        raise ValueError(f"cannot read {path}: {e}") from e
    if not isinstance(doc, dict) or set(doc) - {"defaults", "rules"}:
        raise ValueError(f"{path}: must be a mapping with only `defaults` and `rules`")
    default = build_rule("defaults", doc.get("defaults") or {}, "*", None)
    rules = []
    for n, spec in enumerate(doc.get("rules") or [], 1):
        where = f"rules[{n}]"
        match = spec.get("match") if isinstance(spec, dict) else None
        if not isinstance(match, str) or not match:
            raise ValueError(f"{where}: `match` is a host/repository pattern")
        rules.append(build_rule(where, spec, match, default))
    return Rules(rules, default)


def parse_ref(image):
    if not isinstance(image, str):
        raise Failure(f"image {image!r} is not a string")
    name, _, digest = image.partition("@")
    if digest and not DIGEST_RE.match(digest):
        raise Failure(f"image {image}: the digest is not sha256:<64 hex digits>")
    first, sep, rest = name.partition("/")
    if sep and ("." in first or ":" in first or first == "localhost"):
        host, path = first, rest
    else:
        host, path = "docker.io", name
    if host in DOCKER_HOSTS:
        host = "docker.io"
    last = path.rsplit("/", 1)[-1]
    if ":" not in last:
        raise Failure(f"image {image}: no tag to compare")
    path, tag = path.rsplit(":", 1)
    if host == "docker.io" and "/" not in path:
        path = "library/" + path
    if not REPO_RE.match(path) or not TAG_RE.match(tag):
        raise Failure(f"image {image}: cannot be parsed as a registry reference")
    return Ref(host, path, tag, digest or None)


def shape(tag):
    return re.sub(r"\d+", "\0", tag)


def numbers(tag):
    return [int(n) for n in re.findall(r"\d+", tag)]


def strip_ls(tag):
    m = LS_RE.match(tag)
    return m.group(1) if m else tag


def is_version_tag(tag):
    m = LS_RE.match(tag)
    if not m:
        return False
    rest = m.group(1)
    head, dash, _ = rest.partition("-")
    return not (dash and (head in ARCH_PREFIXES or head.isalpha()))


class Registry:
    def __init__(self, override):
        self.override = override
        self.tokens = {}
        self.tag_lists = {}
        self.digests = {}
        self.deadline = time.monotonic() + RUN_BUDGET
        self.waited = {}
        self.waited_total = 0.0

    def base(self, host):
        if self.override:
            return f"{self.override}/{host}"
        return "https://registry-1.docker.io" if host == "docker.io" else f"https://{host}"

    def token(self, ref, challenge, base):
        if not challenge or not challenge.startswith("Bearer "):
            raise Failure("the registry asks for credentials this check does not have")
        fields = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        realm = fields.get("realm", "")
        if urllib.parse.urlsplit(realm).scheme != urllib.parse.urlsplit(base).scheme:
            raise Failure(f"token realm {realm} does not use the registry's scheme")
        query = urllib.parse.urlencode(
            {"service": fields.get("service", ""), "scope": f"repository:{ref.repo}:pull"}
        )
        body = self.fetch(f"{realm}?{query}", {}, (ref.host, ref.repo))[0]
        try:
            answer = json.loads(body)
            token = answer.get("token") or answer.get("access_token")
        except (ValueError, AttributeError) as e:
            raise Failure(f"token response from {realm}: {e}") from e
        if not token:
            raise Failure(f"token response from {realm} holds no token")
        return token

    def wait(self, failure, attempt, key, url):
        """How long to sleep before retrying, or a Failure when the registry asks
        for more than this check may spend on one wait, on one image or on the run."""
        try:
            seconds = float(failure.headers.get("Retry-After"))
        except (TypeError, ValueError):
            seconds = math.nan
        if not math.isfinite(seconds) or seconds < 0:
            seconds = BACKOFF * 2**attempt
        if (
            seconds > WAIT_CAP
            or self.waited.get(key, 0.0) + seconds > IMAGE_WAIT_CAP
            or self.waited_total + seconds > RUN_WAIT_CAP
            or time.monotonic() + seconds > self.deadline
        ):
            raise Failure(f"GET {url}: HTTP {failure.code}, and waiting {seconds:g}s more is beyond this check's budget")
        self.waited[key] = self.waited.get(key, 0.0) + seconds
        self.waited_total += seconds
        return seconds

    def fetch(self, url, headers, key, method="GET"):
        opener = urllib.request.build_opener(NoRedirect)
        for attempt in range(MAX_RETRIES + 1):
            if time.monotonic() > self.deadline:
                raise Failure(f"{method} {url}: the run's time budget is used up")
            req = urllib.request.Request(url, headers=headers, method=method)
            try:
                with opener.open(req, timeout=TIMEOUT) as resp:
                    return resp.read().decode("utf-8"), resp.headers
            except urllib.error.HTTPError as e:
                failure = HttpFailure(f"{method} {url}: HTTP {e.code}", e.code, e.headers)
                if e.code not in RETRY_STATUS or attempt == MAX_RETRIES:
                    raise failure from e
                time.sleep(self.wait(failure, attempt, key, url))
            except (urllib.error.URLError, OSError, ValueError) as e:
                raise Failure(f"{method} {url}: {e}") from e
        raise AssertionError("unreachable")

    def request(self, ref, url, headers=None, method="GET"):
        headers = dict(headers or {})
        key = (ref.host, ref.repo)
        for attempt in (0, 1):
            if key in self.tokens:
                headers["Authorization"] = "Bearer " + self.tokens[key]
            try:
                return self.fetch(url, headers, key, method)
            except HttpFailure as e:
                if e.code != 401 or attempt == 1:
                    raise
                self.tokens[key] = self.token(ref, e.headers.get("WWW-Authenticate"), self.base(ref.host))
        raise AssertionError("unreachable")

    def tags(self, ref):
        key = (ref.host, ref.repo)
        if key not in self.tag_lists:
            base = self.base(ref.host)
            url = f"{base}/v2/{ref.repo}/tags/list?n={TAGS_PAGE}"
            found = []
            for _ in range(MAX_PAGES):
                body, headers = self.request(ref, url)
                try:
                    page = json.loads(body).get("tags") or []
                except (ValueError, AttributeError) as e:
                    raise Failure(f"{url}: not a tag list: {e}") from e
                if not isinstance(page, list) or not all(isinstance(t, str) for t in page):
                    raise Failure(f"{url}: not a tag list")
                found += [t for t in page if TAG_RE.match(t)]
                link = re.match(r'\s*<([^>]*)>\s*;\s*rel="next"', headers.get("Link") or "")
                if not link:
                    break
                url = urllib.parse.urljoin(url, link.group(1))
                if urllib.parse.urlsplit(url).netloc != urllib.parse.urlsplit(base).netloc:
                    raise Failure(f"{ref.host}/{ref.repo}: the tag list continues on another host")
            else:
                raise Failure(f"{ref.host}/{ref.repo}: more than {MAX_PAGES} pages of tags")
            self.tag_lists[key] = found
        return self.tag_lists[key]

    def digest(self, ref, tag):
        key = (ref.host, ref.repo, tag)
        if key not in self.digests:
            url = f"{self.base(ref.host)}/v2/{ref.repo}/manifests/{tag}"
            _, headers = self.request(ref, url, {"Accept": ACCEPT}, "HEAD")
            digest = headers.get("Docker-Content-Digest") or ""
            if not DIGEST_RE.match(digest):
                raise Failure(f"{url}: no manifest digest")
            self.digests[key] = digest
        return self.digests[key]


def kind_of(new_tag, pinned_tag):
    return "version" if strip_ls(new_tag) != strip_ls(pinned_tag) else "rebuild"


def usable_tags(rule, ref, tags):
    """The tags the rule's filters let through. A filter the pinned tag itself
    matches does not exclude, so a pin on a prerelease line follows that line."""
    excludes = [rx for rx in rule.exclude if not rx.search(ref.tag)]
    if rule.include and not any(rx.search(ref.tag) for rx in rule.include):
        raise Failure(f"the pinned tag {ref.tag} does not match the rule's include filter")
    return [
        t
        for t in tags
        if not any(rx.search(t) for rx in excludes) and (not rule.include or any(rx.search(t) for rx in rule.include))
    ]


def newer_linuxserver(reg, rule, ref):
    """The version tag `latest` points at, found by digest. The -ls<N> build
    counter is only compared between builds of one version, and nothing else is
    assumed of it (it may restart, and versions may be commit hashes).

    linuxserver.io's registries (lscr.io, ghcr.io) list tags in the order they
    were pushed, and `latest` moves with each push, so it is one of the newest
    version tags in the listing: those are probed, newest first, and the number
    of probes is capped because the listing also holds years of tags. A
    `latest` further back than that is a listed failure."""
    pinned = LS_RE.match(ref.tag)
    if not pinned:
        raise Failure(f"{ref.tag} is not a <version>-ls<N> tag")
    pinned_version, pinned_ls = pinned.group(1), int(pinned.group(2))
    latest = reg.digest(ref, "latest")
    if reg.digest(ref, ref.tag) == latest:
        return None, None
    versions = [t for t in usable_tags(rule, ref, reg.tags(ref)) if is_version_tag(t)]
    probes = versions[::-1][:LSIO_PROBES]
    for tag in probes:
        if reg.digest(ref, tag) != latest:
            continue
        version, ls = LS_RE.match(tag).groups()
        if version == pinned_version:
            newer = int(ls) > pinned_ls
        elif DOTTED_RE.match(version) and DOTTED_RE.match(pinned_version):
            newer = numbers(version) > numbers(pinned_version)
        else:
            newer = True
        if not newer:
            raise Failure(f"latest is {tag}, which is not newer than the pinned {ref.tag}")
        return tag, None
    raise Failure(f"latest matches none of the {len(probes)} newest version tags")


def first_width(tag):
    return len(re.search(r"\d+", tag).group())


def newer_channel(reg, rule, ref):
    """semver, following a moving tag: for images that publish prereleases under
    plain version tags, so only the channel tag says which build is stable. The
    update is the version tag of the pinned shape, newer than the pin, that has
    the channel tag's digest; a larger first number is a major unless the rule
    sets `majors: false`. The newest candidates are probed, and a channel that
    matches none of them is a listed failure."""
    pinned = numbers(ref.tag)
    if not pinned:
        raise Failure(f"{ref.tag} has no number to compare")
    channel = reg.digest(ref, rule.channel)
    if reg.digest(ref, ref.tag) == channel:
        return None, None
    width = first_width(ref.tag)
    newer = sorted(
        (
            (numbers(t), t)
            for t in usable_tags(rule, ref, reg.tags(ref))
            if shape(t) == shape(ref.tag) and first_width(t) == width and numbers(t) > pinned
        ),
        reverse=True,
    )
    probes = [t for _, t in newer[:CHANNEL_PROBES]]
    for tag in probes:
        if reg.digest(ref, tag) != channel:
            continue
        if numbers(tag)[0] > pinned[0]:
            return None, tag if rule.majors else None
        return tag, None
    raise Failure(f"{rule.channel} matches none of the {len(probes)} newest tags newer than the pinned {ref.tag}")


def newer_numeric(reg, rule, ref):
    """semver: the newest tag with the pinned tag's first number is the update, a
    larger first number of the same width is a major unless the rule sets
    `majors: false`. calver: the first number
    is a year, so the newest tag of any year is the update and there is no major."""
    pinned = numbers(ref.tag)
    if not pinned:
        raise Failure(f"{ref.tag} has no number to compare")
    tags = reg.tags(ref)
    if ref.tag not in tags:
        raise Failure(f"the pinned tag {ref.tag} is not in the registry's tag list")
    width = first_width(ref.tag)
    same = [(numbers(t), t) for t in usable_tags(rule, ref, tags) if shape(t) == shape(ref.tag) and first_width(t) == width]
    if rule.scheme == "calver":
        update = max((c for c in same if c[0] > pinned), default=None)
        return update and update[1], None
    update = max((c for c in same if c[0][0] == pinned[0] and c[0] > pinned), default=None)
    major = max((c for c in same if c[0][0] > pinned[0]), default=None) if rule.majors else None
    return update and update[1], major and major[1]


def evaluate(reg, rules, ref):
    rule = rules.for_ref(ref)
    read = Ref(*rule.lookup, ref.tag, ref.digest) if rule.lookup else ref
    if not rule.versions:
        new_tag, major = None, None
    elif rule.scheme == "linuxserver":
        new_tag, major = newer_linuxserver(reg, rule, read)
    elif rule.channel:
        new_tag, major = newer_channel(reg, rule, read)
    else:
        new_tag, major = newer_numeric(reg, rule, read)
    if ref.digest:
        digest = reg.digest(read, new_tag or ref.tag)
        if new_tag:
            return Change(kind_of(new_tag, ref.tag), f"{new_tag}@{digest}", ref.pinned), major
        if digest != ref.digest:
            return Change("rebuild", f"{ref.tag}@{digest}", ref.pinned), major
        return None, major
    if new_tag:
        return Change(kind_of(new_tag, ref.tag), new_tag, ref.pinned), major
    return None, major


def load_templates(root):
    templates, problems = [], []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name, "compose.yaml")
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                doc = yaml.safe_load(f)
            block = doc["x-hoserva"]
            id_ = block["id"]
            if not isinstance(id_, str) or not ID_RE.match(id_):
                raise ValueError(f"id {id_!r} is not a template id")
            images = {}
            for service, spec in (doc.get("services") or {}).items():
                if "image" not in spec:
                    continue
                if not SERVICE_RE.match(str(service)):
                    raise ValueError(f"service name {service!r} is not usable in a marker")
                images[str(service)] = spec["image"]
            templates.append(Template(id_, str(block.get("docs", "")), images))
        except (OSError, yaml.YAMLError, KeyError, TypeError, AttributeError, ValueError) as e:
            problems.append(f"{name}: cannot read {path}: {e}")
    return templates, problems


def evaluate_template(reg, rules, tpl):
    changes, majors, pinned, problems = {}, {}, {}, []
    for service, image in tpl.images.items():
        try:
            ref = parse_ref(image)
            pinned[service] = ref.pinned
            change, major = evaluate(reg, rules, ref)
        except Failure as e:
            problems.append(f"{tpl.id}: service {service}: {e}")
            continue
        if change:
            changes[service] = change
        if major and not MAJOR_ID_RE.search(tpl.id):
            majors[service] = major
    return changes, majors, pinned, problems


def encode(mapping):
    return ",".join(f"{k}={v}" for k, v in mapping.items())


def decode(text):
    return dict(item.split("=", 1) for item in (text or "").split(",") if item)


def marker(tpl_id, changes, majors):
    text = f"<!-- image-update id={tpl_id} targets={encode({s: c.target for s, c in changes.items()})}"
    if majors:
        text += f" majors={encode(majors)}"
    return text + " -->"


def registry_page(ref):
    if ref.host == "docker.io":
        name = ref.repo.removeprefix("library/")
        return f"https://hub.docker.com/{'_' if ref.repo.startswith('library/') else 'r'}/{name}"
    if ref.host in ("ghcr.io", "lscr.io"):
        owner, _, package = ref.repo.partition("/")
        if package:
            return f"https://github.com/orgs/{owner}/packages/container/package/{urllib.parse.quote(package, safe='')}"
    return None


def title(tpl_id, changes, majors):
    if changes:
        ordered = sorted(changes.values(), key=lambda c: c.kind != "version")
        word, tags = "new image version", [c.target.split("@")[0] for c in ordered]
    else:
        word, tags = "new major image version", list(majors.values())
    text = f"{tpl_id}: {word} {tags[0]}"
    return text + f" and {len(tags) - 1} more" if len(tags) > 1 else text


def body(tpl, changes, majors):
    lines = [
        marker(tpl.id, changes, majors),
        "",
        f"A newer image version is available for the `{tpl.id}` template.",
        "",
    ]
    if changes:
        lines += ["| Service | Pinned | New | Change |", "| --- | --- | --- | --- |"]
        for service, change in changes.items():
            what = "new version" if change.kind == "version" else "rebuild of the pinned version"
            lines.append(f"| `{service}` | `{change.pinned}` | `{change.target}` | {what} |")
        if any(c.kind == "rebuild" for c in changes.values()):
            lines += [
                "",
                "A rebuild alone (the `-ls<N>` suffix or a digest) is no reason to update a template. "
                "It is listed so that the newest rebuild is the one pinned when the version is updated.",
            ]
        lines.append("")
    for service, tag in majors.items():
        lines += [
            f"New major version for `{service}`: `{tag}`. A new major can need migration steps "
            "(data, configuration, environment): read the upstream release notes before updating.",
            "",
        ]
    links = []
    for service, image in tpl.images.items():
        if service not in changes and service not in majors:
            continue
        page = registry_page(parse_ref(image))
        links.append(f"- Registry page of `{service}`: {page}" if page else f"- Image of `{service}`: `{image}`")
    lines += links + [f"- Image documentation: {tpl.docs}", ""]
    lines += [
        "### Updating the template",
        "",
        "Write the update from the image's upstream documentation "
        "(WRITING-TEMPLATES.md, \"Updating a template\").",
        "",
        "- Increase `x-hoserva.revision` by one in the same change.",
        "- When upstream changed something, add the page that documents it to the `# Written from` line.",
        "- Run the same local checks as for a new template.",
        "- End the commit message with the trailer `Fixes #<n>`, where `<n>` is this issue's number. "
        "The issue then closes when the commit reaches `main`.",
        "",
    ]
    return "\n".join(lines)


class GitHub:
    def __init__(self, repo):
        self.repo = repo
        self.label_ready = False

    def api(self, path, method="GET", data=None):
        cmd = ["gh", "api"] + (["--method", method] if method != "GET" else []) + [path]
        if data is not None:
            cmd += ["--input", "-"]
        try:
            proc = subprocess.run(
                cmd,
                input=json.dumps(data) if data is not None else None,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Failure(f"gh api {method} {path}: {e}") from e
        if proc.returncode != 0:
            raise Failure(f"gh api {method} {path}: {proc.stderr.strip()}")
        try:
            return json.loads(proc.stdout) if proc.stdout.strip() else None
        except ValueError as e:
            raise Failure(f"gh api {method} {path}: not JSON: {e}") from e

    def open_issues(self):
        found = []
        for page in range(1, 51):
            items = self.api(f"repos/{self.repo}/issues?state=open&labels={LABEL}&per_page=100&page={page}")
            if not isinstance(items, list):
                raise Failure("the issue list is not a list")
            for item in items:
                match = MARKER_RE.search(item.get("body") or "")
                if "pull_request" in item or not match:
                    continue
                found.append(
                    {
                        "number": item["number"],
                        "id": match.group(1),
                        "targets": decode(match.group(2)),
                        "majors": decode(match.group(3)),
                    }
                )
            if len(items) < 100:
                return sorted(found, key=lambda i: i["number"])
        raise Failure("more than 50 pages of open image-update issues")

    def ensure_label(self):
        if self.label_ready:
            return
        try:
            self.api(f"repos/{self.repo}/labels/{LABEL}")
        except Failure as e:
            if "404" not in str(e):
                raise
            self.api(
                f"repos/{self.repo}/labels",
                "POST",
                {"name": LABEL, "color": LABEL_COLOR, "description": "A template's image has a newer version"},
            )
        self.label_ready = True

    def create(self, tpl, changes, majors):
        self.ensure_label()
        made = self.api(
            f"repos/{self.repo}/issues",
            "POST",
            {"title": title(tpl.id, changes, majors), "body": body(tpl, changes, majors), "labels": [LABEL]},
        )
        return made["number"]

    def edit(self, number, tpl, changes, majors):
        self.api(
            f"repos/{self.repo}/issues/{number}",
            "PATCH",
            {"title": title(tpl.id, changes, majors), "body": body(tpl, changes, majors)},
        )

    def close(self, number, comment):
        self.api(f"repos/{self.repo}/issues/{number}/comments", "POST", {"body": comment})
        self.api(f"repos/{self.repo}/issues/{number}", "PATCH", {"state": "closed", "state_reason": "not_planned"})

    def supersede(self, old, new):
        self.close(old, f"Superseded by #{new}.")


def version_of(tag_and_digest):
    return strip_ls(tag_and_digest.split("@")[0])


def behind(pin, target):
    """True when the version dev pins is older than the target's; tags of another shape are not comparable."""
    pin, target = version_of(pin), version_of(target)
    return shape(pin) == shape(target) and numbers(pin) < numbers(target)


def ahead(pin, target):
    pin, target = version_of(pin), version_of(target)
    return shape(pin) == shape(target) and numbers(pin) > numbers(target)


def decide(pinned, changes, majors, keep):
    """One of none, create, edit, supersede, close, given the newest open issue (or None)."""
    wants = bool(majors) or any(c.kind == "version" for c in changes.values())
    if keep is None:
        return "create" if wants else "none"
    pending = {s: t for s, t in keep["targets"].items() if pinned.get(s) != t}
    held = [(pinned[s], t) for s, t in pending.items() if s in pinned]
    if not wants and any(behind(p, t) for p, t in held) and not any(ahead(p, t) for p, t in held):
        return "close"
    if not wants and any(ahead(p, t) for p, t in held):
        return "none"
    if not changes and not majors:
        return "none"
    new = {s: c.target for s, c in changes.items()}
    if new == pending and majors == keep["majors"]:
        return "none"
    version_diff = False
    for service, change in changes.items():
        if service in pending:
            version_diff |= version_of(change.target) != version_of(pending[service])
        else:
            version_diff |= change.kind == "version"
    version_diff |= any(service not in changes for service in pending)
    return "supersede" if version_diff else "edit"


def reconcile(gh, tpl, pinned, changes, majors, issues):
    keep = issues[-1] if issues else None
    action = decide(pinned, changes, majors, keep)
    notes = []
    if action == "close":
        for old in issues:
            gh.close(old["number"], NO_UPDATE_COMMENT)
            notes.append(f"closed #{old['number']}: no newer version reported")
        return notes
    if action in ("create", "supersede"):
        new = gh.create(tpl, changes, majors)
        notes.append(f"opened #{new}")
        for old in issues:
            gh.supersede(old["number"], new)
            notes.append(f"closed #{old['number']} as not planned")
        return notes
    if action == "edit":
        gh.edit(keep["number"], tpl, changes, majors)
        notes.append(f"updated #{keep['number']} in place")
    for old in issues[:-1]:
        gh.supersede(old["number"], keep["number"])
        notes.append(f"closed #{old['number']} as not planned")
    return notes


def main(argv):
    root = argv[1] if len(argv) > 1 else "templates"
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.match(r"^[\w.-]+/[\w.-]+$", repo):
        sys.exit("image-updates.py: GITHUB_REPOSITORY must be <owner>/<repo>")
    try:
        rules = load_rules(os.environ.get("IMAGE_UPDATES_RULES") or RULES_PATH)
    except ValueError as e:
        sys.exit(f"image-updates.py: {e}")
    gh = GitHub(repo)
    reg = Registry(os.environ.get("IMAGE_UPDATES_REGISTRY_BASE"))

    problems = []
    try:
        open_issues = gh.open_issues()
    except Failure as e:
        sys.exit(f"image-updates.py: cannot list the open issues: {e}")
    templates, load_problems = load_templates(root)
    problems += load_problems

    actions = []
    for tpl in templates:
        changes, majors, pinned, errors = evaluate_template(reg, rules, tpl)
        if errors:
            problems += errors
            continue
        issues = [i for i in open_issues if i["id"] == tpl.id]
        try:
            notes = reconcile(gh, tpl, pinned, changes, majors, issues)
        except Failure as e:
            problems.append(f"{tpl.id}: {e}")
            continue
        if notes:
            actions.append(f"- `{tpl.id}`: {', '.join(notes)}")

    lines = ["## Image updates", "", f"Checked {len(templates)} templates."]
    lines += ["", "### Changes", ""] + actions if actions else ["", "No issue was opened, changed or closed."]
    if problems:
        lines += ["", "### Not evaluated or failed", ""] + [f"- {p}" for p in problems]
    text = "\n".join(lines) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(text)
    return 1 if problems else 0


sys.exit(main(sys.argv))
