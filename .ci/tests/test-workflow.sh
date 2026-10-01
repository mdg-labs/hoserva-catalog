#!/usr/bin/env bash
# The workflow's structure: the needs chain from validation to build to
# deploy, the triggers, where the signing secret is reachable, and that the
# tooling tests and validation run on every pull request and push.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

workflows="$ci_root/../.github/workflows"
[ -d "$workflows" ] || t_fail "no workflows directory at $workflows"

python3 - "$workflows" "$ci_root/hoserva-version" <<'EOF'
import glob
import re
import sys

import yaml

wf_dir, pin_file = sys.argv[1], sys.argv[2]
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


pin = open(pin_file, encoding="utf-8").read().strip()
check(re.fullmatch(r"[0-9a-f]{40}", pin) is not None, "the Hoserva pin is not a full commit SHA")

files = glob.glob(wf_dir + "/*.yml") + glob.glob(wf_dir + "/*.yaml")
check(len(files) > 0, "no workflow files")

catalog = None
dco = None
for path in files:
    text = open(path, encoding="utf-8").read()
    doc = yaml.safe_load(text)
    for use in re.findall(r"^\s*-?\s*uses:\s*(\S+)", text, re.M):
        check(re.fullmatch(r".+@[0-9a-f]{40}", use) is not None, f"{path}: action not pinned by commit SHA: {use}")
    check("pull_request_target" not in (doc.get("on") or doc.get(True) or {}), f"{path}: uses pull_request_target")
    if "build" in doc["jobs"] and "deploy" in doc["jobs"]:
        catalog = (path, text, doc)
    if "dco" in doc["jobs"]:
        dco = (path, text, doc)

# The DCO check runs on every pull request and every dev push, runs the
# pull request's base copy of the script (a pull request cannot change the
# script that checks it), checks the real base and head, and holds no secret.
check(dco is not None, "no workflow with a dco job")
if dco is not None:
    _, dco_text, dco_doc = dco
    dco_on = dco_doc.get("on") or dco_doc.get(True)
    dco_job = dco_doc["jobs"]["dco"]
    dco_steps = dco_job["steps"]
    dco_runs = "\n".join(s.get("run", "") for s in dco_steps)
    check("pull_request" in dco_on and set(dco_on["pull_request"]["branches"]) == {"dev", "main"}, "dco does not run on pull requests to dev and main")
    check("push" in dco_on and dco_on["push"]["branches"] == ["dev"], "dco does not run on pushes to dev")
    check("pull_request_target" not in dco_on, "dco uses pull_request_target")
    check("if" not in dco_job, "the dco job is conditional")
    check(dco_doc["permissions"] == {"contents": "read"}, "dco permissions are not read-only")
    check("secrets." not in dco_text, "the dco workflow reads a secret")
    checkout = [s for s in dco_steps if str(s.get("uses", "")).startswith("actions/checkout@")]
    check(len(checkout) == 1 and checkout[0].get("with", {}).get("fetch-depth") == 0, "dco checkout is not a full-depth one")
    check("git show \"$BASE_SHA:.ci/check-dco.sh\"" in dco_runs, "dco does not take the base branch's copy of the script")
    check("github.event.pull_request.base.sha" in dco_text and "github.event.pull_request.head.sha" in dco_text and "github.event.before" in dco_text, "dco does not use the real pull request base and head and the push range")
    check(".ci/check-dco.sh" in dco_runs and "check-dco.sh\" \"$base\" \"$head\"" in dco_runs, "dco does not run check-dco.sh on a base and head")
    check("${{" not in dco_runs, "dco interpolates an expression into a run script")

check(catalog is not None, "no workflow with build and deploy jobs")
if catalog is None:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)

path, text, doc = catalog
jobs = doc["jobs"]
triggers = doc.get("on") or doc.get(True)


def needs(job):
    n = jobs[job].get("needs", [])
    return [n] if isinstance(n, str) else n


# Triggers.
check("pull_request" in triggers, "no pull_request trigger")
check(set(triggers["push"]["branches"]) == {"dev", "main"}, "push must run on dev and main")
check("workflow_dispatch" in triggers, "no workflow_dispatch trigger")

# The needs chain: nothing is built before validation, nothing released or
# deployed before the build, and the release comes before the Pages deploy.
check("validate" in needs("build"), "build does not need validate")
check("tooling-tests" in needs("build"), "build does not need the tooling tests")
check("build" in needs("release"), "release does not need build")
check("build" in needs("deploy"), "deploy does not need build")
check("release" in needs("deploy"), "deploy does not need release")
check("validate" not in jobs["validate"].get("needs", []) and not needs("validate"), "validate must run first")

# Validation and the tooling tests run on every change; publishing never on a PR.
for job in ("validate", "tooling-tests"):
    check("if" not in jobs[job], f"{job} is conditional")
for job in ("build", "release", "deploy"):
    check("event_name != 'pull_request'" in jobs[job].get("if", ""), f"{job} may run on a pull request")
