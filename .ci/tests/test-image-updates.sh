#!/usr/bin/env bash
# image-updates.py against a registry served from fixtures/image-updates/ and
# the gh stub's issue tracker: what counts as a newer image under each
# versioning scheme and tag filter of the ruleset, and that the workflow keeps
# exactly one open issue per template and writes nothing when nothing changed.
# No test reaches a real registry or GitHub.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PATH="$ci_root/tests/stubs:$PATH"
export PATH
export STUB_LOG="$T/stub.log"
export STUB_GH_DIR="$T/gh"
export GITHUB_REPOSITORY=mdg-labs/hoserva-catalog
export GITHUB_STEP_SUMMARY="$T/summary"
export PYTHONDONTWRITEBYTECODE=1
export IMAGE_UPDATES_RULES="$fixtures/image-updates/rules.yaml"
mkdir "$STUB_GH_DIR"
: >"$STUB_LOG"
issues="$STUB_GH_DIR/issues.json"
writes="$STUB_GH_DIR/writes.log"
: >"$T/all-writes"

cp "$fixtures/image-updates/registry.json" "$T/registry.json"
python3 -I -u "$fixtures/image-updates/registry-server.py" "$T/registry.json" >"$T/registry.log" 2>&1 &
server_pid=$!
port=""
for _ in $(seq 1 50); do
  port="$(sed -n 's/^port \([0-9][0-9]*\)$/\1/p' "$T/registry.log" | head -n 1)"
  [ -z "$port" ] || break
  sleep 0.1
done
[ -n "$port" ] || t_fail "the test registry did not start"
export IMAGE_UPDATES_REGISTRY_BASE="http://127.0.0.1:$port"

# tpl <id> <service>=<image>... writes templates/<id>/compose.yaml.
tpl() {
  local id="$1" arg
  shift
  mkdir -p "$T/templates/$id"
  {
    echo "services:"
    for arg in "$@"; do
      printf '  %s:\n    image: %s\n' "${arg%%=*}" "${arg#*=}"
    done
    printf 'x-hoserva:\n  id: %s\n  docs: https://docs.example/%s\n' "$id" "$id"
  } >"$T/templates/$id/compose.yaml"
}

# run_updates runs the script and leaves its exit status in $rc and the
# writes it caused in $writes; every write is kept in $T/all-writes.
run_updates() {
  : >"$writes"
  rc=0
  python3 -I "$ci_root/image-updates.py" "$T/templates" >"$T/out" 2>&1 || rc=$?
  cat "$writes" >>"$T/all-writes"
}

# mutate <jq filter> edits the registry the server re-reads on every request.
mutate() {
  jq "$1" "$T/registry.json" >"$T/registry.new"
  mv "$T/registry.new" "$T/registry.json"
}

# seed <number> <label> <body> adds an open issue to the tracker, as a person
# or an earlier run would have.
seed() {
  [ -f "$issues" ] || echo '[]' >"$issues"
  jq --argjson n "$1" --arg l "$2" --arg b "$3" \
    '. + [{number: $n, title: "seeded", body: $b, state: "open", state_reason: null, labels: [{name: $l}], comments: []}]' \
    "$issues" >"$issues.new"
  mv "$issues.new" "$issues"
}

open_for() {
  jq -r --arg id "$1" '[.[] | select(.state == "open") | select(any(.labels[]; .name == "image-update")) | select(.body | startswith("<!-- image-update id=" + $id + " ")) | .number] | sort | join(" ")' "$issues"
}

field() { jq -r --argjson n "$1" ".[] | select(.number == \$n) | $2" "$issues"; }

marker() { field "$1" '.body | split("\n")[0]'; }

assert_open() {
  local id="$1" want="$2" got
  got="$(open_for "$id")"
  [ -n "$got" ] || t_fail "$id: no open issue"
  [ "$(wc -w <<<"$got")" -eq 1 ] || t_fail "$id: more than one open issue: $got"
  assert_eq "$(marker "$got")" "<!-- image-update id=$id $want -->" "$id marker"
}

assert_none() {
  assert_eq "$(open_for "$1")" "" "$1 must have no open issue"
}

