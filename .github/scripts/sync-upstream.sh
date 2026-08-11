#!/usr/bin/env bash

set -euo pipefail

readonly upstream_url="${UPSTREAM_URL:-https://github.com/rustdesk/hbb_common.git}"
readonly upstream_branch="${UPSTREAM_BRANCH:-main}"
readonly upstream_remote="${UPSTREAM_REMOTE:-upstream-sync}"
readonly config_file="src/config.rs"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

extract_unique_line() {
  local pattern="$1"
  local label="$2"
  local matches
  local count

  matches="$(grep -E "$pattern" "$config_file" || true)"
  count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] || die "expected one $label line in $config_file, found $count"
  printf '%s\n' "$matches"
}

abort_merge_on_error() {
  local status=$?

  if [[ "$status" -ne 0 ]] && git rev-parse --verify -q MERGE_HEAD >/dev/null; then
    git merge --abort || true
  fi
  exit "$status"
}

trap abort_merge_on_error EXIT

[[ -z "$(git status --porcelain)" ]] || die "worktree must be clean before syncing"

before_servers="$(extract_unique_line '^[[:space:]]*pub const RENDEZVOUS_SERVERS:' 'rendezvous server')"
before_key="$(extract_unique_line '^[[:space:]]*pub const RS_PUB_KEY:' 'server public key')"
before_sha="$(git rev-parse HEAD)"

if git remote get-url "$upstream_remote" >/dev/null 2>&1; then
  git remote set-url "$upstream_remote" "$upstream_url"
else
  git remote add "$upstream_remote" "$upstream_url"
fi

git fetch --no-tags "$upstream_remote" \
  "+refs/heads/$upstream_branch:refs/remotes/$upstream_remote/$upstream_branch"
upstream_ref="$upstream_remote/$upstream_branch"

if ! git merge-base --is-ancestor "$upstream_ref" HEAD; then
  git merge --no-edit "$upstream_ref"
fi

after_servers="$(extract_unique_line '^[[:space:]]*pub const RENDEZVOUS_SERVERS:' 'rendezvous server')"
after_key="$(extract_unique_line '^[[:space:]]*pub const RS_PUB_KEY:' 'server public key')"

[[ "$after_servers" == "$before_servers" ]] || die "rendezvous server configuration changed during sync"
[[ "$after_key" == "$before_key" ]] || die "server public key changed during sync"
git merge-base --is-ancestor "$upstream_ref" HEAD || die "upstream commit is not an ancestor of HEAD"
git diff --check "$upstream_ref"..HEAD

after_sha="$(git rev-parse HEAD)"
changed=false
if [[ "$after_sha" != "$before_sha" ]]; then
  changed=true
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'changed=%s\nhead=%s\n' "$changed" "$after_sha" >>"$GITHUB_OUTPUT"
fi

printf 'sync complete: changed=%s head=%s\n' "$changed" "$after_sha"
