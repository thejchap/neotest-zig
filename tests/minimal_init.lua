local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.runtimepath:prepend(root)

local dependency_root = vim.env.NEOTEST_ZIG_DEPS
    or (vim.fn.stdpath("data") .. "/lazy")

for _, dependency in ipairs({
    "plenary.nvim",
    "nvim-nio",
    "neotest",
}) do
    local path = dependency_root .. "/" .. dependency
    if vim.fn.isdirectory(path) == 1 then
        vim.opt.runtimepath:append(path)
    end
end

