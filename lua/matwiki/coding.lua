local M = {}
function M.setup(config)
  local definitions = {
    pyright = { cmd = { 'pyright-langserver', '--stdio' }, filetypes = { 'python' }, root_markers = { 'pyproject.toml', '.git' } },
    texlab = { cmd = { 'texlab' }, filetypes = { 'tex', 'plaintex', 'bib' }, root_markers = { '.latexmkrc', '.git' } },
    lua_ls = { cmd = { 'lua-language-server' }, filetypes = { 'lua' }, root_markers = { '.luarc.json', '.git' },
      settings = { Lua = { diagnostics = { globals = { 'vim' } }, telemetry = { enable = false } } } },
    ts_ls = { cmd = { 'typescript-language-server', '--stdio' }, filetypes = { 'javascript', 'typescript', 'javascriptreact', 'typescriptreact' }, root_markers = { 'package.json', '.git' } },
    clangd = { cmd = { 'clangd' }, filetypes = { 'c', 'cpp' }, root_markers = { 'compile_commands.json', '.git' } },
    rust_analyzer = { cmd = { 'rust-analyzer' }, filetypes = { 'rust' }, root_markers = { 'Cargo.toml', '.git' } },
    gopls = { cmd = { 'gopls' }, filetypes = { 'go' }, root_markers = { 'go.mod', '.git' } },
  }
  for name, definition in pairs(config.lsp or {}) do
    if definition == false then
      definitions[name] = false
    else
      definitions[name] = vim.tbl_deep_extend('force', definitions[name] or {}, definition)
      if definition.cmd then definitions[name].cmd = definition.cmd end
    end
  end
  M.servers = definitions
  for name, definition in pairs(definitions) do
    if definition and definition.cmd and vim.fn.executable(definition.cmd[1]) == 1 then
      definition.workspace_required = false
      vim.lsp.config('matwiki_' .. name, definition)
      vim.lsp.enable('matwiki_' .. name)
    elseif vim.lsp.is_enabled('matwiki_' .. name) then
      vim.lsp.enable('matwiki_' .. name, false)
    end
  end
  vim.diagnostic.config({ severity_sort = true, virtual_text = false, float = { border = 'rounded' } })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup('MatwikiLsp', { clear = true }),
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and client:supports_method('textDocument/completion') then
        vim.lsp.completion.enable(true, client.id, event.buf, { autotrigger = true })
      end
      local map = function(key, fn, desc)
        vim.keymap.set('n', key, fn, { buffer = event.buf, desc = desc })
      end
      map('gd', vim.lsp.buf.definition, 'Go to definition')
      map('gr', vim.lsp.buf.references, 'Find references')
      map('K', vim.lsp.buf.hover, 'Hover documentation')
      map('<leader>cr', vim.lsp.buf.rename, 'Rename symbol')
      map('<leader>ca', vim.lsp.buf.code_action, 'Code action')
      map('<leader>cf', function() vim.lsp.buf.format({ async = true }) end, 'Format buffer')
      map('<leader>cd', vim.diagnostic.open_float, 'Show diagnostic')
    end,
  })
end
return M
