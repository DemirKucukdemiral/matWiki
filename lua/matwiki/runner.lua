-- Explicit, local code execution and a language-aware editor for Markdown fences.
local M = {}
local ns = vim.api.nvim_create_namespace('matwiki.runner')
local state = { generation = 0, editors = {}, output = nil, job = nil }
local cfg = {}

local defaults = {
  python = { 'python3', '{file}' }, python3 = { 'python3', '{file}' },
  javascript = { 'node', '{file}' }, js = { 'node', '{file}' }, node = { 'node', '{file}' },
  lua = { 'lua', '{file}' }, bash = { 'bash', '{file}' }, sh = { 'sh', '{file}' },
  julia = { 'julia', '{file}' }, r = { 'Rscript', '{file}' },
}
local languages = {
  python = { 'python', 'py' }, python3 = { 'python', 'py' },
  js = { 'javascript', 'js' }, javascript = { 'javascript', 'js' }, node = { 'javascript', 'js' },
  lua = { 'lua', 'lua' }, bash = { 'sh', 'sh' }, sh = { 'sh', 'sh' },
  julia = { 'julia', 'jl' }, r = { 'r', 'R' },
  typescript = { 'typescript', 'ts' }, ts = { 'typescript', 'ts' },
  ruby = { 'ruby', 'rb' }, rust = { 'rust', 'rs' }, c = { 'c', 'c' }, cpp = { 'cpp', 'cpp' },
  tex = { 'tex', 'tex' }, latex = { 'tex', 'tex' },
}

local function fail(message)
  vim.notify('MatWiki: ' .. message, vim.log.levels.WARN)
  return nil, message
end

local function fence(line)
  local indent, marker, rest = line:match('^( *)([`~]+)(.*)$')
  if not indent or #indent > 3 or marker ~= marker:sub(1, 1):rep(#marker) or #marker < 3 then
    return nil
  end
  return { indent = indent, marker = marker, char = marker:sub(1, 1), rest = rest }
end

-- Rows are zero-based, matching the Neovim buffer API. Only complete fences qualify.
local function find_block(lines, row)
  local opening
  for index, line in ipairs(lines) do
    local f = fence(line)
    if opening then
      if f and f.char == opening.char and #f.marker >= #opening.marker and f.rest:match('^%s*$') then
        if row >= opening.open_row and row <= index - 1 then
          opening.close_row = index - 1
          opening.closing = f
          opening.code = {}
          opening.original = {}
          for n = opening.open_row + 1, index do table.insert(opening.original, lines[n]) end
          for n = opening.open_row + 2, index - 1 do
            local code = lines[n]
            if code:sub(1, #opening.indent) == opening.indent then code = code:sub(#opening.indent + 1) end
            table.insert(opening.code, code)
          end
          return opening
        end
        opening = nil
      end
    elseif f and not (f.char == '`' and f.rest:find('`', 1, true)) then
      opening = f
      opening.open_row = index - 1
      opening.language = (f.rest:match('^%s*{%.?([%w_+.-]+)') or f.rest:match('^%s*([%w_+.-]+)') or ''):lower()
    end
  end
  if opening and row >= opening.open_row then return nil, 'This code fence has no closing fence.' end
  return nil, 'Place the cursor inside a fenced code block.'
end

local function argv_for(runner, path)
  if type(runner) ~= 'table' or #runner == 0 then return nil, 'A runner must be a non-empty argv list.' end
  local argv, has_file = {}, false
  for _, arg in ipairs(runner) do
    if type(arg) ~= 'string' or arg == '' then return nil, 'Runner arguments must be non-empty strings.' end
    if arg:find('{file}', 1, true) then has_file = true end
    table.insert(argv, (arg:gsub('{file}', function() return path end)))
  end
  if not has_file then return nil, 'The runner must include a {file} argument.' end
  return argv
end

local function cache_file(language, directory)
  local info = languages[language]
  local extension = info and info[2] or language:gsub('[^%w]', '')
  if extension == '' then extension = 'txt' end
  local folder = vim.fs.joinpath(cfg.cache_dir, directory)
  vim.fn.mkdir(folder, 'p')
  local basename = tostring(vim.uv.os_getpid()) .. '-' .. vim.fn.fnamemodify(vim.fn.tempname(), ':t')
  return vim.fs.joinpath(folder, basename .. '.' .. extension)
end

local function cwd_for(buf)
  local editor = state.editors[buf]
  local source = editor and editor.source or buf
  local name = vim.api.nvim_buf_is_valid(source) and vim.api.nvim_buf_get_name(source) or ''
  local directory = name ~= '' and vim.fs.dirname(name) or cfg.vault
  return vim.fn.isdirectory(directory or '') == 1 and directory or cfg.vault
end

local function show_buffer(buf)
  local windows = vim.fn.win_findbuf(buf)
  if #windows == 0 then
    vim.cmd('botright 12split')
    vim.api.nvim_win_set_buf(0, buf)
    vim.wo.wrap = false
    vim.wo.number = false
    vim.wo.relativenumber = false
  else
    vim.api.nvim_set_current_win(windows[1])
  end
end

local function output_buffer()
  if not state.output or not vim.api.nvim_buf_is_valid(state.output) then
    state.output = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.output, 'matwiki://output')
    vim.bo[state.output].buftype = 'nofile'
    vim.bo[state.output].bufhidden = 'hide'
    vim.bo[state.output].swapfile = false
    vim.bo[state.output].filetype = 'matwiki-output'
    vim.bo[state.output].modifiable = false
    vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = state.output, silent = true, desc = 'Hide code output' })
  end
  return state.output
