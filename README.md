# Neotest Zig ⚡

![Zig v0.16.0](https://img.shields.io/badge/Zig-v0.16-orange?logo=zig)
![Neovim v0.10](https://img.shields.io/badge/Neovim-v0.10-green?logo=neovim)

[Neotest](https://github.com/nvim-neotest/neotest) test runner for [Zig](https://github.com/ziglang/zig).

https://github.com/lawrence-laz/neotest-zig/assets/8823448/9a003d0a-9ba4-4077-aa1b-3c0c90717734

## ⚙️ Requirements

- [`zig` v0.16.x installed](https://ziglang.org/download/) and available in `PATH`
- [Neotest](https://github.com/nvim-neotest/neotest#installation)
- [Treesitter](https://github.com/nvim-treesitter/nvim-treesitter#installation) with [Zig support](https://github.com/maxxnino/tree-sitter-zig)

This branch targets Zig 0.16. Zig 0.15 remains supported on the `zig_0_15`
branch.

## 📦 Setup

Install & configure using the package manager of your choice.
Example using lazy.nvim:

```lua
return {
	"nvim-neotest/neotest",
	dependencies = {
		"lawrence-laz/neotest-zig", -- Installation
		"nvim-lua/plenary.nvim",
		"nvim-treesitter/nvim-treesitter",
		"antoinemadec/FixCursorHold.nvim",
	},
	config = function()
		require("neotest").setup({
			adapters = {
				-- Registration
				require("neotest-zig")({
					dap = {
						adapter = "lldb",
					}
				}),
			}
		})
	end
}
```

## ⭐ Features

- Run tests in individual `.zig` files and projects using `build.zig`
  - A project must use either individual-file tests or `build.zig`, not both
  - `build.zig` must expose a conventional `test` step
- Exact test filtering
- Per-test timing
- Test output capture, including `std.debug.print` and `std.log`

## 📄 Logs

Enabling logging in `neotest` automatically enables logging in `neotest-zig` as well:

```lua
require("neotest").setup({
    log_level = vim.log.levels.TRACE,
    -- ...
})
```

Open the logs with:

```vim
:exe 'edit' stdpath('log').'/neotest-zig.log'
```

## Development

CI pins Zig 0.16.0. Run the same checks locally from the repository root:

```sh
zig fmt --check zig tests/zig tests/integration/fixtures tests/ci

zig test \
  --dep runner_core \
  -Mroot=tests/zig/runner_core_test.zig \
  -Mrunner_core=zig/runner_core.zig

zig test \
  -target x86_64-windows \
  --test-no-exec \
  --dep platform \
  -Mroot=tests/ci/windows_compile.zig \
  -Mplatform=zig/platform/windows/platform.zig

nvim --headless -u tests/minimal_init.lua -l tests/integration/runner_spec.lua
nvim --headless -u tests/minimal_init.lua -l tests/integration/build_runner_spec.lua

NEOTEST_ZIG_DEPS=/path/to/dependencies \
  nvim --headless \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/lua { minimal_init = 'tests/minimal_init.lua' }"

NEOTEST_ZIG_DEPS=/path/to/dependencies \
  nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/integration/neotest_smoke.lua
```

The adapter specs additionally require pinned checkouts of `plenary.nvim`,
`nvim-nio`, and `neotest` beneath `NEOTEST_ZIG_DEPS`; the CI workflow records
the exact revisions and command. The end-to-end smoke test also expects a Zig
parser at `NEOTEST_ZIG_DEPS/treesitter-runtime/parser/zig.so`.