# Issues the workflow does not own: one without the label, one with the label
# but no marker. Neither may ever be edited, commented on or closed.
seed 1 template-fix '<!-- image-update id=semver targets=app=1.2.4 -->
Filed by hand.'
seed 2 image-update 'Please update semver by hand.'
seed 3 template-request 'Add an app.'
cp "$issues" "$T/foreign.json"

tpl webtop "app=lscr.io/linuxserver/webtop:092de24e-ls318"
tpl sabnzbd "app=lscr.io/linuxserver/sabnzbd:5.1.3-ls275"
tpl prowlarr "app=lscr.io/linuxserver/prowlarr:5.1.3-ls275"
tpl jellyfin "app=lscr.io/linuxserver/jellyfin:12.1-ls51"
tpl inplace "app=lscr.io/linuxserver/inplace:5.1.2-ls270"
tpl semver "app=docker.io/org/semver:1.2.3"
tpl major "app=org/major:2.1.0"
tpl majoronly "app=org/majoronly:2.1.0"
tpl alpine "app=org/alpine:1.2.3-alpine"
tpl plain "app=org/plain:1.2.3"
tpl postgresql-18 "app=docker.io/library/postgres:18.6"
tpl postgresql-17 "app=postgres:17.11"
tpl digrebuild "app=org/digrebuild:2.0.1@sha256:$(printf 'a%.0s' $(seq 64))"
tpl digmix "a=org/digrebuild:2.0.1@sha256:$(printf 'a%.0s' $(seq 64))" "b=org/digversion:1.0.0@sha256:$(printf 'a%.0s' $(seq 64))"
tpl vapp "app=open.example/org/vapp:v3.5.2"
tpl multi "app=org/multi:1.0.0" "db=lscr.io/linuxserver/nzbget:2.0-ls9"
tpl current "app=org/current:4.0.0"

# The first run opens one labelled issue per outdated template, with its marker.
run_updates
assert_eq "$rc" 0 "first run exit status"
grep -qx 'LABEL image-update' "$writes" || t_fail "the missing label was not created"
assert_eq "$(grep -c "^CREATE" "$writes")" 11 "issues opened by the first run"
assert_eq "$(jq '[.[] | select(.number > 3)] | length' "$issues")" 11 "issue count"
assert_eq "$(jq -r '[.[] | select(.number > 3) | .labels[].name] | unique | join(",")' "$issues")" image-update "labels"

# A linuxserver.io image moves to the version tag `latest` points at, found
# past branch-prefixed tags with higher build numbers and across tag pages;
# a hash-shaped version needs no parsing.
assert_open webtop 'targets=app=a1b2c3d4-ls320'
# 5.1.3-ls275 -> 5.1.4-ls276 is a version change.
assert_open prowlarr 'targets=app=5.1.4-ls276'
# 5.1.3-ls275 -> 5.1.3-ls276 is a rebuild only: no issue.
assert_none sabnzbd
assert_none jellyfin
# Same-shape tags compare as numbers (1.10.0 above 1.9.0); release candidates
# and other suffixes are ignored.
assert_open semver 'targets=app=1.10.0'
# A newer first number is a new major, listed apart from the update.
assert_open major 'targets=app=2.1.1 majors=app=3.1.0'
assert_open majoronly 'targets= majors=app=3.0.0'
assert_eq "$(field "$(open_for majoronly)" .title)" 'majoronly: new major image version 3.0.0' "major-only title"
# A suffix never matches a different suffix, in either direction.
assert_open alpine 'targets=app=1.2.5-alpine'
assert_none plain
# A -<major> template never gets an issue for the next major, and keeps the
# update within its own major.
assert_none postgresql-18
assert_open postgresql-17 'targets=app=17.12'
# A digest pin: a changed digest alone is a rebuild (no issue), and is listed
# with the version change that does open one.
assert_none digrebuild
assert_open digmix "targets=a=2.0.1@sha256:$(printf 'b%.0s' $(seq 64)),b=1.0.1@sha256:$(printf 'c%.0s' $(seq 64))"
# The v prefix is part of the tag's shape, and a registry that needs no token works.
assert_open vapp 'targets=app=v3.5.3'
assert_none current
# One issue per template with every service in it.
assert_open multi 'targets=app=1.1.0,db=2.0-ls10'
assert_eq "$(field "$(open_for multi)" .title)" 'multi: new image version 1.1.0 and 1 more' "multi-service title"
grep -q 'https://docs.example/multi' <<<"$(field "$(open_for multi)" .body)" || t_fail "the image documentation is not linked"
grep -q 'Fixes #<n>' <<<"$(field "$(open_for multi)" .body)" || t_fail "the commit trailer is not stated"
grep -q 'x-hoserva.revision' <<<"$(field "$(open_for multi)" .body)" || t_fail "the revision step is not stated"
grep -q '^### Changes' "$GITHUB_STEP_SUMMARY" || t_fail "the job summary lists no changes"

