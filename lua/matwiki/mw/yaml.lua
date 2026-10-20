-- Front matter: a deliberately small, predictable YAML subset.
-- Supports scalars, "quoted"/'quoted' strings, flow {maps} and [lists],
-- indented block maps and "- " lists, and | / > block scalars.
local U = require('matwiki.mw.util')
local Y = {}

local function unquote_double(s)
  local map = { n = '\n', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
  return (s:gsub('\\(.)', function(c) return map[c] or ('\\' .. c) end))
end

local function scalar(s)
  s = U.trim(s)
  if s == '' or s == '~' or s == 'null' then return nil end
  if s == 'true' or s == 'yes' then return true end
  if s == 'false' or s == 'no' then return false end
  local q = s:sub(1, 1)
  if q == '"' and s:sub(-1) == '"' and #s >= 2 then return unquote_double(s:sub(2, -2)) end
  if q == "'" and s:sub(-1) == "'" and #s >= 2 then return (s:sub(2, -2):gsub("''", "'")) end
  if s:match('^-?%d+%.?%d*$') then return tonumber(s) end
  return (s:gsub('%s+#.*$', ''))
end

-- Flow collections: { a: 1, "b": [x, y] }
local function flow(s, i)
  local function ws() i = s:find('[^%s]', i) or (#s + 1) end
  local value
  local function str_or_plain(stops)
    ws()
    local q = s:sub(i, i)
    if q == '"' or q == "'" then
      local j = i + 1
      while j <= #s do
        local c = s:sub(j, j)
        if c == '\\' and q == '"' then j = j + 2
        elseif c == q then
          if q == "'" and s:sub(j + 1, j + 1) == "'" then j = j + 2 else break end
        else j = j + 1 end
      end
      local raw = s:sub(i, j)
      i = j + 1
      return scalar(raw), true
    end
    local j = i
    while j <= #s and not stops[s:sub(j, j)] do j = j + 1 end
    local raw = s:sub(i, j - 1)
    i = j
    return scalar(raw), false
  end
  value = function()
    ws()
    local c = s:sub(i, i)
    if c == '{' then
      i = i + 1
      local map = {}
      while true do
        ws()
        if s:sub(i, i) == '}' then i = i + 1 break end
        if i > #s then break end
        local key = str_or_plain({ [':'] = true, ['}'] = true, [','] = true })
        ws()
        if s:sub(i, i) == ':' then i = i + 1 end
        local v = value()
        if key ~= nil then map[tostring(key)] = v end
        ws()
        if s:sub(i, i) == ',' then i = i + 1 end
      end
      return map
    elseif c == '[' then
      i = i + 1
      local list = setmetatable({}, U.array_mt)
      while true do
        ws()
        if s:sub(i, i) == ']' then i = i + 1 break end
        if i > #s then break end
        list[#list + 1] = value()
        ws()
        if s:sub(i, i) == ',' then i = i + 1 end
      end
      return list
    end
    return (str_or_plain({ [','] = true, ['}'] = true, [']'] = true }))
  end
  return value(), i
end

local function value_of(raw)
  raw = U.trim(raw)
  local c = raw:sub(1, 1)
  if c == '{' or c == '[' then return (flow(raw, 1)) end
  return scalar(raw)
end

local function split_key(line)
  local q = line:sub(1, 1)
  if q == '"' or q == "'" then
    local key, rest = line:match('^' .. q .. '(.-)' .. q .. '%s*:%s*(.*)$')
    if key then return key, rest end
  end
  local key, rest = line:match('^([^:]-)%s*:%s+(.*)$')
  if not key then key = line:match('^([^:]-)%s*:%s*$'); rest = '' end
  return key, rest
end

local parse_block
parse_block = function(lines, i, indent)
  -- Skip blanks/comments to find the first meaningful line.
  while lines[i] and (U.is_blank(lines[i]) or lines[i]:match('^%s*#')) do i = i + 1 end
  if not lines[i] then return nil, i end
  local first_indent = U.indent(lines[i])
  if first_indent < indent then return nil, i end
  indent = first_indent
  local is_list = lines[i]:sub(indent + 1):match('^%- ') or lines[i]:sub(indent + 1) == '-'
  local result = is_list and setmetatable({}, U.array_mt) or {}
  while lines[i] do
    local line = lines[i]
    if U.is_blank(line) or line:match('^%s*#') then
      i = i + 1
    else
      local ind = U.indent(line)
      if ind < indent then break end
      if ind > indent then i = i + 1 -- stray over-indented line; ignore
      else
        local body = line:sub(indent + 1)
        if is_list then
          if not (body:match('^%- ') or body == '-') then break end
          local item = body:sub(3)
          if U.trim(item) == '' then
            local v
            v, i = parse_block(lines, i + 1, indent + 1)
            result[#result + 1] = v
          else
            result[#result + 1] = value_of(item)
            i = i + 1
          end
        else
          local key, rest = split_key(body)
          if not key then i = i + 1
          else
            rest = U.trim(rest or '')
            if rest == '|' or rest == '>' or rest == '|-' or rest == '>-' then
              local buf, j = {}, i + 1
              local block_indent
              while lines[j] and (U.is_blank(lines[j]) or U.indent(lines[j]) > indent) do
                if not U.is_blank(lines[j]) then block_indent = block_indent or U.indent(lines[j]) end
                buf[#buf + 1] = lines[j]
                j = j + 1
              end
              for k, l in ipairs(buf) do buf[k] = l:sub((block_indent or 0) + 1) end
              while #buf > 0 and U.is_blank(buf[#buf]) do buf[#buf] = nil end
              local text = table.concat(buf, rest:sub(1, 1) == '>' and ' ' or '\n')
              result[key] = text
              i = j
            elseif rest == '' then
              local nxt = i + 1
              while lines[nxt] and U.is_blank(lines[nxt]) do nxt = nxt + 1 end
              local same_level_list = lines[nxt] and U.indent(lines[nxt]) == indent
                and lines[nxt]:sub(indent + 1):match('^%- ')
              local v
              v, i = parse_block(lines, i + 1, same_level_list and indent or indent + 1)
              result[key] = v
            else
              result[key] = value_of(rest)
              i = i + 1
            end
          end
        end
      end
    end
  end
  return result, i
end

function Y.parse(lines)
  local ok, value = pcall(parse_block, lines, 1, 0)
  if ok and type(value) == 'table' then return value end
  return {}, not ok and tostring(value) or nil
end

return Y
