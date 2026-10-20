-- MatWiki .mw compiler, site exporter, and in-buffer cell output manager.
local U = require('matwiki.mw.util')
local I = require('matwiki.mw.inline')
local B = require('matwiki.mw.block')
local H = require('matwiki.mw.html')

local M = {
  util = U,
  inline = I,
  block = B,
  html = H,
  config = {},
}

local uv = vim and (vim.uv or vim.loop) or nil

local function hrtime_ms()
  if uv and uv.hrtime then return uv.hrtime() / 1e6 end
  return os.clock() * 1000
end

local function mkdir_p(path)
  if vim and vim.fn then
    vim.fn.mkdir(path, 'p')
  else
    os.execute('mkdir -p ' .. string.format('%q', path))
  end
end

local function copy_file(src, dst)
  local data = U.read_file(src)
  if not data then return false end
  mkdir_p(U.dirname(dst))
  return U.write_file(dst, data)
end

local function copy_tree(src_dir, dst_dir)
  if not uv then return end
  local handle = uv.fs_scandir(src_dir)
  if not handle then return end
  mkdir_p(dst_dir)
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(1, 1) ~= '.' then
      local s = src_dir .. '/' .. name
      local d = dst_dir .. '/' .. name
      if kind == 'directory' then
        copy_tree(s, d)
      elseif kind == 'file' then
        copy_file(s, d)
      end
    end
  end
end

--- Ensure `out_root/assets` has mw.css, KaTeX, and highlight.js for offline viewing.
function M.ensure_site_assets(out_root, matwiki_root)
  matwiki_root = matwiki_root or M.config.root
  if not matwiki_root then return end
  local assets = out_root .. '/assets'
  mkdir_p(assets)
  copy_file(matwiki_root .. '/assets/mw.css', assets .. '/mw.css')
  if not (uv and uv.fs_stat(assets .. '/katex/katex.min.js')) then
    copy_tree(matwiki_root .. '/vendor/katex', assets .. '/katex')
  end
  if not (uv and uv.fs_stat(assets .. '/highlight/highlight.min.js')) then
    copy_tree(matwiki_root .. '/vendor/highlight', assets .. '/highlight')
  end
end

--- Parse a .mw string or line array into an AST.
function M.parse(input, opts)
  return B.parse(input, opts)
end

--- Parse and render a .mw string or line array into HTML.
--- Returns: html_string, doc, fragment_table, elapsed_ms
function M.render(input, opts)
  opts = opts or {}
  local t0 = hrtime_ms()
  opts.matwiki_root = opts.matwiki_root or M.config.root
  local doc = B.parse(input, opts)
  if opts.fragment then
    local frag = H.render_fragment(doc, opts)
    return frag.article, doc, frag, (hrtime_ms() - t0)
  end
  local page, frag = H.render_page(doc, opts)
  return page, doc, frag, (hrtime_ms() - t0)
end