# An immediate second run writes nothing at all.
run_updates
assert_eq "$rc" 0 "second run exit status"
assert_eq "$(cat "$writes")" "" "second run writes"

# An open issue whose targets moved only by a rebuild is edited in place: same
# number, new tags in title, body and marker, no comment, nothing
# closed, no new issue.
inplace_issue="$(open_for inplace)"
assert_open inplace 'targets=app=5.1.3-ls275'
mutate '.["lscr.io"]["linuxserver/inplace"].digests.latest = "=5.1.3-ls276"'
run_updates
assert_eq "$rc" 0 "in-place run exit status"
assert_eq "$(sed 's/ .*//' "$writes")" "PATCH" "an in-place edit is one PATCH"
grep -q "^PATCH #$inplace_issue {\"title\"" "$writes" || t_fail "the open issue was not edited"
assert_eq "$(open_for inplace)" "$inplace_issue" "same issue number"
assert_open inplace 'targets=app=5.1.3-ls276'
grep -q '5.1.3-ls276' <<<"$(field "$inplace_issue" .title)" || t_fail "the title still names the old tag"
assert_eq "$(field "$inplace_issue" '.comments | length')" 0 "in-place comments"
assert_eq "$(field "$inplace_issue" .state)" open "in-place state"
run_updates
assert_eq "$(cat "$writes")" "" "run after an in-place edit writes"

# A newer version supersedes the open issue: the new one is created first, then
# the old one gets the pointer and is closed as not planned, in that order.
# The same run carries a rebuild-only change for another service of multi.
old_semver="$(open_for semver)"
old_multi="$(open_for multi)"
mutate '.["docker.io"]["org/semver"].tags += ["1.11.0"]
  | .["docker.io"]["org/multi"].tags += ["1.2.0"]
  | .["lscr.io"]["linuxserver/nzbget"].tags += ["2.0-ls11"]
  | .["lscr.io"]["linuxserver/nzbget"].digests.latest = "=2.0-ls11"'
run_updates
assert_eq "$rc" 0 "supersede run exit status"
new_semver="$(open_for semver)"
[ "$new_semver" != "$old_semver" ] || t_fail "semver was not superseded"
assert_open semver 'targets=app=1.11.0'
create_line="$(grep -n "^CREATE #$new_semver semver" "$writes" | cut -d: -f1)"
comment_line="$(grep -n "^COMMENT #$old_semver Superseded by #$new_semver\.\$" "$writes" | cut -d: -f1)"
close_line="$(grep -n "^PATCH #$old_semver {\"state\":\"closed\",\"state_reason\":\"not_planned\"}\$" "$writes" | cut -d: -f1)"
if [ -z "$create_line" ] || [ -z "$comment_line" ] || [ -z "$close_line" ]; then
  t_fail "a supersede step is missing: $(cat "$writes")"
fi
if [ "$create_line" -ge "$comment_line" ] || [ "$comment_line" -ge "$close_line" ]; then
  t_fail "supersede steps out of order"
fi
assert_eq "$(field "$old_semver" .state)" closed "superseded issue state"
assert_eq "$(field "$old_semver" .state_reason)" not_planned "superseded issue reason"
assert_eq "$(field "$old_semver" '.comments | join("|")')" "Superseded by #$new_semver." "superseded issue comment"
new_multi="$(open_for multi)"
[ "$new_multi" != "$old_multi" ] || t_fail "a version change next to a rebuild must supersede, not edit"
assert_open multi 'targets=app=1.2.0,db=2.0-ls11'
assert_eq "$(field "$old_multi" .state_reason)" not_planned "superseded multi reason"
run_updates
assert_eq "$(cat "$writes")" "" "run after superseding writes"

