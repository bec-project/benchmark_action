# benchmark_action

Standalone GitHub Action for benchmark workflows.

The default `all` mode runs benchmark attempts, aggregates results, compares pull requests against
the latest published baseline, updates a PR comment, and publishes new baseline data from `main`.
Lower-level modes are also available for repositories that need custom orchestration.

For `mode: all`, the workflow job needs `contents: write` to publish benchmark data and
`issues: write` plus `pull-requests: write` to update pull request comments.

## Modes

| Mode | Purpose |
| --- | --- |
| `all` | Run attempts, aggregate, compare, comment on PRs, and publish on `main`. |
| `run` | Run registered setup scripts, execute benchmarks, and write one benchmark JSON file. |
| `aggregate` | Aggregate multiple benchmark JSON files into a compact median result. |
| `compare` | Compare the current result with the latest published baseline and write Markdown. |
| `publish` | Publish `latest.json` and commit-specific history JSON to `gh-pages`. |

## Registered Scripts

The standalone action does not know how a project builds its benchmark environment. Register setup
scripts from the calling repository instead:

```yaml
- uses: bec-project/benchmark_action@main
  with:
    mode: all
    attempts: "3"
    system-packages: hyperfine
    setup-scripts: .github/scripts/setup_benchmark_env.sh
    benchmark-scripts: |
      tests/benchmarks/hyperfine/benchmark_import_bec_widgets.sh
      tests/benchmarks/hyperfine/benchmark_launch_bec_without_companion.sh
    benchmark-pytest-dirs: tests/unit_tests/benchmarks
```

Shell setup scripts are sourced in the same step that runs the benchmarks, so activating a Conda
environment, exporting variables, or starting local services is visible to the benchmark command. If
a setup script needs values to persist into later workflow steps, it should also append them to
`$GITHUB_ENV`.

The action installs itself into the active Python environment after setup scripts run. Its
`pyproject.toml` declares `pytest-benchmark`, so project workflows do not need to install that plugin
separately. Project-specific test dependencies should still be installed by the calling repository.

Benchmark scripts are run through `hyperfine`. Each script can define a display name with:

```bash
# BENCHMARK_TITLE: Import bec_widgets
```

If `benchmark-scripts` is empty, `run` mode discovers `benchmark_*.sh` under
`benchmark-hyperfine-dir`.

## Supported JSON Formats

The comparator and aggregator support:

- `hyperfine --export-json`
- `pytest-benchmark --benchmark-json`
- the compact aggregate JSON produced by this action

Lower values are treated as better by default. Set `higher-is-better: "true"` for throughput-style
benchmarks.

## BEC Widgets Workflow Shape

See [examples/bec-widgets-benchmark.yml](examples/bec-widgets-benchmark.yml) for a workflow that
matches the original BEC widgets benchmark CI design:

- three benchmark attempts
- median aggregation
- pull request comparison comment
- `gh-pages` baseline publishing on `main`

[examples/setup_bec_widgets_env.sh](examples/setup_bec_widgets_env.sh) shows the setup script that
the BEC widgets repository can copy or adapt. That script owns BEC-specific work such as installing
the e2e environment, starting Redis, and loading the demo config; the action itself only orchestrates
registered scripts and benchmark result handling.

## Versioning

Releases are created with `python-semantic-release` from conventional commits merged to `main`.
Consumers should use the major version tag for normal workflows:

```yaml
- uses: bec-project/benchmark_action@v1
```

Specific version tags such as `@v1.0.0` can be used when exact pinning is needed.
