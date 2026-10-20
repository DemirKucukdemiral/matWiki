-- Run from any directory: nvim --headless -u NONE -i NONE -l /path/to/tests/latex.lua
local project = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(project)
local latex = require('matwiki.latex')
local temporary = vim.fn.tempname() .. ' matwiki latex tests'
vim.fn.mkdir(temporary, 'p')
local messages = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  messages[#messages + 1] = { message = message, level = level }
end

local function write(path, lines)
  vim.fn.writefile(lines, path)
end

local function open(path)
  vim.cmd('edit! ' .. vim.fn.fnameescape(path))
end

local function finished()
  assert(vim.wait(30000, function()
    return not latex.status().running
  end, 20), 'PDF build timed out')
  return latex.status()
end

local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

local function tests()
  latex.setup({ cache_dir = temporary .. '/cache with spaces', open_quickfix = false })
  for _, name in ipairs({ 'MatwikiBuild', 'MatwikiView', 'MatwikiWatch', 'MatwikiLatexStop', 'MatwikiSnippet' }) do
    assert(vim.fn.exists(':' .. name) == 2, 'Missing command ' .. name)
  end

  -- Real native snippet expansion verifies TeX backslashes and literal dollar signs.
  local expected = {
    inline = '$x$',
    display = '\\[\n  x\n\\]\n',
    fraction = '\\frac{a}{b}',
    sum = '\\sum_{i=1}^{n} a_i',
    integral = '\\int_{a}^{b} f(x)\\, dx',
    matrix = '\\begin{pmatrix}\n  a & b \\\\\n  c & d\n\\end{pmatrix}\n',
    aligned = '\\begin{aligned}\n  a &= b \\\\\n  c &= d\n\\end{aligned}\n',
    theorem = '\\begin{theorem}[Title]\n\\label{thm:label}\nStatement.\n\\end{theorem}\n',
    proof = '\\begin{proof}\nProof.\n\\end{proof}\n',
  }
  for name, text in pairs(expected) do
    vim.cmd('enew!')
    latex.snippet(name)
    local actual = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert(actual == text, name .. ' snippet mismatch: ' .. vim.inspect(actual))
    vim.snippet.stop()
    vim.cmd('stopinsert')
  end
  latex.setup({ cache_dir = temporary .. '/cache with spaces', open_quickfix = false,
    snippets = { custom = function() return 'value = ${1:42}$0' end, fraction = 'override $0' } })
  vim.cmd('enew!')
  latex.snippet('custom')
  assert(vim.api.nvim_get_current_line() == 'value = 42', 'Function snippets failed')
  vim.snippet.stop()
  vim.cmd('enew!')
  latex.snippet('fraction')
  assert(vim.api.nvim_get_current_line() == 'override ', 'Snippet override failed')
  vim.snippet.stop()

  -- No shell expansion is used for magic-root names; cycles produce a useful error.
  local cycle_a, cycle_b = temporary .. '/cycle-a.tex', temporary .. '/cycle-b.tex'
  write(cycle_a, { '% !TeX root = cycle-b.tex' })
  write(cycle_b, { '% !TeX root = cycle-a.tex' })
  open(cycle_a)
  assert(latex.build() == false, 'Magic-root cycle was accepted')
  assert(contains(messages[#messages].message, 'Cycle'), 'Missing cycle diagnostic')

  local main = temporary .. '/main note.tex'
  local section = temporary .. '/section.tex'
  write(main, { '\\documentclass{article}', '\\usepackage{amsmath}', '\\begin{document}',
    '\\input{section.tex}', '\\end{document}' })
  write(section, { '% !TeX root = "main note.tex"', 'A test: $\\int_0^1 x^2 \\, dx = \\frac{1}{3}$.' })
  open(section)
  assert(latex.status().source == main, 'Relative magic-root resolution failed')
  assert(contains(latex.status().pdf, '/latex/'), 'Configured cache directory not used')

  if vim.fn.executable('latexmk') == 1 and vim.fn.executable('pdflatex') == 1 then
    assert(latex.build(), 'Real TeX build did not start')
    local good = finished()
    assert(good.last_exit == 0, 'Real TeX build failed; inspect ' .. good.log)
    assert(vim.fn.filereadable(good.pdf) == 1, 'Real TeX build produced no PDF')
    local pdf_header = io.open(good.pdf, 'rb')
    assert(pdf_header and pdf_header:read(4) == '%PDF', 'Output is not a PDF')
    pdf_header:close()
    assert(vim.fn.filereadable((good.pdf:gsub('%.pdf$', '.synctex.gz'))) == 1, 'SyncTeX output is missing')

    -- Save a watched input and require a genuine asynchronous second build.
    assert(latex.watch() == true, 'Watch did not enable')
    finished()
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { 'The next saved revision is also valid: $a^2+b^2=c^2$.' })
    vim.cmd('write')
    assert(latex.status().running, 'Writing a watched source did not trigger a build')
    assert(finished().last_exit == 0, 'Watch rebuild failed')
    assert(latex.watch() == false, 'Watch did not disable')

    -- An actual TeX error must fail and identify the included file and line.
    vim.api.nvim_buf_set_lines(0, 1, -1, false, { '\\definitelyundefinedmatwikicommand' })
    assert(latex.build(), 'Broken TeX build did not start')
    local bad = finished()
    assert(bad.last_exit ~= 0, 'Invalid TeX reported success')
    local errors = vim.fn.getqflist()
    assert(vim.tbl_contains(errors, function(item)
      return item.valid == 1 and item.lnum == 2 and vim.api.nvim_buf_get_name(item.bufnr) == section
    end, { predicate = true }), 'Quickfix lacks the correct included-file location: ' .. vim.inspect(errors))
    assert(latex.view() == false, 'Preview silently opened a stale PDF after a failed build')
    print('PASS: real latexmk success, SyncTeX, watch rebuild, and compiler failure diagnostics')
  else
    print('SKIP: real compilation requires latexmk and pdflatex')
  end

  -- Markdown must diagnose missing Pandoc without treating the operation as success.
  local markdown = temporary .. '/math note.md'
  write(markdown, { '# Test', '', '$E=mc^2$' })
  open(markdown)
  local executable = vim.fn.executable
  vim.fn.executable = function(command)
    return command == 'pandoc' and 0 or executable(command)
  end
  assert(latex.build() == false, 'Missing Pandoc was accepted')
  assert(contains(messages[#messages].message, 'Pandoc'), 'Missing Pandoc diagnostic is unclear')
  vim.fn.executable = executable

  -- A custom previewer receives a literal path argument, with no GUI or shell.
  latex.setup({ viewer = { '/usr/bin/true', '{file}' }, open_quickfix = false })
  local markdown_status = latex.status()
  vim.fn.mkdir(vim.fs.dirname(markdown_status.pdf), 'p')
  write(markdown_status.pdf, { '%PDF-preview-command-test' })
  local original_system = vim.system
  local captured
  vim.system = function(argv)
    captured = argv
    return { pid = 0 }
  end
  assert(latex.view(), 'Custom viewer did not start')
  vim.system = original_system
  assert(captured[1] == '/usr/bin/true' and captured[2] == markdown_status.pdf, 'Viewer did not receive the literal PDF path')
  assert(latex.stop(), 'Stop should safely disable an inactive watcher')
  print('PASS: native snippets, overrides, magic roots, missing Pandoc, and viewer argument safety')
end

local ok, err = xpcall(tests, debug.traceback)
vim.notify = original_notify
vim.fn.delete(temporary, 'rf')
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
else
  print('All MatWiki LaTeX tests passed.')
  vim.cmd('qa!')
end
