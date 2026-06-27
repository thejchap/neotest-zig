local function fail(message)
    error(message, 0)
end

local function assert_equal(expected, actual, message)
    if not vim.deep_equal(expected, actual) then
        fail(("%s\nexpected: %s\nactual: %s"):format(
            message,
            vim.inspect(expected),
            vim.inspect(actual)
        ))
    end
end

local function write_file(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        fail(("cannot open %s: %s"):format(path, err))
    end
    file:write(content)
    file:close()
end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        fail(("cannot open %s: %s"):format(path, err))
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function run(command, options, timeout)
    local completed
    local process = vim.system(command, options, function(result)
        completed = result
    end)
    if not vim.wait(timeout, function()
        return completed ~= nil
    end, 20) then
        process:kill(9)
        vim.wait(1000, function()
            return completed ~= nil
        end, 20)
        return {
            code = 124,
            stdout = completed and completed.stdout or "",
            stderr = completed and completed.stderr or "timed out",
        }
    end
    return completed
end

local root = vim.fs.normalize(vim.fn.getcwd())
local source = vim.fs.normalize(root .. "/tests/integration/fixtures/standalone.zig")
local runner = vim.fs.normalize(root .. "/zig/neotest_runner.zig")
local temp_root = vim.fs.normalize(vim.fn.tempname() .. " neotest zig standalone")
local results_dir = temp_root .. "/results"
local logs_dir = temp_root .. "/logs"
local input_path = temp_root .. "/input.json"

vim.fn.mkdir(results_dir, "p")
vim.fn.mkdir(logs_dir, "p")

local test_names = {
    "passes",
    "fails",
    "skips",
    "prints",
    "uses testing io",
    "fuzz smoke",
    "leaks once",
    "passes after leak",
}

local inputs = {}
local output_paths = {}
for _, name in ipairs(test_names) do
    local symbol_name = "test." .. name
    local output_path = temp_root .. "/" .. name:gsub("[^%w]", "_") .. ".out"
    output_paths[symbol_name] = output_path
    table.insert(inputs, {
        test_name = symbol_name,
        source_path = source,
        output_path = output_path,
    })
end
write_file(input_path, vim.json.encode(inputs))

local command = {
    "zig",
    "test",
    source,
    "--test-runner",
    runner,
    "--test-cmd-bin",
    "--test-cmd",
    "--neotest-input-path",
    "--test-cmd",
    input_path,
    "--test-cmd",
    "--neotest-results-path",
    "--test-cmd",
    results_dir,
    "--test-cmd",
    "--neotest-source-path",
    "--test-cmd",
    source,
    "--test-cmd",
    "--test-runner-logs-path",
    "--test-cmd",
    logs_dir,
    "--test-cmd",
    "--test-runner-log-level",
    "--test-cmd",
    "0",
}

local result = run(command, { text = true }, 30000)
assert_equal(
    0,
    result.code,
    ("standalone runner command failed or timed out\nstdout:\n%s\nstderr:\n%s")
        :format(result.stdout or "", result.stderr or "")
)

local decoded_results = {}
for name, kind in vim.fs.dir(results_dir) do
    if kind == "file" then
        local batch = vim.json.decode(read_file(results_dir .. "/" .. name))
        for _, test_result in ipairs(batch) do
            if decoded_results[test_result.test_name] then
                fail("duplicate result for " .. test_result.test_name)
            end
            decoded_results[test_result.test_name] = test_result
        end
    end
end

assert_equal(#test_names, vim.tbl_count(decoded_results), "unexpected result count")
assert_equal("passed", decoded_results["test.passes"].status, "passing test status")
assert_equal("failed", decoded_results["test.fails"].status, "failing test status")
assert_equal("skipped", decoded_results["test.skips"].status, "skipped test status")
assert_equal("passed", decoded_results["test.uses testing io"].status, "testing IO status")
assert_equal("passed", decoded_results["test.fuzz smoke"].status, "fuzz smoke status")
assert_equal("failed", decoded_results["test.leaks once"].status, "leak status")
assert_equal("passed", decoded_results["test.passes after leak"].status, "leak isolation")

local fixture_lines = vim.fn.readfile(source)
local expected_failure_line
for index, line in ipairs(fixture_lines) do
    if line:find("expectEqual", 1, true) then
        expected_failure_line = index - 1
        break
    end
end
assert_equal(
    expected_failure_line,
    decoded_results["test.fails"].errors[1].line,
    "failure line"
)

local print_output = read_file(output_paths["test.prints"])
if not print_output:find("debug%-output") or not print_output:find("info%-output") then
    fail("test output did not contain debug and info messages:\n" .. print_output)
end
local pass_output = read_file(output_paths["test.passes"])
if pass_output:find("debug%-output") or pass_output:find("info%-output") then
    fail("test output leaked into another test:\n" .. pass_output)
end

local runner_logs = {}
for name, kind in vim.fs.dir(logs_dir) do
    if kind == "file" then
        table.insert(runner_logs, read_file(logs_dir .. "/" .. name))
    end
end
local combined_logs = table.concat(runner_logs, "\n")
if not combined_logs:find("Running test", 1, true) then
    fail("runner logs did not contain runner diagnostics")
end
if combined_logs:find("debug%-output") or combined_logs:find("info%-output") then
    fail("test output leaked into runner logs:\n" .. combined_logs)
end

vim.fn.delete(temp_root, "rf")
print("runner integration tests passed")
