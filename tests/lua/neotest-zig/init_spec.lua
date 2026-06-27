local adapter = require("neotest-zig")
local a = require("nio").tests

local function tree(data, children)
    local node = {
        _data = data,
        _children = children or {},
    }

    function node:data()
        return self._data
    end

    function node:root()
        return self
    end

    function node:iter_nodes()
        local nodes = { self }
        vim.list_extend(nodes, self._children)
        local index = 0
        return function()
            index = index + 1
            if nodes[index] then
                return index, nodes[index]
            end
        end
    end

    return node
end

local function test_node(name, path, id)
    return tree({
        id = id or path .. "::" .. name,
        name = name,
        path = path,
        type = "test",
    })
end

local function mkdir(path)
    assert(vim.uv.fs_mkdir(path, 493))
end

local function write(path, contents)
    local file = assert(io.open(path, "w"))
    file:write(contents)
    file:close()
end

local function read(path)
    local file = assert(io.open(path, "r"))
    local contents = file:read("*a")
    file:close()
    return contents
end

describe("neotest-zig adapter", function()
    local original_dap
    local original_path_to_zig
    local original_temp_file_path
    local original_vim_system
    local temp_paths

    before_each(function()
        original_dap = adapter.dap
        original_path_to_zig = adapter.path_to_zig
        original_temp_file_path = adapter._get_temp_file_path
        original_vim_system = vim.system
        temp_paths = {}
    end)

    after_each(function()
        adapter.dap = original_dap
        adapter.path_to_zig = original_path_to_zig
        adapter._get_temp_file_path = original_temp_file_path
        vim.system = original_vim_system
        for _, path in ipairs(temp_paths) do
            vim.fn.delete(path, "rf")
        end
    end)

    local function temp_path()
        local path = vim.fn.tempname()
        table.insert(temp_paths, path)
        return path
    end

    it("converts string and declaration test names to Zig symbols", function()
        assert.equals("test.adds values", adapter._get_zig_symbol_name_from_node(
            test_node('"adds values"', "/tmp/example.zig")
        ))
        assert.equals("decltest.some_decl", adapter._get_zig_symbol_name_from_node(
            test_node("some_decl", "/tmp/example.zig")
        ))
    end)

    it("preserves configured Zig and DAP settings", function()
        local configured = adapter.setup({
            path_to_zig = "/opt/zig versions/0.16/zig",
            dap = {
                adapter = "codelldb",
                custom_setting = true,
            },
        })

        assert.equals("/opt/zig versions/0.16/zig", configured.path_to_zig)
        assert.same({
            adapter = "codelldb",
            custom_setting = true,
        }, configured.dap)
    end)

    a.it("constructs standalone commands as argv without quoting paths", function()
        local source_path = temp_path() .. " source with spaces.zig"
        table.insert(temp_paths, source_path)
        write(source_path, 'test "works" {}\n')
        adapter.path_to_zig = "/opt/zig versions/0.16/zig"

        local generated = {
            temp_path(),
            temp_path(),
            temp_path(),
            temp_path(),
        }
        local index = 0
        adapter._get_temp_file_path = function()
            index = index + 1
            return generated[index]
        end

        local spec = adapter._build_spec_without_buildfile({
            tree = test_node('"works"', source_path),
        })

        assert.is_table(spec.command)
        assert.same({
            "/opt/zig versions/0.16/zig",
            "test",
            source_path,
            "--test-runner",
            spec.command[5],
            "--test-cmd-bin",
            "--test-cmd",
            "--neotest-input-path",
            "--test-cmd",
            generated[2],
            "--test-cmd",
            "--neotest-results-path",
            "--test-cmd",
            generated[3],
            "--test-cmd",
            "--neotest-source-path",
            "--test-cmd",
            source_path,
            "--test-cmd",
            "--test-runner-logs-path",
            "--test-cmd",
            generated[4],
            "--test-cmd",
            "--test-runner-log-level",
            "--test-cmd",
            tostring(require("neotest-zig.log").get_log_level()),
        }, spec.command)
        assert.same({
            {
                test_name = "test.works",
                source_path = source_path,
                output_path = generated[1],
            },
        }, vim.json.decode(read(generated[2])))
        assert.equals(generated[3], spec.context.test_results_dir_path)
    end)

    a.it("constructs build commands as argv without quoting paths", function()
        local project = temp_path() .. " project with spaces"
        mkdir(project)
        local build_file = project .. "/build.zig"
        write(build_file, "")
        local source_path = project .. "/source file.zig"
        write(source_path, 'test "works" {}\n')
        adapter.path_to_zig = "/opt/zig versions/0.16/zig"

        local generated = {
            temp_path(),
            temp_path(),
            temp_path(),
            temp_path(),
        }
        local index = 0
        adapter._get_temp_file_path = function()
            index = index + 1
            return generated[index]
        end

        local spec = adapter._build_spec_with_buildfile({
            tree = tree({
                id = source_path,
                name = "source file.zig",
                path = source_path,
                type = "file",
            }, {
                test_node('"works"', source_path),
            }),
        }, build_file)

        assert.is_table(spec.command)
        assert.same({
            "/opt/zig versions/0.16/zig",
            "build",
            "test",
            "--build-file",
            project .. "/neotest_build.zig",
            "-Dneotest-runner=" .. spec.command[6]:sub(#"-Dneotest-runner=" + 1),
            "--",
            "--neotest-input-path",
            generated[2],
            "--neotest-results-path",
            generated[3],
            "--test-runner-logs-path",
            generated[4],
            "--test-runner-log-level",
            tostring(require("neotest-zig.log").get_log_level()),
        }, spec.command)
        assert.same({
            {
                test_name = "test.works",
                source_path = source_path,
                output_path = generated[1],
            },
        }, vim.json.decode(read(generated[2])))
        assert.same({
            temp_neotest_build_file_path = project .. "/neotest_build.zig",
            test_results_dir_path = generated[3],
        }, spec.context)
    end)

    a.it("preserves DAP arguments and reports asynchronous build failures", function()
        local project = temp_path()
        mkdir(project)
        local build_file = project .. "/build.zig"
        write(build_file, "")
        local source_path = project .. "/source.zig"
        write(source_path, 'test "works" {}\n')
        adapter.path_to_zig = "/opt/zig versions/0.16/zig"
        adapter.dap = { adapter = "codelldb" }

        local generated = {
            temp_path(),
            temp_path(),
            temp_path(),
            temp_path(),
        }
        local index = 0
        adapter._get_temp_file_path = function()
            index = index + 1
            return generated[index]
        end

        local build_command
        vim.system = function(command, _, on_exit)
            build_command = command
            on_exit({ code = 1, stderr = "compile failed" })
        end

        local spec = adapter._build_spec_with_buildfile({
            strategy = "dap",
            tree = tree({
                id = source_path,
                name = "source.zig",
                path = source_path,
                type = "file",
            }, {
                test_node('"works"', source_path),
            }),
        }, build_file)

        assert.same({
            "/opt/zig versions/0.16/zig",
            "build",
            "neotest-build",
            "--build-file",
            project .. "/neotest_build.zig",
            "-Dneotest-runner=" .. spec.command[6]:sub(#"-Dneotest-runner=" + 1),
        }, build_command)
        assert.same({
            name = "Debug with neotest-zig",
            type = "codelldb",
            request = "launch",
            args = {
                "--neotest-input-path",
                generated[2],
                "--neotest-results-path",
                generated[3],
                "--test-runner-logs-path",
                generated[4],
                "--test-runner-log-level",
                tostring(require("neotest-zig.log").get_log_level()),
            },
            initCommands = { "command source ~/.lldbinit" },
        }, spec.strategy)
        assert.is_truthy(spec.context.dap_build_error:find("compile failed", 1, true))
    end)

    a.it("aggregates result files and marks missing tests skipped", function()
        local results_dir = temp_path()
        mkdir(results_dir)
        local source_path = "/tmp/source.zig"
        write(results_dir .. "/one.json", vim.json.encode({
            {
                test_name = "test.present",
                source_path = source_path,
                output = "/tmp/test-output",
                status = "passed",
                short = "ok",
                errors = {},
            },
        }))
        write(results_dir .. "/two.json", vim.json.encode({
            {
                test_name = "decltest.declaration",
                source_path = source_path,
                output = "/tmp/declaration-output",
                status = "failed",
                short = "failed",
                errors = { { message = "expected true", line = 4 } },
            },
        }))
        mkdir(results_dir .. "/nested")

        local present = test_node('"present"', source_path, "present")
        local declaration = test_node("declaration", source_path, "declaration")
        local missing = test_node('"missing"', source_path, "missing")
        local root = tree({
            id = source_path,
            name = "source.zig",
            path = source_path,
            type = "file",
        }, { present, declaration, missing })

        local results = adapter.results({
            context = { test_results_dir_path = results_dir },
        }, { code = 0 }, root)

        assert.same({
            status = "passed",
            short = "ok",
            errors = {},
            output = "/tmp/test-output",
        }, results.present)
        assert.same({
            status = "skipped",
            short = "No results found. Make sure the test is included in build.",
            errors = {},
        }, results.missing)
        assert.same({
            status = "failed",
            short = "failed",
            errors = { { message = "expected true", line = 4 } },
            output = "/tmp/declaration-output",
        }, results.declaration)
    end)

    a.it("reports nonzero exits and cleans the copied build file", function()
        local copied_build_file = temp_path()
        local output = temp_path()
        write(copied_build_file, "temporary")
        write(output, "compiler failed")

        local results = adapter.results({
            context = {
                temp_neotest_build_file_path = copied_build_file,
                test_results_dir_path = temp_path(),
            },
        }, {
            code = 1,
            output = output,
        }, tree({
            id = "root",
            name = "root",
            path = "/tmp",
            type = "dir",
        }))

        assert.equals(0, vim.fn.filereadable(copied_build_file))
        assert.same({
            run = {
                status = "error",
                short = "build or run returned non-zero exit code",
                errors = "compiler failed",
            },
        }, results)
    end)
end)
