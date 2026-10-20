-- Small, allocation-conscious helpers shared by the .mw compiler.
-- Pure Lua: no Neovim API, so the compiler also runs under plain LuaJIT.
local U = {}

local html_map = { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;' }
function U.esc(s)
  return (tostring(s):gsub('[&<>"]', html_map))
end

function U.trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function U.split_lines(text)
  local lines, n = {}, 0
  text = text:gsub('\r\n?', '\n')
  for line in (text .. '\n'):gmatch('(.-)\n') do
    n = n + 1
    lines[n] = line
  end
  if n > 0 and lines[n] == '' and text:sub(-1) == '\n' then lines[n] = nil end
  return lines
end

--- Expand leading tabs (tab stop 4) so indentation arithmetic is byte-based.
function U.detab(line)
  if not line:find('^ *\t') then return line end
  local lead, rest = line:match('^([ \t]*)(.*)$')
  local width = 0
  for c in lead:gmatch('.') do
    width = c == '\t' and (width + 4 - width % 4) or width + 1
  end
  return string.rep(' ', width) .. rest
end

function U.indent(line)
  local spaces = line:match('^ *')
  return #spaces
end

function U.is_blank(line)
  return line:find('^%s*$') ~= nil
end

function U.strip_ansi(s)
  return (s:gsub('\27%[[%d;?]*[%a]', ''):gsub('\27%][^\7]*\7', ''))
end

--- GitHub-style heading slug: lowercase, punctuation removed, spaces to dashes.
function U.slug(text)
  local s = text:lower():gsub('<[^>]->', ''):gsub('%$', '')
  s = s:gsub('[^%w\128-\255%s_-]', ''):gsub('%s+', '-')
  s = s:gsub('^%-+', ''):gsub('%-+$', '')
  return s ~= '' and s or 'section'
end

--- Parse a pandoc-style attribute list: `#id .class key=value key="v w" flag`.
function U.parse_attrs(s)
  local attrs = { classes = {}, kv = {} }
  if not s then return attrs end
  s = s:gsub('^%s*{', ''):gsub('}%s*$', '')
  local i, n = 1, #s
  while i <= n do
    local ws = s:match('^%s+', i)
    if ws then i = i + #ws end
    if i > n then break end
    local c = s:sub(i, i)
    if c == '#' then
      local id = s:match('^#([^%s}]+)', i)
      attrs.id = id
      i = i + 1 + #(id or '')
    elseif c == '.' then
      local class = s:match('^%.([^%s}]+)', i)
      if class then attrs.classes[#attrs.classes + 1] = class end
      i = i + 1 + #(class or '')
    else
      local key = s:match('^([%w_:%-]+)', i)
      if not key then
        i = i + 1
      else
        i = i + #key
        if s:sub(i, i) == '=' then
          i = i + 1
          local q = s:sub(i, i)
          local value
          if q == '"' or q == "'" then
            local j = i + 1
            local parts = {}
            while j <= n do
              local ch = s:sub(j, j)
              if ch == '\\' and j < n and (s:sub(j + 1, j + 1) == q or s:sub(j + 1, j + 1) == '\\') then
                parts[#parts + 1] = s:sub(j + 1, j + 1)
                j = j + 2
              elseif ch == q then
                break
              else
                parts[#parts + 1] = ch
                j = j + 1
              end
            end
            value = table.concat(parts)
            i = j + 1
          else
            value = s:match('^[^%s}]*', i)
            i = i + #value
          end
          attrs.kv[key] = value
        else
          attrs.kv[key] = true
        end
      end
    end
  end
  return attrs
end

--- Split a trailing `{...}` attribute block off a line. Returns text, attrs-string|nil.
function U.split_trailing_attrs(s)
  local body, attr = s:match('^(.-)%s*(%b{})%s*$')
  if attr and (attr:find('^{%s*[#.]') or attr:find('^{%s*[%w_:%-]+=')) then
    return body, attr
  end
  return s, nil
end

local url_safe = '[^%w%-%._~/]'
function U.url_path(p)
  return (p:gsub(url_safe, function(c) return string.format('%%%02X', c:byte()) end))
end

function U.dirname(p)
  local d = p:match('^(.*)/[^/]*$')
  if d == '' then return '/' end
  return d or '.'
end

function U.basename(p)
  return p:match('([^/]*)$')
end

function U.stem(p)
  return (U.basename(p):gsub('%.[^.]*$', ''))
end

--- Collapse `.` and `..` segments in an absolute or relative path.
function U.normalize(p)
  local absolute = p:sub(1, 1) == '/'
  local parts = {}
  for part in p:gmatch('[^/]+') do
    if part == '..' then
      if #parts > 0 and parts[#parts] ~= '..' then parts[#parts] = nil
      elseif not absolute then parts[#parts + 1] = '..' end
    elseif part ~= '.' then
      parts[#parts + 1] = part
    end
  end
  return (absolute and '/' or '') .. table.concat(parts, '/')
end

--- Relative path from directory `from` to file `to` (both absolute).
function U.relpath(from, to)
  local a, b = {}, {}
  for part in U.normalize(from):gmatch('[^/]+') do a[#a + 1] = part end
  for part in U.normalize(to):gmatch('[^/]+') do b[#b + 1] = part end
  local i = 1
  while i <= #a and i <= #b and a[i] == b[i] do i = i + 1 end
  local out = {}
  for _ = i, #a do out[#out + 1] = '..' end
  for j = i, #b do out[#out + 1] = b[j] end
  return #out > 0 and table.concat(out, '/') or '.'
end

function U.read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

function U.write_file(path, data)
  local f, err = io.open(path, 'wb')
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function U.base64(data)
  if vim and vim.base64 then return vim.base64.encode(data) end
  return ((data:gsub('.', function(x)
    local r, b = '', x:byte()
    for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
    return r
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
    return b64chars:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-- Minimal JSON encoder (strings, numbers, booleans, arrays, objects) for metadata.
local function json(v, out)
  local t = type(v)
  if t == 'table' then
    if #v > 0 or next(v) == nil and getmetatable(v) == U.array_mt then
      out[#out + 1] = '['
      for i, item in ipairs(v) do
        if i > 1 then out[#out + 1] = ',' end
        json(item, out)
      end
      out[#out + 1] = ']'
    else
      out[#out + 1] = '{'
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = ',' end
        json(k, out)
        out[#out + 1] = ':'
        json(v[k] == nil and v[tonumber(k)] or v[k], out)
      end
      out[#out + 1] = '}'
    end
  elseif t == 'string' then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or string.format('\\u%04x', c:byte())
    end):gsub('</', '<\\/') .. '"'
  elseif t == 'number' or t == 'boolean' then
    out[#out + 1] = tostring(v)
  else
    out[#out + 1] = 'null'
  end
end
U.array_mt = {}
function U.json(v)
  local out = {}
  json(v, out)
  return table.concat(out)
end

return U
