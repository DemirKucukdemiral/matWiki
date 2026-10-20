-- Run: nvim --headless -u NONE -i NONE -n -l tests/wiki.lua
local script = debug.getinfo(1, "S").source:sub(2)
local project = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ":p")))
vim.opt.runtimepath:prepend(project)
vim.o.hidden, vim.o.swapfile = true, false

local uv = vim.uv or vim.loop
local vault = assert(uv.fs_mkdtemp("/tmp/matwiki-wiki-XXXXXX"))
local outside = assert(uv.fs_mkdtemp("/tmp/matwiki-outside-XXXXXX"))
local wiki = require("matwiki.wiki")
local picker = require("matwiki.picker")
local notices, picks = {}, {}
vim.notify = function(message) notices[#notices + 1] = message end
local actual_choose = picker.choose
picker.choose = function(items, opts, callback)
  picks[#picks + 1] = { items = items, opts = opts, callback = callback }
end

local count = 0
local function eq(actual, expected, label)
  count = count + 1
  assert(vim.deep_equal(actual, expected), (label or "assertion") .. "\nExpected: " .. vim.inspect(expected) .. "\nActual: " .. vim.inspect(actual))
end
local function truth(value, label)
  count = count + 1
  assert(value, label)
end
local function write(name, lines)
  local path = vault .. "/" .. name
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines or { "# " .. name }, path)
  return path
end

local ok, err = xpcall(function()
  wiki.setup({ vault = vault })
  eq(wiki.slugify("  Linear Algebra & Proofs!  "), "linear-algebra-proofs", "stable slugs")
  eq(wiki.slugify("../"), "untitled", "empty slugs stay safe")
  local note = wiki.new("markdown", "Linear Algebra")
  eq(note, vault .. "/linear-algebra.md", "new note returns its path")
  truth(vim.fn.readfile(note)[1] == "# Linear Algebra", "Markdown title")
  vim.fn.writefile({ "keep me" }, note)
  wiki.new("markdown", "Linear Algebra")
  eq(vim.fn.readfile(note), { "keep me" }, "existing notes never overwritten")
  local tex = wiki.new("tex", "Sets & 100%")
  local tex_content = table.concat(vim.fn.readfile(tex), "\n")
  truth(tex_content:find("amsmath,amssymb,amsthm", 1, true), "TeX math packages")
  truth(tex_content:find("Sets \\& 100\\%", 1, true), "TeX title escapes special characters")
  truth(tex_content:find("\\begin{document}", 1, true), "TeX template is a standalone document")
  local daily = wiki.daily()
  eq(daily, wiki.daily(), "daily notes reuse today's file")
  truth(daily:find("/daily/" .. os.date("%Y-%m-%d") .. ".md", 1, true), "daily path")

  write(".hidden/secret.md")
  write("code/example.md")
  write("build/generated.tex")
  write(".secret.md")
  write("node_modules/readme.md")
  write("not-a-note.txt")
  local top = write("limit.md")
  local nested = write("analysis/limit.md")
  local tex_limit = write("analysis/limit.tex")
  local source = write("analysis/source.md")
  local files = wiki.files()
  eq(#files, 7, "only note files are listed")
  eq(wiki.resolve("limit", source), { nested, tex_limit, top }, "bare links expose all collisions")
  eq(wiki.resolve("analysis/limit.md", source), { nested }, "folder plus extension disambiguates")
  eq(wiki.resolve("linear-algebra|Linear algebra"), { note }, "labels do not affect resolution")
  eq(wiki.resolve("Linear Algebra#Notes"), { note }, "titles resolve to slugs with optional anchors")
  local bad, reason = wiki.resolve("../escape")
  eq(bad, {}, "traversal rejected")
  truth(reason, "traversal explains failure")
  bad, reason = wiki.resolve("/etc/passwd")
  eq(bad, {}, "absolute links rejected")
  truth(reason, "absolute link explains failure")

  vim.fn.writefile({ "outside" }, outside .. "/outside.md")
  assert(uv.fs_symlink(outside .. "/outside.md", vault .. "/outside.md"))
  assert(uv.fs_symlink(outside, vault .. "/escape-dir", { dir = true }))
  eq(wiki.resolve("outside"), {}, "external file symlink excluded")
  local prompted = false
  vim.ui.select = function() prompted = true end
  wiki.follow_link("escape-dir/new-note")
  eq(prompted, false, "external parent symlink blocks before create prompt")
  truth(not uv.fs_stat(outside .. "/new-note.md"), "no file written outside vault")
  assert(uv.fs_symlink(note, vault .. "/alias.md"))
  eq(wiki.resolve("alias"), { note }, "internal symlink resolves safely")
  eq(#wiki.files(), 7, "internal aliases do not duplicate listings")

  eq(wiki.list_links({
    "[[one|One]] and [[two#Section]]", "```lua", "[[ignored]]", "````", "~~~", "[[also-ignored]]", "~~~", "% [[tex-link]]",
  }), {
    { target = "one|One", line = 1, first = 1, last = 11 },
    { target = "two#Section", line = 1, first = 17, last = 31 },
    { target = "tex-link", line = 8, first = 3, last = 14 },
  }, "links skip fenced code and include TeX comments")

  wiki.follow_link("limit")
  eq(#picks[#picks].items, 3, "following ambiguous links offers a picker")
  vim.ui.select = function(_, _, callback) callback(nil, 2) end
  wiki.follow_link("cancelled")
  truth(not uv.fs_stat(vault .. "/cancelled.md"), "missing note cancellation is respected")
  vim.ui.select = function(_, _, callback) callback("Create", 1) end
  wiki.follow_link("new Folder/A Topic|A lovely topic")
  local created = vault .. "/new Folder/a-topic.md"
  truth(uv.fs_stat(created), "confirmed missing link creates a nested note")
  eq(wiki.resolve("new Folder/A Topic"), { created }, "created link remains resolvable")
  eq(vim.fn.readfile(created)[1], "# A lovely topic", "link display label becomes note title")

  write("linked.md", { "[[linear-algebra]]", "```", "[[linear-algebra]]", "```", "[[analysis/limit.md]]" })
  vim.cmd.edit(vim.fn.fnameescape(note))
  wiki.backlinks()
  eq(#picks[#picks].items, 1, "backlinks ignore fenced examples")
  eq(picks[#picks].items[1].value, vault .. "/linked.md", "backlink points to source")
  wiki.search("[[analysis/limit.md]]")
  eq(#picks[#picks].items, 1, "search treats punctuation literally")
  eq(picks[#picks].items[1].line, 5, "search preserves line number")

  local templates = vault .. "/.templates"
  vim.fn.mkdir(templates, "p")
  vim.fn.writefile({ "# {{title}}", "On {{date}}", "{{unknown}}" }, templates .. "/markdown.md")
  wiki.setup({ vault = vault, templates_dir = templates })
  local custom = wiki.new("markdown", "Custom template")
  eq(vim.fn.readfile(custom), { "# Custom template", "On " .. os.date("%Y-%m-%d"), "{{unknown}}" }, "custom templates substitute known placeholders")
  truth(picker.score("linear-algebra", "lalg") ~= nil, "fuzzy subsequence matching")
  eq(picker.score("linear-algebra", "xyz"), nil, "fuzzy nonmatch")
  truth(picker.score("algebra", "alg") < picker.score("a-long-gap", "alg"), "consecutive matches rank first")

  -- Create a note and its parent folders directly from the normal new-note command.
  local nested_mw = wiki.new("mw", "Research/Control/Linear Systems.mw")
  eq(nested_mw, vault .. "/Research/Control/linear-systems.mw", "new note preserves nested folders without a doubled extension")
  truth(vim.fn.readfile(nested_mw)[2] == 'title: "Linear Systems"', "front matter has just the note title")
  local nested_tex = wiki.new("tex", "Research/Proofs/Some Sets.tex")
  eq(nested_tex, vault .. "/Research/Proofs/some-sets.tex", "nested TeX creation")
  eq(wiki.new("mw", "../outside"), nil, "new-note command rejects traversal")
  eq(wiki.new("mw", "escape-dir/nope"), nil, "new-note command rejects escaped symlink parents")
  eq(wiki.new("mw", "Research/"), nil, "a folder path needs a note title")
  eq(wiki.new("mw", "Research/other.md"), nil, "mismatched extension is explained instead of silently renamed")
  eq(wiki.new("mw", "Research/No#Anchor"), nil, "new paths must remain representable in wiki links")
  eq(wiki.new("mw", "Research/picture.assets/hidden"), nil, "new notes cannot be created in excluded asset folders")
  local folder = wiki.folder("Research/New area/Nested")
  eq(folder, vault .. "/Research/New area/Nested", "folder command creates nested parents")
  truth(vim.fn.isdirectory(folder) == 1, "new folder exists")
  eq(wiki.folder("Research/New area/Nested"), folder, "existing folders reopen")
  eq(wiki.folder("escape-dir/new"), nil, "folder creation rejects external symlink parents")
  eq(wiki.folder("../outside"), nil, "folder command rejects traversal")
  eq(wiki.folder("linear-algebra.md"), nil, "folder cannot replace an existing note")
  local prompted_default
  vim.ui.input = function(opts) prompted_default = opts.default end
  wiki.new("mw")
  eq(prompted_default, "Research/New area/Nested/", "new-note prompt starts in the browsed folder")

  -- Exact paths inserted by the picker remain unambiguous, unlike bare titles.
  local collision = write("analysis/analysis/limit.md")
  eq(wiki.resolve("analysis/limit.md", source), { nested }, "explicit path uses vault root before source-local namesake")
  eq(wiki.resolve("limit.md", source), { top }, "explicit filename uses vault root")
  local local_note = write("analysis/unique.md")
  eq(wiki.resolve("unique.md", source), { local_note }, "explicit filename falls back to source folder")
  vim.cmd.edit(vim.fn.fnameescape(source))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "See " })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  wiki.insert_link("analysis/limit.md#Notes|Limit")
  eq(vim.api.nvim_get_current_line(), "See[[analysis/limit.md#Notes|Limit]] ", "direct link retains anchor and display text")
  local original_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.ui.select = function(_, _, callback) callback("Create", 1) end
  wiki.insert_link("Research/Next Idea.mw")
  eq(vim.api.nvim_get_current_buf(), original_buffer, "create and link keeps the source note open")
  eq(vim.api.nvim_get_current_line(), "[[Research/next-idea.mw]]", "create and link inserts canonical path")
  truth(vim.fn.filereadable(vault .. "/Research/next-idea.mw") == 1, "create and link writes its destination")
  vim.ui.select = function(_, _, callback) callback(nil, 2) end
  wiki.insert_link("Research/cancelled.mw")
  truth(vim.fn.filereadable(vault .. "/Research/cancelled.mw") == 0, "cancelled link does not create a note")
  wiki.insert_link()
  truth(picks[#picks].items[1].create, "link picker always offers a create action")
  vim.ui.input = function(_, callback) callback("Research/From Picker.mw") end
  vim.ui.select = function(_, _, callback) callback("Create", 1) end
  picks[#picks].callback(picks[#picks].items[1])
  truth(vim.fn.filereadable(vault .. "/Research/from-picker.mw") == 1, "link picker can create a new note")

  vim.cmd("MatwikiFolder Command/Folder")
  truth(vim.fn.isdirectory(vault .. "/Command/Folder") == 1, "folder command is registered")
  vim.cmd("MatwikiMw Command/Folder/From Command")
  eq(vim.api.nvim_buf_get_name(0), vault .. "/Command/Folder/from-command.mw", "new-note command handles paths with spaces")
  vim.cmd("MatwikiLink Research/next-idea.mw")
  truth(vim.api.nvim_get_current_line():find("[[Research/next-idea.mw]]", 1, true), "link command accepts a destination")

  truth(vim.fn.isdirectory(vault .. "/.git") == 1, "vault automatically initializes its own .git repo")
  truth(vim.fn.filereadable(vault .. "/.gitignore") == 1, "vault automatically writes .gitignore")
  truth(wiki.sync(), "MatwikiSync commits notes in the vault")
  local second_vault = outside .. "/second-vault"
  vim.cmd("MatwikiVault " .. second_vault)
  truth(vim.fn.isdirectory(second_vault .. "/.git") == 1, "MatwikiVault creates and Git-initializes a new vault")
  truth(vim.fn.filereadable(second_vault .. "/.gitignore") == 1, "MatwikiVault writes .gitignore in new vault")

  -- Exercise real floating window creation/cleanup, including the cancel callback.
  picker.choose = actual_choose
  local cancelled = false
  local handle = picker.choose({ "alpha", "beta" }, { title = "Test" }, function(item) cancelled = item == nil end)
  truth(vim.api.nvim_buf_is_valid(handle.input), "picker creates input buffer")
  vim.api.nvim_buf_set_lines(handle.input, 0, -1, false, { "bt" })
  vim.wait(20)
  eq(vim.api.nvim_buf_get_lines(handle.results, 0, -1, false), { " beta" }, "picker filters live input")
  handle.close()
  vim.wait(20)
  truth(cancelled, "picker cancellation callback")
  truth(not vim.api.nvim_buf_is_valid(handle.input), "picker cleans up its scratch buffer")
end, debug.traceback)

vim.fn.delete(vault, "rf")
vim.fn.delete(outside, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("wiki tests: " .. count .. " assertions passed")
  vim.cmd("qa!")
end
