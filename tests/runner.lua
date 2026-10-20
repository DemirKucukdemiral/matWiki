-- nvim --headless -u NONE -l tests/runner.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local runner = require('matwiki.runner')
local tmp = vim.fn.tempname() .. ' matwiki $(touch INJECTED)'
vim.fn.mkdir(tmp, 'p')
local notices = {}
vim.notify = function(message) table.insert(notices, message) end
runner.setup({ vault = tmp, cache_dir = vim.fs.joinpath(tmp, 'cache') })

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or 'Values differ') .. '\nActual: ' .. vim.inspect(actual) .. '\nExpected: ' .. vim.inspect(expected))
end
local function note(lines)
  vim.cmd('enew!')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(tmp, 'note-' .. buf .. '.md'))
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local ok, err = xpcall(function()
  local sample = { '# Test', '```python', 'print("``` is text")', '~~~', '```', 'after', '  ~~~~{.python}', '  print(2)', '  ~~~~' }
  local block = assert(runner._find_block(sample, 2))
  equal(block.code, { 'print("``` is text")', '~~~' }, 'An alternate fence must stay inside code')
  equal(block.language, 'python')
  local second = assert(runner._find_block(sample, 7))
  equal(second.code, { 'print(2)' })
  equal(second.language, 'python')
  assert(not runner._find_block(sample, 5), 'Prose must not select a block')
  assert(not runner._find_block({ '```python', 'print(1)' }, 1), 'Unclosed fences must not run')
  equal(runner._argv({ 'python3', '{file}' }, '/a/$(touch injected); file.py'), { 'python3', '/a/$(touch injected); file.py' })

  local source = note({ 'before', '```python', 'print("original")', '```', 'after' })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local editor = assert(runner.edit_block())
  equal(vim.bo[editor].filetype, 'python')
  assert(vim.fn.filereadable(vim.api.nvim_buf_get_name(editor)) == 1, 'Block needs a real file for tooling')
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { 'inserted above' })
  vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'print("edited")', '```', 'more' })
  vim.cmd('write')
  equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), {
    'inserted above', 'before', '````python', 'print("edited")', '```', 'more', '````', 'after',
  }, 'Writing must follow shifted extmarks and expand colliding fences')
  assert(vim.bo[source].modified, 'Source note should remain unsaved until the user saves it')
  assert(not vim.bo[editor].modified, 'The editor write should finish successfully')
  vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'print("second write")' })
  vim.cmd('write')
  equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), {
    'inserted above', 'before', '````python', 'print("second write")', '````', 'after',
  }, 'Repeated block writes must retain safe fences')
  vim.api.nvim_buf_set_lines(source, 3, 4, false, { 'user changed the source' })
  vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'do not overwrite source' })
  vim.cmd('write')
  equal(vim.api.nvim_buf_get_lines(source, 3, 4, false), { 'user changed the source' })
  assert(vim.bo[editor].modified, 'A refused write must keep pending edits')
  assert(notices[#notices]:find('source block changed', 1, true), 'Conflict should explain why saving was refused')
  vim.api.nvim_buf_delete(editor, { force = true })

  note({ '```python', 'import os, sys', 'print("hello from python")', 'print(os.getcwd())', 'print("stderr works", file=sys.stderr)', '```' })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  assert(runner.run(), 'Python must start')
  assert(vim.wait(10000, function() return runner._state.job == nil end, 10), 'Python did not finish')
  equal(runner._state.last_run.exit_code, 0)
  local output = table.concat(vim.api.nvim_buf_get_lines(runner._state.output, 0, -1, false), '\n')
  assert(output:find('hello from python', 1, true))
  assert(output:find(tmp, 1, true), 'Runner should use the source directory')
  assert(output:find('stderr works', 1, true))
  assert(output:find('[Exit 0]', 1, true))
  assert(vim.fn.filereadable(vim.fs.joinpath(tmp, 'INJECTED')) == 0, 'Script path must never be shell-expanded')
  assert(vim.fn.filereadable('INJECTED') == 0, 'Script path must never run shell substitutions')
  assert(vim.fn.filereadable(runner._state.last_run.file) == 0, 'Finished temporary scripts should be deleted')

  local old = note({ '```python', 'import time', 'time.sleep(2)', 'print("OLD RUN SHOULD NOT APPEAR")', '```' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(runner.run())
  vim.api.nvim_buf_set_lines(old, 1, 4, false, { 'print("new run")' })
  assert(runner.run())
  assert(vim.wait(10000, function() return runner._state.job == nil end, 10))
  output = table.concat(vim.api.nvim_buf_get_lines(runner._state.output, 0, -1, false), '\n')
  assert(output:find('new run', 1, true))
  assert(not output:find('OLD RUN SHOULD NOT APPEAR', 1, true), 'Cancelled jobs must not mix into a new run')

  runner.setup({ vault = tmp, cache_dir = vim.fs.joinpath(tmp, 'cache'), max_output_bytes = 1024, max_output_lines = 20 })
  note({ '```python', 'print("x" * 5000)', '```' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(runner.run())
  assert(vim.wait(10000, function() return runner._state.job == nil end, 10))
  output = table.concat(vim.api.nvim_buf_get_lines(runner._state.output, 0, -1, false), '\n')
  assert(output:find('Output truncated', 1, true), 'Output must be bounded')
  assert(#output < 3000, 'Output cap should prevent runaway buffers')
end, debug.traceback)
runner.stop()
vim.fn.delete(tmp, 'rf')
if not ok then error(err) end
print('MatWiki runner: all tests passed')