local function html_rel_for_note(rel_note)
  local stem = rel_note:gsub('%.[^./]+$', '')
  local parts = {}
  for part in stem:gmatch('[^/]+') do parts[#parts + 1] = part end
  return table.concat(parts, '/') .. '.html'
end
M._html_rel_for_note = html_rel_for_note

-- Copy referenced local figures as well as generated <note>.assets folders.
-- Keep vault-relative media in the same layout and map external relative media
-- into a note-specific asset directory so export never writes outside out_root.
local function export_asset_map(src_path, dst_path, out_root, vault)
  local source_dir, dst_dir = U.dirname(src_path), U.dirname(dst_path)
  return function(src)
    if src:find('^%a[%w+.-]*:') or src:sub(1, 1) == '#' then return nil end
    local path, suffix = src:match('^(.-)([?#].*)$')
    path, suffix = path or src, suffix or ''
    path = path:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
    local abs = U.normalize(path:sub(1, 1) == '/' and ((vault or source_dir) .. path) or (source_dir .. '/' .. path))
    local st = uv and uv.fs_stat(abs)
    if not st or st.type ~= 'file' then return nil end
    local dst
    if vault and abs:sub(1, #vault + 1) == vault .. '/' then
      dst = out_root .. '/' .. abs:sub(#vault + 2)
    elseif abs:sub(1, #source_dir + 1) == source_dir .. '/' then
      dst = dst_dir .. '/' .. abs:sub(#source_dir + 2)
    else
      local key = vim.fn.sha256(abs):sub(1, 12)
      dst = dst_dir .. '/' .. U.stem(src_path) .. '.assets/' .. key .. '-' .. U.basename(abs)
    end
    if U.normalize(dst) ~= abs and not copy_file(abs, dst) then return nil end
    return U.url_path(U.relpath(dst_dir, dst)) .. suffix
  end
end

--- Compile a single .mw or .md file on disk to HTML.
function M.compile_file(src_path, dst_path, opts)
  opts = opts or {}
  local t0 = hrtime_ms()
  if vim and vim.fn then src_path = vim.fs.normalize(vim.fn.fnamemodify(src_path, ':p')) end
  local text = U.read_file(src_path)
  if not text then return nil, 'Cannot read file: ' .. tostring(src_path) end

  local root = opts.matwiki_root or M.config.root
  local vault = opts.vault or M.config.vault
  local out_root = opts.out_dir
  if not dst_path then
    if not out_root and vault and src_path:sub(1, #vault + 1) == vault .. '/' then
      out_root = vault .. '/.site'
    end
    if out_root and vault and src_path:sub(1, #vault + 1) == vault .. '/' then
      local rel = src_path:sub(#vault + 2)
      dst_path = out_root .. '/' .. html_rel_for_note(rel)
    elseif out_root then
      dst_path = out_root .. '/' .. U.stem(src_path) .. '.html'
    else
      dst_path = src_path:gsub('%.[^./]+$', '') .. '.html'
    end
  end
  if vim and vim.fn then dst_path = vim.fs.normalize(vim.fn.fnamemodify(dst_path, ':p')) end
  local dst_dir = U.dirname(dst_path)
  out_root = out_root and U.normalize(out_root) or dst_dir

  local asset_prefix = U.relpath(dst_dir, out_root .. '/assets')
  local index_href = U.relpath(dst_dir, out_root .. '/index.html')

  local render_opts = {
    matwiki_root = root,
    source_dir = U.dirname(src_path),
    asset_prefix = asset_prefix,
    index_href = index_href,
    standalone = opts.standalone,
    live = opts.live,
    wiki = opts.wiki,
    backlinks = opts.backlinks,
    title = U.stem(src_path),
    asset_map = not opts.standalone and export_asset_map(src_path, dst_path, out_root, vault) or nil,
  }

  local page, doc, frag = M.render(text, render_opts)
  mkdir_p(dst_dir)
  local ok, write_err = U.write_file(dst_path, page)
  if not ok then return nil, 'Cannot write HTML: ' .. tostring(write_err) end

  if not opts.standalone then
    M.ensure_site_assets(out_root, root)
    local note_assets = U.dirname(src_path) .. '/' .. U.stem(src_path) .. '.assets'
    if uv and uv.fs_stat(note_assets) then
      copy_tree(note_assets, dst_dir .. '/' .. U.stem(src_path) .. '.assets')
    end
  end

  return {
    ok = true,
    source = src_path,
    output = dst_path,
    out_root = out_root,
    doc = doc,
    frag = frag,
    elapsed_ms = hrtime_ms() - t0,
  }
end

local function scan_vault_notes(vault, include_tex, output_dir)
  local excluded = {
    code = true, build = true, dist = true, node_modules = true,
    vendor = true, target = true, __pycache__ = true, assets = true, site = true,
  }
  local notes = {}
  local function walk(dir)
    local handle = uv and uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      if name:sub(1, 1) ~= '.' then
        local p = dir .. '/' .. name
        if kind == 'directory' and p ~= output_dir and not excluded[name] and not name:match('%.assets$') then
          walk(p)
        elseif kind == 'file' and (name:match('%.mw$') or name:match('%.md$') or (include_tex and name:match('%.tex$'))) then
          notes[#notes + 1] = p
        end
      end
    end
  end
  walk(vault)
  table.sort(notes)
  return notes
end
M._scan_vault_notes = scan_vault_notes

local function extract_raw_wikilinks(text, front_matter_end)
  local links, fence = {}, nil
  for num, line in ipairs(U.split_lines(text)) do
    if num > (front_matter_end or 0) then
      if fence then
        if B._fence_close(line, fence) then fence = nil end
      elseif B._fence_open(line) then
        fence = B._fence_open(line)
      else
        I.render(line, { wiki = function(target)
          links[#links + 1] = { target = target, line = U.trim(line) }
          return '#'
        end })
      end
    end
  end
  return links
end

-- One resolver shared by static export and live preview. File paths keep their
-- spelling; only heading text is slugged, and explicit IDs are preserved.
function M.vault_index(opts)
  opts = opts or {}
  local vault = U.normalize(opts.vault or M.config.vault)
  local out_dir = U.normalize(opts.out_dir or (vault .. '/.site'))
  local files = scan_vault_notes(vault, true, out_dir)
  local entries, by_rel, by_stem, by_slug = {}, {}, {}, {}

  for _, path in ipairs(files) do
    local rel = path:sub(#vault + 2)
    local is_tex = path:match('%.tex$') ~= nil
    local html_rel = is_tex and rel or html_rel_for_note(rel)
    local stem = rel:gsub('%.[^./]+$', '')
    local base = U.basename(stem)
    local text = (opts.read_file or U.read_file)(path) or ''
    local entry = {
      path = path,
      rel = rel,
      stem = stem,
      base = base,
      html_rel = html_rel,
      html_abs = out_dir .. '/' .. html_rel,
      text = text,
      ext = path:match('%.([^./]+)$'),
      is_tex = is_tex,
      backlinks = {},
    }
    entries[#entries + 1] = entry
    by_rel[rel] = entry
    if not by_rel[stem] or entry.ext == 'mw' then by_rel[stem] = entry end
    by_stem[base] = by_stem[base] or {}
    by_stem[base][#by_stem[base] + 1] = entry
    by_slug[U.slug(base)] = by_slug[U.slug(base)] or {}
    by_slug[U.slug(base)][#by_slug[U.slug(base)] + 1] = entry
    entry.doc = not is_tex and B.parse(text) or nil
    entry.title = entry.doc and ((entry.doc.meta.title and I.plain(tostring(entry.doc.meta.title)))
      or (entry.doc.toc[1] and I.plain(entry.doc.toc[1].text))) or base
  end
  for _, e in ipairs(entries) do
    if e.ext == 'md' and by_rel[e.stem .. '.mw'] then
      e.html_rel = e.stem .. '.md.html'
      e.html_abs = out_dir .. '/' .. e.html_rel
    end
  end

  local function lookup(path)
    path = U.normalize(path):gsub('^/', '')
    if path == '..' or path:sub(1, 3) == '../' then return nil end
    return by_rel[path]
  end
  local function unambiguous(list, ext)
    local found
    for _, e in ipairs(list or {}) do
      if not ext or e.ext == ext then
        if found and found.stem ~= e.stem then return nil end
        if not found or e.ext == 'mw' then found = e end
      end
    end
    return found
  end
  local function resolve_entry(target, from_entry)
    local page, anchor = (target or ''):match('^(.-)#(.*)$')
    page = U.trim(page or target or '')
    if page == '' then return from_entry, anchor end
    local ext = page:match('%.(mw)$') or page:match('%.(md)$') or page:match('%.(tex)$')
    local clean = ext and page:sub(1, -#ext - 2) or page
    -- Paths inserted by MatWiki are relative to the vault root.
    if (page:find('/', 1, true) or ext) and not page:match('^%.%.?/') then
      local direct = lookup(page)
      if direct then return direct, anchor end
    end
    if not ext and not page:find('/', 1, true) then
      return unambiguous(by_stem[clean], ext) or unambiguous(by_slug[U.slug(clean)], ext), anchor
    end
    if from_entry then
      local dir = U.dirname(from_entry.rel)
      local rel_cand = lookup(dir .. '/' .. page)
      if rel_cand then return rel_cand, anchor end
    end
    local e = lookup(page)
    if not e and not page:find('/', 1, true) then
      e = unambiguous(by_stem[clean], ext) or unambiguous(by_slug[U.slug(clean)], ext)
    end
    return e, anchor
  end

  -- First pass: parse titles and build the backlink graph.
  for _, e in ipairs(entries) do
    local seen_targets = {}
    for _, wl in ipairs(e.doc and extract_raw_wikilinks(e.text, e.doc.front_matter_end) or {}) do
      local target_entry = resolve_entry(wl.target, e)
      if target_entry and target_entry ~= e and not seen_targets[target_entry.rel] then
        seen_targets[target_entry.rel] = true
        table.insert(target_entry.backlinks, {
          from = e,
          title = e.title,
          excerpt = wl.line:gsub('%[%[([^%]|]*)|([^%]]*)%]%]', '%2'):gsub('%[%[([^%]]*)%]%]', '%1'),
        })
      end
    end
  end

  local index_rel = 'index.html'
  while true do
    local collision = false
    for _, e in ipairs(entries) do if e.html_rel == index_rel then collision = true; break end end
    if not collision then break end
    index_rel = '_' .. index_rel
  end

  local function render_options(e, dst_dir)
    local backlinks = {}
    for _, bl in ipairs(e.backlinks) do
      backlinks[#backlinks + 1] = {
        href = U.url_path(U.relpath(dst_dir, bl.from.html_abs)),
        title = bl.title,
        excerpt = bl.excerpt,
      }
    end
    return {
      backlinks = backlinks,
      wiki = function(target)
        local target_entry, anchor = resolve_entry(target, e)
        if not target_entry then return nil end
        local href = U.url_path(U.relpath(dst_dir, target_entry.html_abs))
        if anchor and anchor ~= '' and not target_entry.is_tex then
          local id = target_entry.doc.labels[anchor] and anchor or U.slug(anchor)
          href = href .. '#' .. U.url_path(id)
        end
        return href
      end,
    }
  end
  return { entries = entries, by_rel = by_rel, resolve = resolve_entry,
    render_options = render_options, index_rel = index_rel, out_dir = out_dir }
end

--- Compile .mw/.md pages and carry .tex source notes into a linked offline site.
function M.export_vault(opts)
  opts = opts or {}
  local t0 = hrtime_ms()
  local vault = U.normalize(opts.vault or M.config.vault)
  local root = opts.matwiki_root or M.config.root
  local out_dir = U.normalize(opts.out_dir or (vault .. '/.site'))
  mkdir_p(out_dir)
  M.ensure_site_assets(out_dir, root)
  local index = M.vault_index({ vault = vault, out_dir = out_dir })
  local entries = index.entries
  local compiled, sources = 0, 0

  -- Second pass: render HTML pages with resolved wiki links and backlinks.
  for _, e in ipairs(entries) do
    local dst_dir = U.dirname(e.html_abs)
    local asset_prefix = U.relpath(dst_dir, out_dir .. '/assets')
    local index_href = U.relpath(dst_dir, out_dir .. '/' .. index.index_rel)
    local links = index.render_options(e, dst_dir)
    local page = e.is_tex and e.text or H.render_page(e.doc, {
      matwiki_root = root,
      source_dir = U.dirname(e.path),
      asset_map = export_asset_map(e.path, e.html_abs, out_dir, vault),
      asset_prefix = asset_prefix,
      index_href = index_href,
      wiki = links.wiki,
      backlinks = links.backlinks,
      live = opts.live,
      title = e.title,
    })
    mkdir_p(dst_dir)
    U.write_file(e.html_abs, page)
    if e.is_tex then sources = sources + 1 else compiled = compiled + 1 end
    local note_assets = U.dirname(e.path) .. '/' .. e.base .. '.assets'
    if uv and uv.fs_stat(note_assets) then
      copy_tree(note_assets, dst_dir .. '/' .. e.base .. '.assets')
    end
  end

  -- Generate index.html
  local cards = {}
  for _, e in ipairs(entries) do
    local badge = '.' .. (e.ext or 'mw')
    local cells = 0
    for _, b in ipairs(e.doc and e.doc.blocks or {}) do if b.cell then cells = cells + 1 end end
    local meta_parts = { badge, e.rel }
    if e.is_tex then meta_parts[#meta_parts + 1] = 'LaTeX source' end
    if cells > 0 then meta_parts[#meta_parts + 1] = cells .. (cells == 1 and ' cell' or ' cells') end
    if #e.backlinks > 0 then meta_parts[#meta_parts + 1] = #e.backlinks .. ' backlinks' end
    cards[#cards + 1] = '<a class="mw-index-card" href="' .. U.esc(U.url_path(e.html_rel)) .. '" data-search="'
      .. U.esc((e.title .. ' ' .. e.rel):lower()) .. '">'
      .. '<div class="mw-index-card-title">' .. U.esc(e.title) .. '</div>'
      .. '<div class="mw-index-card-meta">' .. U.esc(table.concat(meta_parts, ' · ')) .. '</div>'
      .. '</a>'
  end

  local index_md = table.concat({
    '---',
    'title: MatWiki Notebook',
    'subtitle: "' .. compiled .. ' compiled notes (.mw + .md)' .. (sources > 0 and ('; ' .. sources .. ' LaTeX sources') or '') .. '"',
    'toc: false',
    '---',
    '',
    '<input id="mw-search" class="mw-index-search" type="search" placeholder="Filter notes by title or path…" autocomplete="off">',
    '',
    '<div class="mw-index-grid" id="mw-index-grid">',
    table.concat(cards, '\n'),
    '</div>',
    '',
    '<script>',
    '(function(){var s=document.getElementById("mw-search");if(!s)return;s.addEventListener("input",function(){var q=s.value.toLowerCase().trim();document.querySelectorAll("#mw-index-grid .mw-index-card").forEach(function(c){c.style.display=(!q||c.dataset.search.indexOf(q)!==-1)?"":"none";});});})();',
    '</script>',
  }, '\n')

  local index_doc = B.parse(index_md)
  local index_html = H.render_page(index_doc, {
    matwiki_root = root,
    asset_prefix = 'assets',
    index_href = index.index_rel,
    live = opts.live,
  })
  U.write_file(out_dir .. '/' .. index.index_rel, index_html)

  return {
    ok = true,
    out_dir = out_dir,
    index = out_dir .. '/' .. index.index_rel,
    count = compiled,
    source_count = sources,
    entries = entries,
    elapsed_ms = hrtime_ms() - t0,
  }
end

---------------------------------------------------------------------------
-- In-buffer .mw cell discovery & output write-back
---------------------------------------------------------------------------

--- Locate all fenced blocks and their attached ```output blocks in `lines` (0-based rows).
function M.find_cells(lines)
  local cells = {}
  local i, n = 1, #lines
  while i <= n do
    local f = B._fence_open(lines[i])
    if f then
      local j, code = i + 1, {}
      while j <= n and not B._fence_close(lines[j], f) do
        local l = lines[j]
        local strip = math.min(f.indent, U.indent(l))
        code[#code + 1] = l:sub(strip + 1)
        j = j + 1
      end
      if j <= n then
        local lang, rest = f.info:match('^([%w_+%-%.#]+)%s*(.*)$')
        lang = (lang or ''):lower()
        local attrs = U.parse_attrs(rest and rest:match('^%b{}'))
        if lang ~= 'output' and lang ~= 'result' and lang ~= 'results' then
          local cell = {
            open_row = i - 1,
            close_row = j - 1,
            indent = string.rep(' ', f.indent),
            lang = lang,
            attrs = attrs,
            code = code,
          }
          -- Check if the very next non-blank line is an ```output fence.
          local k = j + 1
          while k <= n and U.is_blank(lines[k]) do k = k + 1 end
          local of = k <= n and B._fence_open(lines[k])
          if of then
            local olang = (of.info:match('^([%w_+%-%.#]+)') or ''):lower()
            if olang == 'output' or olang == 'result' or olang == 'results' then
              local m = k + 1
              local out_lines = {}
              while m <= n and not B._fence_close(lines[m], of) do
                out_lines[#out_lines + 1] = lines[m]
                m = m + 1
              end
              if m <= n then
                cell.out_open_row = k - 1
                cell.out_close_row = m - 1
                cell.out_lines = out_lines
                j = m
              end
            end
          end
          cells[#cells + 1] = cell
        end
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return cells
end

--- Insert or update the ```output block immediately following the cell at `open_row`.
function M.write_cell_output(buf, open_row, output_lines, meta)
  if not vim or not vim.api.nvim_buf_is_valid(buf) then return false end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local target
  for _, c in ipairs(M.find_cells(lines)) do
    if c.open_row == open_row or (open_row >= c.open_row and open_row <= c.close_row) then
      target = c
      break
    end
  end
  if not target then return false end

  local clean = {}
  for _, l in ipairs(output_lines or {}) do
    clean[#clean + 1] = U.strip_ansi(l)
  end
  while #clean > 0 and clean[#clean] == '' do clean[#clean] = nil end

  local fence_char = '`'
  local fence_len = 3
  for _, l in ipairs(clean) do
    local ticks = l:match('^ *(`+)')
    if ticks and #ticks >= fence_len then fence_len = #ticks + 1 end
  end
  local fence = string.rep(fence_char, fence_len)
  local attr_parts = {}
  if target.attrs and target.attrs.id then attr_parts[#attr_parts + 1] = 'of=' .. target.attrs.id end
  if meta and meta.error then attr_parts[#attr_parts + 1] = 'status=error' end
  local info = 'output' .. (#attr_parts > 0 and (' {' .. table.concat(attr_parts, ' ') .. '}') or '')

  local block = { target.indent .. fence .. info }
  for _, l in ipairs(clean) do block[#block + 1] = target.indent .. l end
  block[#block + 1] = target.indent .. fence

  if target.out_open_row and target.out_close_row then
    vim.api.nvim_buf_set_lines(buf, target.out_open_row, target.out_close_row + 1, false, block)
  else
    vim.api.nvim_buf_set_lines(buf, target.close_row + 1, target.close_row + 1, false, block)
  end
  return true
end

--- Remove all ```output blocks in buffer `buf`.
function M.clear_outputs(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cells = M.find_cells(lines)
  local removed = 0
  for idx = #cells, 1, -1 do
    local c = cells[idx]
    if c.out_open_row and c.out_close_row then
      vim.api.nvim_buf_set_lines(buf, c.out_open_row, c.out_close_row + 1, false, {})
      removed = removed + 1
    end
  end
  return removed
end

---------------------------------------------------------------------------
-- Neovim integration
---------------------------------------------------------------------------
function M.setup(config)
  M.config = config or {}
  if not vim then return M end

  vim.filetype.add({
    extension = { mw = 'mw' },
  })
  if vim.treesitter and vim.treesitter.language and vim.treesitter.language.register then
    pcall(vim.treesitter.language.register, 'markdown', 'mw')
  end

  vim.api.nvim_create_user_command('MatwikiExport', function(args)
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].modified then pcall(vim.cmd, 'update') end
    local src = vim.api.nvim_buf_get_name(buf)
    if src == '' then
      vim.notify('MatWiki: Save this note before exporting to HTML.', vim.log.levels.WARN)
      return
    end
    local standalone = args.bang or (args.args and args.args:find('%-%-standalone') ~= nil)
    local custom_out = args.args and U.trim(args.args:gsub('%-%-standalone', '')) or ''
    local dst = custom_out ~= '' and vim.fn.fnamemodify(custom_out, ':p') or nil
    local out_dir = not dst and not standalone and (M.config.vault .. '/.site') or nil
    local res, err = M.compile_file(src, dst, {
      vault = M.config.vault,
      matwiki_root = M.config.root,
      out_dir = out_dir,
      standalone = standalone,
    })
    if not res then
      vim.notify('MatWiki: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format('MatWiki: Exported %s (%.1f ms)', res.output, res.elapsed_ms))
  end, { nargs = '*', bang = true, desc = 'Compile current .mw/.md note to HTML (! for standalone)' })

  vim.api.nvim_create_user_command('MatwikiExportVault', function(args)
    local out_dir = args.args ~= '' and vim.fn.fnamemodify(args.args, ':p') or (M.config.vault .. '/.site')
    local res = M.export_vault({
      vault = M.config.vault,
      matwiki_root = M.config.root,
      out_dir = out_dir,
    })
    vim.notify(string.format('MatWiki: Exported %d notes to %s (%.1f ms)', res.count, res.index, res.elapsed_ms))
  end, { nargs = '?', desc = 'Compile all vault notes to an HTML site' })

  vim.api.nvim_create_user_command('MatwikiPreview', function()
    require('matwiki.mw.server').preview_current(M.config)
  end, { desc = 'Open live HTML preview for the current note' })

  vim.api.nvim_create_user_command('MatwikiPreviewStop', function()
    require('matwiki.mw.server').stop()
  end, { desc = 'Stop the live HTML preview server' })

  vim.api.nvim_create_user_command('MatwikiClearOutputs', function()
    local n = M.clear_outputs(0)
    vim.notify('MatWiki: Cleared ' .. n .. ' cell output(s).')
  end, { desc = 'Clear all ```output blocks in the current note' })

  vim.api.nvim_create_user_command('MatwikiRunAll', function()
    require('matwiki.runner').run_all()
  end, { desc = 'Run all code cells in the current note sequentially' })

  return M
end

return M
