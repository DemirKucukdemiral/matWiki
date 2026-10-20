local M = {}

local function directory(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ':p')):gsub('/$', '')
  vim.fn.mkdir(path, 'p')
  return path
end

function M.setup(opts)
  opts = opts or {}
  local root = opts.root or vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
  local defaults = {
    root = root, vault = root .. '/notebook',
    cache_dir = (vim.env.MATWIKI_STATE_DIR or vim.fn.stdpath('cache')) .. '/matwiki',
    templates_dir = root .. '/templates', engine = 'pdflatex', keymaps = true,
    runners = {}, snippets = {}, lsp = {}, after_setup = function() end,
  }
  M.config = vim.tbl_deep_extend('force', defaults, opts)
  local c = M.config
  c.vault, c.cache_dir = directory(c.vault), directory(c.cache_dir)
  if c.standalone then require('matwiki.ui').setup(c) end
  require('matwiki.wiki').setup(c)
  require('matwiki.runner').setup(c)
  require('matwiki.latex').setup(c)
  require('matwiki.coding').setup(c)
  vim.api.nvim_create_user_command('MatwikiHome', function() require('matwiki.ui').dashboard(c) end, {})
  vim.api.nvim_create_user_command('MatwikiHelp', function()
    vim.cmd.edit(vim.fn.fnameescape(c.root .. '/README.md'))
  end, {})
  vim.api.nvim_create_user_command('MatwikiConfig', function()
    vim.cmd.edit(vim.fn.fnameescape(vim.env.MATWIKI_CONFIG or c.root .. '/user.lua'))
  end, {})
  vim.api.nvim_create_user_command('MatwikiCommands', function() M.palette() end, {})
  vim.api.nvim_create_user_command('MatwikiDoctor', function() require('matwiki.ui').doctor(c) end, {})
  vim.api.nvim_create_user_command('MatwikiFiles', function()
    vim.cmd.edit(vim.fn.fnameescape(c.vault))
  end, {})
  if c.keymaps then
    for _, action in ipairs(M.actions) do
      vim.keymap.set('n', '<leader>' .. action[1], '<cmd>' .. action[3] .. '<cr>', { desc = action[2] })
    end
    vim.keymap.set('n', '<leader>?', M.palette, { desc = 'MatWiki command palette' })
    vim.keymap.set('n', '<leader>w', '<cmd>write<cr>', { desc = 'Save file' })
    vim.keymap.set('n', '<leader>q', '<cmd>confirm quit<cr>', { desc = 'Close window' })
    vim.keymap.set('n', '<leader>co', '<cmd>copen<cr>', { desc = 'Open diagnostics / search results' })
    vim.keymap.set('n', '<leader>cc', '<cmd>cclose<cr>', { desc = 'Close diagnostics' })
    vim.keymap.set('n', '<leader>jl', '<cmd>MatwikiFollow<cr>', { desc = 'Follow wiki link' })
    vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Leave terminal input mode' })
    vim.keymap.set({ 'i', 's' }, '<Tab>', function()
      if vim.snippet.active({ direction = 1 }) then vim.snippet.jump(1)
      elseif vim.fn.pumvisible() == 1 then
        vim.api.nvim_feedkeys(vim.keycode('<C-n>'), 'n', false)
      else vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'n', false) end
    end, { desc = 'Next snippet field or completion' })
    vim.keymap.set({ 'i', 's' }, '<S-Tab>', function()
      if vim.snippet.active({ direction = -1 }) then vim.snippet.jump(-1)
      elseif vim.fn.pumvisible() == 1 then
        vim.api.nvim_feedkeys(vim.keycode('<C-p>'), 'n', false)
      end
    end, { desc = 'Previous snippet field' })
    vim.keymap.set('n', '<leader>mi', '<cmd>MatwikiSnippet inline<cr>', { desc = 'Inline maths snippet' })
    vim.keymap.set('n', '<leader>md', '<cmd>MatwikiSnippet display<cr>', { desc = 'Display maths snippet' })
  end
  if c.standalone then
    vim.api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = function()
        if vim.fn.argc() == 0 and #vim.api.nvim_list_uis() > 0 then
          require('matwiki.ui').dashboard(c)
        end
      end,
    })
  end
  local ok, err = pcall(c.after_setup, M)
  if not ok then vim.notify('MatWiki after_setup: ' .. tostring(err), vim.log.levels.ERROR) end
  return M
end

M.actions = {
  { 'nn', 'New Markdown note', 'MatwikiNew' },
  { 'nx', 'New LaTeX note', 'MatwikiTex' },
  { 'nd', 'Today’s daily note', 'MatwikiDaily' },
  { 'nf', 'Find a note', 'MatwikiFind' },
  { 'ns', 'Search note contents', 'MatwikiSearch' },
  { 'nl', 'Insert wiki link', 'MatwikiLink' },
  { 'no', 'Follow wiki link under cursor', 'MatwikiFollow' },
  { 'nb', 'Show backlinks', 'MatwikiBacklinks' },
  { 'nh', 'Notebook home', 'MatwikiHome' },
  { 'ne', 'Browse files and code', 'MatwikiFiles' },
  { 'mb', 'Build PDF', 'MatwikiBuild' },
  { 'mv', 'View PDF', 'MatwikiView' },
  { 'mw', 'Toggle build on save', 'MatwikiWatch' },
  { 'ms', 'Insert maths snippet', 'MatwikiSnippet' },
  { 'mx', 'Stop PDF build', 'MatwikiLatexStop' },
  { 'rr', 'Run current code block / file', 'MatwikiRun' },
  { 're', 'Edit code block in language buffer', 'MatwikiEditBlock' },
  { 'rs', 'Stop running code', 'MatwikiStop' },
  { 'rt', 'Open terminal', 'MatwikiTerminal' },
  { 'oc', 'Edit configuration', 'MatwikiConfig' },
  { 'oh', 'Read guide', 'MatwikiHelp' },
  { 'od', 'Check dependencies', 'MatwikiDoctor' },
}

function M.palette()
  local items = {}
  for _, a in ipairs(M.actions) do
    table.insert(items, { label = a[2], detail = 'Space ' .. a[1], command = a[3] })
  end
  require('matwiki.picker').choose(items, { title = 'MatWiki commands' }, function(item)
    if item then vim.cmd(item.command) end
  end)
end

return M
