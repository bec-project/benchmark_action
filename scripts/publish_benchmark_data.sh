#!/usr/bin/env bash
set -euo pipefail

benchmark_json="${BENCHMARK_JSON:-benchmark-results/current.json}"
gh_pages_dir="${GH_PAGES_DIR:-gh-pages-benchmark-data}"
publish_branch="${PUBLISH_BRANCH:-gh-pages}"
history_dir="${HISTORY_DIR:-benchmarks}"
commit_message="${COMMIT_MESSAGE:-Update benchmark data}"

if [ ! -s "$benchmark_json" ]; then
  echo "Benchmark JSON not found or empty: $benchmark_json" >&2
  exit 1
fi

if [ -d "$gh_pages_dir" ]; then
  git worktree remove "$gh_pages_dir" --force || rm -rf "$gh_pages_dir"
fi

if git ls-remote --exit-code --heads origin "$publish_branch"; then
  git fetch --depth=1 origin "$publish_branch"
  git worktree add "$gh_pages_dir" FETCH_HEAD
else
  git worktree add --detach "$gh_pages_dir"
  git -C "$gh_pages_dir" checkout --orphan "$publish_branch"
  git -C "$gh_pages_dir" rm -rf .
fi

mkdir -p "$gh_pages_dir/$history_dir/history"
cp "$benchmark_json" "$gh_pages_dir/$history_dir/latest.json"
cp "$benchmark_json" "$gh_pages_dir/$history_dir/history/${GITHUB_SHA}.json"

git -C "$gh_pages_dir" config user.name "github-actions[bot]"
git -C "$gh_pages_dir" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$gh_pages_dir" add "$history_dir/latest.json" "$history_dir/history/${GITHUB_SHA}.json"
git -C "$gh_pages_dir" commit -m "$commit_message for ${GITHUB_SHA}" || exit 0
git -C "$gh_pages_dir" push origin "HEAD:$publish_branch"
