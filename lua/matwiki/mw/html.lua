-- AST -> HTML renderer for .mw documents (fragment and full page modes).
local U = require('matwiki.mw.util')
local I = require('matwiki.mw.inline')
local B = require('matwiki.mw.block')
local esc = U.esc
local H = {}

H.DEFAULT_MACROS = {
  ['\\R'] = '\\mathbb{R}',
  ['\\N'] = '\\mathbb{N}',
  ['\\Z'] = '\\mathbb{Z}',
  ['\\Q'] = '\\mathbb{Q}',
  ['\\C'] = '\\mathbb{C}',
  ['\\F'] = '\\mathbb{F}',
  ['\\E'] = '\\mathbb{E}',
  ['\\P'] = '\\mathbb{P}',
  ['\\eps'] = '\\varepsilon',
  ['\\inner'] = '\\langle #1, #2 \\rangle',
  ['\\norm'] = '\\lVert #1 \\rVert',
  ['\\abs'] = '\\lvert #1 \\rvert',
  ['\\set'] = '\\{ #1 \\}',
  ['\\dd'] = '\\,\\mathrm{d}',
}

local MIME = {
  png = 'image/png', jpg = 'image/jpeg', jpeg = 'image/jpeg',
  gif = 'image/gif', svg = 'image/svg+xml', webp = 'image/webp',
}

local function resolve_asset(src, opts)
  if not src or src:find('^%a[%w+.-]*:') or src:sub(1, 1) == '/' or src:sub(1, 1) == '#' then
    return src
  end
  if opts.standalone and opts.source_dir then
    local ext = (src:match('%.([^./]+)$') or ''):lower()
    local mime = MIME[ext]
    if mime then
      local data = U.read_file(opts.source_dir .. '/' .. src)
      if data then return 'data:' .. mime .. ';base64,' .. U.base64(data) end
    end
  end
  if opts.asset_map then
    local mapped = opts.asset_map(src)
    if mapped then return mapped end
  end
  return src
end

local function default_wiki(target)
  local page, anchor = target:match('^(.-)#(.*)$')
  page = page or target
  local href = ''
  if page ~= '' then
    local stem = page:gsub('%.mw$', ''):gsub('%.md$', ''):gsub('%.tex$', '')
    local dir = stem:match('^(.*)/[^/]+$')
    local base = stem:match('([^/]+)$') or stem
    href = (dir and (dir .. '/') or '') .. U.slug(base) .. '.html'
  end
  if anchor and anchor ~= '' then href = href .. '#' .. U.slug(anchor) end
  return href ~= '' and href or '#'
end

local render_blocks

