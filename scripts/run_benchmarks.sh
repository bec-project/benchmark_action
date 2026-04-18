#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p benchmark-results
benchmark_json="${BENCHMARK_JSON:-benchmark-results/current.json}"
benchmark_root="$(dirname "$benchmark_json")"
hyperfine_benchmark_dir="${BENCHMARK_HYPERFINE_DIR:-tests/benchmarks/hyperfine}"
registered_benchmark_scripts="${BENCHMARK_SCRIPTS:-}"
pytest_benchmark_dirs="${BENCHMARK_PYTEST_DIRS:-${BENCHMARK_PYTEST_DIR:-}}"
benchmark_work_dir="$benchmark_root/raw-results"
hyperfine_json_dir="$benchmark_work_dir/hyperfine"
pytest_json="$benchmark_work_dir/pytest.json"
hyperfine_warmup="${BENCHMARK_HYPERFINE_WARMUP:-1}"
hyperfine_runs="${BENCHMARK_HYPERFINE_RUNS:-5}"

benchmark_scripts=()
if [ -n "$registered_benchmark_scripts" ]; then
  while IFS= read -r benchmark_script; do
    for benchmark_script_part in $benchmark_script; do
      benchmark_scripts+=("$benchmark_script_part")
    done
  done <<< "$registered_benchmark_scripts"
else
  shopt -s nullglob
  benchmark_scripts=("$hyperfine_benchmark_dir"/benchmark_*.sh)
  shopt -u nullglob
fi

pytest_dirs=()
for pytest_benchmark_dir in $pytest_benchmark_dirs; do
  if [ -d "$pytest_benchmark_dir" ]; then
    pytest_dirs+=("$pytest_benchmark_dir")
  else
    echo "Pytest benchmark directory not found: $pytest_benchmark_dir" >&2
    exit 1
  fi
done

if [ "${#benchmark_scripts[@]}" -eq 0 ] && [ "${#pytest_dirs[@]}" -eq 0 ]; then
  echo "No registered benchmark scripts, discovered benchmark scripts, or pytest benchmarks found" >&2
  exit 1
fi

echo "Benchmark Python: $(command -v python)"
python -c 'import sys; print(sys.version)'

rm -rf "$benchmark_work_dir"
mkdir -p "$hyperfine_json_dir"

if [ "${#benchmark_scripts[@]}" -gt 0 ]; then
  if ! command -v hyperfine >/dev/null 2>&1; then
    echo "hyperfine is required when benchmark scripts are registered or discovered" >&2
    exit 1
  fi

  for benchmark_script in "${benchmark_scripts[@]}"; do
    if [ ! -f "$benchmark_script" ]; then
      echo "Benchmark script not found: $benchmark_script" >&2
      exit 1
    fi

    title="$(sed -n 's/^# BENCHMARK_TITLE:[[:space:]]*//p' "$benchmark_script" | head -n 1)"
    if [ -z "$title" ]; then
      title="$(basename "$benchmark_script" .sh)"
    fi
    benchmark_name="$(basename "$benchmark_script" .sh)"
    benchmark_result_json="$hyperfine_json_dir/$benchmark_name.json"
    echo "Preflight benchmark script: $benchmark_script"
    bash "$benchmark_script"

    hyperfine \
      --show-output \
      --warmup "$hyperfine_warmup" \
      --runs "$hyperfine_runs" \
      --command-name "$title" \
      --export-json "$benchmark_result_json" \
      "bash $(printf "%q" "$benchmark_script")"
  done
fi

if [ "${#pytest_dirs[@]}" -gt 0 ]; then
  pytest \
    -q "${pytest_dirs[@]}" \
    --benchmark-only \
    --benchmark-json "$pytest_json"
fi

python "$script_dir/aggregate_benchmarks.py" \
  --input-dir "$benchmark_work_dir" \
  --output "$benchmark_json"
