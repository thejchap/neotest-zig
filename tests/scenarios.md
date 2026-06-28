# Test scenarios

## Automated

The Zig unit suite covers:

- Test and declaration symbol-name normalization
- Exact input matching by symbol and source path
- Neovim-to-Zig log-level mapping
- POSIX and Windows failure-trace line parsing
- Result precedence for failures, skips, leaks, and passes

The standalone runner integration covers:

- Passing, failing, skipped, printing, testing-I/O, fuzz, and leaking tests
- Failure source lines and exactly one result per selected test
- Per-test allocator isolation after a leak
- Captured `std.debug.print` and `std.log` output

The `zig build test` integration covers:

- Multiple test binaries
- Passing, failing, and skipped results
- Paths containing spaces
- One result file per test binary without duplicate merged results

The adapter specs cover:

- String and declaration symbol conversion
- Argument-vector commands for standalone and build-project runs
- Zig executable overrides and paths containing spaces
- Result aggregation, missing-result skips, nonzero exits, and cleanup

The end-to-end Neotest smoke test covers real Zig Tree-sitter discovery,
standalone command execution, and the final passing status reported by
Neotest's state consumer.

The watch integration test covers Zig symbol-query registration and a
pass-to-fail rerun after `BufWritePost`.

The Windows platform test compiles for Windows on every CI host and runs on
Windows. It verifies that stderr redirection restores the original process
handle.

CI runs the runner integrations with Zig 0.16.0 and Neovim 0.12.2 on Linux,
macOS, and Windows. Adapter specs run on Linux with Neovim 0.10.4, 0.11.5, and
0.12.2.

See the development section in `README.md` for local commands.

## Manual

These scenarios still require interactive Neovim validation:

- Discovery updates after adding or removing Zig test files and declarations
- Summary behavior for directories with and without Zig sources
- DAP launch and debugging with the configured adapter
- Short-output rendering in Neotest's UI
- Build errors rendered for both standalone and `zig build test` runs