end

local function set_output(lines)
  local buf = output_buffer()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function append_output(lines)
  if #lines == 0 then return end
  local buf = output_buffer()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

-- Keep results attached to their original cell while the note is being edited.
local function cell_writer(source, block)
  local original = vim.api.nvim_buf_get_lines(source, block.open_row, block.close_row + 1, false)
  local mark = vim.api.nvim_buf_set_extmark(source, ns, block.open_row, 0, {
    end_row = block.close_row + 1, end_col = 0, right_gravity = true, end_right_gravity = false,
  })
  return function(lines, meta)
    if not vim.api.nvim_buf_is_valid(source) then return false end
    local position = vim.api.nvim_buf_get_extmark_by_id(source, ns, mark, { details = true })
    pcall(vim.api.nvim_buf_del_extmark, source, ns, mark)
    if not lines or #position == 0 or not position[3].end_row then return false end
    if not vim.deep_equal(original, vim.api.nvim_buf_get_lines(source, position[1], position[3].end_row, false)) then
      fail('Cell changed while running; its result was not written into the note.')
      return false
    end
    return require('matwiki.mw').write_cell_output(source, position[1], lines, meta)
  end
end

local function use_kernel(language, attrs)
  return not cfg.custom_runners[language] and attrs.kv.session ~= 'none'
    and require('matwiki.mw.kernel').supports(language)
end

function M.stop()
  if state.batch then state.batch.cancelled = true; state.batch = nil end
  local current = state.job
  if current then
    current.cancelled = true
    if current.kernel then
      require('matwiki.mw.kernel').stop(current.source, current.language, current.session)
    elseif current.process then
      current.process:kill(15)
    elseif current.id then
      vim.fn.jobstop(current.id)
    end
    return true
  end
  return false
end