# An open issue whose targets dev already pins, wholly or in part, is left
# untouched.
tpl devpin "app=org/devpin:1.4.0"
seed 800 image-update '<!-- image-update id=devpin targets=app=1.4.0 -->
Body.'
tpl halfpin "a=org/devpin:1.4.0" "b=org/halfpin:1.0.0"
seed 805 image-update '<!-- image-update id=halfpin targets=a=1.4.0,b=1.1.0 -->
Body.'
tpl dupes "app=org/dupes:1.0.0"
seed 810 image-update '<!-- image-update id=dupes targets=app=1.1.0 -->
Older.'
seed 811 image-update '<!-- image-update id=dupes targets=app=1.1.0 -->
Newer.'
cp "$issues" "$T/before.json"
run_updates
assert_eq "$rc" 0 "devpin run exit status"
assert_eq "$(open_for devpin)" 800 "devpin issue"
assert_eq "$(jq -c '.[] | select(.number == 800)' "$issues")" "$(jq -c '.[] | select(.number == 800)' "$T/before.json")" "devpin issue changed"
# Only part of the issue is pinned on dev, and what is left still matches it.
assert_eq "$(open_for halfpin)" 805 "halfpin issue"
# Two open issues for one template are reduced to the newest.
assert_eq "$(open_for dupes)" 811 "dupes survivor"
assert_eq "$(cat "$writes")" "COMMENT #810 Superseded by #811.
PATCH #810 {\"state\":\"closed\",\"state_reason\":\"not_planned\"}" "dupes writes"
assert_eq "$(field 810 .state_reason)" not_planned "dupes reason"

# A registry failure leaves the template's open issue alone and fails the run
# after every other template has been processed; so does a template that
# cannot be compared at all.
tpl a-broken "app=org/broken:1.0.0"
seed 820 image-update '<!-- image-update id=a-broken targets=app=1.0.1 -->
Body.'
tpl h-half "a=org/hone:1.0.0" "b=org/broken:1.0.0"
seed 830 image-update '<!-- image-update id=h-half targets=a=1.1.0,b=1.0.1 -->
Body.'
mutate '.["docker.io"]["org/hone"] = {"tags": ["1.0.0", "1.1.0"]}'
tpl b-missing "app=ghcr.io/org/missing:1.0.0"
# shellcheck disable=SC2016 # the literal text of an unresolvable image
tpl c-variable 'app=${IMAGE}'
tpl d-untagged "app=org/untagged:latest"
tpl e-older "app=lscr.io/linuxserver/older:5.1.4-ls280"
tpl f-unmatched "app=lscr.io/linuxserver/unmatched:1.0-ls1"
tpl g-unlisted "app=org/unlisted:9.9.9"
tpl z-last "app=org/znew:1.0.0"
mutate '.["docker.io"]["org/znew"] = {"tags": ["1.0.0", "1.0.1"]}'
run_updates
[ "$rc" -ne 0 ] || t_fail "a failed lookup must fail the run"
assert_eq "$(field 820 .state)" open "broken template's issue state"
assert_eq "$(field 820 '.comments | length')" 0 "broken template's issue comments"
if grep -q '#820' "$writes"; then t_fail "the broken template's issue was written to"; fi
# One failing service of two leaves the template alone, not read as "no update".
assert_eq "$(open_for h-half)" 830 "half-broken template's issue"
if grep -q '#830\|h-half' "$writes"; then t_fail "a template with a failed service was written to"; fi
assert_open z-last 'targets=app=1.0.1'
for id in a-broken h-half b-missing c-variable d-untagged e-older f-unmatched g-unlisted; do
  grep -q "$id" "$GITHUB_STEP_SUMMARY" || t_fail "$id is not listed in the job summary"
done
grep -q 'HTTP 500' "$GITHUB_STEP_SUMMARY" || t_fail "the registry failure is not in the job summary"
grep -q 'HTTP 404' "$GITHUB_STEP_SUMMARY" || t_fail "the unknown repository is not in the job summary"
grep -q 'no number to compare' "$GITHUB_STEP_SUMMARY" || t_fail "the incomparable tag is not in the job summary"
grep -q 'not newer than the pinned' "$GITHUB_STEP_SUMMARY" || t_fail "a latest older than the pin is not in the job summary"
grep -q 'matches none of the' "$GITHUB_STEP_SUMMARY" || t_fail "a latest that matches no version tag is not in the job summary"
grep -q 'is not in the registry' "$GITHUB_STEP_SUMMARY" || t_fail "an unlisted pinned tag is not in the job summary"
assert_none e-older
assert_none f-unmatched
assert_none g-unlisted
for id in a-broken h-half b-missing c-variable d-untagged e-older f-unmatched g-unlisted; do rm -r "${T:?}/templates/$id"; done

