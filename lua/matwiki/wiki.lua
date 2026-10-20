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
  if target:find("[%c\\%[%]#|]") or target:sub(1, 1) == "/" or target:match("^%a:") then
    return false, "Use a relative note name inside your vault."
  end
  for part in target:gmatch("[^/]+") do
    if part == ".." or part == "." or part:sub(1, 1) == "." then
      return false, "Hidden paths and parent traversal are not allowed in wiki links."
    end
    if excluded[part] or part:match("%.assets$") then return false, "That directory is excluded from the note vault." end
  end
  return true
end

---Sorted absolute paths to .mw, Markdown, and TeX notes, excluding hidden/build/code/.assets dirs.
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
        if kind == "directory" and not excluded[name] and not name:match("%.assets$") then
          walk(path)
        elseif (kind == "file" or kind == "link")
          and (name:match("%.mw$") or name:match("%.md$") or name:match("%.tex$")) then
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
  local extension = target:match("%.(mw)$") or target:match("%.(md)$") or target:match("%.(tex)$")
  local candidates, result, seen, rooted = {}, {}, {}, {}
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
      add(path .. ".mw")
      add(path .. ".md")
      add(path .. ".tex")
    end
  end
  for name in pairs(names) do
    candidate(root .. "/" .. name)
  end
  for path in pairs(candidates) do rooted[path] = true end
  for name in pairs(names) do
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
  -- A path or explicit filename identifies a vault-root note first. This makes
  -- links inserted by the picker stable even when the source has a namesake.
  if extension or target:find("/", 1, true) then
    local exact = {}
    for _, path in ipairs(result) do if rooted[path] then exact[#exact + 1] = path end end
    if #exact > 0 then return exact end
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
  mw = "---\ntitle: {{title}}\ndate: {{date}}\nkernel: python\n---\n\n# {{title}}\n\n## Notes\n\n\n## Connections\n\n",
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
    local name = kind == "tex" and "tex.tex" or (kind == "mw" and "mw.mw") or (kind .. ".md")
    local path = vim.fs.normalize(vim.fn.expand(config.templates_dir)) .. "/" .. name
    if uv.fs_stat(path) then text = table.concat(read_lines(path), "\n") .. "\n" end
  end
  local replacements = {
    title = kind == "tex" and tex_escape(title) or title,
    date = os.date("%Y-%m-%d"), datetime = os.date("%Y-%m-%d %H:%M"),
  }
  if kind == "mw" then
    -- Quote front-matter titles without quoting their Markdown headings.
    text = text:gsub("(\ntitle:%s*){{title}}", function(prefix) return prefix .. vim.json.encode(title) end, 1)
  end
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

local function create(kind, title, path, stay)
  local safe, err = safe_path(path)
  if not safe then notify(err, vim.log.levels.ERROR); return end
  local stat = uv.fs_stat(safe)
  if stat then
    if stat.type ~= "file" then notify("A folder already uses that note name.", vim.log.levels.ERROR); return end
    if stay then return safe end
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
  return stay and safe or open(safe)
end

local function note_path(kind, title)
  local valid, err = valid_target(title)
  if not valid then return nil, err end
  if title:sub(-1) == "/" or title:find("//", 1, true) then return nil, "Add a note title after the folder name." end
  local ext = kind == "tex" and ".tex" or (kind == "mw" and ".mw" or ".md")
  local supplied = title:match("%.(mw)$") or title:match("%.(md)$") or title:match("%.(tex)$")
  if supplied and ("." .. supplied) ~= ext then
    return nil, "Use the matching note command for ." .. supplied .. " files."
  end
  local stem = supplied and title:sub(1, -#ext - 1) or title
  local parent, basename = vim.fs.dirname(stem), vim.fs.basename(stem)
  local path = root .. "/" .. (parent ~= "." and parent .. "/" or "") .. M.slugify(basename) .. ext
  local safe, safe_err = safe_path(path)
  return safe, safe_err, basename
end

local function current_folder()
  local path = normalize(vim.api.nvim_buf_get_name(0))
  if within(path) then
    local stat = uv.fs_stat(path)
    local dir = relative(stat and stat.type == "directory" and path or vim.fs.dirname(path))
    if dir ~= root and dir ~= "" then return dir .. "/" end
  end
  return ""
end

function M.new(kind, title, stay)
  kind = kind or "markdown"
  if not builtin[kind] then notify("Unknown note type: " .. tostring(kind), vim.log.levels.ERROR); return end
  if kind == "daily" then
    return create("daily", os.date("%A, %d %B %Y"), root .. "/daily/" .. os.date("%Y-%m-%d") .. ".md")
  end
  if not title then
    local prompt = kind == "tex" and "New TeX note (folder/title): " or (kind == "mw" and "New .mw note (folder/title): " or "New Markdown note (folder/title): ")
    vim.ui.input({ prompt = prompt, default = current_folder() }, function(value)
      if value and vim.trim(value) ~= "" then M.new(kind, value) end
    end)
    return
  end
  title = vim.trim(title)
  if title == "" then return end
  local path, err, basename = note_path(kind, title)
  if not path then notify(err, vim.log.levels.ERROR); return end
  return create(kind, basename, path, stay)
end

function M.daily() return M.new("daily") end

function M.folder(name)
  if not name then
    vim.ui.input({ prompt = "New folder (parent/name): ", default = current_folder() }, function(value)
      if value and vim.trim(value) ~= "" then M.folder(value) end
    end)
    return
  end
  name = vim.trim(name):gsub("/+$", "")
  local valid, err = valid_target(name)
  if not valid then notify(err, vim.log.levels.ERROR); return end
  local path
  path, err = safe_path(root .. "/" .. name)
  if not path then notify(err, vim.log.levels.ERROR); return end
  local stat = uv.fs_stat(path)
  if stat and stat.type ~= "directory" then notify("A file already uses that folder name.", vim.log.levels.ERROR); return end
  local ok, mkdir_err = pcall(vim.fn.mkdir, path, "p")
  if not ok then notify(tostring(mkdir_err), vim.log.levels.ERROR); return end
  notify((stat and "Opened folder: " or "Created folder: ") .. relative(path))
  return open(path)
end

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
    if heading and M.slugify(heading:gsub("%s*%b{}%s*$", ""):gsub("%s+#+%s*$", "")) == wanted then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      return
    end
    if line:find("\\label{" .. anchor .. "}", 1, true)
      or line:find("{#" .. anchor .. "}", 1, true)
      or line:find("{#" .. anchor .. " ", 1, true) then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      return
    end
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
  local extension = destination:match("%.(tex)$") and ".tex"
    or (destination:match("%.(mw)$") and ".mw")
    or (source:match("%.mw$") and not destination:match("%.(md)$") and ".mw")
    or ".md"
  local name = destination:gsub("%.mw$", ""):gsub("%.md$", ""):gsub("%.tex$", "")
  local parent = vim.fs.dirname(name)
  if parent == "." then parent = "" end
  local stem = M.slugify(vim.fs.basename(name))
  local relative_new = (parent ~= "" and (parent .. "/") or "") .. stem .. extension
  local safe, safe_err = safe_path(root .. "/" .. relative_new)
  if not safe then notify(safe_err, vim.log.levels.ERROR); return end
  vim.ui.select({ "Create " .. relative_new, "Cancel" }, { prompt = "This note does not exist." }, function(_, index)
    if index == 1 then
      local kind = extension == ".tex" and "tex" or (extension == ".mw" and "mw" or "markdown")
      create(kind, (target:match("|(.+)$") or vim.fs.basename(name)), safe)
    end
  end)
end

function M.insert_link(target)
  local buffer, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  local source = vim.api.nvim_buf_get_name(buffer)
  local function insert(path, suffix)
    if not vim.api.nvim_buf_is_valid(buffer) then return end
    -- Explicit root-relative path plus extension avoids .md/.tex name collisions.
    local text = "[[" .. relative(path) .. (suffix or "") .. "]]"
    local row, col = cursor[1] - 1, cursor[2]
    local line = vim.api.nvim_buf_get_lines(buffer, row, row + 1, false)[1]
    if not line then return end
    col = math.min(col, #line)
    local ok, err = pcall(vim.api.nvim_buf_set_text, buffer, row, col, row, col, { text })
    if not ok then notify(tostring(err), vim.log.levels.ERROR) end
  end
  local function choose_target(value)
    if not value or vim.trim(value) == "" then return end
    local destination, anchor = parse_target(value)
    local label = value:match("|(.+)$")
    if destination == "" and anchor then
      if within(normalize(source)) then insert(source, "#" .. anchor .. (label and "|" .. label or "")) end
      return
    end
    local paths, err = M.resolve(destination, source)
    if err then notify(err, vim.log.levels.ERROR); return end
    local suffix = (anchor and "#" .. anchor or "") .. (label and "|" .. label or "")
    if #paths == 1 then insert(paths[1], suffix); return end
    if #paths > 1 then
      return picker.choose(items(paths), { title = "Choose the note to link" }, function(item)
        if item then insert(item.value, suffix) end
      end)
    end
    local ext = destination:match("%.(mw)$") or destination:match("%.(md)$") or destination:match("%.(tex)$")
      or (source:match("%.mw$") and "mw" or "md")
    local kind = ext == "tex" and "tex" or (ext == "mw" and "mw" or "markdown")
    local path, path_err, title = note_path(kind, destination)
    if not path then notify(path_err, vim.log.levels.ERROR); return end
    vim.ui.select({ "Create and link " .. relative(path), "Cancel" }, { prompt = "This note does not exist." }, function(_, index)
      if index ~= 1 then return end
      local created = create(kind, label or title, path, true)
      if created then insert(created, suffix) end
    end)
  end
  if target then return choose_target(target) end
  local choices = items(M.files())
  table.insert(choices, 1, { label = "+ Create and link a new note…", create = true })
  return picker.choose(choices, { title = "Insert wiki link" }, function(item)
    if not item then return end
    if item.create then
      vim.ui.input({ prompt = "Link to new note (folder/title): ", default = current_folder() }, choose_target)
    else insert(item.value) end
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

function M.ensure_git(vault_dir)
  vault_dir = normalize(vault_dir or root)
  if config.root and vault_dir == normalize(config.root .. "/notebook") then return false end
  local gitignore = vault_dir .. "/.gitignore"
  if not uv.fs_stat(gitignore) then
    pcall(vim.fn.writefile, {
      ".site/",
      "**/.site/",
      ".matwiki-build/",
      "**/.matwiki-build/",
      "*.swp",
      "*.swo",
      "__pycache__/",
      ".DS_Store",
    }, gitignore)
  end
  if config.git_init ~= false and not uv.fs_stat(vault_dir .. "/.git") and vim.fn.executable("git") == 1 then
    local res = vim.system({ "git", "init", "-q", vault_dir }, { text = true }):wait(5000)
    return res and res.code == 0 or false
  end
  return uv.fs_stat(vault_dir .. "/.git") ~= nil
end

function M.vault(target)
  if not target or vim.trim(target) == "" then
    local default_parent = root and (vim.fs.dirname(root) .. "/") or (vim.fn.expand("~/Documents") .. "/")
    vim.ui.input({ prompt = "Open or create vault folder: ", default = default_parent }, function(value)
      if value and vim.trim(value) ~= "" then M.vault(value) end
    end)
    return
  end
  local requested = normalize(vim.fn.expand(vim.trim(target)))
  local ok, err = pcall(vim.fn.mkdir, requested, "p")
  if not ok then notify("Cannot create vault: " .. tostring(err), vim.log.levels.ERROR); return nil end
  local app = package.loaded["matwiki"]
  if app and app.config then
    app.config.vault = requested
    M.setup(app.config)
    pcall(function() require("matwiki.runner").setup(app.config) end)
    pcall(function() require("matwiki.latex").setup(app.config) end)
    pcall(function() require("matwiki.mw").setup(app.config) end)
    if app.config.standalone then
      pcall(function() require("matwiki.ui").dashboard(app.config) end)
    end
  else
    config.vault = requested
    M.setup(config)
  end
  notify("Vault ready (Git-initialized): " .. root)
  return root
end

function M.sync(remote_url)
  if not root then return false end
  if vim.fn.executable("git") ~= 1 then
    notify("git is not installed.", vim.log.levels.ERROR)
    return false
  end
  M.ensure_git(root)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local name = normalize(vim.api.nvim_buf_get_name(buf))
      if within(name) then pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("silent! write") end) end
    end
  end
  local function git(args)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    return vim.system(cmd, { text = true }):wait(15000)
  end
  if remote_url and vim.trim(remote_url) ~= "" then
    remote_url = vim.trim(remote_url)
    local has_origin = git({ "remote", "get-url", "origin" })
    if has_origin and has_origin.code == 0 then
      git({ "remote", "set-url", "origin", remote_url })
    else
      git({ "remote", "add", "origin", remote_url })
    end
  end
  git({ "add", "-A" })
  local status = git({ "status", "--porcelain" })
  local committed = false
  if status and status.code == 0 and vim.trim(status.stdout or "") ~= "" then
    local msg = "MatWiki sync " .. os.date("%Y-%m-%d %H:%M:%S")
    local c = git({ "commit", "-m", msg })
    if not c or c.code ~= 0 then
      c = git({ "-c", "user.name=MatWiki", "-c", "user.email=matwiki@local", "commit", "-m", msg })
    end
    committed = c and c.code == 0 or false
  end
  local origin = git({ "remote", "get-url", "origin" })
  if origin and origin.code == 0 and vim.trim(origin.stdout or "") ~= "" then
    local branch_res = git({ "rev-parse", "--abbrev-ref", "HEAD" })
    local branch = (branch_res and branch_res.code == 0 and vim.trim(branch_res.stdout or "") ~= "")
      and vim.trim(branch_res.stdout) or "master"
    git({ "pull", "--rebase", "origin", branch })
    local push = git({ "push", "-u", "origin", "HEAD" })
    if push and push.code == 0 then
      notify("Vault synced with origin (" .. vim.trim(origin.stdout) .. ")")
      return true
    else
      notify("Committed locally, but push failed: " .. vim.trim((push and push.stderr) or ""), vim.log.levels.WARN)
      return false
    end
  end
  notify((committed and "Committed notes in " or "Vault up to date in ") .. root
    .. " (run :MatwikiSync <git-url> to connect a remote)")
  return true
end

function M.setup(options)
  config = options or {}
  local requested = normalize(vim.fn.expand(assert(config.vault, "MatWiki requires config.vault")))
  vim.fn.mkdir(requested, "p")
  root = normalize(assert(uv.fs_realpath(requested), "Cannot access the MatWiki vault"))
  M.ensure_git(root)
  local commands = {
    MatwikiMw = { function(args) M.new("mw", args.args ~= "" and args.args or nil) end, "*" },
    MatwikiNew = { function(args) M.new("markdown", args.args ~= "" and args.args or nil) end, "*" },
    MatwikiTex = { function(args) M.new("tex", args.args ~= "" and args.args or nil) end, "*" },
    MatwikiFolder = { function(args) M.folder(args.args ~= "" and args.args or nil) end, "*" },
    MatwikiVault = { function(args) M.vault(args.args ~= "" and args.args or nil) end, "*" },
    MatwikiSync = { function(args) M.sync(args.args ~= "" and args.args or nil) end, "*" },
    MatwikiDaily = { M.daily, 0 }, MatwikiFind = { M.find, 0 },
    MatwikiSearch = { function(args) M.search(args.args ~= "" and args.args or nil) end, "*" },
    MatwikiFollow = { function() M.follow_link() end, 0 },
    MatwikiLink = { function(args) M.insert_link(args.args ~= "" and args.args or nil) end, "*" }, MatwikiBacklinks = { M.backlinks, 0 },
  }
  for name, command in pairs(commands) do
    vim.api.nvim_create_user_command(name, command[1], { nargs = command[2], force = true })
  end
  return M
end

return M