function M.run()
  local source = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
  local ft = vim.bo[source].filetype:lower()
  local is_mw = ft == 'mw' or vim.api.nvim_buf_get_name(source):match('%.mw$') ~= nil
  local language = ft
  local block
  if ft == 'markdown' or ft == 'mw' or ft == 'quarto' or ft == 'rmd' or is_mw then
    local err
    block, err = find_block(lines, vim.api.nvim_win_get_cursor(0)[1] - 1)
    if not block then return fail(err) end
    lines, language = block.code, block.language
  elseif state.editors[source] then
    language = state.editors[source].language
  end
  if language == '' then return fail('Add a language to the code fence, for example ```python.') end
  if language == 'output' or language == 'result' or language == 'results' then
    return fail('Place the cursor inside a code cell, not its output block.')
  end

  -- In .mw buffers, use persistent kernel for Python/Node unless custom runner or session=none.
  local kernel = require('matwiki.mw.kernel')
  local attrs = block and require('matwiki.mw.util').parse_attrs(block.rest:match('%b{}')) or { kv = {} }
  if is_mw and block and use_kernel(language, attrs) then
    M.stop()
    state.generation = state.generation + 1
    local current = { generation = state.generation, lines = 0, bytes = 0,
      kernel = true, source = source, language = language, session = attrs.kv.session }
    local write_output = cell_writer(source, block)
    local cell_id = 1
    for index, cell in ipairs(require('matwiki.mw').find_cells(vim.api.nvim_buf_get_lines(source, 0, -1, false))) do
      if cell.open_row == block.open_row then cell_id = index; break end
    end
    state.job = current
    kernel.eval(source, language, lines, { session = attrs.kv.session, cell = cell_id }, function(res)
      if current.generation ~= state.generation then write_output(); return end
      current.exit_code = res.ok and 0 or 1
      state.last_run = current
      state.job = nil
      set_output(vim.list_extend({ 'MatWiki · ' .. language .. ' (kernel)', '' },
        current.cancelled and { '[Stopped]' } or res.lines or {}))
      write_output(not current.cancelled and (res.lines or {}) or nil, { error = not res.ok })
      pcall(function() require('matwiki.mw.server').broadcast() end)
    end)
    return 1
  end

  local runner = cfg.runners[language]
  if not runner then return fail('No runner for ' .. language .. '. Add an argv list to config.runners.' ) end
  local file = cache_file(language, 'runs')
  local argv, err = argv_for(runner, file)
  if not argv then return fail(err) end
  if vim.fn.executable(argv[1]) ~= 1 then return fail('Missing executable: ' .. argv[1] .. '. Install it or change config.runners.' ) end
  local cwd = cwd_for(source)
  local wrote, write_error = pcall(vim.fn.writefile, lines, file)
  if not wrote then return fail('Could not create script: ' .. tostring(write_error)) end
  M.stop()
  state.generation = state.generation + 1
  local captured = {}
  local current = { generation = state.generation, file = file, partial = { stdout = '', stderr = '' }, bytes = 0, lines = 0 }
  local write_output = is_mw and block and cell_writer(source, block) or function() end
  state.job = current
  set_output({ 'MatWiki · ' .. language, 'cwd: ' .. cwd, 'argv: ' .. vim.inspect(argv), '' })
  local previous_window = vim.api.nvim_get_current_win()
  show_buffer(output_buffer())
  if vim.api.nvim_win_is_valid(previous_window) then vim.api.nvim_set_current_win(previous_window) end

  local function emit(line)
    if current.truncated then return end
    local remaining = cfg.max_output_bytes - current.bytes
    if remaining <= 0 or current.lines >= cfg.max_output_lines then
      current.truncated = true
      append_output({ '[Output truncated; the process continues. Use :MatwikiStop to cancel.]' })
      return
    end
    local clipped = line:sub(1, remaining)
    current.bytes = current.bytes + #clipped + 1
    current.lines = current.lines + 1
    captured[#captured + 1] = clipped
    append_output({ clipped })
    if #line > #clipped then
      current.truncated = true
      append_output({ '[Output truncated; the process continues. Use :MatwikiStop to cancel.]' })
    end
  end

  local function receive(stream, data)
    if current.generation ~= state.generation or current.truncated then return end
    if not data or #data == 0 then return end
    local first = current.partial[stream] .. data[1]
    if #data == 1 then
      -- Bound even a process that emits megabytes without a newline.
      if #first > cfg.max_output_bytes then emit(first); current.partial[stream] = ''
      else current.partial[stream] = first end
      return
    end
    emit(first)
    for n = 2, #data - 1 do emit(data[n]) end
    current.partial[stream] = data[#data]:sub(1, cfg.max_output_bytes + 1)
  end

  local id = vim.fn.jobstart(argv, {
    cwd = cwd, stdin = 'null',
    on_stdout = function(_, data) receive('stdout', data) end,
    on_stderr = function(_, data) receive('stderr', data) end,
    on_exit = function(_, code)
      vim.fn.delete(file)
      if current.generation ~= state.generation then write_output(); return end
      for _, stream in ipairs({ 'stdout', 'stderr' }) do
        if current.partial[stream] ~= '' then emit(current.partial[stream]) end
      end
      current.exit_code = code
      append_output({ '', current.cancelled and '[Stopped · exit ' .. code .. ']' or '[Exit ' .. code .. ']' })
      if is_mw and block and not current.cancelled then
        write_output(captured, { error = code ~= 0 })
        pcall(function() require('matwiki.mw.server').broadcast() end)
      else write_output() end
      state.last_run = current
      state.job = nil
    end,
  })
  if id <= 0 then
    write_output()
    vim.fn.delete(file)
    state.job = nil
    append_output({ '[Could not start process]' })
    return fail('Could not start ' .. argv[1] .. '.')
  end
  current.id = id
  return id
end

function M.run_all()
  local source = vim.api.nvim_get_current_buf()
  local mw = require('matwiki.mw')
  local kernel = require('matwiki.mw.kernel')
  M.stop()
  state.job = nil
  state.generation = state.generation + 1
  local batch = { generation = state.generation }
  state.batch = batch
  local idx = 1
  local function step()
    if batch.cancelled or batch.generation ~= state.generation or not vim.api.nvim_buf_is_valid(source) then
      if state.batch == batch then state.batch = nil end
      return
    end
    local cells = mw.find_cells(vim.api.nvim_buf_get_lines(source, 0, -1, false))
    while idx <= #cells do
      local c = cells[idx]
      local run_opt = c.attrs and c.attrs.kv and c.attrs.kv.run
      if c.lang ~= '' and run_opt ~= 'never' and run_opt ~= 'false' and run_opt ~= 'manual' then
        local current_idx = idx
        idx = idx + 1
        if use_kernel(c.lang, c.attrs) then
          local current = { generation = batch.generation, kernel = true, source = source,
            language = c.lang, session = c.attrs.kv.session }
          local write_output = cell_writer(source, c)
          state.job = current
          kernel.eval(source, c.lang, c.code, { cell = current_idx, session = c.attrs.kv.session }, function(res)
            if current.generation ~= state.generation then write_output(); return end
            state.job = nil
            current.exit_code = res.ok and 0 or 1
            state.last_run = current
            write_output(not current.cancelled and (res.lines or {}) or nil, { error = not res.ok })
            step()
          end)
          return
        elseif cfg.runners[c.lang] then
          local file = cache_file(c.lang, 'runs')
          local argv = argv_for(cfg.runners[c.lang], file)
          if argv and vim.fn.executable(argv[1]) == 1 then
            vim.fn.writefile(c.code, file)
            local current = { generation = batch.generation, file = file }
            local write_output = cell_writer(source, c)
            state.job = current
            local started, process = pcall(vim.system, argv, { cwd = cwd_for(source), text = true }, function(res)
              vim.schedule(function()
                vim.fn.delete(file)
                if current.generation ~= state.generation then write_output(); return end
                state.job = nil
                current.exit_code = res.code
                state.last_run = current
                local out = ((res.stdout or '') .. (res.stderr or '')):gsub('\r\n', '\n')
                local out_lines = out ~= '' and vim.split(out:gsub('\n$', ''), '\n', { plain = true }) or {}
                write_output(not current.cancelled and out_lines or nil, { error = res.code ~= 0 })
                step()
              end)
            end)
            if started then current.process = process; return end
            vim.fn.delete(file)
            write_output()
            state.job = nil
            fail('Could not start ' .. argv[1] .. ': ' .. tostring(process))
          else
            fail('Skipped cell ' .. current_idx .. ': runner is invalid or its executable is unavailable.')
          end
        end
      else
        idx = idx + 1
      end
    end
    if state.batch == batch then state.batch = nil end
    pcall(function() require('matwiki.mw.server').broadcast() end)
    vim.notify('MatWiki: Finished running all cells.')
  end
  step()
end

function M.restart_kernel()
  M.stop()
  local n = require('matwiki.mw.kernel').restart(vim.api.nvim_get_current_buf())
  vim.notify('MatWiki: Restarted ' .. n .. ' kernel session(s).')
end

function M.edit_block()
  local source = vim.api.nvim_get_current_buf()
  local block, err = find_block(vim.api.nvim_buf_get_lines(source, 0, -1, false), vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not block then return fail(err) end
  local language = block.language ~= '' and block.language or 'text'
  local file = cache_file(language, 'blocks')
  local ok, write_error = pcall(vim.fn.writefile, block.code, file)
  if not ok then return fail('Could not create block file: ' .. tostring(write_error)) end
  local mark = vim.api.nvim_buf_set_extmark(source, ns, block.open_row, 0, {
    end_row = block.close_row + 1, end_col = 0, right_gravity = true, end_right_gravity = false,
  })
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, file)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, block.code)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local editor = { source = source, language = language, mark = mark, original = block.original }
  state.editors[buf] = editor
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_buf_is_valid(source) or not vim.api.nvim_buf_is_loaded(source) then
        return fail('The source note is no longer open. Copy your code before closing this buffer.')
      end
      local position = vim.api.nvim_buf_get_extmark_by_id(source, ns, mark, { details = true })
      if #position == 0 or not position[3].end_row then return fail('The source block no longer exists.') end
      local start_row, end_row = position[1], position[3].end_row
      local existing = vim.api.nvim_buf_get_lines(source, start_row, end_row, false)
      if not vim.deep_equal(existing, editor.original) then
        return fail('The source block changed. Copy your edits and reopen it; write was refused to protect the note.')
      end
      local code = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local replacement = vim.deepcopy(editor.original)
      if not vim.deep_equal(code, block.code) then
        local width = #block.marker
        for _, line in ipairs(code) do
          local candidate = fence(block.indent .. line)
          if candidate and candidate.char == block.char and candidate.rest:match('^%s*$') then width = math.max(width, #candidate.marker + 1) end
        end
        replacement = { block.indent .. block.char:rep(width) .. block.rest }
        for _, line in ipairs(code) do table.insert(replacement, block.indent .. line) end
        table.insert(replacement, block.closing.indent .. block.char:rep(math.max(width, #block.closing.marker)) .. block.closing.rest)
      end
      local saved, save_error = pcall(vim.fn.writefile, code, file)
      if not saved then return fail('Could not save block file: ' .. tostring(save_error)) end
      vim.api.nvim_buf_set_lines(source, start_row, end_row, false, replacement)
      vim.api.nvim_buf_set_extmark(source, ns, start_row, 0, {
        id = mark, end_row = start_row + #replacement, end_col = 0, right_gravity = true, end_right_gravity = false,
      })
      editor.original = vim.deepcopy(replacement)
      block.code = vim.deepcopy(code)
      block.marker = replacement[1]:match('^ *([`~]+)')
      block.closing.marker = replacement[#replacement]:match('^ *([`~]+)')
      vim.bo[buf].modified = false
      vim.notify('MatWiki: Code updated in the note buffer. Save the note to persist it.', vim.log.levels.INFO)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf, once = true,
    callback = function()
      state.editors[buf] = nil
      if vim.api.nvim_buf_is_valid(source) then pcall(vim.api.nvim_buf_del_extmark, source, ns, mark) end
      vim.fn.delete(file)
    end,
  })
  vim.cmd('vsplit')
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = languages[language] and languages[language][1] or language
  vim.bo[buf].modified = false
  return buf
end

function M.terminal()
  vim.cmd('botright 12new')
  local buf = vim.api.nvim_get_current_buf()
  local id = vim.fn.jobstart({ vim.o.shell }, { term = true, cwd = cfg.vault })
  if id <= 0 then return fail('Could not start your shell: ' .. vim.o.shell) end
  vim.bo[buf].bufhidden = 'hide'
  vim.cmd('startinsert')
  return buf
end

function M.setup(config)
  config = config or {}
  cfg = {
    vault = vim.fn.fnamemodify(config.vault or vim.fn.getcwd(), ':p'),
    cache_dir = config.cache_dir or vim.fs.joinpath(vim.fn.stdpath('cache'), 'matwiki'),
    runners = vim.tbl_deep_extend('force', vim.deepcopy(defaults), config.runners or {}),
    custom_runners = vim.deepcopy(config.runners or {}),
    max_output_bytes = math.max(1024, tonumber(config.max_output_bytes) or 256 * 1024),
    max_output_lines = math.max(20, tonumber(config.max_output_lines) or 5000),
  }
  for _, spec in ipairs({
    { 'MatwikiRun', M.run, 'Run this code fence or code buffer' },
    { 'MatwikiRunAll', M.run_all, 'Run all code cells in this note' },
    { 'MatwikiKernelRestart', M.restart_kernel, 'Restart persistent kernel sessions for this note' },
    { 'MatwikiEditBlock', M.edit_block, 'Edit this code fence with language tooling' },
    { 'MatwikiStop', M.stop, 'Stop the active code runner' },
    { 'MatwikiTerminal', M.terminal, 'Open a shell in the note vault' },
  }) do
    vim.api.nvim_create_user_command(spec[1], spec[2], { desc = spec[3], force = true })
  end
end

-- Pure helpers and observable state are exposed for headless integration tests.
M._find_block = find_block
M._argv = argv_for
M._state = state
return M