# A pointer comment that fails leaves two open issues, never none; the next
# run reduces them to the newest.
rm -r "$T/templates"
tpl partial "app=org/partial:1.0.0"
mutate '.["docker.io"]["org/partial"] = {"tags": ["1.0.0", "1.1.0"]}'
run_updates
first="$(open_for partial)"
mutate '.["docker.io"]["org/partial"].tags += ["1.2.0"]'
STUB_GH_FAIL=comment run_updates
[ "$rc" -ne 0 ] || t_fail "a failed comment must fail the run"
assert_eq "$(wc -w <<<"$(open_for partial)")" 2 "open issues after the failed comment"
assert_eq "$(field "$first" .state)" open "the old issue stays open when its pointer failed"
run_updates
assert_eq "$rc" 0 "recovery run exit status"
second="$(open_for partial)"
assert_eq "$(wc -w <<<"$second")" 1 "open issues after recovery"
[ "$second" -gt "$first" ] || t_fail "the newest issue must survive"
assert_eq "$(field "$first" .state_reason)" not_planned "recovered issue reason"

# The versioning ruleset. Each scheme and filter is exercised on its own images.
rm -r "$T/templates"
# The -ls<N> counter says nothing across versions (older versions can carry
# higher counters than the current build): the tag `latest` points at is found
# by digest, and a version change is decided on the version part.
tpl jackett "app=lscr.io/linuxserver/jackett:v0.24.2793-ls49"
tpl jellyfinreal "app=lscr.io/linuxserver/jellyfinreal:12.1ubu2604-ls51"
tpl reset "app=lscr.io/linuxserver/reset:3.0.0-ls400"
# The default exclude filter keeps 25 prerelease tags out of the probes.
tpl betas "app=lscr.io/linuxserver/betas:1.0.0-ls10"
# calver: the newest tag of any year is the update, and there is no major.
tpl calver "app=org/calver:2026.9.4"
# Nightly date tags of the N.N.N shape: dropped by a rule's exclude filter, and
# by the first number's width where no rule covers the image.
tpl kopia "app=org/kopia:0.23.1"
tpl nightly "app=org/nightly:0.23.1"
tpl incl "app=org/incl:1.0.0"
tpl excl "app=org/excl:1.0.0"
tpl prerel "app=org/prerel:1.0.0-rc1"
run_updates
assert_eq "$rc" 0 "ruleset run exit status"
assert_eq "$(grep -c "^CREATE" "$writes")" 10 "issues opened by the ruleset run"
assert_open jackett 'targets=app=v0.24.2798-ls50'
assert_open jellyfinreal 'targets=app=12.2ubu2604-ls52'
assert_open reset 'targets=app=3.1.0-ls2'
assert_open betas 'targets=app=1.0.1-ls11'
assert_open calver 'targets=app=2027.1.0'
assert_open kopia 'targets=app=0.23.2'
assert_open nightly 'targets=app=0.23.2'
assert_open incl 'targets=app=1.1.0'
assert_open excl 'targets=app=1.1.0'
assert_open prerel 'targets=app=1.0.0-rc2'
run_updates
assert_eq "$(cat "$writes")" "" "ruleset second run writes"
# A new nightly changes neither a major line nor any issue, run after run.
mutate '.["docker.io"]["org/kopia"].tags += ["20261006.0.1"] | .["docker.io"]["org/nightly"].tags += ["20261006.0.1"]'
run_updates
assert_eq "$rc" 0 "nightly run exit status"
assert_eq "$(cat "$writes")" "" "a nightly tag must not write"

