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

local function mw_note(lines)
  local buf = note(lines)
  vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(tmp, 'note-' .. buf .. '.mw'))
  vim.bo[buf].filetype = 'mw'
  return buf
end

local function finished()
  assert(vim.wait(10000, function() return runner._state.job == nil and runner._state.batch == nil end, 10),
    'Cell execution did not finish')
end

local function cells(buf)
  return require('matwiki.mw').find_cells(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
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

  -- RunAll must retain named sessions without leaking variables between them.
  local batch = mw_note({
    '```python {session=alpha}', 'shared = 10', '```',
    '```python {session=beta}', 'shared = 100', '```',
    '```python {session=alpha}', 'shared + 1', '```',
    '```python {session=beta}', 'shared + 1', '```',
    '```python {run=manual}', 'raise RuntimeError("must not run")', '```',
    '```python {run=never}', 'raise RuntimeError("must not run")', '```',
    '```python {session=none}', 'print("isolated", "shared" not in globals())', '```',
  })
  runner.run_all()
  finished()
  local results = cells(batch)
  equal(results[3].out_lines, { '11' }, 'Named alpha session lost its state')
  equal(results[4].out_lines, { '101' }, 'Named beta session lost its state')
  assert(not results[5].out_lines and not results[6].out_lines, 'RunAll ignored manual/never attributes')
  equal(results[7].out_lines, { 'isolated True' }, 'session=none must execute in isolation')

  -- Explicit custom Python runners must apply to both execution commands.
  runner.setup({ vault = tmp, cache_dir = vim.fs.joinpath(tmp, 'cache'), runners = {
    python = { 'python3', '-c', 'import sys; print("custom runner"); exec(open(sys.argv[1]).read())', '{file}' },
  } })
  local custom = mw_note({ '```python', 'print("cell")', '```' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(runner.run())
  finished()
  equal(cells(custom)[1].out_lines, { 'custom runner', 'cell' })
  runner.run_all()
  finished()
  equal(cells(custom)[1].out_lines, { 'custom runner', 'cell' })
  runner.setup({ vault = tmp, cache_dir = vim.fs.joinpath(tmp, 'cache') })

  -- Editing prose above an executing cell must not misattach its result.
  local shifted = mw_note({ 'before', '```python', 'import time; time.sleep(0.1)', 'print("right cell")', '```' })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  assert(runner.run())
  vim.api.nvim_buf_set_lines(shifted, 0, 0, false, { 'new prose', '' })
  finished()
  equal(cells(shifted)[1].out_lines, { 'right cell' })
  require('matwiki.mw').clear_outputs(shifted)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  assert(runner.run())
  vim.api.nvim_buf_set_lines(shifted, 4, 5, false, { 'print("new code")' })
  finished()
  assert(not cells(shifted)[1].out_lines, 'A changed cell must not receive stale output')

  -- Stop cancels persistent execution, including the remaining RunAll cells.
  local stopped = mw_note({ '```python', 'import time; time.sleep(30)', '```',
    '```python', 'print("must not run")', '```' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(runner.run())
  assert(runner.stop(), 'Persistent cell did not support Stop')
  finished()
  assert(not cells(stopped)[1].out_lines, 'Cancelled output should not replace saved results')
  runner.run_all()
  assert(runner.stop(), 'RunAll did not support Stop')
  finished()
  assert(not cells(stopped)[2].out_lines, 'RunAll continued after Stop')
  assert(runner.run())
  mw_note({ '# No code cells' })
  runner.run_all()
  finished()
  assert(runner._state.job == nil, 'Empty RunAll retained the cancelled previous job')

  -- Restart immediately followed by evaluation must retain the new process.
  local kernel = require('matwiki.mw.kernel')
  local function evaluate(buf, lang, code)
    local result
    assert(kernel.eval(buf, lang, code, {}, function(res) result = res end))
    assert(vim.wait(10000, function() return result ~= nil end, 10), 'Kernel response timed out')
    assert(result.ok, vim.inspect(result.lines))
    return result.lines
  end
  local restarted = mw_note({ '# Restart test' })
  evaluate(restarted, 'python', { 'value = 1' })
  assert(kernel.restart(restarted) == 1)
  evaluate(restarted, 'python', { 'value = 50' })
  equal(evaluate(restarted, 'python', { 'value + 2' }), { '52' }, 'Old kernel exit removed the new session')
  if vim.fn.executable('node') == 1 then
    evaluate(restarted, 'javascript', { 'let shared = 7' })
    equal(evaluate(restarted, 'javascript', { 'console.log("node"); shared + 1' }), { 'node', '8' })
  end

  -- A small pyplot fixture verifies first-import interception and repeated show()
  -- without making the regression suite depend on an optional matplotlib install.
  vim.fn.mkdir(tmp .. '/matplotlib', 'p')
  vim.fn.writefile({}, tmp .. '/matplotlib/__init__.py')
  vim.fn.writefile({
    'figures = []',
    'class Figure:',
    '    def savefig(self, path, **kwargs):',
    '        with open(path, "w") as f: f.write("figure")',
    'def figure(n): return figures[n - 1]',
    'def get_fignums(): return list(range(1, len(figures) + 1))',
    'def close(*args): figures.clear()',
    'def plot(*args): figures.append(Figure())',
    'def show(*args): raise RuntimeError("plot hook was not installed")',
  }, tmp .. '/matplotlib/pyplot.py')
  local plotted = mw_note({
    '```python', 'import matplotlib.pyplot as plt', 'plt.plot([1])', 'plt.show()',
    'plt.plot([2])', 'plt.show()', 'print("done")', '```',
    '```python', 'plt.plot([3])', 'plt.show()', 'print("second")', '```',
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(runner.run())
  finished()
  local plots = cells(plotted)
  local assets = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(plotted), ':t:r') .. '.assets'
  equal(plots[1].out_lines, { 'done', '![figure](' .. assets .. '/cell-1.png)',
    '![figure](' .. assets .. '/cell-1-2.png)' }, 'First-import or repeated pyplot.show capture failed')
  vim.api.nvim_win_set_cursor(0, { plots[2].open_row + 2, 0 })
  assert(runner.run())
  finished()
  equal(cells(plotted)[2].out_lines, { 'second', '![figure](' .. assets .. '/cell-2.png)' },
    'Separate cells must use separate figure paths')
end, debug.traceback)
runner.stop()
require('matwiki.mw.kernel').restart()
vim.fn.delete(tmp, 'rf')
if not ok then error(err) end
print('MatWiki runner: all tests passed')
