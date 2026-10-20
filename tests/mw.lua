-- Headless test suite and benchmark for the .mw compiler, HTML/CSS exporter,
-- persistent kernels, in-buffer output blocks, and live preview server.
-- Run: nvim --headless -u NONE -i NONE -n -l tests/mw.lua
local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ':p')))
vim.opt.runtimepath:prepend(root)
vim.o.hidden, vim.o.swapfile = true, false

local uv = vim.uv or vim.loop
local mw = require('matwiki.mw')
local runner = require('matwiki.runner')
local server = require('matwiki.mw.server')

local tmp = assert(uv.fs_mkdtemp('/tmp/matwiki-mw-XXXXXX'))
local assertions = 0

local function truth(val, msg)
  assertions = assertions + 1
  assert(val, msg or 'assertion failed')
end

local function eq(actual, expected, msg)
  assertions = assertions + 1
  assert(vim.deep_equal(actual, expected), (msg or 'values differ')
    .. '\nExpected: ' .. vim.inspect(expected)
    .. '\nActual:   ' .. vim.inspect(actual))
end

local ok, err = xpcall(function()
  mw.setup({ root = root, vault = tmp })
  runner.setup({ vault = tmp, cache_dir = tmp .. '/cache' })

  -- 1. Front matter, math numbering, theorems, cells, refs, footnotes, tables, figures
  local sample = table.concat({
    '---',
    'title: Test Workbench',
    'author: Ada Lovelace',
    'number-sections: true',
    'macros: { \\R: "\\\\mathbb{R}", \\tr: "\\\\operatorname{tr}" }',
    'tags: [math, spectral]',
    'abstract: |',
    '  Short abstract with $x \\in \\R$.',
    '---',
    '',
    '# Introduction {#sec:intro}',
    '',
    'Inline $\\tr(A)$ and \\(y^2\\). Forward refs: @eq:quad, \\eqref{eq:euler}, @thm:main, @fig:plot, @tbl:data, @cell:py1.',
    'Also a footnote[^fn1] and inline note^[Inline footnote text].',
    '',
    '$$',
    'q(x) = x^T A x',
    '$$ {#eq:quad}',
    '',
    '\\begin{equation}',
    '\\label{eq:euler}',
    'e^{i\\pi} + 1 = 0',
    '\\end{equation}',
    '',
    '::: theorem {#thm:main title=" Spectral Bound "}',
    'For all $x \\in \\R^n$, $q(x) \\le \\lambda_{\\max} \\lVert x \\rVert^2$.',
    ':::',
    '',
    '::: proof',
    'Immediate from @eq:quad.',
    ':::',
    '',
    '::: lemma {.unnumbered}',
    'Unnumbered helper lemma.',
    ':::',
    '',
    '> [!WARNING] Watch out',
    '> Singular matrix ahead.',
    '',
    '```python {#cell:py1}',
    'print(6 * 7)',
    '![plot](test.assets/fig1.png)',
    '```',
    '```output {of=cell:py1}',
    '42',
    '![plot](test.assets/fig1.png)',
    '```',
    '',
    '```python {echo=fold output=fold}',
    'x = 1',
    '```',
    '```output',
    'folded output',
    '```',
    '',
    '![Eigenvalue decay](decay.png){#fig:plot width=400}',
    '',
    '| Name | Value |',
    '| :--- | ---: |',
    '| $\\lambda_1$ | 1.0 |',
    '',
    ': Eigenvalue table {#tbl:data}',
    '',
    '- [x] Completed task',
    '- [ ] Pending task',
    '',
    '[^fn1]: First footnote body.',
  }, '\n')

  local page, doc, frag, elapsed = mw.render(sample, { matwiki_root = root })
  truth(elapsed < 50, 'render should be fast')
  eq(doc.meta.title, 'Test Workbench', 'front matter title')
  eq(doc.meta.author, 'Ada Lovelace', 'front matter author')
  eq(doc.meta.macros['\\tr'], '\\operatorname{tr}', 'front matter macros')
  eq(#doc.diags, 0, 'no diagnostics on valid document: ' .. vim.inspect(doc.diags))

  -- Verify cross-reference resolution
  truth(frag.body:find('href="#eq:quad">(1)</a>', 1, true), 'equation 1 ref resolved')
  truth(frag.body:find('href="#eq:euler">(2)</a>', 1, true), 'equation 2 ref resolved')
  truth(frag.body:find('href="#thm:main">Theorem 1</a>', 1, true), 'theorem ref resolved')
  truth(frag.body:find('href="#fig:plot">Figure 1</a>', 1, true), 'figure ref resolved')
  truth(frag.body:find('href="#tbl:data">Table 1</a>', 1, true), 'table ref resolved')
  truth(frag.body:find('href="#cell:py1">Cell 1</a>', 1, true), 'cell ref resolved')

  -- Verify theorem & proof rendering
  truth(frag.body:find('Theorem 1 <span class="mw-env-title">(Spectral Bound)</span>.', 1, true), 'theorem header')
  truth(frag.body:find('&#8718;', 1, true), 'proof QED symbol')
  truth(frag.body:find('Lemma.</div>', 1, true), 'unnumbered lemma has no number')
  truth(frag.body:find('mw-env-warning', 1, true), 'GitHub alert blockquote converted to callout')

  -- Verify cell & hybrid output rendering
  truth(frag.body:find('In [1]:', 1, true), 'cell input prompt')
  truth(frag.body:find('Out [1]:', 1, true), 'cell output prompt')
  truth(frag.body:find('<pre class="mw-output-stream">42</pre>', 1, true), 'cell stream output')
  truth(frag.body:find('<div class="mw-output-rich"><img src="test.assets/fig1.png"', 1, true), 'cell image output')
  truth(frag.body:find('<details class="mw-cell-fold"><summary>Show code (In [2]:)</summary>', 1, true), 'echo=fold')

  -- Verify footnotes & tasks
  truth(frag.footnotes:find('id="fn-fn1"', 1, true), 'named footnote rendered')
  truth(frag.footnotes:find('id="fn-n1"', 1, true), 'inline footnote rendered')
  truth(frag.body:find('class="mw-task-item"><input type="checkbox" disabled checked>', 1, true), 'task list')
  truth(page:find('window.MW_MACROS =', 1, true), 'page includes KaTeX macros')

  -- 2. In-buffer cell execution, persistent Python kernel, and ```output write-back
  local mw_path = tmp .. '/session-test.mw'
  vim.fn.writefile({
    '# Kernel Test',
    '',
    '```python {#cell:a}',
    'shared_var = 40',
    'print("init", shared_var)',
    '```',
    '',
    '```python {#cell:b}',
    'shared_var + 2',
    '```',
  }, mw_path)
  vim.cmd.edit(vim.fn.fnameescape(mw_path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = 'mw'

  -- Run first cell via M.run()
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  assert(runner.run(), 'cell 1 should start')
  assert(vim.wait(10000, function() return runner._state.job == nil end, 10), 'cell 1 should finish')
  local lines_after_1 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  truth(table.concat(lines_after_1, '\n'):find('```output {of=cell:a}\ninit 40\n```', 1, true),
    'cell 1 output written into .mw buffer')

  -- Run second cell (uses shared_var from cell 1 and auto-prints last expression)
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  assert(runner.run(), 'cell 2 should start')
  assert(vim.wait(10000, function() return runner._state.job == nil end, 10), 'cell 2 should finish')
  local lines_after_2 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  truth(table.concat(lines_after_2, '\n'):find('```output {of=cell:b}\n42\n```', 1, true),
    'persistent kernel preserved state and auto-printed final expression')

  -- Re-running cell 2 updates its ```output block in-place instead of duplicating it
  vim.api.nvim_buf_set_lines(buf, 11, 12, false, { 'shared_var + 100' })
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  assert(runner.run())
  assert(vim.wait(10000, function() return runner._state.job == nil end, 10))
  local lines_after_3 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local joined_3 = table.concat(lines_after_3, '\n')
  truth(joined_3:find('```output {of=cell:b}\n140\n```', 1, true), 'output updated in-place')
  local _, out_count = joined_3:gsub('```output', '')
  eq(out_count, 2, 'still exactly two output blocks')

  -- Clear outputs
  eq(mw.clear_outputs(buf), 2, 'clear_outputs removes both output blocks')
  vim.cmd('write')

  -- 3. Vault export & standalone export
  local linked_path = tmp .. '/linked-topic.mw'
  vim.fn.writefile({
    '---',
    'title: Linked Topic',
    '---',
    '',
    'See [[session-test|Session Test]] for details.',
  }, linked_path)

  local site_res = mw.export_vault({
    vault = tmp,
    matwiki_root = root,
    out_dir = tmp .. '/.site',
  })
  truth(site_res.ok and site_res.count == 2, 'vault export compiled 2 notes')
  truth(uv.fs_stat(tmp .. '/.site/index.html'), 'index.html created')
  truth(uv.fs_stat(tmp .. '/.site/assets/mw.css'), 'mw.css copied to site assets')
  truth(uv.fs_stat(tmp .. '/.site/assets/katex/katex.min.js'), 'KaTeX copied to site assets')
  local session_html = mw.util.read_file(tmp .. '/.site/session-test.html')
  truth(session_html:find('Linked from', 1, true) and session_html:find('Linked Topic', 1, true),
    'backlink card rendered on target page')

  local standalone_out = tmp .. '/standalone.html'
  local st_res = assert(mw.compile_file(root .. '/notebook/spectral-workbench.mw', standalone_out, {
    matwiki_root = root,
    standalone = true,
  }))
  local st_html = mw.util.read_file(st_res.output)
  truth(st_html:find('<style>', 1, true) and st_html:find('data:font/woff2;base64,', 1, true),
    'standalone HTML embeds CSS and KaTeX woff2 fonts inline')

  -- 4. Live preview server (HTTP + fragment JSON)
  local port = assert(server.start({ root = root, vault = tmp }))
  local curl_res
  vim.system({ 'curl', '-fsS', string.format('http://127.0.0.1:%d/session-test.html?fragment=1', port) }, { text = true }, function(r)
    curl_res = r
  end)
  assert(vim.wait(5000, function() return curl_res ~= nil end, 10), 'preview server should respond')
  eq(curl_res.code, 0, 'preview server responds 200 to fragment request')
  local decoded = vim.json.decode(curl_res.stdout)
  truth(decoded and decoded.shell and decoded.shell:find('Kernel Test', 1, true), 'fragment JSON contains rendered shell')
  server.stop(true)

  -- 5. UI standalone setup, dashboard, and doctor
  local matwiki = require('matwiki').setup({
    root = root,
    vault = tmp,
    cache_dir = tmp .. '/cache',
    standalone = true,
  })
  local ui = require('matwiki.ui')
  ui.dashboard(matwiki.config)
  local dash_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  truth(dash_lines:find('M A T W I K I', 1, true) and dash_lines:find('New .mw note', 1, true),
    'dashboard renders MatWiki home screen with .mw shortcut')
  ui.doctor(matwiki.config)
  local doc_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  truth(doc_lines:find('MatWiki dependency check', 1, true), 'doctor screen renders')

  -- 6. Performance benchmark on spectral-workbench.mw
  local bench_src = mw.util.read_file(root .. '/notebook/spectral-workbench.mw')
  local t0 = uv.hrtime()
  local runs = 50
  for _ = 1, runs do
    mw.render(bench_src, { matwiki_root = root })
  end
  local avg_ms = ((uv.hrtime() - t0) / 1e6) / runs
  truth(avg_ms < 5.0, string.format('expected < 5 ms per compile, got %.2f ms', avg_ms))
  print(string.format('mw tests: %d assertions passed (avg compile: %.2f ms)', assertions, avg_ms))
end, debug.traceback)

require('matwiki.mw.kernel').restart()
server.stop(true)
vim.fn.delete(tmp, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
