-- Native, asynchronous TeX builds. This module deliberately owns no VimTeX commands.
local M = {}
local config = {}
local builds = {}
local watched = {}

local engine_flags = { pdflatex = '-pdf', lualatex = '-lualatex', xelatex = '-xelatex' }
local snippets = {
  inline = [[\$${1:x}\$$0]],
  display = [=[\\[
  ${1:x}
\\]
$0]=],
  fraction = [[\\frac{${1:a}}{${2:b}}$0]],
  sum = [[\\sum_{${1:i=1}}^{${2:n}} ${3:a_i}$0]],
  integral = [[\\int_{${1:a}}^{${2:b}} ${3:f(x)}\\, d${4:x}$0]],
  matrix = [=[\\begin{${1:pmatrix}}
  ${2:a} & ${3:b} \\\\
  ${4:c} & ${5:d}
\\end{$1}
$0]=],
  aligned = [=[\\begin{aligned}
  ${1:a} &= ${2:b} \\\\
  ${3:c} &= ${4:d}
\\end{aligned}
$0]=],
  theorem = [=[\\begin{theorem}[${1:Title}]
\\label{thm:${2:label}}
${3:Statement.}
\\end{theorem}
$0]=],
  proof = [=[\\begin{proof}
${1:Proof.}
\\end{proof}
$0]=],
}

local function notify(message, level)
  vim.notify('MatWiki: ' .. message, level or vim.log.levels.INFO)
end

local function absolute(path, directory)
  if path:sub(1, 1) ~= '/' then
    path = vim.fs.joinpath(directory or vim.fn.getcwd(), path)
  end
  return vim.fs.normalize(path)
end

local function extension(path)
  return (path:match('%.([^./]+)$') or ''):lower()
end

