-- Standalone entry point. Does not load or change ~/.config/nvim.
if vim.fn.has('nvim-0.12.4') == 0 then
  vim.api.nvim_err_writeln('MatWiki needs Neovim 0.12.4 or newer (bundled VimTeX requirement).')
  vim.cmd('cquit 1')
  return
end
local root = vim.env.MATWIKI_HOME or vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local runtime_paths = { root, root .. '/vendor/vimtex', vim.env.VIMRUNTIME }
-- Neovim ships its Treesitter parsers outside VIMRUNTIME. Keep those builtin
-- runtime entries while excluding the user's normal configuration/plugins.
for _, path in ipairs(vim.opt.runtimepath:get()) do
  if path:match('/lib/?%d*/nvim$') then runtime_paths[#runtime_paths + 1] = path end
end
vim.list_extend(runtime_paths, { vim.env.VIMRUNTIME .. '/after', root .. '/vendor/vimtex/after' })
vim.opt.runtimepath = runtime_paths
vim.opt.packpath = vim.opt.runtimepath:get()
vim.g.mapleader = ' '
vim.g.maplocalleader = ','
local config = {}
local system_install = vim.env.MATWIKI_SYSTEM_INSTALL == '1'
if system_install and not vim.env.MATWIKI_CONFIG and vim.env.MATWIKI_STATE_DIR then
  local user_cfg = vim.env.MATWIKI_STATE_DIR .. '/user.lua'
  if vim.fn.filereadable(user_cfg) == 0 and vim.fn.filereadable(root .. '/user.lua') == 1 then
    vim.fn.mkdir(vim.env.MATWIKI_STATE_DIR, 'p')
    pcall(vim.fn.writefile, vim.fn.readfile(root .. '/user.lua'), user_cfg)
  end
  vim.env.MATWIKI_CONFIG = user_cfg
end
local config_path = vim.env.MATWIKI_CONFIG or root .. '/user.lua'
if vim.fn.filereadable(config_path) == 1 then
  local ok, value = pcall(dofile, config_path)
  if ok and type(value) == 'table' then config = value
  else
    vim.schedule(function()
      vim.notify('Cannot load ' .. config_path .. ': ' .. tostring(value), vim.log.levels.ERROR)
    end)
  end
end
if not vim.env.MATWIKI_CONFIG and vim.fn.filereadable(root .. '/user.local.lua') == 1 then
  local ok, local_cfg = pcall(dofile, root .. '/user.local.lua')
  if ok and type(local_cfg) == 'table' then
    config = vim.tbl_deep_extend('force', config, local_cfg)
  end
end
config.root = root
config.standalone = true
-- Explicit CLI/environment vault wins over user.lua.
local default_vault = system_install and vim.fn.expand('~/Documents/MatWiki') or (root .. '/notebook')
config.vault = vim.env.MATWIKI_VAULT or config.vault or default_vault
require('matwiki').setup(config)
