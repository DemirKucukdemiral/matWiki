local M = {}
local function scratch(name, lines, ft)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, 'matwiki://' .. name .. '/' .. buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].buftype = 'nofile'
  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = ft or 'matwiki'
  vim.api.nvim_set_current_buf(buffer)
  return buffer
end

function M.setup(c)
  vim.opt.termguicolors = true
  vim.opt.background = 'dark'
  vim.opt.number = true
  vim.opt.relativenumber = true
  vim.opt.signcolumn = 'yes'
  vim.opt.cursorline = true
  vim.opt.scrolloff = 6
  vim.opt.sidescrolloff = 6
  vim.opt.splitbelow = true
  vim.opt.splitright = true
  vim.opt.ignorecase = true
  vim.opt.smartcase = true
  vim.opt.updatetime = 250
  vim.opt.timeoutlen = 650
  vim.opt.undofile = true
  vim.opt.hidden = true
  vim.opt.swapfile = true
  vim.opt.expandtab = true
  vim.opt.shiftwidth = 2
  vim.opt.tabstop = 2
  vim.opt.completeopt = { 'menu', 'menuone', 'noselect' }
  vim.opt.pumheight = 12
  vim.opt.laststatus = 3
  vim.opt.showmode = false
  vim.opt.mouse = 'a'
  vim.opt.conceallevel = 0
  vim.opt.clipboard = '' -- Keep ordinary yanks independent of platform clipboard tools.
  vim.opt.statusline = '%#MatwikiAccent#  MatWiki  %#StatusLine# %<%f %m%r %= %{&filetype}  %l:%c  %p%% '
  vim.g.netrw_banner = 0
  vim.g.netrw_liststyle = 3
  vim.g.tex_flavor = 'latex'
  vim.g.vimtex_quickfix_mode = 0
  vim.g.vimtex_compiler_latexmk = { out_dir = '.matwiki-build',
    options = { '-verbose', '-file-line-error', '-synctex=1', '-interaction=nonstopmode', '-no-shell-escape' } }
  if vim.fn.has('macunix') == 1 and vim.fn.isdirectory('/Applications/Skim.app') == 1 then
    vim.g.vimtex_view_method = 'skim'
  elseif vim.fn.executable('zathura') == 1 then
    vim.g.vimtex_view_method = 'zathura'
  else
    vim.g.vimtex_view_method = 'general'
    vim.g.vimtex_view_general_viewer = vim.fn.has('macunix') == 1 and 'open' or 'xdg-open'
    vim.g.vimtex_view_general_options = '@pdf'
  end
  vim.cmd('filetype plugin indent on')
  vim.cmd('syntax enable')
  local groups = {
    Normal = { fg = '#d8dee9', bg = '#141b24' }, NormalFloat = { fg = '#d8dee9', bg = '#1c2633' },
    FloatBorder = { fg = '#607d8b', bg = '#1c2633' }, FloatTitle = { fg = '#99d5ca', bold = true },
    Comment = { fg = '#8294a8', italic = true }, LineNr = { fg = '#4b6176' },
    CursorLineNr = { fg = '#d4bb85', bold = true }, CursorLine = { bg = '#1b2633' },
    Visual = { bg = '#344858' }, Search = { bg = '#4c5140', fg = '#fff0bc' },
    StatusLine = { fg = '#adbdce', bg = '#22303e' }, StatusLineNC = { fg = '#607080', bg = '#1b2633' },
    MatwikiAccent = { fg = '#142820', bg = '#99d5ca', bold = true },
    MatwikiTitle = { fg = '#99d5ca', bold = true }, MatwikiDim = { fg = '#8294a8' },
    MatwikiKey = { fg = '#d4bb85', bold = true }, MatwikiLink = { fg = '#8eb9dc', underline = true },
    Title = { fg = '#99d5ca', bold = true }, Function = { fg = '#8eb9dc' },
    String = { fg = '#a8c991' }, Statement = { fg = '#bea6d9' }, Type = { fg = '#d4bb85' },
    Constant = { fg = '#dfb28c' }, Identifier = { fg = '#b7d4e6' },
    Pmenu = { fg = '#d8dee9', bg = '#22303e' }, PmenuSel = { bg = '#345366', bold = true },
  }
  for name, value in pairs(groups) do vim.api.nvim_set_hl(0, name, value) end
  local group = vim.api.nvim_create_augroup('MatwikiEditing', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group, pattern = { 'mw', 'markdown', 'tex', 'plaintex' }, callback = function()
      vim.opt_local.wrap = true
      vim.opt_local.linebreak = true
      vim.opt_local.spell = false
      vim.opt_local.textwidth = 0
      vim.keymap.set('n', 'j', 'gj', { buffer = true })
      vim.keymap.set('n', 'k', 'gk', { buffer = true })
      vim.cmd([[syntax match MatwikiLink /\[\[[^\]]\+\]\]/]])
    end,
  })
