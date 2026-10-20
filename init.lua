-- Standalone entry point. Does not load or change ~/.config/nvim.
if vim.fn.has('nvim-0.12.4') == 0 then
  vim.api.nvim_err_writeln('MatWiki needs Neovim 0.12.4 or newer (bundled VimTeX requirement).')
  vim.cmd('cquit 1')
  return
end
local root = vim.env.MATWIKI_HOME or vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
vim.opt.runtimepath = { root, root .. '/vendor/vimtex', vim.env.VIMRUNTIME,
  vim.env.VIMRUNTIME .. '/after', root .. '/vendor/vimtex/after' }
vim.opt.packpath = vim.opt.runtimepath:get()
vim.g.mapleader = ' '
vim.g.maplocalleader = ','
local config = {}
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
config.root = root
config.standalone = true
-- Explicit CLI/environment vault wins over user.lua.
config.vault = vim.env.MATWIKI_VAULT or config.vault or root .. '/notebook'
require('matwiki').setup(config)