local function render_output_content(out_node, ctx, doc)
  local kv = out_node.attrs and out_node.attrs.kv or {}
  local text = U.strip_ansi(out_node.text or '')
  if kv.format == 'html' then
    return '<div class="mw-output-rich">' .. text .. '</div>'
  elseif kv.format == 'markdown' or kv.format == 'rich' then
    local blocks = B.parse_fragment(text, doc, out_node.line)
    return '<div class="mw-output-rich">' .. render_blocks(blocks, ctx, doc) .. '</div>'
  end
  -- Hybrid stream + rich line detection (handles stdout mixed with ![plot](...) or $$...$$).
  local lines = U.split_lines(text)
  local parts, stream = {}, {}
  local function flush_stream()
    if #stream > 0 then
      parts[#parts + 1] = '<pre class="mw-output-stream">' .. esc(table.concat(stream, '\n')) .. '</pre>'
      stream = {}
    end
  end
  for _, line in ipairs(lines) do
    if line:match('^%s*!%[.-%]%(.-%)') or line:match('^%s*!%[%[.-%]%]')
      or (line:match('^%s*%$%$.+%$%$%s*$')) then
      flush_stream()
      parts[#parts + 1] = '<div class="mw-output-rich">' .. I.render(U.trim(line), ctx) .. '</div>'
    else
      stream[#stream + 1] = line
    end
  end
  flush_stream()
  return table.concat(parts, '\n')
end

local function is_error_output(out_node)
  if out_node.attrs and out_node.attrs.kv then
    if out_node.attrs.kv.error or out_node.attrs.kv.status == 'error' then return true end
    for _, c in ipairs(out_node.attrs.classes or {}) do
      if c == 'error' or c == 'stderr' then return true end
    end
  end
  local t = out_node.text or ''
  return t:find('^Traceback %(most recent call last%):') ~= nil
    or t:find('\nTraceback %(most recent call last%):') ~= nil
    or t:find('^Error:') ~= nil
end

render_blocks = function(nodes, ctx, doc, tight)
  local out = {}
  local envs = B.ENVS
  for _, node in ipairs(nodes) do
    local t = node.t
    if t == 'para' then
      local inner = I.render(node.text, ctx)
      if tight then
        out[#out + 1] = inner
      else
        out[#out + 1] = '<p>' .. inner .. '</p>'
      end

    elseif t == 'heading' then
      local tag = 'h' .. node.level
      local num = node.number and ('<span class="mw-sec-num">' .. esc(node.number) .. '</span>') or ''
      local id_attr = node.id and (' id="' .. esc(node.id) .. '"') or ''
      local anchor = node.id and ('<a class="mw-anchor" href="#' .. esc(node.id) .. '" aria-label="Permalink">§</a>') or ''
      out[#out + 1] = '<' .. tag .. id_attr .. '>' .. num .. I.render(node.text, ctx) .. anchor .. '</' .. tag .. '>'

    elseif t == 'math' then
      local id_attr = node.id and (' id="' .. esc(node.id) .. '"') or ''
      local eq_num = node.number
        and ('<a class="mw-eq-num" href="#' .. esc(node.id or '') .. '">(' .. esc(node.number) .. ')</a>')
        or ''
      out[#out + 1] = '<div class="mw-math-block"' .. id_attr .. '>'
        .. '<div class="mw-math-inner"><span class="mw-math mw-display">' .. esc(node.tex) .. '</span></div>'
        .. eq_num .. '</div>'

    elseif t == 'div' then
      local env = envs[node.name]
      local id_attr = (node.attrs and node.attrs.id) and (' id="' .. esc(node.attrs.id) .. '"') or ''
      local body = render_blocks(node.children, ctx, doc)
      if env then
        local label_text, style = env[1], env[2]
        local title_html = (node.title and node.title ~= '') and I.render(node.title, ctx) or nil
        if style == 'details' then
          local open_attr = (node.attrs.kv.open == true or node.attrs.kv.open == 'true') and ' open' or ''
          out[#out + 1] = '<details class="mw-env-details"' .. id_attr .. open_attr .. '>'
            .. '<summary>' .. (title_html or esc(label_text)) .. '</summary>\n'
            .. body .. '\n</details>'
        elseif style == 'proof' then
          local head = title_html and (esc(label_text) .. ' (' .. title_html .. ').') or (esc(label_text) .. '.')
          out[#out + 1] = '<div class="mw-env mw-env-proof mw-env-' .. esc(node.name) .. '"' .. id_attr .. '>'
            .. '<div class="mw-env-body"><span class="mw-env-header">' .. head .. '</span> '
            .. body .. '<span class="mw-qed" title="End of proof">&#8718;</span></div></div>'
        else
          local num = node.number and (' ' .. node.number) or ''
          local title_span = title_html and (' <span class="mw-env-title">(' .. title_html .. ')</span>') or ''
          out[#out + 1] = '<div class="mw-env mw-env-' .. esc(style) .. ' mw-env-' .. esc(node.name) .. '"' .. id_attr .. '>'
            .. '<div class="mw-env-header">' .. esc(label_text) .. num .. title_span .. '.</div>'
            .. '<div class="mw-env-body">' .. body .. '</div></div>'
        end
      else
        out[#out + 1] = '<div' .. I.attrs_html(node.attrs, 'mw-div ' .. node.name) .. '>' .. body .. '</div>'
      end

    elseif t == 'code' then
      local kv = node.attrs and node.attrs.kv or {}
      local echo = kv.echo
      local show_code = echo ~= 'false' and echo ~= false and echo ~= 'none'
      local fold_code = echo == 'fold'
      local lang_class = node.lang ~= '' and (' class="language-' .. esc(node.lang) .. '"') or ''
      local code_pre = '<pre><code' .. lang_class .. '>' .. esc(node.code) .. '</code></pre>'

      if node.cell or node.output then
        local cell_id = (node.attrs and node.attrs.id) or (node.cell and ('cell-' .. node.cell))
        local id_attr = cell_id and (' id="' .. esc(cell_id) .. '"') or ''
        local parts = { '<div class="mw-cell"' .. id_attr .. ' data-lang="' .. esc(node.lang) .. '">' }
        if show_code then
          local prompt = node.cell and ('In [' .. node.cell .. ']:') or node.lang
          local bar = '<div class="mw-cell-bar">'
            .. '<span class="mw-cell-prompt-in">' .. esc(prompt) .. '</span>'
            .. '<div class="mw-cell-meta">'
            .. (node.attrs and node.attrs.id and ('<span>#' .. esc(node.attrs.id) .. '</span>') or '')
            .. (node.lang ~= '' and ('<span>' .. esc(node.lang) .. '</span>') or '')
            .. '<button class="mw-cell-copy" type="button" data-copy>Copy</button>'
            .. '</div></div>'
          if fold_code then
            parts[#parts + 1] = '<details class="mw-cell-fold"><summary>Show code (' .. esc(prompt) .. ')</summary>'
              .. bar .. code_pre .. '</details>'
          else
            parts[#parts + 1] = bar .. code_pre
          end
        end
        local out_mode = kv.output
        if node.output and out_mode ~= 'hide' and out_mode ~= 'none' and out_mode ~= 'false' then
          local err_cls = is_error_output(node.output) and ' mw-output-error' or ''
          local out_prompt = node.cell and ('Out [' .. node.cell .. ']:') or 'Output:'
          local out_body = render_output_content(node.output, ctx, doc)
          local fold_out = out_mode == 'fold' or (node.output.attrs and node.output.attrs.kv.fold)
          if fold_out then
            parts[#parts + 1] = '<details class="mw-cell-fold mw-cell-output' .. err_cls .. '">'
              .. '<summary><span class="mw-cell-prompt-out">' .. esc(out_prompt) .. '</span> Show output</summary>'
              .. out_body .. '</details>'
          else
            parts[#parts + 1] = '<div class="mw-cell-output' .. err_cls .. '">'
              .. '<div class="mw-cell-output-head"><span class="mw-cell-prompt-out">' .. esc(out_prompt) .. '</span></div>'
              .. out_body .. '</div>'
          end
        end
        parts[#parts + 1] = '</div>'
        out[#out + 1] = table.concat(parts, '\n')
      elseif show_code then
        out[#out + 1] = code_pre
      end

    elseif t == 'output' then
      local err_cls = is_error_output(node) and ' mw-output-error' or ''
      out[#out + 1] = '<div class="mw-cell"><div class="mw-cell-output' .. err_cls .. '">'
        .. render_output_content(node, ctx, doc) .. '</div></div>'

    elseif t == 'table' then
      local id_attr = (node.attrs and node.attrs.id) and (' id="' .. esc(node.attrs.id) .. '"') or ''
      local parts = { '<div class="mw-table-wrap"><table' .. id_attr .. '><thead><tr>' }
      for k, h in ipairs(node.head) do
        local al = node.align[k] and (' style="text-align:' .. node.align[k] .. '"') or ''
        parts[#parts + 1] = '<th' .. al .. '>' .. I.render(h, ctx) .. '</th>'
      end
      parts[#parts + 1] = '</tr></thead><tbody>'
      for _, row in ipairs(node.rows) do
        parts[#parts + 1] = '<tr>'
        for k = 1, #node.align do
          local al = node.align[k] and (' style="text-align:' .. node.align[k] .. '"') or ''
          parts[#parts + 1] = '<td' .. al .. '>' .. I.render(row[k] or '', ctx) .. '</td>'
        end
        parts[#parts + 1] = '</tr>'
      end
      parts[#parts + 1] = '</tbody>'
      if node.caption then
        local prefix = node.number and ('<strong>Table ' .. node.number .. ':</strong> ') or ''
        parts[#parts + 1] = '<caption>' .. prefix .. I.render(node.caption, ctx) .. '</caption>'
      end
      parts[#parts + 1] = '</table></div>'
      out[#out + 1] = table.concat(parts)

    elseif t == 'figure' then
      local id_attr = (node.attrs and node.attrs.id) and (' id="' .. esc(node.attrs.id) .. '"') or ''
      local img_attrs = vim and vim.deepcopy(node.attrs) or { classes = node.attrs.classes, kv = node.attrs.kv }
      img_attrs.id = nil
      local img_md = '![' .. node.alt .. ']' .. node.src .. (node.attr_text and node.attr_text:gsub('#[^%s}]+', '') or '')
      local img_html = I.render(img_md, ctx)
      local cap = ''
      if node.alt ~= '' or node.number then
        local prefix = node.number and ('<strong>Figure ' .. node.number .. ':</strong> ') or ''
        cap = '<figcaption>' .. prefix .. I.render(node.alt, ctx) .. '</figcaption>'
      end
      out[#out + 1] = '<figure class="mw-figure"' .. id_attr .. '>' .. img_html .. cap .. '</figure>'

    elseif t == 'list' then
      local tag = node.ordered and 'ol' or 'ul'
      local start_attr = (node.ordered and node.start and node.start ~= 1) and (' start="' .. node.start .. '"') or ''
      local parts = { '<' .. tag .. start_attr .. '>' }
      for _, item in ipairs(node.items) do
        local cls = item.task ~= nil and ' class="mw-task-item"' or ''
        local box = item.task ~= nil
          and ('<input type="checkbox" disabled' .. (item.task and ' checked' or '') .. '> ')
          or ''
        local use_tight = node.tight and #item.children == 1 and item.children[1].t == 'para'
        local inner = render_blocks(item.children, ctx, doc, use_tight)
        parts[#parts + 1] = '<li' .. cls .. '>' .. box .. inner .. '</li>'
      end
      parts[#parts + 1] = '</' .. tag .. '>'
      out[#out + 1] = table.concat(parts, '\n')

    elseif t == 'quote' then
      out[#out + 1] = '<blockquote>\n' .. render_blocks(node.children, ctx, doc) .. '\n</blockquote>'

    elseif t == 'hr' then
      out[#out + 1] = '<hr>'

    elseif t == 'html' then
      out[#out + 1] = ctx.safe and esc(node.text) or node.text
    end
  end
  return table.concat(out, '\n')
end

local function make_ctx(doc, opts)
  opts = opts or {}
  local fn_defs = {}
  for k, v in pairs(doc.footnotes or {}) do fn_defs[k] = { blocks = v } end
  return {
    labels = doc.labels,
    refs = doc.refs,
    fn = { defs = fn_defs, order = {}, index = {} },
    wiki = opts.wiki or default_wiki,
    asset = function(src) return resolve_asset(src, opts) end,
    diag = function(msg) doc.diags[#doc.diags + 1] = { line = 0, message = msg } end,
    safe = opts.safe,
  }
end

local function render_footnotes(ctx, doc)
  local fn = ctx.fn
  if not fn or #fn.order == 0 then return '' end
  local parts = { '<section class="mw-footnotes"><div class="mw-footnotes-title">Footnotes</div><ol>' }
  local i = 1
  while i <= #fn.order do
    local id = fn.order[i]
    local def = fn.defs[id]
    local body = ''
    if def then
      body = def.inline or render_blocks(def.blocks or {}, ctx, doc, #def.blocks == 1)
    end
    parts[#parts + 1] = '<li id="fn-' .. esc(id) .. '">' .. body
      .. ' <a class="mw-fn-back" href="#fnref-' .. esc(id) .. '" aria-label="Back to content">↩</a></li>'
    i = i + 1
  end
  parts[#parts + 1] = '</ol></section>'
  return table.concat(parts, '\n')
end

local function render_toc(doc, ctx)
  local toc = doc.toc or {}
  if doc.meta.toc == false or #toc < 2 then return '' end
  local parts = { '<aside class="mw-toc" aria-label="Table of contents"><div class="mw-toc-title">On this page</div><ul>' }
  for _, h in ipairs(toc) do
    if h.level <= 4 then
      local num = h.number and (esc(h.number) .. ' ') or ''
      parts[#parts + 1] = '<li class="mw-toc-l' .. h.level .. '"><a href="#' .. esc(h.id) .. '">'
        .. num .. I.render(h.text, ctx) .. '</a></li>'
    end
  end
  parts[#parts + 1] = '</ul></aside>'
  return table.concat(parts, '\n')
end

local function render_header(doc, ctx)
  local m = doc.meta or {}
  if not (m.title or m.subtitle or m.author or m.date or m.abstract or m.kernel or m.tags) then
    return ''
  end
  local parts = { '<header class="mw-doc-header">' }
  if m.title then parts[#parts + 1] = '<h1 class="mw-doc-title">' .. I.render(tostring(m.title), ctx) .. '</h1>' end
  if m.subtitle then parts[#parts + 1] = '<p class="mw-doc-subtitle">' .. I.render(tostring(m.subtitle), ctx) .. '</p>' end
  local meta_items = {}
  if m.author then
    local a = type(m.author) == 'table' and table.concat(m.author, ', ') or tostring(m.author)
    meta_items[#meta_items + 1] = '<span>' .. esc(a) .. '</span>'
  end
  if m.date then meta_items[#meta_items + 1] = '<time>' .. esc(tostring(m.date)) .. '</time>' end
  if m.kernel then meta_items[#meta_items + 1] = '<span class="mw-badge">kernel: ' .. esc(tostring(m.kernel)) .. '</span>' end
  if type(m.tags) == 'table' then
    for _, tag in ipairs(m.tags) do
      meta_items[#meta_items + 1] = '<span class="mw-badge">#' .. esc(tostring(tag)) .. '</span>'
    end
  elseif type(m.tags) == 'string' then
    meta_items[#meta_items + 1] = '<span class="mw-badge">#' .. esc(m.tags) .. '</span>'
  end
  if #meta_items > 0 then
    parts[#parts + 1] = '<div class="mw-doc-meta">' .. table.concat(meta_items, '') .. '</div>'
  end
  if m.abstract then
    parts[#parts + 1] = '<div class="mw-abstract"><div class="mw-abstract-title">Abstract</div>'
      .. I.render(tostring(m.abstract), ctx) .. '</div>'
  end
  parts[#parts + 1] = '</header>'
  return table.concat(parts, '\n')
end

local function render_backlinks(backlinks)
  if not backlinks or #backlinks == 0 then return '' end
  local parts = { '<section class="mw-backlinks"><div class="mw-backlinks-title">Linked from</div><ul class="mw-backlinks-list">' }
  for _, b in ipairs(backlinks) do
    parts[#parts + 1] = '<li class="mw-backlink-card"><a href="' .. esc(b.href) .. '">' .. esc(b.title) .. '</a>'
      .. (b.excerpt and ('<div style="color:var(--mw-fg-muted);font-size:0.8rem;margin-top:0.2rem">' .. esc(b.excerpt) .. '</div>') or '')
      .. '</li>'
  end
  parts[#parts + 1] = '</ul></section>'
  return table.concat(parts, '\n')
end

--- Render only the inner HTML body of `doc`.
function H.render_fragment(doc, opts)
  local ctx = make_ctx(doc, opts)
  local blocks = doc.blocks
  -- Avoid a duplicate H1 when front matter already defines `title`.
  if doc.meta and doc.meta.title and blocks[1] and blocks[1].t == 'heading' and blocks[1].level == 1
    and U.slug(I.plain(blocks[1].text)) == U.slug(I.plain(tostring(doc.meta.title))) then
    local trimmed = {}
    for k = 2, #blocks do trimmed[#trimmed + 1] = blocks[k] end
    blocks = trimmed
  end
  local header = render_header(doc, ctx)
  local body = render_blocks(blocks, ctx, doc)
  local footnotes = render_footnotes(ctx, doc)
  local backlinks = render_backlinks(opts and opts.backlinks)
  local toc = render_toc(doc, ctx)
  return {
    header = header,
    body = body,
    footnotes = footnotes,
    backlinks = backlinks,
    toc = toc,
    article = table.concat({ header, body, footnotes, backlinks }, '\n'),
  }
end

local CLIENT_JS = [=[
(function () {
  var root = document.documentElement;
  var saved = localStorage.getItem('mw-theme');
  if (saved) root.setAttribute('data-theme', saved);

  function bindUI() {
    var btn = document.getElementById('mw-theme-toggle');
    if (btn && !btn.dataset.bound) {
      btn.dataset.bound = '1';
      btn.addEventListener('click', function () {
        var cur = root.getAttribute('data-theme');
        var dark = cur ? cur === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches;
        var next = dark ? 'light' : 'dark';
        root.setAttribute('data-theme', next);
        localStorage.setItem('mw-theme', next);
      });
    }
    var macros = Object.assign({}, window.MW_MACROS || {});
    if (window.katex) {
      document.querySelectorAll('.mw-math:not([data-rendered])').forEach(function (el) {
        el.dataset.rendered = '1';
        var display = el.classList.contains('mw-display');
        katex.render(el.textContent, el, {
          displayMode: display,
          throwOnError: false,
          trust: true,
          strict: false,
          macros: macros
        });
      });
    }
    if (window.hljs) {
      document.querySelectorAll('pre code:not([data-highlighted])').forEach(function (el) {
        hljs.highlightElement(el);
      });
    }
    document.querySelectorAll('[data-copy]:not([data-bound])').forEach(function (b) {
      b.dataset.bound = '1';
      b.addEventListener('click', function () {
        var cell = b.closest('.mw-cell');
        var code = cell && cell.querySelector('pre code');
        if (!code || !navigator.clipboard) return;
        navigator.clipboard.writeText(code.textContent).then(function () {
          var prev = b.textContent;
          b.textContent = 'Copied';
          setTimeout(function () { b.textContent = prev; }, 1200);
        });
      });
    });
  }

  bindUI();
  window.__mwBindUI = bindUI;

  if (window.MW_LIVE) {
    var es = new EventSource('/__mw_events');
    es.addEventListener('reload', function (ev) {
      var y = window.scrollY;
      fetch(window.location.pathname + '?fragment=1', { cache: 'no-store' })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (data) {
          if (!data) { window.location.reload(); return; }
          if (data.macros) window.MW_MACROS = data.macros;
          var shell = document.querySelector('.mw-shell');
          if (shell && data.shell) {
            shell.outerHTML = data.shell;
            bindUI();
            window.scrollTo(0, y);
          } else {
            window.location.reload();
          }
        })
        .catch(function () { window.location.reload(); });
    });
  }
})();
]=]

--- Render a complete HTML5 page for `doc`.
function H.render_page(doc, opts)
  opts = opts or {}
  local frag = H.render_fragment(doc, opts)
  local title = (doc.meta and doc.meta.title and I.plain(tostring(doc.meta.title)))
    or (doc.toc and doc.toc[1] and I.plain(doc.toc[1].text))
    or opts.title or 'MatWiki Note'

  local macros = {}
  for k, v in pairs(H.DEFAULT_MACROS) do macros[k] = v end
  if type(doc.meta and doc.meta.macros) == 'table' then
    for k, v in pairs(doc.meta.macros) do
      local key = tostring(k)
      if key:sub(1, 1) ~= '\\' then key = '\\' .. key end
      macros[key] = tostring(v)
    end
  end

  local prefix = (opts.asset_prefix or 'assets'):gsub('/$', '')
  local root_dir = opts.matwiki_root
  local head_assets, foot_assets = {}, {}

  if opts.standalone and root_dir then
    local mw_css = U.read_file(root_dir .. '/assets/mw.css') or ''
    local katex_css = U.read_file(root_dir .. '/vendor/katex/katex.min.css') or ''
    -- Inline woff2 fonts so standalone HTML renders math without external font files.
    katex_css = katex_css:gsub('url%(fonts/([%w_%-%.]+%.woff2)%)', function(font)
      local data = U.read_file(root_dir .. '/vendor/katex/fonts/' .. font)
      return data and ('url(data:font/woff2;base64,' .. U.base64(data) .. ')') or ('url(fonts/' .. font .. ')')
    end):gsub('url%(fonts/[^%)]+%.woff%)%s*format%("woff"%),?', ''):gsub('url%(fonts/[^%)]+%.ttf%)%s*format%("truetype"%)', '')
    local hl_light = U.read_file(root_dir .. '/vendor/highlight/github.min.css') or ''
    local hl_dark = U.read_file(root_dir .. '/vendor/highlight/github-dark.min.css') or ''
    local katex_js = U.read_file(root_dir .. '/vendor/katex/katex.min.js') or ''
    local hl_js = U.read_file(root_dir .. '/vendor/highlight/highlight.min.js') or ''
    head_assets[#head_assets + 1] = '<style>' .. katex_css .. '\n' .. hl_light
      .. '\n[data-theme="dark"] {' .. hl_dark .. '}\n' .. mw_css .. '</style>'
    foot_assets[#foot_assets + 1] = '<script>' .. katex_js .. '</script>'
    foot_assets[#foot_assets + 1] = '<script>' .. hl_js .. '</script>'
  else
    head_assets[#head_assets + 1] = '<link rel="stylesheet" href="' .. esc(prefix .. '/katex/katex.min.css') .. '">'
    head_assets[#head_assets + 1] = '<link rel="stylesheet" href="' .. esc(prefix .. '/highlight/github.min.css') .. '" media="(prefers-color-scheme: light)">'
    head_assets[#head_assets + 1] = '<link rel="stylesheet" href="' .. esc(prefix .. '/highlight/github-dark.min.css') .. '" media="(prefers-color-scheme: dark)">'
    head_assets[#head_assets + 1] = '<link rel="stylesheet" href="' .. esc(prefix .. '/mw.css') .. '">'
    foot_assets[#foot_assets + 1] = '<script defer src="' .. esc(prefix .. '/katex/katex.min.js') .. '"></script>'
    foot_assets[#foot_assets + 1] = '<script defer src="' .. esc(prefix .. '/highlight/highlight.min.js') .. '"></script>'
    for _, lang in ipairs({ 'julia', 'r', 'latex', 'rust', 'go', 'matlab', 'haskell' }) do
      foot_assets[#foot_assets + 1] = '<script defer src="' .. esc(prefix .. '/highlight/' .. lang .. '.min.js') .. '"></script>'
    end
  end

  local shell_cls = frag.toc == '' and 'mw-shell mw-no-toc' or 'mw-shell'
  local shell_html = '<div class="' .. shell_cls .. '">\n<main class="mw-doc">\n'
    .. frag.article .. '\n</main>\n' .. frag.toc .. '\n</div>'

  if opts.fragment_only then
    return shell_html, macros
  end

  local index_href = opts.index_href or 'index.html'
  local live_badge = opts.live and '<span class="mw-live-pill"><span class="mw-live-dot"></span>Live</span>' or ''
  local topbar = '<nav class="mw-topbar" aria-label="Notebook navigation">'
    .. '<div class="mw-breadcrumbs"><a href="' .. esc(index_href) .. '">MatWiki</a>'
    .. '<span>/</span><span>' .. esc(title) .. '</span></div>'
    .. '<div class="mw-topbar-actions">' .. live_badge
    .. '<button id="mw-theme-toggle" class="mw-btn" type="button" title="Switch light/dark theme">Theme</button>'
    .. '</div></nav>'

  local page = table.concat({
    '<!DOCTYPE html>',
    '<html lang="' .. esc(tostring(doc.meta and doc.meta.lang or 'en')) .. '">',
    '<head>',
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<title>' .. esc(title) .. ' — MatWiki</title>',
    table.concat(head_assets, '\n'),
    '</head>',
    '<body>',
    topbar,
    shell_html,
    '<script>window.MW_MACROS = ' .. U.json(macros) .. ';'
      .. (opts.live and 'window.MW_LIVE = true;' or '') .. '</script>',
    table.concat(foot_assets, '\n'),
    '<script defer>' .. CLIENT_JS .. '</script>',
    '</body>',
    '</html>',
  }, '\n')

  return page, frag
end

return H
