local function fail(message)
    error(message, 0)
end

if not pcall(vim.treesitter.language.add, "zig") then
    fail("Zig Tree-sitter parser is unavailable")
end

local temp_root = vim.fs.normalize(vim.fn.tempname() .. " neotest zig watch")
local source = temp_root .. "/watch test.zig"
vim.fn.mkdir(temp_root, "p")
local file = assert(io.open(source, "wb"))
file:write([[const std = @import("std");

test "watch reruns" {
    try std.testing.expect(true);
}
]])
file:close()
source = vim.uv.fs_realpath(source) or source

local neotest = require("neotest")
neotest.setup({
    adapters = {
        require("neotest-zig")({
            path_to_zig = "zig",
        }),
    },
})

vim.cmd.edit(vim.fn.fnameescape(source))
vim.bo.filetype = "zig"

neotest.run.run(source)
if not vim.wait(30000, function()
    for _, adapter_id in ipairs(neotest.state.adapter_ids()) do
        local status = neotest.state.status_counts(adapter_id)
        if status and status.total == 1 and status.running == 0 and status.passed == 1 then
            return true
        end
    end
    return false
end, 25) then
    fail("initial passing test run did not complete")
end

local nio_lsp = require("nio.lsp")
local original_get_clients = nio_lsp.get_clients
nio_lsp.get_clients = function()
    return {
        {
            name = "neotest-zig-watch-test",
            supports_method = {
                textDocument_definition = function()
                    return true
                end,
            },
            request = {
                textDocument_definition = function()
                    return nil, {}
                end,
            },
        },
    }
end

neotest.watch.watch(source)
if not vim.wait(10000, function()
    return neotest.watch.is_watching(source)
end, 25) then
    fail("watcher did not start")
end

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
    if line:find("expect(true)", 1, true) then
        lines[index] = line:gsub("expect%(true%)", "expect(false)")
    end
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.cmd.write()

if not vim.wait(30000, function()
    for _, adapter_id in ipairs(neotest.state.adapter_ids()) do
        local status = neotest.state.status_counts(adapter_id)
        if status and status.total == 1 and status.running == 0 and status.failed == 1 then
            return true
        end
    end
    return false
end, 25) then
    fail("watcher did not rerun the changed test as failed")
end

neotest.watch.stop(source)
nio_lsp.get_clients = original_get_clients
vim.fn.delete(temp_root, "rf")
print("Neotest watch integration test passed")
