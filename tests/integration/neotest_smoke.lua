local function fail(message)
    error(message, 0)
end

local dependency_root = vim.env.NEOTEST_ZIG_DEPS
if dependency_root then
    local parser_runtime = dependency_root .. "/treesitter-runtime"
    if vim.fn.isdirectory(parser_runtime) == 1 then
        vim.opt.runtimepath:append(parser_runtime)
    end
end

if not pcall(vim.treesitter.language.add, "zig") then
    fail("Zig Tree-sitter parser is unavailable")
end

local temp_root = vim.fs.normalize(vim.fn.tempname() .. " neotest zig smoke")
local source = temp_root .. "/smoke test.zig"
vim.fn.mkdir(temp_root, "p")
local file = assert(io.open(source, "wb"))
file:write('test "smoke passes" {}\n')
file:close()

local neotest = require("neotest")
neotest.setup({
    adapters = {
        require("neotest-zig")({
            path_to_zig = "zig",
        }),
    },
})

vim.cmd.edit(vim.fn.fnameescape(source))
neotest.run.run(source)

local completed = vim.wait(30000, function()
    for _, adapter_id in ipairs(neotest.state.adapter_ids()) do
        local status = neotest.state.status_counts(adapter_id)
        if status and status.total == 1 and status.running == 0 then
            return status.passed == 1
        end
    end
    return false
end, 25)

if not completed then
    local states = {}
    for _, adapter_id in ipairs(neotest.state.adapter_ids()) do
        states[adapter_id] = neotest.state.status_counts(adapter_id)
    end
    fail("Neotest smoke run did not produce one passing test: " .. vim.inspect(states))
end

vim.fn.delete(temp_root, "rf")
print("Neotest smoke test passed")
