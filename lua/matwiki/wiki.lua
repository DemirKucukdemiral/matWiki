local M = {}
local uv = vim.uv or vim.loop
local picker = require("matwiki.picker")
local config = {}
local root
local excluded = {
  code = true, build = true, dist = true, node_modules = true,
  vendor = true, target = true, __pycache__ = true,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "MatWiki" })
end

local function within(path)
  return root and (path == root or path:sub(1, #root + 1) == root .. "/")
end

local function normalize(path)
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return #normalized > 1 and (normalized:gsub("/$", "")) or normalized
end

-- Resolve existing ancestors as well as the final component. A symlink in a
-- parent directory must never turn a new note into a write outside the vault.
local function safe_path(path, must_exist)
  path = normalize(path)
  if not within(path) then return nil, "The note must stay inside your vault." end
  local resolved = uv.fs_realpath(path)
  if resolved then
    resolved = normalize(resolved)
    if within(resolved) then return resolved end
    return nil, "That path is a symlink outside your vault."
  end
  if must_exist then return nil, "Note does not exist." end
  local parent, tail = path, {}
  while parent ~= root do
    table.insert(tail, 1, vim.fs.basename(parent))
    parent = vim.fs.dirname(parent)
    local existing = uv.fs_realpath(parent)
    if existing then
      if not within(normalize(existing)) then return nil, "That directory points outside your vault." end
      return normalize(existing .. "/" .. table.concat(tail, "/"))
    end
    if uv.fs_lstat(parent) then return nil, "That directory is an unresolved symlink." end
  end
  return path
end

local function relative(path)
  if within(path) then return path:sub(#root + 2) end
  return path
end

function M.slugify(title)
  local slug = vim.fn.tolower(vim.trim(title or ""))
  slug = slug:gsub("[^%w\128-\255%s_-]", ""):gsub("[%s_]+", "-"):gsub("%-+", "-")
  slug = slug:gsub("^%-+", ""):gsub("%-+$", "")
  return slug ~= "" and slug or "untitled"
end

local function parse_target(target)
  target = vim.trim((target or ""):match("^([^|]*)") or "")
  local path, anchor = target:match("^(.-)#(.*)$")
  return path or target, anchor
end

local function valid_target(target)
  if target == "" then return false, "Choose a note name first." end
  if target:find("[\r\n%z\\]") or target:sub(1, 1) == "/" or target:match("^%a:") then
    return false, "Use a relative note name inside your vault."
  end
  for part in target:gmatch("[^/]+") do
    if part == ".." or part == "." or part:sub(1, 1) == "." then
      return false, "Hidden paths and parent traversal are not allowed in wiki links."
    end
    if excluded[part] then return false, "That directory is excluded from the note vault." end
  end
  return true
end

---Sorted absolute paths to Markdown and TeX notes, excluding hidden/build/code dirs.
function M.files()
  if not root then return {} end
  local result, seen = {}, {}
  local function walk(dir)
    local handle = uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      if name:sub(1, 1) ~= "." then
        local path = dir .. "/" .. name
        if kind == "directory" and not excluded[name] then
          walk(path)
        elseif (kind == "file" or kind == "link") and (name:match("%.md$") or name:match("%.tex$")) then
          local resolved = safe_path(path, true)
          local stat = resolved and uv.fs_stat(resolved)
          if resolved and stat and stat.type == "file" and not seen[resolved] then
            seen[resolved] = true
            result[#result + 1] = resolved
          end
        end
      end
    end
  end
  walk(root)
  table.sort(result)
  return result
end

---Return every matching absolute note path, plus an optional invalid-path error.
---Bare names match throughout the vault; folder/name links match relative to the
---current note and to the vault. Ambiguous names are deliberately not guessed.
function M.resolve(target, source, known_files)
  target = parse_target(target)
  local valid, err = valid_target(target)
  if not valid then return {}, err end
  local extension = target:match("%.(md)$") or target:match("%.(tex)$")
  local candidates, result, seen = {}, {}, {}
  local names = { [target] = true }
  local bare_target = extension and target:gsub("%.%w+$", "") or target
  local parent = vim.fs.dirname(bare_target)
  local slugged = (parent ~= "." and (parent .. "/") or "") .. M.slugify(vim.fs.basename(bare_target))
    .. (extension and ("." .. extension) or "")
  names[slugged] = true
  local function candidate(path)
    local function add(name)
      candidates[normalize(name)] = true
      local canonical = safe_path(name, true)
      if canonical then candidates[canonical] = true end
    end
    if extension then
      add(path)
    else
      add(path .. ".md")
      add(path .. ".tex")
    end
  end
  for name in pairs(names) do
    candidate(root .. "/" .. name)
    if source and within(normalize(source)) then candidate(vim.fs.dirname(normalize(source)) .. "/" .. name) end
  end
  for _, path in ipairs(known_files or M.files()) do
    local basename = vim.fs.basename(path)
    local basename_match = not target:find("/", 1, true)
      and (names[basename] or (not extension and names[basename:gsub("%.%w+$", "")]))
    if candidates[path] or basename_match then
      if not seen[path] then result[#result + 1], seen[path] = path, true end
    end
  end
  return result
end

local function tex_escape(text)
  local replacements = {
    ["\\"] = "\\textbackslash{}", ["{"] = "\\{", ["}"] = "\\}",
    ["%"] = "\\%", ["$"] = "\\$", ["#"] = "\\#", ["&"] = "\\&",
    ["_"] = "\\_", ["~"] = "\\textasciitilde{}", ["^"] = "\\textasciicircum{}",
  }
  return (text:gsub("[\\{}%%$#&_~^]", replacements))
end

local builtin = {
  markdown = "# {{title}}\n\nCreated: {{date}}\n\n## Notes\n\n\n## Links\n\n",
  daily = "# {{title}}\n\n## Focus\n\n- [ ] \n\n## Notes\n\n\n## Links\n\n",
  tex = [=[\documentclass[11pt]{article}
\usepackage[T1]{fontenc}
\usepackage[utf8]{inputenc}
\usepackage{amsmath,amssymb,amsthm,mathtools}
\usepackage[margin=1in]{geometry}
\usepackage[hidelinks]{hyperref}
\newtheorem{theorem}{Theorem}[section]
\newtheorem{lemma}[theorem]{Lemma}
\newtheorem{proposition}[theorem]{Proposition}
\newtheorem{corollary}[theorem]{Corollary}
\theoremstyle{definition}
\newtheorem{definition}[theorem]{Definition}
\newtheorem{example}[theorem]{Example}
\theoremstyle{remark}
\newtheorem*{remark}{Remark}
\newcommand{\R}{\mathbb{R}}
\newcommand{\N}{\mathbb{N}}
\newcommand{\Z}{\mathbb{Z}}
\newcommand{\Q}{\mathbb{Q}}
\newcommand{\C}{\mathbb{C}}
\title{ {{title}} }
\author{}
\date{ {{date}} }
\begin{document}
\maketitle

\section{Notes}

% Wiki links work in comments: [[index]]

\end{document}
]=],
}

local function read_lines(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.size > 2 * 1024 * 1024 then return {} end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

local function template(kind, title)
  local text = builtin[kind]
  if config.templates_dir then
    local name = kind == "tex" and "tex.tex" or (kind .. ".md")
    local path = vim.fs.normalize(vim.fn.expand(config.templates_dir)) .. "/" .. name
    if uv.fs_stat(path) then text = table.concat(read_lines(path), "\n") .. "\n" end
  end
  local replacements = {
    title = kind == "tex" and tex_escape(title) or title,
    date = os.date("%Y-%m-%d"), datetime = os.date("%Y-%m-%d %H:%M"),
  }
  return (text:gsub("{{(%w+)}}", function(key) return replacements[key] or ("{{" .. key .. "}}") end))
end

local function open(path, line)
  local safe, err = safe_path(path, true)
  if not safe then notify(err, vim.log.levels.ERROR); return end
  local ok, edit_error = pcall(vim.cmd.edit, vim.fn.fnameescape(safe))
  if not ok then notify(tostring(edit_error), vim.log.levels.ERROR); return end
  if line then vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 }) end
  return safe
end

local function create(kind, title, path)
  local safe, err = safe_path(path)
  if not safe then notify(err, vim.log.levels.ERROR); return end
  if uv.fs_stat(safe) then
    notify("Opening existing note: " .. relative(safe))
    return open(safe)
  end
  local parent = vim.fs.dirname(safe)
  local ok, mkdir_err = pcall(vim.fn.mkdir, parent, "p")
  if not ok then notify(tostring(mkdir_err), vim.log.levels.ERROR); return end
  safe, err = safe_path(safe)
  if not safe then notify(err, vim.log.levels.ERROR); return end
  local fd, write_err = uv.fs_open(safe, "wx", 420)
  if not fd then notify("Could not create note: " .. tostring(write_err), vim.log.levels.ERROR); return end
  local content = template(kind, title)
  local written, content_err = uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  if not written then notify("Could not write note: " .. tostring(content_err), vim.log.levels.ERROR); return end
  return open(safe)
end

function M.new(kind, title)
  kind = kind or "markdown"
  if not builtin[kind] then notify("Unknown note type: " .. tostring(kind), vim.log.levels.ERROR); return end
  if kind == "daily" then
    return create("daily", os.date("%A, %d %B %Y"), root .. "/daily/" .. os.date("%Y-%m-%d") .. ".md")
  end
  if not title then
    vim.ui.input({ prompt = kind == "tex" and "TeX note title: " or "Note title: " }, function(value)
      if value and vim.trim(value) ~= "" then M.new(kind, value) end
    end)
    return
  end
  title = vim.trim(title:gsub("[\r\n]", " "))
  if title == "" then return end
  return create(kind, title, root .. "/" .. M.slugify(title) .. (kind == "tex" and ".tex" or ".md"))
end

function M.daily() return M.new("daily") end

local function items(paths)
  local result = {}
  for _, path in ipairs(paths) do result[#result + 1] = { label = relative(path), value = path } end
  return result
end

function M.find()
  return picker.choose(items(M.files()), { title = "Find note" }, function(item)
    if item then open(item.value) end
  end)
end

function M.search(query)
  if not query then
    vim.ui.input({ prompt = "Search notes (literal text): " }, function(value)
      if value and value ~= "" then M.search(value) end
    end)
    return
  end
  if query == "" then return end
  local matches, truncated = {}, false
  for _, path in ipairs(M.files()) do
    for line_number, line in ipairs(read_lines(path)) do
      if line:lower():find(query:lower(), 1, true) then
        matches[#matches + 1] = { label = relative(path) .. ":" .. line_number .. "  " .. vim.trim(line), value = path, line = line_number }
        if #matches >= 1000 then truncated = true; break end
      end
    end
    if truncated then break end
  end
  if truncated then notify("Showing the first 1,000 matches; use a more specific search to narrow results.") end
  return picker.choose(matches, { title = "Search: " .. query, empty = "No notes contain that text." }, function(item)
    if item then open(item.value, item.line) end
  end)
end

---Extract wiki links, ignoring Markdown fenced code blocks.
function M.list_links(lines)
  local links, fence, fence_size = {}, nil, nil
  for row, line in ipairs(lines) do
    local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if marker then
      if not fence then fence, fence_size = marker:sub(1, 1), #marker
      elseif marker:sub(1, 1) == fence and #marker >= fence_size then fence, fence_size = nil, nil end
    elseif not fence then
      local offset = 1
      while true do
        local first, last, target = line:find("%[%[([^%]]+)%]%]", offset)
        if not first then break end
        links[#links + 1] = { target = target, line = row, first = first, last = last }
        offset = last + 1
      end
    end
  end
  return links
end

local function at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, link in ipairs(M.list_links(lines)) do
    if link.line == cursor[1] and cursor[2] + 1 >= link.first and cursor[2] + 1 <= link.last then return link.target end
  end
end

local function jump_anchor(anchor)
  if not anchor or anchor == "" then return end
  local wanted = M.slugify(anchor)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local heading = line:match("^#+%s+(.+)")
    if heading and M.slugify(heading:gsub("%s+#+%s*$", "")) == wanted then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      return
    end
    if line:find("\\label{" .. anchor .. "}", 1, true) then vim.api.nvim_win_set_cursor(0, { row, 0 }); return end
  end
  notify("Note opened; heading or label not found: " .. anchor, vim.log.levels.WARN)
end

function M.follow_link(target)
  target = target or at_cursor()
  if not target then notify("Place the cursor inside a [[wiki-link]]."); return end
  local destination, anchor = parse_target(target)
  local source = vim.api.nvim_buf_get_name(0)
  if destination == "" and anchor and within(normalize(source)) then jump_anchor(anchor); return end
  local paths, err = M.resolve(destination, source)
  if err then notify(err, vim.log.levels.ERROR); return end
  local function visit(path) if open(path) then jump_anchor(anchor) end end
  if #paths == 1 then visit(paths[1]); return paths[1] end
  if #paths > 1 then
    return picker.choose(items(paths), { title = "Several notes match — choose one" }, function(item)
      if item then visit(item.value) end
    end)
  end
  local extension = destination:match("%.(tex)$") and ".tex" or ".md"
  local name = destination:gsub("%.md$", ""):gsub("%.tex$", "")
  local parent = vim.fs.dirname(name)
  if parent == "." then parent = "" end
  local stem = M.slugify(vim.fs.basename(name))
  local relative_new = (parent ~= "" and (parent .. "/") or "") .. stem .. extension
  local safe, safe_err = safe_path(root .. "/" .. relative_new)
  if not safe then notify(safe_err, vim.log.levels.ERROR); return end
  vim.ui.select({ "Create " .. relative_new, "Cancel" }, { prompt = "This note does not exist." }, function(_, index)
    if index == 1 then
      create(extension == ".tex" and "tex" or "markdown", (target:match("|(.+)$") or vim.fs.basename(name)), safe)
    end
  end)
end

function M.insert_link()
  local buffer, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  return picker.choose(items(M.files()), { title = "Insert wiki link" }, function(item)
    if not item or not vim.api.nvim_buf_is_valid(buffer) then return end
    -- Explicit root-relative path plus extension avoids .md/.tex name collisions.
    local text = "[[" .. relative(item.value) .. "]]"
    local row, col = cursor[1] - 1, cursor[2]
    local line = vim.api.nvim_buf_get_lines(buffer, row, row + 1, false)[1]
    if not line then return end
    col = math.min(col, #line)
    local ok, err = pcall(vim.api.nvim_buf_set_text, buffer, row, col, row, col, { text })
    if not ok then notify(tostring(err), vim.log.levels.ERROR) end
  end)
end

function M.backlinks()
  local current, err = safe_path(vim.api.nvim_buf_get_name(0), true)
  if not current then notify(err, vim.log.levels.WARN); return end
  local matches = {}
  local all_files = M.files()
  for _, path in ipairs(all_files) do
    for _, link in ipairs(M.list_links(read_lines(path))) do
      local candidates = M.resolve(link.target, path, all_files)
      for _, candidate in ipairs(candidates) do
        if candidate == current then
          matches[#matches + 1] = {
            label = relative(path) .. ":" .. link.line, detail = "[[" .. link.target .. "]]",
            value = path, line = link.line,
          }
          break
        end
      end
    end
  end
  return picker.choose(matches, { title = "Backlinks", empty = "No wiki links point to this note yet." }, function(item)
    if item then open(item.value, item.line) end
  end)
end

function M.setup(options)
  config = options or {}
  local requested = normalize(vim.fn.expand(assert(config.vault, "MatWiki requires config.vault")))
  vim.fn.mkdir(requested, "p")
  root = normalize(assert(uv.fs_realpath(requested), "Cannot access the MatWiki vault"))
  local commands = {
    MatwikiNew = { function(args) M.new("markdown", args.args ~= "" and args.args or nil) end, "*" },
    MatwikiTex = { function(args) M.new("tex", args.args ~= "" and args.args or nil) end, "*" },
    MatwikiDaily = { M.daily, 0 }, MatwikiFind = { M.find, 0 },
    MatwikiSearch = { function(args) M.search(args.args ~= "" and args.args or nil) end, "*" },
    MatwikiFollow = { function() M.follow_link() end, 0 },
    MatwikiLink = { M.insert_link, 0 }, MatwikiBacklinks = { M.backlinks, 0 },
  }
  for name, command in pairs(commands) do
    vim.api.nvim_create_user_command(name, command[1], { nargs = command[2], force = true })
  end
  return M
end

return M
