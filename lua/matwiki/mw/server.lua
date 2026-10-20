-- Zero-dependency HTTP + Server-Sent Events (SSE) live preview server on vim.uv.
local U = require('matwiki.mw.util')
local B = require('matwiki.mw.block')
local H = require('matwiki.mw.html')
local mw = require('matwiki.mw')

local S = {}
local uv = vim.uv or vim.loop

local state = {
  server = nil,
  port = nil,
  clients = {},
  config = nil,
  augroup = nil,
}

local TYPES = {
  html = 'text/html; charset=utf-8',
  css = 'text/css; charset=utf-8',
  js = 'application/javascript; charset=utf-8',
  json = 'application/json; charset=utf-8',
  svg = 'image/svg+xml',
  png = 'image/png',
  jpg = 'image/jpeg',
  jpeg = 'image/jpeg',
  gif = 'image/gif',
  webp = 'image/webp',
  woff2 = 'font/woff2',
}

local function mime_for(path)
  local ext = (path:match('%.([^./]+)$') or ''):lower()
  return TYPES[ext] or 'application/octet-stream'
end

local function url_decode(s)
  return (s:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

local function respond(sock, status, content_type, body)
  body = body or ''
  local head = table.concat({
    'HTTP/1.1 ' .. status,
    'Content-Type: ' .. content_type,
    'Content-Length: ' .. #body,
    'Cache-Control: no-store',
    'Connection: close',
    '',
    '',
  }, '\r\n')
  sock:write(head .. body, function()
    if not sock:is_closing() then sock:close() end
  end)
end

local function find_source_for_req(vault, rel_html)
  local stem = rel_html:gsub('%.html$', '')
  for _, ext in ipairs({ '.mw', '.md' }) do
    local cand = U.normalize(vault .. '/' .. stem .. ext)
    if cand:sub(1, #vault + 1) == vault .. '/' and uv.fs_stat(cand) then
      return cand
    end
  end
  return nil
end

local function buffer_text_or_file(abs_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and U.normalize(name) == abs_path then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        return table.concat(lines, '\n')
      end
    end
  end
  return U.read_file(abs_path)
end

local function render_live_note(src_path, rel_html, fragment_only)
  local c = state.config
  local text = buffer_text_or_file(src_path)
  if not text then return nil end
  local doc = B.parse(text)
  local depth = 0
  for _ in rel_html:gmatch('/') do depth = depth + 1 end
  local prefix = depth > 0 and string.rep('../', depth) .. 'assets' or 'assets'
  local index_href = depth > 0 and string.rep('../', depth) .. 'index.html' or 'index.html'
  return H.render_page(doc, {
    matwiki_root = c.root,
    source_dir = U.dirname(src_path),
    asset_prefix = prefix,
    index_href = index_href,
    live = true,
    fragment_only = fragment_only,
    title = U.stem(src_path),
  })
end

local function handle_request(sock, raw)
  local method, target = raw:match('^(%u+)%s+([^%s]+)%s+HTTP/')
  if not method or (method ~= 'GET' and method ~= 'HEAD') then
    return respond(sock, '405 Method Not Allowed', 'text/plain', 'Method Not Allowed')
  end
  local raw_path, query = target:match('^([^?]*)(.*)$')
  local path = U.normalize('/' .. url_decode(raw_path or '/'))
  local c = state.config
  local root = U.normalize(c.root)
  local vault = U.normalize(c.vault)

  if path == '/__mw_events' then
    local headers = table.concat({
      'HTTP/1.1 200 OK',
      'Content-Type: text/event-stream',
      'Cache-Control: no-cache',
      'Connection: keep-alive',
      '',
      ': connected\n\n',
    }, '\r\n')
    sock:write(headers)
    state.clients[sock] = true
    return
  end

  if path == '/assets/mw.css' then
    local data = U.read_file(root .. '/assets/mw.css')
    if data then return respond(sock, '200 OK', TYPES.css, data) end
  elseif path:sub(1, 14) == '/assets/katex/' then
    local f = U.normalize(root .. '/vendor/katex/' .. path:sub(15))
    if f:sub(1, #root + 14) == root .. '/vendor/katex/' then
      local data = U.read_file(f)
      if data then return respond(sock, '200 OK', mime_for(f), data) end
    end
  elseif path:sub(1, 18) == '/assets/highlight/' then
    local f = U.normalize(root .. '/vendor/highlight/' .. path:sub(19))
    if f:sub(1, #root + 18) == root .. '/vendor/highlight/' then
      local data = U.read_file(f)
      if data then return respond(sock, '200 OK', mime_for(f), data) end
    end
  end

  if path == '/' or path == '/index.html' then
    local res = mw.export_vault({
      vault = vault,
      matwiki_root = root,
      out_dir = vault .. '/.site',
      live = true,
    })
    local data = U.read_file(res.index)
    if data then return respond(sock, '200 OK', TYPES.html, data) end
  end

  local rel = path:sub(2)
  if rel:match('%.html$') then
    local src = find_source_for_req(vault, rel)
    if src then
      if query and query:find('fragment=1', 1, true) then
        local shell, macros = render_live_note(src, rel, true)
        return respond(sock, '200 OK', TYPES.json, U.json({ shell = shell, macros = macros }))
      else
        local page = render_live_note(src, rel, false)
        return respond(sock, '200 OK', TYPES.html, page)
      end
    end
  end

  -- Static asset inside vault (e.g. note.assets/plot.png)
  local asset_cand = U.normalize(vault .. '/' .. rel)
  if asset_cand:sub(1, #vault + 1) == vault .. '/' then
    local st = uv.fs_stat(asset_cand)
    if st and st.type == 'file' then
      local data = U.read_file(asset_cand)
      if data then return respond(sock, '200 OK', mime_for(asset_cand), data) end
    end
  end

  respond(sock, '404 Not Found', 'text/plain; charset=utf-8', 'Not found: ' .. path)
end

function S.broadcast()
  for sock in pairs(state.clients) do
    if sock:is_closing() then
      state.clients[sock] = nil
    else
      sock:write('event: reload\ndata: {}\n\n', function(err)
        if err then
          state.clients[sock] = nil
          if not sock:is_closing() then sock:close() end
        end
      end)
    end
  end
end

function S.start(config, port)
  state.config = config or mw.config
  if state.server then return state.port end

  local srv = uv.new_tcp()
  local ok, err = srv:bind('127.0.0.1', port or 0)
  if not ok then
    vim.notify('MatWiki preview bind failed: ' .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  local name = srv:getsockname()
  state.port = name.port
  state.server = srv

  srv:listen(64, function(listen_err)
    if listen_err then return end
    local client = uv.new_tcp()
    srv:accept(client)
    local chunks = {}
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        state.clients[client] = nil
        if not client:is_closing() then client:close() end
        return
      end
      chunks[#chunks + 1] = chunk
      local raw = table.concat(chunks)
      if raw:find('\r\n\r\n', 1, true) or raw:find('\n\n', 1, true) then
        chunks = {}
        vim.schedule(function()
          if not client:is_closing() then
            handle_request(client, raw)
          end
        end)
      end
    end)
  end)

  state.augroup = vim.api.nvim_create_augroup('MatwikiLivePreview', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'TextChanged', 'InsertLeave' }, {
    group = state.augroup,
    pattern = { '*.mw', '*.md' },
    callback = function()
      S.broadcast()
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = state.augroup,
    callback = function() S.stop(true) end,
  })

  return state.port
end

function S.stop(quiet)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  for sock in pairs(state.clients) do
    if not sock:is_closing() then sock:close() end
    state.clients[sock] = nil
  end
  if state.server then
    if not state.server:is_closing() then state.server:close() end
    state.server = nil
  end
  state.port = nil
  if not quiet then
    vim.notify('MatWiki: Live preview server stopped.')
  end
end

function S.url_for(path)
  if not state.port then return nil end
  local vault = U.normalize(state.config.vault)
  path = U.normalize(path or '')
  if path ~= '' and path:sub(1, #vault + 1) == vault .. '/' then
    local rel = path:sub(#vault + 2)
    return string.format('http://127.0.0.1:%d/%s', state.port, mw._html_rel_for_note(rel))
  end
  return string.format('http://127.0.0.1:%d/index.html', state.port)
end

function S.preview_current(config)
  config = config or mw.config
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].modified then pcall(vim.cmd, 'update') end
  local port = S.start(config)
  if not port then return nil end
  local url = S.url_for(vim.api.nvim_buf_get_name(buf))
  vim.notify('MatWiki live preview: ' .. url)
  if vim.env.MATWIKI_NO_BROWSER ~= '1' and #vim.api.nvim_list_uis() > 0 then
    local opener = vim.fn.has('macunix') == 1 and 'open' or 'xdg-open'
    if vim.fn.executable(opener) == 1 then
      pcall(vim.system, { opener, url }, { detach = true })
    end
  end
  return url, port
end

S._state = state
return S