# A change only in the major line edits the open issue in place; a new version
# within the major supersedes it.
tpl majedit "app=org/majedit:2.1.0"
run_updates
major_issue="$(open_for majedit)"
assert_open majedit 'targets= majors=app=3.0.0'
mutate '.["docker.io"]["org/majedit"].tags += ["3.1.0"]'
run_updates
assert_eq "$(sed 's/ .*//' "$writes")" "PATCH" "a major-only change is one PATCH"
assert_eq "$(open_for majedit)" "$major_issue" "major-only change keeps the issue"
assert_open majedit 'targets= majors=app=3.1.0'
assert_eq "$(field "$major_issue" '.comments | length')" 0 "major-only change comments"
run_updates
assert_eq "$(cat "$writes")" "" "run after a major-only edit writes"
mutate '.["docker.io"]["org/majedit"].tags += ["2.1.1"]'
run_updates
[ "$(open_for majedit)" != "$major_issue" ] || t_fail "a new same-major version must supersede"
assert_open majedit 'targets=app=2.1.1 majors=app=3.1.0'
assert_eq "$(field "$major_issue" .state_reason)" not_planned "superseded major-only issue"

# A rule with majors: false (a database server) reports no newer major, and
# still reports an update within the pinned major.
tpl dbonly "app=org/dbmajor:17.6"
tpl dbsame "app=org/dbmajor:17.5"
run_updates
assert_eq "$rc" 0 "database major run exit status"
assert_none dbonly
assert_open dbsame 'targets=app=17.6'
run_updates
assert_eq "$(cat "$writes")" "" "database major second run writes"
rm -r "${T:?}/templates/dbonly" "${T:?}/templates/dbsame"

# The first matching rule wins, and a rule added elsewhere changes nothing for
# the images another rule already covers.
{
  cat "$fixtures/image-updates/rules.yaml"
  printf '  - match: lscr.io/linuxserver/*\n    scheme: calver\n  - match: docker.io/org/unrelated\n    scheme: calver\n'
} >"$T/rules-extended.yaml"
IMAGE_UPDATES_RULES="$T/rules-extended.yaml" run_updates
assert_eq "$rc" 0 "extended ruleset exit status"
assert_eq "$(cat "$writes")" "" "writes under an extended ruleset"

# A pinned tag the rule cannot classify is a listed failure, never "no update",
# and an unreadable ruleset stops the run before anything is written.
tpl inclpin "app=org/inclpin:1.0.0"
: >"$GITHUB_STEP_SUMMARY"
run_updates
[ "$rc" -ne 0 ] || t_fail "a pin outside the include filter must fail the run"
grep -q "inclpin" "$GITHUB_STEP_SUMMARY" || t_fail "inclpin is not listed in the job summary"
grep -q "include filter" "$GITHUB_STEP_SUMMARY" || t_fail "the include filter is not named in the job summary"
assert_none inclpin
assert_eq "$(cat "$writes")" "" "writes next to an unclassifiable pin"
rm -r "${T:?}/templates/inclpin"
n=0
for bad in 'rules: [{match: "x/*", scheme: rolling}]' \
  'rules: [{match: "x/*", exclude: ["("]}]' \
  'rules: [{match: "x/*", exclud: ["a"]}]' \
  'rules: [{scheme: semver}]' \
  'ruless: []'; do
  n=$((n + 1))
  printf '%s\n' "$bad" >"$T/rules-bad-$n.yaml"
  IMAGE_UPDATES_RULES="$T/rules-bad-$n.yaml" run_updates
  [ "$rc" -ne 0 ] || t_fail "the ruleset $bad must stop the run"
  assert_eq "$(cat "$writes")" "" "writes under the ruleset $bad"
done
IMAGE_UPDATES_RULES="$T/missing.yaml" run_updates
[ "$rc" -ne 0 ] || t_fail "a missing ruleset must stop the run"

# A tag list longer than the page cap the check used to have (200 pages) is
# still walked; one beyond the cap is a listed failure, never "no update".
rm -r "$T/templates"
mutate '.["docker.io"]["org/biglist"] = {"pageSize": 1, "tags": (["1.0.0"] + [range(250) | "1.1.\(.)"])}'
tpl biglist "app=org/biglist:1.0.0"
run_updates
assert_eq "$rc" 0 "long tag list exit status"
assert_open biglist 'targets=app=1.1.249'
run_updates
assert_eq "$(cat "$writes")" "" "long tag list second run writes"
rm -r "$T/templates/biglist"
tpl capped "app=org/biglist:1.0.0"
IMAGE_UPDATES_MAX_PAGES=3 run_updates
[ "$rc" -ne 0 ] || t_fail "a tag list beyond the page cap must fail the run"
grep -q 'more than 3 pages of tags' "$T/out" || t_fail "the page cap is not named: $(cat "$T/out")"
assert_none capped
assert_eq "$(cat "$writes")" "" "writes next to a tag list beyond the cap"
rm -r "$T/templates/capped"

