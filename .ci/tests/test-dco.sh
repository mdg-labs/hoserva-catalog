#!/usr/bin/env bash
# check-dco.sh against throwaway git repositories: a signed range passes, an
# unsigned commit, a mismatched sign-off and every range that cannot be
# walked fail, and merge commits are skipped while the commits they merge
# are still checked.
# shellcheck source=helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

script="$ci_root/check-dco.sh"
zero=0000000000000000000000000000000000000000

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Jane GIT_AUTHOR_EMAIL=jane@example.com
export GIT_COMMITTER_NAME=Jane GIT_COMMITTER_EMAIL=jane@example.com

repo="$T/repo"
git init -q -b main "$repo"
cd "$repo"

# commit <signed|unsigned> <file>: one commit touching <file>.
commit() {
  echo "$2 $RANDOM" >"$2"
  git add "$2"
  if [ "$1" = signed ]; then
    git commit -q -s -m "change $2"
  else
    git commit -q -m "change $2"
  fi
}

commit signed root
root="$(git rev-parse HEAD)"

# A signed range passes.
commit signed a
commit signed b
head_signed="$(git rev-parse HEAD)"
expect_ok "$script" "$root" "$head_signed"
grep -q "2 commit(s) checked" "$T/out" || t_fail "the signed range did not check both commits"

# The same range given as a new branch's push (all-zero base) passes too, and
# walks every commit reachable from head.
expect_ok "$script" "$zero" "$head_signed"
grep -q "3 commit(s) checked" "$T/out" || t_fail "the all-zero base did not check every reachable commit"

# An unsigned commit anywhere in the range fails and is named.
commit unsigned c
unsigned="$(git rev-parse HEAD)"
commit signed d
head_unsigned="$(git rev-parse HEAD)"
expect_fail "$script" "$root" "$head_unsigned"
grep -q "$unsigned" "$T/out" || t_fail "the unsigned commit is not named"
grep -q "no Signed-off-by trailer" "$T/out" || t_fail "the failure does not say why"
expect_fail "$script" "$zero" "$head_unsigned"

# A range that starts after the unsigned commit is signed again.
expect_ok "$script" "$unsigned" "$head_unsigned"

# A sign-off by someone other than the author does not count.
git checkout -q -b other "$root"
echo x >x
git add x
git commit -q -m "change x" -m "Signed-off-by: Someone Else <else@example.com>"
expect_fail "$script" "$root" "$(git rev-parse HEAD)"
grep -q "does not match its author email" "$T/out" || t_fail "the mismatch is not reported as one"

# Merge commits are skipped (the merge itself is unsigned) while the signed
# commits it merges pass.
git checkout -q -b feature "$root"
commit signed f
git checkout -q -b mainline "$root"
commit signed g
git merge -q --no-ff --no-edit feature
merged="$(git rev-parse HEAD)"
[ "$(git rev-list --parents -n1 "$merged" | wc -w)" -eq 3 ] || t_fail "the test merge is not a merge commit"
if git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$merged" | grep -q .; then
  t_fail "the test merge commit was meant to be unsigned"
fi
expect_ok "$script" "$root" "$merged"
grep -q "2 commit(s) checked" "$T/out" || t_fail "the merge commit was counted, or a merged commit was not"

# An unsigned commit inside the merged branch is still caught, merge or not.
git checkout -q -b feature2 "$root"
commit unsigned h
git checkout -q -b mainline2 "$root"
commit signed i
git merge -q --no-ff --no-edit feature2
expect_fail "$script" "$root" "$(git rev-parse HEAD)"

# Ranges that cannot be walked never pass.
expect_fail "$script" "" "$head_signed"
expect_fail "$script" "$root" ""
expect_fail "$script" "1111111111111111111111111111111111111111" "$head_signed"
expect_fail "$script" "$root" "1111111111111111111111111111111111111111"
expect_fail "$script" "$root"
grep -q "usage" "$T/out" || t_fail "no usage message"

# A shallow clone that cannot see the base fails rather than checking nothing.
git checkout -q mainline
shallow="$T/shallow"
git clone -q --depth 1 "file://$repo" "$shallow" 2>/dev/null
cd "$shallow"
expect_fail "$script" "$root" "$(git rev-parse HEAD)"
grep -q "shallow clone" "$T/out" || t_fail "a shallow clone is not reported as one"

echo "test-dco: ok"
