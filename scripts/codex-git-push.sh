#!/usr/bin/env bash
set -euo pipefail

target_remote="${TARGET_REMOTE:-origin}"
target_branch="${TARGET_BRANCH:-main}"
codex_bin="${CODEX_BIN:-codex}"
require_branch_match="${REQUIRE_BRANCH_MATCH:-1}"

usage() {
	cat <<'USAGE'
Usage: codex-git-push.sh [options]

Run Codex CLI to split current changes into coherent commits, then push.

Options:
  -r, --remote <name>    Git remote name (default: TARGET_REMOTE or "origin")
  -b, --branch <name>    Target branch name (default: TARGET_BRANCH or "main")
      --no-branch-check  Allow running even when current branch != target branch
  -h, --help             Show help

Environment:
  TARGET_REMOTE          Default remote
  TARGET_BRANCH          Default branch
  CODEX_BIN              Codex executable name/path (default: codex)
  REQUIRE_BRANCH_MATCH   "1" to require current branch == target branch (default: 1)
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	-r|--remote)
		if [ "$#" -lt 2 ]; then
			echo "Missing value for $1"
			exit 1
		fi
		target_remote="$2"
		shift 2
		;;
	-b|--branch)
		if [ "$#" -lt 2 ]; then
			echo "Missing value for $1"
			exit 1
		fi
		target_branch="$2"
		shift 2
		;;
	--no-branch-check)
		require_branch_match="0"
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		echo "Unknown option: $1"
		usage
		exit 1
		;;
	esac
done

if ! command -v "$codex_bin" >/dev/null 2>&1; then
	echo "$codex_bin CLI is required."
	exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "This command must be run inside a git repository."
	exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ! git remote get-url "$target_remote" >/dev/null 2>&1; then
	echo "Git remote '$target_remote' does not exist."
	exit 1
fi

current_branch="$(git branch --show-current)"
if [ "$require_branch_match" = "1" ] && [ "$current_branch" != "$target_branch" ]; then
	echo "Current branch is '$current_branch'. Switch to '$target_branch' or pass --no-branch-check."
	exit 1
fi

if [ -z "$(git status --porcelain)" ]; then
	echo "No changes to commit."
	exit 0
fi

if ! "$codex_bin" login status >/dev/null 2>&1; then
	echo "Codex CLI login is required. Run: $codex_bin login"
	exit 1
fi

"$codex_bin" exec --full-auto --cd "$repo_root" - <<PROMPT
You are in a local git repository. Commit and push the current working tree.

Task:
1. Inspect all staged/unstaged/untracked changes.
2. Split the changes into coherent, minimal commits by topic.
3. Use concise Conventional Commit messages.
4. Commit all current changes.
5. Push to ${target_remote} ${target_branch}.

Constraints:
- Use non-interactive commands only. Do not open editors or interactive prompts.
- Do not amend or rewrite existing commits.
- Never force-push.
- Keep each commit focused and internally consistent.
- After each commit, verify that staged content matches the commit message.
- At the end, print the pushed commit list as "<short_sha> <subject>".
PROMPT
