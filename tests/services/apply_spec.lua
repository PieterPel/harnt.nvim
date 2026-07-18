---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; and its narrowing is invisible to emmylua)

local apply = require("harnt.services.apply")

local function read_file(path)
  return vim.fn.readfile(path)
end

describe("apply.write_file", function()
  it("writes lines to disk", function()
    local path = vim.fn.tempname()
    local ok, err = apply.write_file(path, { "one", "two" })
    assert.is_true(ok)
    assert.is_nil(err)
    assert.same({ "one", "two" }, read_file(path))
  end)

  it("creates missing parent directories", function()
    local path = vim.fn.tempname() .. "/nested/deep/file.txt"
    local ok = apply.write_file(path, { "hi" })
    assert.is_true(ok)
    assert.equals(1, vim.fn.filereadable(path))
  end)
end)

describe("apply.set_buffer", function()
  it("replaces a buffer's contents in memory", function()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "old" })
    apply.set_buffer(bufnr, { "new", "content" })
    assert.same({ "new", "content" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)

describe("apply.apply_file", function()
  it("writes the file and reloads an unmodified open buffer", function()
    local autoread = vim.o.autoread
    vim.o.autoread = true

    local path = vim.fn.tempname() .. ".txt"
    assert.is_true(apply.write_file(path, { "before" }))

    -- open it in a buffer
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.same({ "before" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

    -- apply new content; the open buffer should reload
    assert.is_true(apply.apply_file(path, { "after", "line2" }))
    assert.same({ "after", "line2" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

    vim.o.autoread = autoread
  end)

  it("does not clobber a buffer with unsaved edits", function()
    local path = vim.fn.tempname() .. ".txt"
    assert.is_true(apply.write_file(path, { "before" }))

    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    -- simulate an unsaved user edit
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "user edit" })
    assert.is_true(vim.bo[bufnr].modified)

    apply.apply_file(path, { "agent write" })
    -- checktime must not overwrite the modified buffer
    assert.same({ "user edit" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("returns an error when the path is unwritable", function()
    -- creating a directory directly under / requires root; mkdir -p fails
    local ok, err = apply.apply_file("/harnt_no_permission_dir/sub/file.txt", { "x" })
    assert.is_false(ok)
    assert.is_string(err)
  end)
end)
