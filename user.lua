-- Your MatWiki configuration. Restart MatWiki after changing this file.
-- This is ordinary Lua: define functions, keymaps, commands, and language tools.
return {
  -- vault = vim.fn.expand('~/Documents/MatWiki'),
  engine = 'pdflatex', -- or 'lualatex' / 'xelatex', when installed
  auto_view = false,  -- Space mv opens the PDF after Space mb builds it
  -- viewer = { 'zathura', '{file}' }, -- Linux
  -- viewer = { 'open', '-a', 'Skim', '{file}' }, -- macOS

  runners = {
    -- python = { '/absolute/path/to/.venv/bin/python', '{file}' },
    -- julia = { 'julia', '--project=.', '{file}' },
  },
  snippets = {
    -- LSP snippet syntax; double backslashes escape a literal backslash.
    -- Lua long strings keep these escapes intact for the snippet engine.
    norm = [[\\lVert ${1:x} \\rVert$0]],
    inner = [[\\langle ${1:x}, ${2:y} \\rangle$0]],
  },
  lsp = {
    -- pyright = { settings = { python = { analysis = { typeCheckingMode = 'basic' } } } },
    -- texlab = false, -- disable a built-in server
    -- custom_server = { cmd = { 'my-server', '--stdio' }, filetypes = { 'python' } },
  },
  after_setup = function(matwiki)
    -- Example: Space ni opens a permanent inbox note.
    vim.keymap.set('n', '<leader>ni', function()
      require('matwiki.wiki').new('markdown', 'Inbox')
    end, { desc = 'Open inbox' })

    -- Define any custom command here, e.g.:
    -- vim.api.nvim_create_user_command('MyFunction', function()
    --   print('My notebook is at ' .. matwiki.config.vault)
    -- end, {})
  end,
}
