-- Inline .mw syntax -> HTML.
-- One left-to-right scan that jumps between special characters, a CommonMark-style
-- delimiter stack for emphasis, and a bracket stack for links/images.
local U = require('matwiki.mw.util')
local esc = U.esc
local I = {}

local SPECIAL = '[\\`%$%[%]!%*_~=<@&\n:%^]'
local REF_ID = '(%a[%w_-]*:[%w_%-%.:]*[%w_-])'

local function is_space(c) return c == '' or c == ' ' or c == '\n' or c == '\t' end
local function is_punct(c) return c ~= '' and c:find('^%p') ~= nil end

local function normlabel(s)
  return U.trim(s):lower():gsub('%s+', ' ')
end
I.normlabel = normlabel

local function math_html(tex, display)
  return '<span class="mw-math' .. (display and ' mw-display' or '') .. '">' .. esc(tex) .. '</span>'
end

local function attrs_html(attrs, extra_class)
  if not attrs then return extra_class and (' class="' .. extra_class .. '"') or '' end
  local parts = {}
  if attrs.id then parts[#parts + 1] = ' id="' .. esc(attrs.id) .. '"' end
  local classes = {}
  if extra_class then classes[1] = extra_class end
  for _, c in ipairs(attrs.classes) do classes[#classes + 1] = c end
  if #classes > 0 then parts[#parts + 1] = ' class="' .. esc(table.concat(classes, ' ')) .. '"' end
  local style = {}
  for k, v in pairs(attrs.kv) do
    if k == 'width' or k == 'height' then
      local val = tostring(v)
      if val:match('^%d+$') then val = val .. 'px' end
      style[#style + 1] = k .. ':' .. val
    elseif k == 'style' then
      style[#style + 1] = tostring(v)
    elseif v ~= true then
      parts[#parts + 1] = ' data-' .. esc(k) .. '="' .. esc(v) .. '"'
    end
  end
  if #style > 0 then parts[#parts + 1] = ' style="' .. esc(table.concat(style, ';')) .. '"' end
  return table.concat(parts)
end
I.attrs_html = attrs_html

local function safe_url(url)
  url = U.trim(url)
  if url:lower():match('^%s*javascript:') or url:lower():match('^%s*vbscript:') then return '#' end
  return (url:gsub(' ', '%%20'))
end

-- Emphasis resolution (CommonMark §6.2 "process emphasis", including the rule of 3).
local function process_emphasis(stack, bottom)
  local ci = bottom + 1
  local openers_bottom = {}
  while ci <= #stack do
    local closer = stack[ci]
    if closer.can_close and closer.count > 0 then
      local key = closer.char .. (closer.can_open and '1' or '0') .. (closer.orig % 3)
      local limit = math.max(bottom, openers_bottom[key] or bottom)
      local found
      for oi = ci - 1, limit + 1, -1 do
        local op = stack[oi]
        if op.char == closer.char and op.can_open and op.count > 0 then
          if op.char == '~' or op.char == '=' then
            if op.count >= 2 and closer.count >= 2 then found = oi break end
          else
            local odd = (op.can_close or closer.can_open) and (op.orig + closer.orig) % 3 == 0
              and not (op.orig % 3 == 0 and closer.orig % 3 == 0)
            if not odd then found = oi break end
          end
        end
      end
      if found then
        local op = stack[found]
        local use = (op.count >= 2 and closer.count >= 2) and 2 or 1
        local tag = closer.char == '~' and 'del' or closer.char == '=' and 'mark' or (use == 2 and 'strong' or 'em')
        op.count, closer.count = op.count - use, closer.count - use
        table.insert(op.open_tags, 1, '<' .. tag .. '>')
        closer.close_tags[#closer.close_tags + 1] = '</' .. tag .. '>'
        for _ = found + 1, ci - 1 do table.remove(stack, found + 1) end
        ci = found + 1
        if op.count == 0 then
          table.remove(stack, found)
          ci = ci - 1
        end
        if closer.count == 0 then table.remove(stack, ci) end
      else
        openers_bottom[key] = ci - 1
        if not closer.can_open then table.remove(stack, ci) else ci = ci + 1 end
      end
    else
      ci = ci + 1
    end
  end
  for k = #stack, bottom + 1, -1 do stack[k] = nil end
end

local function render_out(out, a, b)
  local parts = {}
  for k = a, b do
    local e = out[k]
    if type(e) == 'string' then
      parts[#parts + 1] = e
    elseif e.kind == 'delim' then
      parts[#parts + 1] = table.concat(e.close_tags) .. string.rep(e.char, e.count) .. table.concat(e.open_tags)
    else
      parts[#parts + 1] = e.text
    end
  end
  return table.concat(parts)
end

-- `(dest "title"){attrs}` after a closing bracket. Returns dest, title, next index, attrs.
local function link_tail(s, p)
  if s:sub(p, p) ~= '(' then return nil end
  local q = s:find('[^%s]', p + 1) or (#s + 1)
  local dest
  if s:sub(q, q) == '<' then
    dest = s:match('^<([^>\n]*)>', q)
    if not dest then return nil end
    q = q + #dest + 2
  else
    local depth, k, buf = 0, q, {}
    while k <= #s do
      local c = s:sub(k, k)
      if c == '\\' and s:sub(k + 1, k + 1):match('%p') then
        buf[#buf + 1] = s:sub(k + 1, k + 1)
        k = k + 2
      elseif is_space(c) then break
      elseif c == '(' then depth = depth + 1; buf[#buf + 1] = c; k = k + 1
      elseif c == ')' then
        if depth == 0 then break end
        depth = depth - 1; buf[#buf + 1] = c; k = k + 1
      else buf[#buf + 1] = c; k = k + 1 end
    end
    dest = table.concat(buf)
    q = k
  end
  q = s:find('[^%s]', q) or (#s + 1)
  local title
  local open = s:sub(q, q)
  if open == '"' or open == "'" or open == '(' then
    local close = open == '(' and ')' or open
    local k = q + 1
    local buf = {}
    while k <= #s and s:sub(k, k) ~= close do
      if s:sub(k, k) == '\\' and k < #s then k = k + 1 end
      buf[#buf + 1] = s:sub(k, k)
      k = k + 1
    end
    if k > #s then return nil end
    title = table.concat(buf)
    q = s:find('[^%s]', k + 1) or (#s + 1)
  end
  if s:sub(q, q) ~= ')' then return nil end
  q = q + 1
  local attrs
  local braces = s:match('^%b{}', q)
  if braces then
    attrs = U.parse_attrs(braces)
    q = q + #braces
  end
  return dest, title, q, attrs
end

function I.render(s, ctx)
  ctx = ctx or {}
  local out, stack, brackets, buf = {}, {}, {}, {}
  local function flush()
    if #buf > 0 then
      out[#out + 1] = table.concat(buf)
      buf = {}
    end
  end
  local function emit(html)
    flush()
    out[#out + 1] = html
  end
  local function diag(msg)
    if ctx.diag then ctx.diag(msg) end
  end

  local function ref(id)
    local label = ctx.labels and ctx.labels[id]
    if label then
      return '<a class="mw-ref" href="#' .. esc(id) .. '">' .. label.ref .. '</a>'
    end
    diag('Unknown reference @' .. id)
    return '<a class="mw-ref mw-missing" href="#' .. esc(id) .. '">??' .. esc(id) .. '</a>'
  end

  local function wiki(inner, embed)
    local target, label = inner:match('^([^|]*)|(.*)$')
    target = U.trim(target or inner)
    if embed then
      local src = ctx.asset and ctx.asset(target) or target
      return '<img class="mw-embed" src="' .. esc(safe_url(src)) .. '" alt="' .. esc(label or target) .. '" loading="lazy">'
    end
    if not label then
      local page, anchor = target:match('^(.-)#(.*)$')
      page = page or target
      label = page ~= '' and page:gsub('%.mw$', ''):gsub('%.md$', ''):gsub('%.tex$', '') or anchor
      if page ~= '' and anchor and anchor ~= '' then label = label .. ' › ' .. anchor end
      label = esc(label)
    else
      label = I.render(label, ctx)
    end
    local href = ctx.wiki and ctx.wiki(target)
    if href then
      return '<a class="mw-wikilink" href="' .. esc(href) .. '">' .. label .. '</a>'
    end
    diag('Wiki link target not found: [[' .. target .. ']]')
    return '<a class="mw-wikilink mw-missing" title="Note not found">' .. label .. '</a>'
  end

  local function footnote(id)
    local fn = ctx.fn
    if not fn or not fn.defs[id] then
      diag('Undefined footnote [^' .. id .. ']')
      return esc('[^' .. id .. ']')
    end
    if not fn.index[id] then
      fn.order[#fn.order + 1] = id
      fn.index[id] = #fn.order
    end
    local n = fn.index[id]
    return '<sup class="mw-fnref"><a href="#fn-' .. esc(id) .. '" id="fnref-' .. esc(id) .. '">' .. n .. '</a></sup>'
  end

  local i, n = 1, #s
  while i <= n do
    local j = s:find(SPECIAL, i)
    if not j then
      buf[#buf + 1] = esc(s:sub(i))
      break
    end
    if j > i then buf[#buf + 1] = esc(s:sub(i, j - 1)) end
    i = j
    local c = s:sub(i, i)

    if c == '\\' then
      local nx = s:sub(i + 1, i + 1)
      local refcmd, refid = s:match('^\\(%a*ref){([^}]+)}', i)
      if nx == '(' or nx == '[' then
        local close = nx == '(' and '\\)' or '\\]'
        local k = s:find(close, i + 2, true)
        if k then
          emit(math_html(s:sub(i + 2, k - 1), nx == '['))
          i = k + 2
        else
          buf[#buf + 1] = nx
          i = i + 2
        end
      elseif refcmd and (refcmd == 'ref' or refcmd == 'eqref' or refcmd == 'cref' or refcmd == 'autoref') then
        emit(ref(refid))
        i = i + #refcmd + #refid + 3
      elseif nx == '\n' then
        emit('<br>\n')
        i = i + 2
      elseif nx ~= '' and is_punct(nx) then
        buf[#buf + 1] = esc(nx)
        i = i + 2
      else
        buf[#buf + 1] = '\\'
        i = i + 1
      end

    elseif c == '`' then
      local run = s:match('^`+', i)
      local len, k, a, b = #run, i + #run, nil, nil
      while true do
        a, b = s:find('`+', k)
        if not a or b - a + 1 == len then break end
        k = b + 1
      end
      if a then
        local code = s:sub(i + len, a - 1):gsub('\n', ' ')
        if code:match('^ .* $') and not code:match('^ +$') then code = code:sub(2, -2) end
        emit('<code>' .. esc(code) .. '</code>')
        i = b + 1
      else
        buf[#buf + 1] = run
        i = i + len
      end

    elseif c == '$' then
      if s:sub(i + 1, i + 1) == '$' then
        local k = s:find('$$', i + 2, true)
        if k and k > i + 2 then
          emit(math_html(s:sub(i + 2, k - 1), true))
          i = k + 2
        else
          buf[#buf + 1] = '$$'
          i = i + 2
        end
      else
        local nx = s:sub(i + 1, i + 1)
        local found
        if nx ~= '' and not is_space(nx) then
          local k = i + 1
          while true do
            local a = s:find('$', k, true)
            if not a then break end
            local before, after = s:sub(a - 1, a - 1), s:sub(a + 1, a + 1)
            if before == '\\' or is_space(before) or after:match('%d') then
              k = a + 1
            else
              found = a
              break
            end
          end
        end
        if found then
          emit(math_html(s:sub(i + 1, found - 1), false))
          i = found + 1
        else
          buf[#buf + 1] = '$'
          i = i + 1
        end
      end

    elseif c == '[' then
      local bracket_ref = s:match('^%[@' .. REF_ID .. '%]', i)
      if s:sub(i + 1, i + 1) == '[' then
        local k = s:find(']]', i + 2, true)
        if k then
          emit(wiki(s:sub(i + 2, k - 1), false))
          i = k + 2
        else
          buf[#buf + 1] = '[['
          i = i + 2
        end
      elseif bracket_ref then
        emit(ref(bracket_ref))
        i = i + #bracket_ref + 3
      elseif s:sub(i + 1, i + 1) == '^' and s:match('^%[%^([^%]%s]+)%]', i) then
        local id = s:match('^%[%^([^%]%s]+)%]', i)
        emit(footnote(id))
        i = i + #id + 3
      else
        flush()
        local br = { kind = 'bracket', text = '[', image = false, active = true, spos = i + 1, dbottom = #stack }
        out[#out + 1] = br
        br.pos = #out
        brackets[#brackets + 1] = br
        i = i + 1
      end

    elseif c == '!' then
      if s:sub(i + 1, i + 2) == '[[' then
        local k = s:find(']]', i + 3, true)
        if k then
          emit(wiki(s:sub(i + 3, k - 1), true))
          i = k + 2
        else
          buf[#buf + 1] = '!'
          i = i + 1
        end
      elseif s:sub(i + 1, i + 1) == '[' then
        flush()
        local br = { kind = 'bracket', text = '![', image = true, active = true, spos = i + 2, dbottom = #stack }
        out[#out + 1] = br
        br.pos = #out
        brackets[#brackets + 1] = br
        i = i + 2
      else
        buf[#buf + 1] = '!'
        i = i + 1
      end

    elseif c == '^' then
      if s:sub(i + 1, i + 1) == '[' then
        local depth, k = 0, i + 1
        while k <= n do
          local ch = s:sub(k, k)
          if ch == '[' then depth = depth + 1
          elseif ch == ']' then
            depth = depth - 1
            if depth == 0 then break end
          end
          k = k + 1
        end
        if k <= n and ctx.fn then
          ctx.fn.inline_count = (ctx.fn.inline_count or 0) + 1
          local id = 'n' .. ctx.fn.inline_count
          ctx.fn.defs[id] = { inline = I.render(s:sub(i + 2, k - 1), ctx) }
          emit(footnote(id))
          i = k + 1
        else
          buf[#buf + 1] = '^'
          i = i + 1
        end
      else
        buf[#buf + 1] = '^'
        i = i + 1
      end

    elseif c == ']' then
      local op = table.remove(brackets)
      if not op or not op.active then
        buf[#buf + 1] = ']'
        i = i + 1
      else
        local dest, title, after, attrs = link_tail(s, i + 1)
        local raw = s:sub(op.spos, i - 1)
        if not dest then
          local nxt = s:match('^%[([^%]]*)%]', i + 1)
          local label
          if nxt and nxt ~= '' then
            label, after = nxt, i + #nxt + 3
          elseif nxt == '' then
            label, after = raw, i + 3
          else
            label, after = raw, i + 1
          end
          local r = ctx.refs and ctx.refs[normlabel(label)]
          if r then dest, title = r.url, r.title end
        end
        local span_attrs = not dest and not op.image and s:match('^%b{}', i + 1)
        if dest or span_attrs then
          flush()
          process_emphasis(stack, op.dbottom)
          local content = render_out(out, op.pos + 1, #out)
          for k = #out, op.pos, -1 do out[k] = nil end
          if span_attrs then
            emit('<span' .. attrs_html(U.parse_attrs(span_attrs)) .. '>' .. content .. '</span>')
            i = i + 1 + #span_attrs
          elseif op.image then
            local src = ctx.asset and ctx.asset(dest) or dest
            local alt = content:gsub('<[^>]->', '')
            emit('<img src="' .. esc(safe_url(src)) .. '" alt="' .. alt .. '"'
              .. (title and (' title="' .. esc(title) .. '"') or '') .. attrs_html(attrs) .. ' loading="lazy">')
            i = after
          else
            emit('<a href="' .. esc(safe_url(dest)) .. '"' .. (title and (' title="' .. esc(title) .. '"') or '')
              .. attrs_html(attrs) .. '>' .. content .. '</a>')
            for _, b in ipairs(brackets) do
              if not b.image then b.active = false end
            end
            i = after
          end
        else
          buf[#buf + 1] = ']'
          i = i + 1
        end
      end

    elseif c == '*' or c == '_' or c == '~' or c == '=' then
      local run = s:match('^%' .. c .. '+', i)
      local before = i > 1 and s:sub(i - 1, i - 1) or ''
      local after = s:sub(i + #run, i + #run)
      if (c == '~' or c == '=') and #run ~= 2 then
        buf[#buf + 1] = run
      else
        local left = not is_space(after) and (not is_punct(after) or is_space(before) or is_punct(before))
        local right = not is_space(before) and (not is_punct(before) or is_space(after) or is_punct(after))
        local can_open, can_close = left, right
        if c == '_' then
          can_open = left and (not right or is_punct(before))
          can_close = right and (not left or is_punct(after))
        end
        flush()
        local d = { kind = 'delim', char = c, count = #run, orig = #run, can_open = can_open,
          can_close = can_close, open_tags = {}, close_tags = {} }
        out[#out + 1] = d
        if can_open or can_close then stack[#stack + 1] = d end
      end
      i = i + #run

    elseif c == '<' then
      local auto = s:match('^<(%a[%w+.-]*:[^%s<>]*)>', i)
      local email = not auto and s:match('^<([%w._%%+-]+@[%w.-]+%.%a+)>', i)
      local tag = s:match('^</?%a[%w-]*[^<>]*>', i)
      if auto then
        emit('<a href="' .. esc(safe_url(auto)) .. '">' .. esc(auto) .. '</a>')
        i = i + #auto + 2
      elseif email then
        emit('<a href="mailto:' .. esc(email) .. '">' .. esc(email) .. '</a>')
        i = i + #email + 2
      elseif s:sub(i, i + 3) == '<!--' and s:find('-->', i + 4, true) then
        local k = s:find('-->', i + 4, true)
        emit(s:sub(i, k + 2))
        i = k + 3
      elseif tag and not ctx.safe then
        emit(tag)
        i = i + #tag
      else
        buf[#buf + 1] = '&lt;'
        i = i + 1
      end

    elseif c == '@' then
      local prev = i > 1 and s:sub(i - 1, i - 1) or ' '
      local id = not prev:match('[%w]') and s:match('^@' .. REF_ID, i)
      if id then
        emit(ref(id))
        i = i + #id + 1
      else
        buf[#buf + 1] = '@'
        i = i + 1
      end

    elseif c == '&' then
      local entity = s:match('^&#?%w+;', i)
      if entity then
        buf[#buf + 1] = entity
        i = i + #entity
      else
        buf[#buf + 1] = '&amp;'
        i = i + 1
      end

    elseif c == '\n' then
      local last = buf[#buf]
      if last and last:match('  +$') then
        buf[#buf] = last:gsub(' +$', '')
        emit('<br>\n')
      else
        buf[#buf + 1] = '\n'
      end
      i = i + 1

    elseif c == ':' then
      local scheme = (s:sub(i - 5, i - 1) == 'https' and 'https') or (s:sub(i - 4, i - 1) == 'http' and 'http')
      local last = buf[#buf]
      local start = scheme and i - #scheme
      if scheme and s:sub(i + 1, i + 2) == '//' and last and last:sub(-#scheme) == scheme
        and (start == 1 or s:sub(start - 1, start - 1):match('[%s(]')) then
        local url = s:match('^[^%s<>]*', i + 3)
        url = scheme .. '://' .. url
        url = url:gsub('[%.,:;!?"\'*_~]+$', '')
        local _, opens = url:gsub('%(', '')
        local _, closes = url:gsub('%)', '')
        while url:sub(-1) == ')' and closes > opens do
          url = url:sub(1, -2)
          closes = closes - 1
        end
        buf[#buf] = last:sub(1, -#scheme - 1)
        emit('<a href="' .. esc(url) .. '">' .. esc(url) .. '</a>')
        i = start + #url
      else
        buf[#buf + 1] = ':'
        i = i + 1
      end
    else
      buf[#buf + 1] = esc(c)
      i = i + 1
    end
  end
  flush()
  process_emphasis(stack, 0)
  return render_out(out, 1, #out)
end

--- Plain-text approximation of inline markup (titles, slugs, alt text).
function I.plain(s)
  s = s:gsub('%[%[([^%]|]*)|([^%]]*)%]%]', '%2'):gsub('%[%[([^%]]*)%]%]', '%1')
  s = s:gsub('!?%[([^%]]*)%]%b()', '%1'):gsub('`([^`]*)`', '%1')
  s = s:gsub('[*_~=]+', ''):gsub('%s*%b{}%s*$', '')
  return U.trim(s)
end

return I