local function source_for(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    return nil, 'Save this note as a .tex or .md file before building.'
  end
  path = absolute(path)
  local ext = extension(path)
  if ext ~= 'tex' and ext ~= 'md' and ext ~= 'markdown' then
    return nil, 'PDF builds support .tex and Markdown notes.'
  end
  -- A magic root is a filename, never a command or an expression.
  local visited = {}
  for _ = 1, 16 do
    if visited[path] then
      return nil, 'Cycle in % !TeX root directives: ' .. path
    end
    visited[path] = true
    if vim.fn.filereadable(path) ~= 1 then
      return nil, 'Source file does not exist: ' .. path
    end
    if extension(path) ~= 'tex' then
      return path
    end
    local root
    for _, line in ipairs(vim.fn.readfile(path, '', 30)) do
      root = line:match('^%s*%%%s*!%s*[Tt][Ee][Xx]%s+[Rr][Oo][Oo][Tt]%s*=%s*(.-)%s*$')
      if root and root ~= '' then
        root = root:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
        break
      end
    end
    if not root or root == '' then
      return path
    end
    path = absolute(root, vim.fs.dirname(path))
    if extension(path) ~= 'tex' then
      return nil, 'The % !TeX root must point to a .tex file.'
    end
  end
  return nil, 'Too many nested % !TeX root directives.'
end

local function output_paths(source)
  local directory
  if config.cache_dir and config.cache_dir ~= '' then
    directory = vim.fs.joinpath(vim.fn.expand(config.cache_dir), 'latex', vim.fn.sha256(source):sub(1, 16))
  else
    directory = vim.fs.joinpath(vim.fs.dirname(source), '.matwiki-build')
  end
  directory = absolute(directory)
  local stem = vim.fs.basename(source):gsub('%.[^.]+$', '')
  return directory, vim.fs.joinpath(directory, stem .. '.pdf'), vim.fs.joinpath(directory, stem .. '.matwiki.log')
end

local errorformat = table.concat({
  '%E%f:%l:%c: %m',
  '%E%f:%l: %m',
  '%E! %m',
  '%Zl.%l %m',
  '%WLaTeX Warning: %m',
  '%WPackage %*[^ ] Warning: %m',
  '%-G%.%#',
}, ',')

local function diagnostics(state, output, failed)
  local lines = vim.split(output, '\n', { plain = true })
  -- TeX uses paths relative to its working directory, which may differ from
  -- Neovim's cwd. Resolve those before asking errorformat to parse the log.
  for index, line in ipairs(lines) do
    local path, number, message = line:match('^(.-):(%d+):%s*(.*)$')
    if path and path:match('%.[%w]+$') then
      lines[index] = absolute(path, vim.fs.dirname(state.source)) .. ':' .. number .. ': ' .. message
    end
  end
  vim.fn.setqflist({}, 'r', { title = 'MatWiki · ' .. vim.fs.basename(state.source), lines = lines, efm = errorformat })
  local valid = vim.tbl_filter(function(item)
    return item.valid == 1
  end, vim.fn.getqflist())
  if failed and #valid == 0 then
    vim.fn.setqflist({}, 'r', { title = 'MatWiki · build failed', items = {
      { filename = state.source, lnum = 1, type = 'E', text = 'PDF build failed (exit ' .. tostring(state.last_exit) .. '). Log: ' .. state.log },
    } })
  end
  if failed and config.open_quickfix ~= false then
    vim.cmd('botright copen')
  end
end

local function collect_inputs(state)
  state.inputs = { [state.source] = true }
  local recorder = state.pdf:gsub('%.pdf$', '.fls')
  if vim.fn.filereadable(recorder) ~= 1 then
    return
  end
  for _, line in ipairs(vim.fn.readfile(recorder)) do
    local path = line:match('^INPUT (.+)$')
    if path then
      state.inputs[absolute(path, vim.fs.dirname(state.source))] = true
    end
  end
end

local function viewer_command(pdf)
  local argv
  if config.viewer then
    if type(config.viewer) ~= 'table' or #config.viewer == 0 then
      return nil, 'viewer must be an argument list, such as { "zathura", "{file}" }.'
    end
    argv = vim.deepcopy(config.viewer)
  elseif vim.fn.has('macunix') == 1 then
    local skim = vim.uv.fs_stat('/Applications/Skim.app') or vim.uv.fs_stat(vim.fn.expand('~/Applications/Skim.app'))
    argv = skim and { 'open', '-a', 'Skim', '{file}' } or { 'open', '{file}' }
  elseif vim.fn.executable('zathura') == 1 then
    argv = { 'zathura', '{file}' }
  else
    argv = { 'xdg-open', '{file}' }
  end
  local replaced = false
  for index, arg in ipairs(argv) do
    if type(arg) ~= 'string' then
      return nil, 'Every viewer argument must be a string.'
    end
    argv[index] = arg:gsub('%{file%}', function()
      replaced = true
      return pdf
    end)
  end
  if not replaced then
    argv[#argv + 1] = pdf
  end
  if vim.fn.executable(argv[1]) ~= 1 then
    return nil, 'PDF viewer is unavailable: ' .. argv[1] .. '. Set viewer = { "your-viewer", "{file}" }.'
  end
  return argv
end

local function view_source(source)
  local state = builds[source]
  local _, pdf = output_paths(source)
  if state and state.last_exit and state.last_exit ~= 0 then
    notify('The latest PDF build failed. Fix the quickfix errors and rebuild.', vim.log.levels.WARN)
    return false
  end
  if vim.fn.filereadable(pdf) ~= 1 then
    notify('No compiled PDF yet. Run :MatwikiBuild first.', vim.log.levels.WARN)
    return false
  end
  local argv, err = viewer_command(pdf)
  if not argv then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  local ok, process = pcall(vim.system, argv, { text = true, detach = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        if state then
          state.previewed = false
        end
        notify('PDF viewer failed: ' .. vim.trim(result.stderr or ('exit ' .. result.code)), vim.log.levels.ERROR)
      end)
    end
  end)
  if not ok then
    notify('Could not start PDF viewer: ' .. tostring(process), vim.log.levels.ERROR)
    return false
  end
  if state then
    state.previewed = true
  end
  return true
end

local start_build
start_build = function(source, quiet)
  local state = builds[source]
  if state and state.running then
    state.pending = true
    if not quiet then
      notify('Build already running; the latest saved changes are queued.')
    end
    return true
  end
  local engine = config.engine or 'pdflatex'
  if not engine_flags[engine] then
    notify('Unsupported TeX engine: ' .. tostring(engine), vim.log.levels.ERROR)
    return false
  end
  local markdown = extension(source) ~= 'tex'
  local executable = markdown and 'pandoc' or 'latexmk'
  if vim.fn.executable(executable) ~= 1 then
    notify(markdown and 'Markdown PDF export needs Pandoc and a TeX engine. Install them, or write a .tex note and use latexmk.'
      or 'TeX builds need latexmk. Install a TeX distribution with latexmk, then retry.', vim.log.levels.ERROR)
    return false
  end
  if vim.fn.executable(engine) ~= 1 then
    notify('The selected TeX engine is unavailable: ' .. engine, vim.log.levels.ERROR)
    return false
  end
  local directory, pdf, log = output_paths(source)
  local ok_dir, dir_err = pcall(vim.fn.mkdir, directory, 'p')
  if not ok_dir then
    notify('Cannot create PDF build directory: ' .. tostring(dir_err), vim.log.levels.ERROR)
    return false
  end
  state = state or {}
  state.source, state.pdf, state.log = source, pdf, log
  state.running, state.pending, state.stopped = true, false, false
  state.last_exit = nil
  builds[source] = state
  local argv
  if markdown then
    argv = { 'pandoc', '--from=markdown+tex_math_dollars+tex_math_single_backslash', '--standalone',
      '--pdf-engine=' .. engine, '--pdf-engine-opt=-no-shell-escape', '--pdf-engine-opt=-file-line-error',
      '--output=' .. pdf, source }
  else
    argv = { 'latexmk', engine_flags[engine], '-interaction=nonstopmode', '-synctex=1',
      '-file-line-error', '-halt-on-error', '-no-shell-escape', '-outdir=' .. directory, source }
  end
  state.argv = argv
  local ok, process = pcall(vim.system, argv, { cwd = vim.fs.dirname(source), text = true }, function(result)
    vim.schedule(function()
      state.running, state.job = false, nil
      state.last_exit = result.code
      local output = (result.stdout or '') .. '\n' .. (result.stderr or '')
      state.output = output
      pcall(vim.fn.writefile, vim.split(output, '\n', { plain = true }), log)
      if state.stopped then
        state.pending = false
        notify('PDF build stopped.')
        return
      end
      -- Exit zero without an output is not a successful build.
      local failed = result.code ~= 0 or vim.fn.filereadable(pdf) ~= 1
      if failed and result.code == 0 then
        state.last_exit = -1
      end
      diagnostics(state, output, failed)
      collect_inputs(state)
      if failed then
        notify('PDF build failed. Use :copen for errors; full log: ' .. log, vim.log.levels.ERROR)
      else
        notify('PDF ready: ' .. pdf)
        if config.auto_view and not state.previewed then
          view_source(source)
        end
      end
      if state.pending then
        state.pending = false
        start_build(source, true)
      end
    end)
  end)
  if not ok then
    state.running, state.last_exit, state.job = false, -1, nil
    notify('Could not start PDF build: ' .. tostring(process), vim.log.levels.ERROR)
    return false
  end
  state.job = process
  if not quiet then
    notify('Building ' .. vim.fs.basename(source) .. '…')
  end
  return true
end

--- Save the current note and asynchronously compile its root document.
function M.build()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    local ok, err = pcall(vim.cmd, 'update')
    if not ok then
      notify('Could not save source: ' .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end
  local source, err = source_for(bufnr)
  if not source then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  return start_build(source)
end

function M.view()
  local source, err = source_for()
  if not source then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  return view_source(source)
end

--- Toggle build-on-save for the current root and its recorded TeX dependencies.
function M.watch()
  local source, err = source_for()
  if not source then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  watched[source] = not watched[source] or nil
  notify('Build on save ' .. (watched[source] and 'enabled' or 'disabled') .. ': ' .. vim.fs.basename(source))
  if watched[source] then
    M.build()
  end
  return watched[source] == true
end

function M.stop()
  local source, err = source_for()
  if not source then
    notify(err, vim.log.levels.WARN)
    return false
  end
  watched[source] = nil
  local state = builds[source]
  if state and state.running and state.job then
    state.stopped, state.pending = true, false
    state.job:kill(15)
  else
    notify('Build on save disabled; no PDF build is running.')
  end
  return true
end

--- Read-only snapshot for statuslines, integrations, and diagnostics.
function M.status()
  local source = source_for()
  if not source then
    return { running = false, watching = false }
  end
  local state = builds[source] or {}
  local _, pdf, log = output_paths(source)
  return { source = source, pdf = pdf, log = log, running = state.running == true,
    watching = watched[source] == true, last_exit = state.last_exit, pending = state.pending == true }
end

function M.snippet(name)
  local choices = vim.tbl_extend('force', snippets, config.snippets or {})
  local function expand(selected)
    if not selected then
      return
    end
    local body = choices[selected]
    if type(body) == 'function' then
      local ok, value = pcall(body)
      if not ok then
        notify('Snippet function failed: ' .. tostring(value), vim.log.levels.ERROR)
        return
      end
      body = value
    end
    if type(body) ~= 'string' then
      notify('Unknown or invalid snippet: ' .. selected, vim.log.levels.ERROR)
      return
    end
    local ok, err = pcall(vim.snippet.expand, body)
    if not ok then
      notify('Snippet failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
  if name and name ~= '' then
    expand(name)
    return
  end
  local names = vim.tbl_keys(choices)
  table.sort(names)
  vim.ui.select(names, { prompt = 'MatWiki · insert LaTeX snippet' }, expand)
end

function M.setup(options)
  config = options or {}
  local group = vim.api.nvim_create_augroup('MatWikiLatex', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(event)
      if next(watched) == nil then
        return
      end
      local path = absolute(vim.api.nvim_buf_get_name(event.buf))
      local resolved = source_for(event.buf)
      for source, enabled in pairs(watched) do
        local state = builds[source]
        if enabled and (resolved == source or path == source or (state and state.inputs and state.inputs[path])) then
          start_build(source, true)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, state in pairs(builds) do
        if state.running and state.job then
          state.stopped, state.pending = true, false
          state.job:kill(15)
        end
      end
    end,
  })
  local commands = { MatwikiBuild = M.build, MatwikiView = M.view, MatwikiWatch = M.watch, MatwikiLatexStop = M.stop }
  for name, callback in pairs(commands) do
    vim.api.nvim_create_user_command(name, callback, { force = true, desc = 'MatWiki LaTeX workflow' })
  end
  vim.api.nvim_create_user_command('MatwikiSnippet', function(args)
    M.snippet(args.args)
  end, { nargs = '?', force = true, desc = 'Insert a native LaTeX snippet', complete = function()
    local names = vim.tbl_keys(vim.tbl_extend('force', snippets, config.snippets or {}))
    table.sort(names)
    return names
  end })
end

return M
