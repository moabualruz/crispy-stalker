#!/usr/bin/env bash
set -euo pipefail

workflow="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

extract_run() {
  awk -v wanted="$1" '
    $0 == "      - name: " wanted || $0 == "        name: " wanted { step = 1; next }
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

# Every gate job must run the SAME guard as prepare (executed below against real git state).
extract_job_run() {
  awk -v job="  $1:" -v wanted="$2" '
    $0 == job { j = 1; next }
    j && /^  [a-z-]+:$/ { exit }
    j && $0 == "      - name: " wanted { step = 1; next }
    step && $0 == "        run: |" { run = 1; next }
    step && /^      - / { exit }
    run { sub(/^          /, ""); print }
  ' "$workflow"
}
for job in fmt clippy cargo-test doc package; do
  gate_guard="$(extract_job_run "$job" 'Verify host-prepared PR checkout')"
  [[ "$gate_guard" == "$guard" ]] || { echo "job $job guard differs from prepare guard" >&2; exit 1; }
done
grep -Fq 'bash tests/runner-contract.test.sh' "$(dirname "$workflow")/../../justfile"

# Execute the real route step and evaluate the real runs-on expressions per event.
route="$(extract_run 'Select trusted runner route')"
route_out() {
  : > "$tmp/route.out"
  env GITHUB_OUTPUT="$tmp/route.out" EVENT_NAME="$1" HEAD_REPOSITORY="$2" BASE_REPOSITORY=o/r REPOSITORY_ID=42 PR_NUMBER=7 bash -e -c "$route"
  cat "$tmp/route.out"
}
[[ "$(route_out pull_request o/r)" == 'runs_on=["self-hosted","linux","x64","generic","pr-42-7"]' ]]
[[ "$(route_out pull_request fork/r)" == 'runs_on="ubuntu-latest"' ]]
[[ "$(route_out push '')" == 'runs_on=["self-hosted","linux","x64","generic"]' ]]
python3 - "$workflow" <<'PY'
import json, sys
from types import SimpleNamespace as N
lines = open(sys.argv[1]).read().split("\n")
def runs_on(job):
    start = lines.index(f"  {job}:")
    line = next(l for l in lines[start + 1:] if l.startswith("    runs-on: "))
    return line.split("${{", 1)[1].rsplit("}}", 1)[0].strip().replace("&&", " and ").replace("||", " or ")
def route(expr, name, head="o/r"):
    g = N(event_name=name, repository="o/r", repository_id=42,
          event=N(pull_request=N(head=N(repo=N(full_name=head)), number=7)))
    return eval(expr, {"__builtins__": {}}, {"github": g, "fromJSON": json.loads,
                "format": lambda t, *a: t.format(*a)})
for job in ("prepare", "test"):
    expr = runs_on(job)
    assert route(expr, "pull_request") == ["self-hosted", "linux", "x64", "generic", "pr-42-7"], job
    assert route(expr, "pull_request", "fork/r") == "ubuntu-latest", job
    assert route(expr, "push") == ["self-hosted", "linux", "x64", "generic"], job
PY

# The aggregate must still start after a cancelled prerequisite.
[[ "$aggregate_condition" == '${{ always() }}' ]]
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
# pull_request checkouts are the test MERGE commit, so GITHUB_SHA is the merge sha.
git -C "$tmp" worktree add -q --detach "$pr_worktree" "$merge_sha"
pr_workspace_link="$tmp/pr-workspace"
ln -s "$pr_worktree" "$pr_workspace_link"

(
  cd "$pr_workspace_link"
  GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge_sha" GITHUB_WORKSPACE="$pr_workspace_link" bash -e -c "$guard"
)
if (
  cd "$pr_workspace_link"
  GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$head_sha" GITHUB_WORKSPACE="$pr_workspace_link" bash -e -c "$guard"
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
# Simulate a re-run of failed jobs: prepare uploaded in attempt 1, the re-run gate jobs download in
# attempt 2. Resolve every artifact name with those contexts; each download must find the upload.
ruby -ryaml -e '
  jobs = YAML.load_file(ARGV[0]).fetch("jobs")
  resolve = lambda { |name, attempt| name.to_s.gsub("${{ github.run_id }}", "4242").gsub("${{ github.run_attempt }}", attempt.to_s) }
  steps = jobs.values.flat_map { |job| job.fetch("steps", []) }
  uploads = steps.select { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
  downloads = steps.select { |step| step["uses"].to_s.start_with?("actions/download-artifact@") }
  abort "no upload step" if uploads.empty?
  abort "no download steps" if downloads.empty?
  uploads.each { |step| abort "upload does not overwrite" unless step.dig("with", "overwrite") == true }
  uploaded = uploads.map { |step| resolve.call(step.dig("with", "name"), 1) }.uniq
  abort "uploads resolve to several names: #{uploaded}" unless uploaded.size == 1
  downloads.each do |step|
    found = resolve.call(step.dig("with", "name"), 2)
    abort "re-run download #{found} cannot find upload #{uploaded.first}" unless found == uploaded.first
  end
' "$workflow"
echo 'runner workflow contract passed'