end

function M.dashboard(c)
  local files = require('matwiki.wiki').files()
  local lines = {
    '', '  M A T W I K I', '  A notebook for thinking in mathematics.', '',
    '  LOCAL WORKSPACE', '  ' .. c.vault, '',
    '  WRITE                         EXPLORE',
    '  w   New .mw note              f   Find a note',
    '  n   New Markdown note         s   Search contents',
    '  x   New LaTeX note            e   Files & code',
    '  d   Today’s note              p   Export HTML site', '',
    '  CONTINUE',
  }
  local recent = {}
  for _, path in ipairs(files) do
    local stat = vim.uv.fs_stat(path)
    table.insert(recent, { path = path, modified = stat and stat.mtime.sec or 0 })
  end
  table.sort(recent, function(a, b)
    if a.modified == b.modified then return a.path < b.path end
    return a.modified > b.modified
  end)
  for i = 1, math.min(5, #recent) do
    lines[#lines + 1] = ('  %d   %s'):format(i, recent[i].path:sub(#c.vault + 2))
  end
  if #recent == 0 then lines[#lines + 1] = '  Your notebook is empty. Press w or n to begin.' end
  vim.list_extend(lines, { '', '  ?   Command palette           h   Getting started',
    '  c   Configure MatWiki         D   Check dependencies', '',
    ('  %d notes  /  .mw + Markdown + LaTeX  /  Neovim'):format(#files),
    '  Press i in a note to write. Escape returns to normal mode.', '' })
  local buf = scratch('home', lines)
  vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn = false, false, 'no'
  vim.wo.cursorline = false
  local ns = vim.api.nvim_create_namespace('MatwikiHome')
  for i, line in ipairs(lines) do
    local hl = line:match('^  [A-Z][A-Z ]+$') and 'MatwikiTitle' or 'MatwikiDim'
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #line, hl_group = hl })
    if line:match('^  [%d%l%?D]   ') then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 2, { end_col = 3, hl_group = 'MatwikiKey' })
    end
  end
  local commands = { w = 'MatwikiMw', n = 'MatwikiNew', x = 'MatwikiTex', d = 'MatwikiDaily', f = 'MatwikiFind',
    s = 'MatwikiSearch', e = 'MatwikiFiles', p = 'MatwikiExportVault', ['?'] = 'MatwikiCommands', h = 'MatwikiHelp',
    c = 'MatwikiConfig', D = 'MatwikiDoctor' }
  for key, command in pairs(commands) do
    vim.keymap.set('n', key, '<cmd>' .. command .. '<cr>', { buffer = buf, nowait = true })
  end
  for i = 1, math.min(5, #recent) do
    local path = recent[i].path
    vim.keymap.set('n', tostring(i), function() vim.cmd.edit(vim.fn.fnameescape(path)) end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_win_set_cursor(0, { 2, 2 })
  vim.api.nvim_create_autocmd('BufWinLeave', { buffer = buf, once = true, callback = function()
    vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn, vim.wo.cursorline = true, true, 'yes', true
  end })
end

function M.doctor(c)
  local lines = { '# MatWiki dependency check', '', 'Notebook: ' .. c.vault, 'Cache: ' .. c.cache_dir, '',
    'Neovim: ' .. tostring(vim.version()), '', 'Core tools' }
  for _, exe in ipairs({ 'latexmk', c.engine or 'pdflatex', 'python3', 'node', 'pandoc', 'git', 'rg' }) do
    lines[#lines + 1] = string.format('  %-12s %s', exe, vim.fn.exepath(exe) ~= '' and vim.fn.exepath(exe) or 'not installed (optional)')
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Language servers (install only for languages you use)'
  for name, definition in pairs(require('matwiki.coding').servers or {}) do
    if definition and definition.cmd then
      lines[#lines + 1] = ('  %-15s %s'):format(name, vim.fn.executable(definition.cmd[1]) == 1 and 'available' or 'not installed')
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Missing optional tools do not prevent writing or linking notes.'
  scratch('doctor', lines, 'markdown')
end

return M