# A rate-limited registry (HTTP 429) is waited for, as long as Retry-After or a
# small backoff says and within a bounded budget; past it, a listed failure.
mutate '.["docker.io"]["org/limited"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 2, "retryAfter": "0"}
  | .["docker.io"]["org/backoff"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 2}
  | .["docker.io"]["org/stuck"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 1000, "retryAfter": "0"}
  | .["docker.io"]["org/slow"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 1000, "retryAfter": "100"}'
tpl limited "app=org/limited:1.0.0"
tpl backoff "app=org/backoff:1.0.0"
seed 840 image-update '<!-- image-update id=stuck targets=app=1.0.1 -->
Body.'
seed 841 image-update '<!-- image-update id=slow targets=app=1.0.1 -->
Body.'
tpl stuck "app=org/stuck:1.0.0"
tpl slow "app=org/slow:1.0.0"
tpl zfine "app=org/semver:1.2.3"
: >"$GITHUB_STEP_SUMMARY"
IMAGE_UPDATES_BACKOFF=0.01 run_updates
[ "$rc" -ne 0 ] || t_fail "a registry that stays rate-limited must fail the run"
assert_open limited 'targets=app=1.0.1'
assert_open backoff 'targets=app=1.0.1'
assert_open zfine 'targets=app=1.11.0'
grep -q 'stuck: .*HTTP 429' "$GITHUB_STEP_SUMMARY" || t_fail "the rate-limited image is not in the job summary"
grep -q 'slow: .*beyond this check' "$GITHUB_STEP_SUMMARY" || t_fail "a Retry-After beyond the budget is not in the job summary"
assert_eq "$(open_for stuck)" 840 "stuck template's issue"
assert_eq "$(open_for slow)" 841 "slow template's issue"
if grep -E '#84[01]|stuck|slow' "$writes"; then t_fail "a rate-limited template was written to"; fi
for id in limited backoff stuck slow zfine; do rm -r "${T:?}/templates/$id"; done

# A run past its time budget lists every template as not evaluated and writes
# nothing, instead of being killed by the job's timeout.
tpl late "app=org/limited:1.0.0"
IMAGE_UPDATES_RUN_BUDGET=0 run_updates
[ "$rc" -ne 0 ] || t_fail "an exhausted time budget must fail the run"
grep -q 'time budget is used up' "$T/out" || t_fail "the time budget is not named"
assert_eq "$(cat "$writes")" "" "writes after the time budget"
rm -r "$T/templates/late"

# A Retry-After that is not a finite, non-negative number is no wait to honour:
# the registry is retried after the small backoff, as with no header at all.
mutate '.["docker.io"]["org/nanwait"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 2, "retryAfter": "nan"}
  | .["docker.io"]["org/infwait"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 2, "retryAfter": "inf"}
  | .["docker.io"]["org/negwait"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 2, "retryAfter": "-5"}
  | .["docker.io"]["org/junkwait"] = {"tags": ["1.0.0", "1.0.1"], "throttle": 2, "retryAfter": "soon"}'
for id in nanwait infwait negwait junkwait; do tpl "$id" "app=org/$id:1.0.0"; done
IMAGE_UPDATES_BACKOFF=0.01 run_updates
assert_eq "$rc" 0 "unusable Retry-After run exit status"
if grep -q Traceback "$T/out"; then t_fail "a Retry-After that is not a number ended in a traceback: $(cat "$T/out")"; fi
for id in nanwait infwait negwait junkwait; do assert_open "$id" 'targets=app=1.0.1'; done
for id in nanwait infwait negwait junkwait; do rm -r "${T:?}/templates/$id"; done

