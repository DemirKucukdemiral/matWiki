-- Exercise the real standalone launcher without touching the bundled notebook.
local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or 'Values differ')
    .. '\nActual: ' .. vim.inspect(actual) .. '\nExpected: ' .. vim.inspect(expected))
end

local function check_ui()
  equal(vim.v.vim_did_enter, 1, 'UI checks must run after the real startup sequence')
  equal(vim.v.errmsg, '', 'Standalone startup must not report an error')
  local app = require('matwiki')
  equal(app.config.vault, vim.env.MATWIKI_UI_VAULT, '--vault should override user.lua')
  assert(vim.fn.stdpath('data'):find(vim.env.MATWIKI_STATE_DIR, 1, true), 'State must stay in the chosen directory')
  equal(require('matwiki.coding').servers.texlab, false, 'Disabling a language server must be supported')
  equal(vim.g.matwiki_test_config_loaded, true, 'Custom configuration must load')

  for _, action in ipairs(app.actions) do
    equal(vim.fn.exists(':' .. action[3]), 2, 'Every palette command must exist: ' .. action[3])
    assert(vim.fn.maparg(' ' .. action[1], 'n') ~= '', 'Every advertised action needs a keymap')
  end

  local note = app.config.vault .. '/first.mw'
  vim.cmd.edit(vim.fn.fnameescape(note))
  equal(vim.bo.filetype, 'mw', '.mw files must load their filetype and editor support')
  assert(vim.wo.wrap and vim.wo.linebreak)
  equal(vim.fn.maparg('j', 'n'), 'gj', 'Note navigation should follow wrapped lines')
  equal(vim.fn.synIDattr(vim.fn.synID(2, 5, 1), 'name'), 'MatwikiLink', 'Wiki links should be highlighted')

  -- Returning from Home must respect custom window settings, including after
  -- opening Home twice before choosing a note.
  vim.wo.number, vim.wo.relativenumber = true, false
  vim.wo.signcolumn, vim.wo.cursorline = 'auto', false
  vim.cmd.MatwikiHome()
  vim.cmd.MatwikiHome()
  assert(not vim.wo.number and not vim.wo.relativenumber)
  local home_lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(home_lines:find('first.mw', 1, true), 'Home must show recent notes')
  equal(vim.fn.maparg('g', 'n'), '<Cmd>MatwikiFolder<CR>', 'Home should expose folder creation')
  vim.cmd.edit(vim.fn.fnameescape(note))
  equal({ vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn, vim.wo.cursorline },
    { true, false, 'auto', false }, 'Leaving Home should restore previous window settings')

  -- Route the real palette selection callback without requiring terminal input.
  local picker = require('matwiki.picker')
  local choose = picker.choose
  picker.choose = function(items, _, callback)
    for _, item in ipairs(items) do
      if item.command == 'MatwikiDoctor' then callback(item); return end
    end
    error('Dependency doctor is missing from the palette')
  end
  vim.cmd.MatwikiCommands()
  picker.choose = choose
  assert(vim.api.nvim_buf_get_name(0):find('matwiki://doctor/', 1, true))
  assert(not vim.bo.modifiable, 'Diagnostic output should be read-only')

  vim.cmd.MatwikiFiles()
  equal(vim.bo.filetype, 'netrw', 'The bundled file browser must load at standalone startup')
  vim.cmd.MatwikiConfig()
  equal(vim.api.nvim_buf_get_name(0), vim.env.MATWIKI_CONFIG)
  equal(vim.v.errmsg, '', 'Core UI commands must not report errors')
end

if vim.env.MATWIKI_UI_CHILD == '1' then
  local ok, err = xpcall(check_ui, debug.traceback)
  if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd('cquit 1')
  end
  print('MatWiki standalone UI checks passed')
  return
end

local root = vim.fn.getcwd()
local temp = vim.fn.tempname() .. ' matwiki UI'
vim.fn.mkdir(temp .. '/vault', 'p')
vim.fn.mkdir(temp .. '/bin', 'p')
vim.fn.mkdir(temp .. '/links', 'p')
local ok, err = xpcall(function()
  vim.fn.writefile({ '# UI test', '[[first]]', '' }, temp .. '/vault/first.mw')
  vim.fn.writefile({
    'return {',
    '  vault = ' .. string.format('%q', temp .. '/wrong-vault') .. ',',
    '  lsp = { pyright = false, texlab = false, lua_ls = false, ts_ls = false,',
    '    clangd = false, rust_analyzer = false, gopls = false },',
    '  after_setup = function() vim.g.matwiki_test_config_loaded = true end,',
    '}',
  }, temp .. '/user.lua')

  -- Simulate macOS readlink without -f and systems without realpath, then launch
  -- through a relative symlink followed by an absolute symlink.
  local function shell_quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
  local readlink = vim.fn.exepath('readlink')
  assert(readlink ~= '', 'Symlink test needs readlink')
  vim.fn.writefile({ '#!/bin/sh', '[ "$1" != "-f" ] || exit 1', 'exec ' .. shell_quote(readlink) .. ' "$@"' }, temp .. '/bin/readlink')
  vim.fn.writefile({ '#!/bin/sh', 'exit 1' }, temp .. '/bin/realpath')
  assert(vim.uv.fs_chmod(temp .. '/bin/readlink', 493))
  assert(vim.uv.fs_chmod(temp .. '/bin/realpath', 493))
  assert(vim.uv.fs_symlink(root .. '/matwiki', temp .. '/links/matwiki'))
  assert(vim.uv.fs_symlink('../links/matwiki', temp .. '/bin/matwiki'))

  local result = vim.system({ temp .. '/bin/matwiki', '--vault', temp .. '/vault', '--headless', '-i', 'NONE', '-n',
    '-c', 'lua vim.api.nvim_create_autocmd("VimEnter", { once = true, nested = true, callback = function() dofile('
      .. string.format('%q', root .. '/tests/ui.lua') .. '); vim.cmd("qa!") end })',
  }, {
    text = true,
    env = {
      MATWIKI_UI_CHILD = '1', MATWIKI_UI_VAULT = temp .. '/vault',
      MATWIKI_STATE_DIR = temp .. '/state', MATWIKI_CONFIG = temp .. '/user.lua',
      NVIM_LOG_FILE = temp .. '/nvim.log',
      PATH = temp .. '/bin:' .. vim.env.PATH,
    },
  }):wait(20000)
  equal(result.code, 0, (result.stdout or '') .. (result.stderr or ''))
  assert(((result.stdout or '') .. (result.stderr or '')):find('MatWiki standalone UI checks passed', 1, true))
  assert(vim.fn.isdirectory(temp .. '/wrong-vault') == 0, 'The overridden configuration vault should stay untouched')
end, debug.traceback)
vim.fn.delete(temp, 'rf')
if not ok then error(err) end
print('MatWiki UI: all tests passed')
