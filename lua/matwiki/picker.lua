-- A small keyboard-first fuzzy picker; no external plugin is required.
local M = {}

local function label(item)
  if type(item) == "table" then
    return tostring(item.label or item.value or "")
  end
  return tostring(item)
end

-- Subsequence matching: consecutive letters and matches near the start rank first.
function M.score(text, query)
  text, query = text:lower(), query:lower()
  if query == "" then return 0 end
  local position, score, previous = 1, 0, 0
  for i = 1, #query do
    local found = text:find(query:sub(i, i), position, true)
    if not found then return nil end
    score = score + found - previous - 1
    if i == 1 then score = score + found * 2 end
    previous, position = found, found + 1
  end
  return score
end

---Choose from strings or { label, detail?, value? } records.
---The callback receives the original item, or nil when cancelled.
function M.choose(items, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if #items == 0 then
    vim.notify(opts.empty or "No matching notes.", vim.log.levels.INFO)
    callback(nil)
    return
  end

  local origin = vim.api.nvim_get_current_win()
  local columns, lines = vim.o.columns, vim.o.lines
  local width = math.max(1, math.min(opts.width or 80, columns - 6))
  local height = math.max(1, math.min(opts.height or 12, #items, lines - 9))
  local row = math.max(0, math.floor((lines - height - 5) / 2))
  local col = math.max(0, math.floor((columns - width) / 2))
  local input = vim.api.nvim_create_buf(false, true)
  local results = vim.api.nvim_create_buf(false, true)
  for _, buf in ipairs({ input, results }) do
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "matwiki-picker"
  end
  local input_win = vim.api.nvim_open_win(input, true, {
    relative = "editor", row = row, col = col, width = width, height = 1,
    style = "minimal", border = "rounded", title = " " .. (opts.prompt or opts.title or "MatWiki") .. " ",
    title_pos = "left",
  })
  local result_win = vim.api.nvim_open_win(results, false, {
    relative = "editor", row = row + 3, col = col, width = width, height = height,
    style = "minimal", border = "rounded", focusable = false,
    footer = " Enter select · Ctrl-n/p move · Esc close ", footer_pos = "left",
  })
  vim.wo[input_win].wrap = false
  vim.wo[result_win].wrap = false
  vim.wo[result_win].cursorline = true
  vim.wo[result_win].winhighlight = "CursorLine:PmenuSel"
  local selected, filtered, closed = 1, {}, false
  local autocmd

  local function close(item)
    if closed then return end
    closed = true
    if autocmd then pcall(vim.api.nvim_del_autocmd, autocmd) end
    vim.cmd.stopinsert()
    for _, win in ipairs({ input_win, result_win }) do
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end
    for _, buf in ipairs({ input, results }) do
      if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    end
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
    vim.schedule(function() callback(item) end)
  end

  local function render()
    if closed or not vim.api.nvim_buf_is_valid(results) then return end
    local output = {}
    for _, entry in ipairs(filtered) do
      local detail = type(entry.item) == "table" and entry.item.detail or nil
      output[#output + 1] = " " .. label(entry.item):gsub("[\r\n]", " ")
        .. (detail and ("  · " .. tostring(detail):gsub("[\r\n]", " ")) or "")
    end
    if #output == 0 then output = { " No matches" } end
    vim.bo[results].modifiable = true
    vim.api.nvim_buf_set_lines(results, 0, -1, false, output)
    vim.bo[results].modifiable = false
    if vim.api.nvim_win_is_valid(result_win) then
      vim.api.nvim_win_set_cursor(result_win, { math.max(1, selected), 0 })
    end
  end

  local function filter()
    if closed or not vim.api.nvim_buf_is_valid(input) then return end
    local query = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), " ")
    filtered = {}
    for index, item in ipairs(items) do
      local score = M.score(label(item), query)
      if score then filtered[#filtered + 1] = { item = item, score = score, index = index } end
    end
    table.sort(filtered, function(a, b)
      if a.score == b.score then return a.index < b.index end
      return a.score < b.score
    end)
    selected = 1
    render()
  end

  local function move(delta)
    if #filtered == 0 then return end
    selected = ((selected - 1 + delta) % #filtered) + 1
    render()
  end

  local function choose()
    if filtered[selected] then close(filtered[selected].item) end
  end

  local function map(mode, key, action)
    vim.keymap.set(mode, key, action, { buffer = input, nowait = true, silent = true })
  end
  for _, mode in ipairs({ "i", "n" }) do
    map(mode, "<CR>", choose)
    map(mode, "<Esc>", function() close(nil) end)
    map(mode, "<C-c>", function() close(nil) end)
    map(mode, "<C-n>", function() move(1) end)
    map(mode, "<C-p>", function() move(-1) end)
    map(mode, "<Down>", function() move(1) end)
    map(mode, "<Up>", function() move(-1) end)
  end
  map("n", "j", function() move(1) end)
  map("n", "k", function() move(-1) end)
  map("n", "q", function() close(nil) end)
  vim.api.nvim_buf_attach(input, false, {
    on_lines = function() vim.schedule(filter) end,
    on_detach = function() if not closed then vim.schedule(function() close(nil) end) end end,
  })
  autocmd = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(input_win), once = true,
    callback = function() vim.schedule(function() close(nil) end) end,
  })
  filter()
  vim.cmd.startinsert()
  return { close = function() close(nil) end, input = input, results = results }
end

return M
