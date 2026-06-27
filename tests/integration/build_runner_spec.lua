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

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        fail(("cannot open %s: %s"):format(path, err))
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function write_file(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        fail(("cannot open %s: %s"):format(path, err))
    end
    file:write(content)
    file:close()
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
local fixture_root = root .. "/tests/integration/fixtures/build_project"
local runner = root .. "/zig/neotest_runner.zig"
local temp_root = vim.fs.normalize(vim.fn.tempname() .. " neotest zig build")
local project_root = temp_root .. "/project with spaces"
local results_dir = temp_root .. "/results"
local logs_dir = temp_root .. "/logs"
local input_path = temp_root .. "/input.json"
local wrapper_path = project_root .. "/neotest_build.zig"

vim.fn.mkdir(project_root .. "/src", "p")
vim.fn.mkdir(results_dir, "p")
vim.fn.mkdir(logs_dir, "p")
write_file(project_root .. "/build.zig", read_file(fixture_root .. "/build.zig"))
write_file(project_root .. "/src/first.zig", read_file(fixture_root .. "/src/first.zig"))
write_file(project_root .. "/src/second.zig", read_file(fixture_root .. "/src/second.zig"))
write_file(wrapper_path, read_file(root .. "/zig/neotest_build.zig"))

local first_source = project_root .. "/src/first.zig"
local second_source = project_root .. "/src/second.zig"
local inputs = {
    {
        test_name = "test.first passes",
        source_path = first_source,
        output_path = temp_root .. "/first_passes.out",
    },
    {
        test_name = "test.first fails",
        source_path = first_source,
        output_path = temp_root .. "/first_fails.out",
    },
    {
        test_name = "test.shared name",
        source_path = first_source,
        output_path = temp_root .. "/first_shared.out",
    },
    {
        test_name = "test.second passes",
        source_path = second_source,
        output_path = temp_root .. "/second_passes.out",
    },
    {
        test_name = "test.second skips",
        source_path = second_source,
        output_path = temp_root .. "/second_skips.out",
    },
    {
        test_name = "test.shared name",
        source_path = second_source,
        output_path = temp_root .. "/second_shared.out",
    },
}
write_file(input_path, vim.json.encode(inputs))

local command = {
    "zig",
    "build",
    "test",
    "--build-file",
    wrapper_path,
    "-Dneotest-runner=" .. runner,
    "--",
    "--neotest-input-path",
    input_path,
    "--neotest-results-path",
    results_dir,
    "--test-runner-logs-path",
    logs_dir,
    "--test-runner-log-level",
    "0",
}
local result = run(command, { cwd = project_root, text = true }, 30000)
assert_equal(
    0,
    result.code,
    ("build runner command failed or timed out\nstdout:\n%s\nstderr:\n%s")
        :format(result.stdout or "", result.stderr or "")
)

local decoded_results = {}
local result_file_count = 0
for name, kind in vim.fs.dir(results_dir) do
    if kind == "file" then
        result_file_count = result_file_count + 1
        for _, test_result in ipairs(vim.json.decode(read_file(results_dir .. "/" .. name))) do
            local key = test_result.source_path .. "::" .. test_result.test_name
            if decoded_results[key] then
                fail("duplicate result for " .. key)
            end
            decoded_results[key] = test_result
        end
    end
end

assert_equal(2, result_file_count, "expected one result file per test binary")
assert_equal(6, vim.tbl_count(decoded_results), "unexpected merged result count")
assert_equal(
    "passed",
    decoded_results[first_source .. "::test.first passes"].status,
    "first pass status"
)
assert_equal(
    "failed",
    decoded_results[first_source .. "::test.first fails"].status,
    "first failure status"
)
assert_equal(
    "passed",
    decoded_results[first_source .. "::test.shared name"].status,
    "first shared-name status"
)
assert_equal(
    "passed",
    decoded_results[second_source .. "::test.second passes"].status,
    "second pass status"
)
assert_equal(
    "skipped",
    decoded_results[second_source .. "::test.second skips"].status,
    "second skip status"
)
assert_equal(
    "passed",
    decoded_results[second_source .. "::test.shared name"].status,
    "second shared-name status"
)

local debug_build = run({
    "zig",
    "build",
    "neotest-build",
    "--build-file",
    wrapper_path,
    "-Dneotest-runner=" .. runner,
}, { cwd = project_root, text = true }, 30000)
assert_equal(
    0,
    debug_build.code,
    ("debug artifact build failed\nstdout:\n%s\nstderr:\n%s")
        :format(debug_build.stdout or "", debug_build.stderr or "")
)

local debug_artifact_count = 0
for _, kind in vim.fs.dir(project_root .. "/zig-out/test") do
    if kind == "file" then
        debug_artifact_count = debug_artifact_count + 1
    end
end
assert_equal(2, debug_artifact_count, "debug test artifact count")

vim.fn.delete(temp_root, "rf")
print("build runner integration tests passed")
