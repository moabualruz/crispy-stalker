#!/usr/bin/env bash
set -euo pipefail

workflow="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

extract_run() {
  awk -v wanted="$1" '
    $0 == "      - name: " wanted { step = 1; next }
    step && $0 == "        run: |" { run = 1; next }
    step && /^        run: / { sub(/^        run: /, ""); print; exit }
    step && /^      - / { exit }
    run { sub(/^          /, ""); print }
  ' "$workflow"
}

guard="$(extract_run 'Verify host-prepared PR checkout')"
archive="$(extract_run 'Create source archive')"
aggregate_condition="$(awk '
  /^  test:$/ { job = 1; next }
  job && /^    if: / { sub(/^    if: /, ""); print; exit }
' "$workflow")"
aggregate="$(extract_run 'Preserve required test status')"
test -n "$guard"
test -n "$archive"
test -n "$aggregate"
grep -Fq 'persist-credentials: false' "$workflow"
grep -Fq 'github.sha' "$workflow"
grep -Fq 'pr-%s-%s' "$workflow"
grep -Fq 'group: crispy-stalker-pr-${{ github.event.pull_request.number || github.ref }}' "$workflow"
grep -Fq 'cancel-in-progress: false' "$workflow"
if grep -Fq 'runs-on: [self-hosted, linux, x64, generic, group:' "$workflow"; then
  echo 'workflow uses the old runner group syntax' >&2
  exit 1
fi
if grep -Fq 'pr-%s-%s-run-%s-attempt-%s' "$workflow"; then
  echo 'workflow uses run-scoped PR labels' >&2
  exit 1
fi
if grep -Fq 'cancel-in-progress: true' "$workflow"; then
  echo 'workflow may cancel required CI runs' >&2
  exit 1
fi

# Internal PR jobs must all consume the one serialized prepared checkout. Only
# the prepare job may call checkout, and only for forks or non-PR events.
test "$(grep -Fc 'uses: actions/checkout@v4' "$workflow")" -eq 1
grep -Fq '      - uses: actions/checkout@v4' "$workflow"
checkout_if="$(awk '
  /^      - uses: actions\/checkout@v4$/ { in_checkout = 1; next }
  in_checkout && /^        if: / { sub(/^        if: /, ""); print; exit }
  in_checkout && /^      - / { exit }
' "$workflow")"
test "$checkout_if" = "\${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository }}"
awk '
  function check_job() {
    if (job != "" && job != "prepare" && !has_prepare) {
      print "job does not depend on prepare: " job > "/dev/stderr"; failed = 1
    }
  }
  /^jobs:$/ { in_jobs = 1; next }
  in_jobs && /^  [A-Za-z0-9_-]+:$/ { check_job(); job = $1; sub(/:$/, "", job); has_prepare = 0; next }
  in_jobs && /^    needs:/ && $0 ~ /prepare/ { has_prepare = 1 }
  END { check_job(); exit failed }
' "$workflow"
awk '
  /^      - uses: actions\/download-artifact@/ { artifact = 1; next }
  artifact && /^        if: / {
    if ($0 !~ /github.event_name != '\''pull_request'\''/ || $0 !~ /head.repo.full_name != github.repository/) {
      print "artifact restore is not fork/non-PR scoped" > "/dev/stderr"; exit 1
    }
    artifact = 0
  }
  END { if (artifact) { print "artifact restore has no event condition" > "/dev/stderr"; exit 1 } }
' "$workflow"

# Model the status-function behavior that decides whether GitHub starts the
# aggregate job after a prerequisite is cancelled.
case "$aggregate_condition" in
  "\${{ always() }}") aggregate_runs_after_cancel=true ;;
  "\${{ !cancelled() }}") aggregate_runs_after_cancel=false ;;
  *) echo "unsupported aggregate condition: $aggregate_condition" >&2; exit 1 ;;
esac
test "$aggregate_runs_after_cancel" = true
if env PREPARE_RESULT=success FMT_RESULT=success CLIPPY_RESULT=cancelled \
  CARGO_TEST_RESULT=success DOC_RESULT=success PACKAGE_RESULT=success \
  bash -e -c "$aggregate"; then
  echo 'aggregate accepted a cancelled prerequisite' >&2
  exit 1
fi

git -C "$tmp" init -q
git -C "$tmp" config user.name 'Runner contract test'
git -C "$tmp" config user.email 'runner-contract@example.invalid'
printf 'merge source\n' > "$tmp/source.txt"
git -C "$tmp" add source.txt
git -C "$tmp" commit -qm 'merge commit'
merge_sha="$(git -C "$tmp" rev-parse HEAD)"
printf 'PR head source\n' > "$tmp/source.txt"
git -C "$tmp" commit -qam 'PR head commit'
head_sha="$(git -C "$tmp" rev-parse HEAD)"
test "$merge_sha" != "$head_sha"
pr_worktree="$tmp/pr-worktree"
git -C "$tmp" worktree add -q --detach "$pr_worktree" "$head_sha"
pr_workspace_link="$tmp/pr-workspace"
ln -s "$pr_worktree" "$pr_workspace_link"

(
  cd "$pr_workspace_link"
  GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$head_sha" GITHUB_WORKSPACE="$pr_workspace_link" bash -e -c "$guard"
)
if (
  cd "$pr_workspace_link"
  GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge_sha" GITHUB_WORKSPACE="$pr_workspace_link" bash -e -c "$guard"
); then
  echo 'same-repo guard accepted a checkout at the wrong commit' >&2
  exit 1
fi
if (
  cd "$tmp"
  GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$head_sha" GITHUB_WORKSPACE="$pr_workspace_link" bash -e -c "$guard"
); then
  echo 'same-repo guard accepted an unrelated working directory at the right commit' >&2
  exit 1
fi

mkdir "$tmp/runner-temp"
printf 'untracked secret-shaped fixture\n' > "$tmp/untracked.txt"
(
  cd "$tmp"
  GITHUB_SHA="$merge_sha" RUNNER_TEMP="$tmp/runner-temp" bash -e -c "$archive"
)
tar -tzf "$tmp/runner-temp/source.tar.gz" > "$tmp/archive-files.txt"
grep -Fxq source.txt "$tmp/archive-files.txt"
if grep -Fq '.git' "$tmp/archive-files.txt"; then
  echo 'source archive contains Git metadata' >&2
  exit 1
fi
if grep -Fq untracked.txt "$tmp/archive-files.txt"; then
  echo 'source archive contains untracked content' >&2
  exit 1
fi
mkdir "$tmp/restore"
tar -xzf "$tmp/runner-temp/source.tar.gz" -C "$tmp/restore"
grep -Fxq 'merge source' "$tmp/restore/source.txt"
echo 'runner workflow contract passed'