# `latest` is found among the newest version tags of the listing (registries
# list in push order), never by the build number or by a tag shaped like the
# pinned one: commit-hash versions change shape with every build, and a counter
# that is higher on older builds must not hide the new one. Both lists below
# mirror ghcr.io/linuxserver: duckdns has 60 older hash builds with higher
# counters and 30 dotted versions, webtop 95 dotted versions before its hash
# builds and arch- and dev- tags pushed after the newest build.
mutate '.["lscr.io"]["linuxserver/duckdns"] = {"tags": (["latest"]
    + [range(1; 31) | "1.\(.)-ls\(.)"]
    + [range(0; 60) | "b\(1000 + .)cc-ls\(100 + .)"]
    + ["d860cc34-ls92", "e1f2a3b4-ls93"]), "digests": {"latest": "=e1f2a3b4-ls93"}}
  | .["lscr.io"]["linuxserver/webtop"] = {"tags": (["latest"]
    + [range(0; 95) | "4.\(.)-r0-ls\(. + 1)"]
    + ["375eb96f-ls311", "53802b0e-ls315", "502d4f96-ls317", "092de24e-ls318", "7ac1e90b-ls319",
       "amd64-7ac1e90b-ls319", "arm64v8-7ac1e90b-ls319", "dev-8bdc3535-ls16", "version-7ac1e90b"]),
    "digests": {"latest": "=7ac1e90b-ls319"}}'
rm -r "$T/templates"
tpl duckdns "app=lscr.io/linuxserver/duckdns:d860cc34-ls92"
tpl webtopnew "app=lscr.io/linuxserver/webtop:092de24e-ls318"
run_updates
assert_eq "$rc" 0 "hash-versioned linuxserver run exit status"
assert_open duckdns 'targets=app=e1f2a3b4-ls93'
assert_open webtopnew 'targets=app=7ac1e90b-ls319'
# A `latest` further back than the probes reach is a listed failure, and
# nothing is opened or closed for it.
mutate '.["lscr.io"]["linuxserver/deep"] = {"tags": (["latest", "1.0.0-ls9", "2.0.0-ls1"] + [range(0; 25) | "2.1.\(.)-ls\(. + 2)"]),
    "digests": {"latest": "=2.0.0-ls1"}}'
rm -r "$T/templates"
tpl deep "app=lscr.io/linuxserver/deep:1.0.0-ls9"
run_updates
[ "$rc" -ne 0 ] || t_fail "a latest beyond the probes must fail the run"
grep -q 'deep: .*latest matches none of the 20 newest version tags' "$T/out" || t_fail "the probe bound is not named: $(cat "$T/out")"
assert_none deep
assert_eq "$(cat "$writes")" "" "writes next to a latest beyond the probes"

# The catalog's own ruleset: kopia's nightlies and calver images.
rm -r "$T/templates"
tpl realkopia "app=docker.io/kopia/kopia:0.23.1"
tpl realha "app=ghcr.io/home-assistant/home-assistant:2026.9.4"
tpl realjackett "app=lscr.io/linuxserver/jackett:v0.24.2793-ls49"
tpl realpg "app=docker.io/library/postgres:18.6"
IMAGE_UPDATES_RULES="$ci_root/image-updates-rules.yaml" run_updates
assert_eq "$rc" 0 "catalog ruleset exit status"
assert_open realkopia 'targets=app=0.23.2'
assert_open realha 'targets=app=2027.1.0'
assert_open realjackett 'targets=app=v0.24.2798-ls50'
assert_none realpg
mutate '.["docker.io"]["kopia/kopia"].tags += ["20261006.0.7"]'
IMAGE_UPDATES_RULES="$ci_root/image-updates-rules.yaml" run_updates
assert_eq "$(cat "$writes")" "" "a kopia nightly under the catalog ruleset writes"

# Foreign issues were never edited, commented on or closed.
assert_eq "$(jq -c '[.[] | select(.number <= 3)]' "$issues")" "$(jq -c . "$T/foreign.json")" "foreign issues changed"
if grep -E '#[123] ' "$T/all-writes"; then t_fail "a foreign issue was written to"; fi

# An issue list that cannot be read stops the run before anything is written.
STUB_LOOKUP_FAIL=1 run_updates
[ "$rc" -ne 0 ] || t_fail "an unreadable issue list must fail the run"
assert_eq "$(cat "$writes")" "" "writes after an unreadable issue list"

echo "test-image-updates: ok"