for job in ("release", "deploy"):
    check("refs/heads/main" in jobs[job].get("if", ""), f"{job} is not limited to main")
check("refs/heads/main" not in jobs["build"].get("if", ""), "the dev dry run would not build")

# The jobs run the scripts the tests cover.
def runs(job):
    return "\n".join(s.get("run", "") for s in jobs[job]["steps"])


check(".ci/tests/run.sh" in runs("tooling-tests"), "tooling-tests does not run the tooling tests")
check(".ci/validate.sh" in runs("validate"), "validate does not run validate.sh")
check(re.search(r"\.ci/validate\.sh templates\s*$", runs("validate"), re.M) is not None, "validate.sh is not run on templates/")
check(".ci/check-layout.sh" in runs("validate"), "validate does not run check-layout.sh")
check(runs("validate").find(".ci/check-layout.sh") < runs("validate").find(".ci/validate.sh"), "check-layout.sh does not run before validate.sh")
check(".ci/build.sh" in runs("build"), "build does not run build.sh")
check(re.search(r"\.ci/build\.sh templates dist\s*$", runs("build"), re.M) is not None, "build.sh is not run on templates/ into dist")
check(".ci/sign.sh" in runs("build"), "build does not run sign.sh")
check(".ci/check-key.sh" in runs("build"), "build does not run check-key.sh")
check(".ci/release.sh" in runs("release"), "release does not run release.sh")
check(".ci/check-tip.sh" in runs("release"), "release does not run check-tip.sh")
check(".ci/check-tip.sh" in runs("deploy"), "deploy does not run check-tip.sh")

# The signing secret is reachable from the build job only.
check("secrets." not in str(doc.get("env", "")), "a workflow-level env reads a secret")
for name, job in jobs.items():
    uses_secret = "secrets." in str(job)
    check(uses_secret == (name == "build"), f"job {name}: secret access {'present' if uses_secret else 'absent'}")
check(text.count("secrets.HOSERVA_CATALOG_SIGNING_KEY") == 2 and text.count("secrets.") == 2, "unexpected secret references")

# Only the deploy job may write Pages or mint an id token, and only the
# release job may write contents.
check(doc["permissions"] == {"contents": "read"}, "workflow permissions are not read-only")
check(jobs["deploy"]["permissions"] == {"contents": "read", "pages": "write", "id-token": "write"}, "deploy permissions differ from Pages write")
check(jobs["release"]["permissions"] == {"contents": "write"}, "release permissions are not contents write alone")
for name, job in jobs.items():
    if name not in ("deploy", "release"):
        check("permissions" not in job, f"job {name} widens permissions")
check(text.count("contents: write") == 1, "contents: write appears outside the release job")

# Releases and Pages deploys share one concurrency group, never cancelled mid-run.
for name in ("release", "deploy"):
    conc = jobs[name].get("concurrency", {})
    check(conc.get("group") == "catalog-pages" and conc.get("cancel-in-progress") is False, f"{name} is not in the catalog-pages group")

# Release order: the downloaded archive is verified, then the serial guard and
# the tip check, then the release.
rsteps = jobs["release"]["steps"]
order = []
for s in rsteps:
    r = s.get("run", "")
    if str(s.get("uses", "")).startswith("actions/download-artifact@"):
        order.append("download")
    for key, script in (("verify", "verify.sh"), ("guard", "check-serial.sh"), ("tip", "check-tip.sh"), ("release", "release.sh")):
        if script in r:
            order.append(key)
check(order == ["download", "verify", "guard", "tip", "release"], f"release job order is {order}")

# Deploy order: serial guard, tip check, deploy, fetch-back.
steps = jobs["deploy"]["steps"]
idx = {}
for i, s in enumerate(steps):
    if "check-serial.sh" in s.get("run", ""):
        idx["guard"] = i
    if "check-tip.sh" in s.get("run", ""):
        idx["tip"] = i
    if str(s.get("uses", "")).startswith("actions/deploy-pages@"):
        idx["deploy"] = i
    if "check-published.sh" in s.get("run", ""):
        idx["fetchback"] = i
check(len(idx) == 4 and idx["guard"] < idx["tip"] < idx["deploy"] < idx["fetchback"], "deploy steps are not guard, tip check, deploy, fetch-back")

# Build order: build, key check, sign, verify, then upload.
steps = jobs["build"]["steps"]
order = []
for s in steps:
    r = s.get("run", "")
    for key, script in (("build", "build.sh"), ("key", "check-key.sh"), ("sign", "sign.sh"), ("verify", "verify.sh")):
        if script in r and key not in order:
            order.append(key)
    if str(s.get("uses", "")).startswith("actions/upload-"):
        order.append("upload")
check(order[:4] == ["build", "key", "sign", "verify"], f"build job order is {order}")
check(all(o == "upload" for o in order[4:]) and len(order) > 4, "nothing is uploaded after verification")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
EOF

echo "test-workflow: ok"
