-- Block-level .mw parser: lines -> AST, plus a numbering pass that resolves
-- labels (@eq:, @thm:, @fig:, @tbl:, @sec:, @cell:) before any HTML is produced.
local U = require('matwiki.mw.util')
local Y = require('matwiki.mw.yaml')
local I = require('matwiki.mw.inline')
local B = {}

local MATH_ENVS = {
  equation = true, align = true, gather = true, multline = true, flalign = true,
  alignat = true, eqnarray = true, CD = true, displaymath = true,
}

--- Theorem-like and callout environments for `::: name` blocks.
--- style: plain (italic body), definition (upright), remark (unnumbered upright),
---        proof (∎ at end), callout (coloured aside), details (collapsible).
B.ENVS = {
  theorem = { 'Theorem', 'plain', true }, lemma = { 'Lemma', 'plain', true },
  proposition = { 'Proposition', 'plain', true }, corollary = { 'Corollary', 'plain', true },
  conjecture = { 'Conjecture', 'plain', true }, claim = { 'Claim', 'plain', true },
  axiom = { 'Axiom', 'plain', true }, hypothesis = { 'Hypothesis', 'plain', true },
  definition = { 'Definition', 'definition', true }, example = { 'Example', 'definition', true },
  exercise = { 'Exercise', 'definition', true }, problem = { 'Problem', 'definition', true },
  question = { 'Question', 'definition', true }, algorithm = { 'Algorithm', 'definition', true },
  remark = { 'Remark', 'remark', false }, observation = { 'Observation', 'remark', false },
  intuition = { 'Intuition', 'remark', false },
  proof = { 'Proof', 'proof', false }, solution = { 'Solution', 'proof', false },
  note = { 'Note', 'callout', false }, tip = { 'Tip', 'callout', false },
  important = { 'Important', 'callout', false }, warning = { 'Warning', 'callout', false },
  caution = { 'Caution', 'callout', false }, info = { 'Info', 'callout', false },
  todo = { 'To do', 'callout', false }, summary = { 'Summary', 'callout', false },
  details = { 'Details', 'details', false }, fold = { 'Details', 'details', false },
}

B.RUNNABLE = {
  python = true, python3 = true, py = true, javascript = true, js = true, node = true,
  lua = true, bash = true, sh = true, zsh = true, julia = true, r = true, ruby = true,
  typescript = true, ts = true,
}

---------------------------------------------------------------------------
-- Line classifiers
---------------------------------------------------------------------------
local function fence_open(line)
  local ind, fence, info = line:match('^( *)(```+)(.*)$')
  if not ind then ind, fence, info = line:match('^( *)(~~~+)(.*)$') end
  if not ind or #ind > 3 then return nil end
  if fence:sub(1, 1) == '`' and info:find('`', 1, true) then return nil end
  return { indent = #ind, char = fence:sub(1, 1), len = #fence, info = U.trim(info) }
end

local function fence_close(line, f)
  local ind, fence = line:match('^( *)([`~]+)%s*$')
  return ind and #ind <= 3 and fence:sub(1, 1) == f.char and #fence >= f.len
    and fence == f.char:rep(#fence)
end

local function atx(line)
  local hashes, rest = line:match('^ ? ? ?(#+)%s+(.-)%s*$')
  if not hashes then hashes = line:match('^ ? ? ?(#+)%s*$'); rest = '' end
  if not hashes or #hashes > 6 then return nil end
  rest = rest:gsub('%s+#+$', ''):gsub('^#+$', '')
  return #hashes, rest
end

local function is_hr(line)
  local s = line:gsub('%s', '')
  if #s < 3 or U.indent(line) > 3 then return false end
  local c = s:sub(1, 1)
  return (c == '-' or c == '*' or c == '_') and s == c:rep(#s)
end

local function list_marker(line)
  local ind, m = line:match('^( *)([-+*])')
  local ordered, num, delim
  if not ind then
    ind, num, delim = line:match('^( *)(%d+)([.)])')
    if not ind or #num > 9 then return nil end
    ordered, m = true, num .. delim
  end
  if #ind > 3 then return nil end
  local rest = line:sub(#ind + #m + 1)
  if rest ~= '' and not rest:find('^ ') then return nil end
  local sp = rest:match('^ *')
  local content = rest:sub(#sp + 1)
  local width
  if content == '' then
    width = #ind + #m + 1
  elseif #sp > 4 then
    width = #ind + #m + 1
    content = rest:sub(2)
  else
    width = #ind + #m + #sp
  end
  return {
    indent = #ind, ordered = ordered, bullet = not ordered and m or nil, delim = delim,
    start = tonumber(num), width = width, content = content, empty = content == '',
  }
end

local function same_list(a, b)
  if a.ordered ~= b.ordered then return false end
  if a.ordered then return a.delim == b.delim end
  return a.bullet == b.bullet
end

local function div_open(line)
  local colons, rest = line:match('^ ? ? ?(:::+)%s*(.-)%s*$')
  if colons and rest ~= '' and not rest:find('^:+$') then return colons, rest end
end

local function div_close(line)
  return line:find('^ ? ? ?:::+%s*$') ~= nil
end

local function math_start(line)
  local s = line:match('^ ? ? ?(.*)$')
  if s:sub(1, 2) == '$$' then return '$$' end
  if s:sub(1, 2) == '\\[' then return '\\[' end
  local env = s:match('^\\begin{(%a+)%*?}')
  if env and MATH_ENVS[env] then return 'env' end
end

local BLOCK_TAGS = {}
for tag in ([[address article aside blockquote center details dialog dd div dl dt fieldset figcaption
  figure footer form h1 h2 h3 h4 h5 h6 header hr iframe li main nav ol p pre section summary table
  tbody td tfoot th thead tr ul video audio canvas svg script style textarea picture]]):gmatch('%S+') do
  BLOCK_TAGS[tag] = true
end

local function html_start(line)
  if line:find('^ ? ? ?<!%-%-') then return 'comment' end
  local tag = line:match('^ ? ? ?</?([%a][%w-]*)[%s/>]') or line:match('^ ? ? ?</?([%a][%w-]*)$')
  if tag and BLOCK_TAGS[tag:lower()] then return tag:lower() end
end

local function quote_line(line) return line:find('^ ? ? ?>') ~= nil end

local function interrupts(line)
  if fence_open(line) or atx(line) or is_hr(line) or quote_line(line) or div_open(line)
    or math_start(line) or html_start(line) or div_close(line) then
    return true
  end
  local m = list_marker(line)
  if m and not m.empty and (not m.ordered or m.start == 1) then return true end
  return false
end

---------------------------------------------------------------------------
-- Maths helpers
---------------------------------------------------------------------------
local ENV_MAP = {
  equation = { '', '' }, displaymath = { '', '' },
  align = { '\\begin{aligned}', '\\end{aligned}' }, flalign = { '\\begin{aligned}', '\\end{aligned}' },
  gather = { '\\begin{gathered}', '\\end{gathered}' }, multline = { '\\begin{gathered}', '\\end{gathered}' },
  alignat = { '\\begin{alignedat}', '\\end{alignedat}' }, eqnarray = { '\\begin{array}{rcl}', '\\end{array}' },
}

--- Normalise display maths for KaTeX: numbered LaTeX environments become their
--- KaTeX-safe inner forms; numbering is handled document-wide by MatWiki.
local function prepare_math(tex)
  local labels = {}
  tex = tex:gsub('\\label%s*{([^}]*)}', function(l) labels[#labels + 1] = l; return '' end)
  tex = tex:gsub('\\nonumber', ''):gsub('\\notag', '')
  local tag
  tex = tex:gsub('\\tag%*?%s*(%b{})', function(t) tag = t:sub(2, -2); return '' end)
  local numbered_env = false
  local env, star = tex:match('^%s*\\begin{(%a+)(%*?)}')
  if env and MATH_ENVS[env] then
    local body = tex:match('^%s*\\begin{' .. env .. '%*?}(.*)\\end{' .. env .. '%*?}%s*$')
    if body then
      numbered_env = star == '' and env ~= 'displaymath' and env ~= 'CD'
      local map = ENV_MAP[env]
      if map then tex = map[1] .. body .. map[2] end
    end
  end
  tex = U.trim(tex)
  if tag then tex = tex .. ' \\tag{' .. tag .. '}' end
  return tex, labels, numbered_env, tag
end

---------------------------------------------------------------------------
-- Parser
---------------------------------------------------------------------------
local parse

local function info_parts(info)
  local lang, rest = info:match('^([%w_+%-%.#]+)%s*(.*)$')
  local attrs
  if lang then
    attrs = U.parse_attrs(rest:match('^%b{}'))
  elseif info:find('^{') then
    attrs = U.parse_attrs(info:match('^%b{}'))
    if attrs.classes[1] then
      lang = table.remove(attrs.classes, 1)
    else
      local first = info:match('^{%s*([%w_+%-]+)')
      if first and attrs.kv[first] == true then
        lang = first
        attrs.kv[first] = nil
      end
    end
  else
    attrs = U.parse_attrs(nil)
  end
  return (lang or ''):lower(), attrs
end

local function para_text(buf)
  for k, l in ipairs(buf) do buf[k] = l:gsub('^%s+', '') end
  buf[#buf] = buf[#buf]:gsub('%s+$', '')
  return table.concat(buf, '\n')
end

local function split_row(line)
  line = U.trim(line)
  if line:sub(1, 1) == '|' then line = line:sub(2) end
  if line:sub(-1) == '|' and line:sub(-2, -2) ~= '\\' then line = line:sub(1, -2) end
  local cells, cur, in_code, in_math = {}, {}, false, false
  local k = 1
  while k <= #line do
    local c = line:sub(k, k)
    if c == '\\' and line:sub(k + 1, k + 1) == '|' then
      cur[#cur + 1] = in_math and '\\|' or '|'
      k = k + 2
    else
      if c == '`' then in_code = not in_code
      elseif c == '$' and not in_code then in_math = not in_math end
      if c == '|' and not in_code and not in_math then
        cells[#cells + 1] = U.trim(table.concat(cur))
        cur = {}
      else
        cur[#cur + 1] = c
      end
      k = k + 1
    end
  end
  cells[#cells + 1] = U.trim(table.concat(cur))
  return cells
end

local function delimiter_row(line)
  if not line:find('-', 1, true) or line:find('[^|:%-%s]') then return nil end
  local cells = split_row(line)
  local align = {}
  for k, c in ipairs(cells) do
    if not c:find('^:?%-+:?$') then return nil end
    local l, r = c:sub(1, 1) == ':', c:sub(-1) == ':'
    align[k] = (l and r) and 'center' or r and 'right' or l and 'left' or false
  end
  return align
end

-- Collect an indented continuation block (list items, footnotes). Returns lines, nums, next index, internal_blank.
local function collect_indented(lines, nums, j, width, first_line, first_num)
  local out, onums = { first_line }, { first_num }
  local pending, internal_blank = 0, false
  local in_fence = fence_open(first_line)
  while j <= #lines do
    local l = lines[j]
    if U.is_blank(l) then
      pending = pending + 1
      j = j + 1
    else
      local ind = U.indent(l)
      if ind >= width then
        for p = pending, 1, -1 do
          out[#out + 1] = ''
          onums[#onums + 1] = nums[j - p]
        end
        if pending > 0 and not in_fence then internal_blank = true end
        pending = 0
        local content = l:sub(width + 1)
        if in_fence then
          if fence_close(content, in_fence) then in_fence = nil end
        else
          in_fence = fence_open(content)
        end
        out[#out + 1] = content
        onums[#onums + 1] = nums[j]
        j = j + 1
      elseif pending == 0 and not in_fence and not interrupts(l) and not list_marker(l)
        and out[#out] ~= '' and not fence_open(out[#out]) then
        out[#out + 1] = l:gsub('^%s+', '')
        onums[#onums + 1] = nums[j]
        j = j + 1
      else
        break
      end
    end
  end
  return out, onums, j - pending, internal_blank, pending
end

parse = function(lines, nums, st)
  local nodes = {}
  local i, n = 1, #lines
  local function add(node)
    nodes[#nodes + 1] = node
    return node
  end
  local function diag(line, msg)
    st.diags[#st.diags + 1] = { line = line, message = msg }
  end

  while i <= n do
    local line = lines[i]
    local ln = nums[i]
    local f, mstart, colons, drest

    if U.is_blank(line) then
      i = i + 1

    elseif (function() f = fence_open(line); return f end)() then
      local j, body = i + 1, {}
      local closed = false
      while j <= n do
        if fence_close(lines[j], f) then closed = true break end
        local l = lines[j]
        local strip = math.min(f.indent, U.indent(l))
        body[#body + 1] = l:sub(strip + 1)
        j = j + 1
      end
      if not closed then diag(ln, 'Code fence is not closed') end
      local lang, attrs = info_parts(f.info)
      local text = table.concat(body, '\n')
      if lang == 'output' or lang == 'result' or lang == 'results' then
        local node = { t = 'output', attrs = attrs, text = text, line = ln, end_line = nums[math.min(j, n)] }
        local prev = nodes[#nodes]
        if prev and prev.t == 'code' and not prev.output then prev.output = node else add(node) end
      elseif lang == 'math' or lang == 'latex-display' then
        local tex, labels, numbered = prepare_math(text)
        add({ t = 'math', tex = tex, id = attrs.id or labels[1], numbered = numbered, line = ln, attrs = attrs })
      else
        add({ t = 'code', lang = lang, attrs = attrs, code = text, line = ln, end_line = nums[math.min(j, n)] })
      end
      i = j + 1

    elseif (function() mstart = math_start(line); return mstart end)() then
      local s = line:match('^ ? ? ?(.*)$')
      local body, trailing, closed, j = {}, '', false, i
      if mstart == 'env' then
        local env = s:match('^\\begin{(%a+%*?)}')
        local close = '\\end{' .. env .. '}'
        while j <= n do
          local l = j == i and s or lines[j]
          local k = l:find(close, 1, true)
          if k then
            body[#body + 1] = l:sub(1, k + #close - 1)
            trailing = l:sub(k + #close)
            closed = true
            break
          end
          body[#body + 1] = l
          j = j + 1
        end
      else
        local close = mstart == '$$' and '$$' or '\\]'
        local first = s:sub(3)
        local k = first:find(close, 1, true)
        if k then
          body[1], trailing, closed = first:sub(1, k - 1), first:sub(k + 2), true
        else
          if not U.is_blank(first) then body[1] = first end
          j = i + 1
          while j <= n do
            local l = lines[j]
            local kk = l:find(close, 1, true)
            if kk then
              if not U.is_blank(l:sub(1, kk - 1)) then body[#body + 1] = l:sub(1, kk - 1) end
              trailing, closed = l:sub(kk + 2), true
              break
            end
            body[#body + 1] = l
            j = j + 1
          end
        end
      end
      if closed then
        local attrs = U.parse_attrs(trailing:match('%b{}'))
        local tex, labels, numbered, tag = prepare_math(table.concat(body, '\n'))
        add({ t = 'math', tex = tex, id = attrs.id or labels[1], numbered = numbered, tag = tag, line = ln, attrs = attrs })
        i = j + 1
      else
        -- Unclosed (often mid-typing): degrade to a paragraph instead of swallowing the note.
        diag(ln, 'Display maths is not closed')
        add({ t = 'para', text = U.trim(line), line = ln })
        i = i + 1
      end

    elseif (function() colons, drest = div_open(line); return colons end)() then
      local depth, j, in_fence = 1, i + 1, nil
      while j <= n do
        local l = lines[j]
        if in_fence then
          if fence_close(l, in_fence) then in_fence = nil end
        else
          local ff = fence_open(l)
          if ff then in_fence = ff
          elseif div_open(l) then depth = depth + 1
          elseif div_close(l) then
            depth = depth - 1
            if depth == 0 then break end
          end
        end
        j = j + 1
      end
      if depth > 0 then diag(ln, 'Fenced div ":::" is not closed') end
      local body_text, attr_s = U.split_trailing_attrs(drest)
      if drest:find('^{') then body_text, attr_s = '', drest end
      local attrs = U.parse_attrs(attr_s)
      local name, title = body_text:match('^([%w_-]+)%s*(.-)$')
      if not name then
        name = table.remove(attrs.classes, 1) or 'div'
        title = ''
      end
      title = title:gsub('^%[(.*)%]$', '%1'):gsub('^"(.*)"$', '%1'):gsub('^%((.*)%)$', '%1')
      if title == '' then title = attrs.kv.title end
      if title then title = U.trim(tostring(title)) end
      attrs.kv.title = nil
      local sub, subn = {}, {}
      for k = i + 1, math.min(j - 1, n) do
        sub[#sub + 1] = lines[k]
        subn[#subn + 1] = nums[k]
      end
      add({ t = 'div', name = name:lower(), title = title, attrs = attrs, children = parse(sub, subn, st), line = ln })
      i = j + 1

    elseif atx(line) then
      local level, rest = atx(line)
      local text, attr_s = U.split_trailing_attrs(rest)
      add({ t = 'heading', level = level, text = text, attrs = U.parse_attrs(attr_s), line = ln })
      i = i + 1

    elseif is_hr(line) then
      add({ t = 'hr', line = ln })
      i = i + 1

    elseif quote_line(line) then
      local sub, subn, j = {}, {}, i
      while j <= n do
        local l = lines[j]
        if quote_line(l) then
          sub[#sub + 1] = l:gsub('^ ? ? ?> ?', '')
          subn[#subn + 1] = nums[j]
        elseif not U.is_blank(l) and #sub > 0 and not U.is_blank(sub[#sub]) and not interrupts(l) then
          sub[#sub + 1] = l
          subn[#subn + 1] = nums[j]
        else
          break
        end
        j = j + 1
      end
      local alert, alert_title = (sub[1] or ''):match('^%s*%[!(%a+)%]%s*(.-)%s*$')
      if alert and B.ENVS[alert:lower()] then
        table.remove(sub, 1)
        table.remove(subn, 1)
        add({ t = 'div', name = alert:lower(), title = alert_title ~= '' and alert_title or nil,
          attrs = U.parse_attrs(nil), children = parse(sub, subn, st), line = ln })
      else
        add({ t = 'quote', children = parse(sub, subn, st), line = ln })
      end
      i = j

    elseif list_marker(line) then
      local first = list_marker(line)
      local list = { t = 'list', ordered = first.ordered, start = first.start or 1, items = {}, tight = true, line = ln }
      local j = i
      while j <= n do
        local m = list_marker(lines[j])
        if not m or not same_list(m, first) or is_hr(lines[j]) then break end
        local task
        local content = m.content
        local box, after = content:match('^%[([ xX])%]%s+(.*)$')
        if not box then box = content:match('^%[([ xX])%]$'); after = '' end
        if box then task, content = box ~= ' ', after end
        local sub, subn, nxt, internal_blank, pending = collect_indented(lines, nums, j + 1, m.width, content, nums[j])
        if internal_blank then list.tight = false end
        list.items[#list.items + 1] = { children = parse(sub, subn, st), task = task, line = nums[j] }
        local following = nxt + (pending or 0)
        local nm = following <= n and list_marker(lines[following])
        if nm and same_list(nm, first) and not is_hr(lines[following]) then
          if (pending or 0) > 0 then list.tight = false end
          j = following
        else
          j = nxt
          break
        end
      end
      add(list)
      i = j

    elseif line:find('^ ? ? ?%[%^[^%]]+%]:') then
      local id, first = line:match('^ ? ? ?%[%^([^%]]+)%]:%s?(.*)$')
      local sub, subn, nxt = collect_indented(lines, nums, i + 1, 4, first, ln)
      st.footnotes[id] = parse(sub, subn, st)
      i = nxt

    elseif line:find('^ ? ? ?%[[^%]]+%]:') and not line:find('^ ? ? ?%[%^') then
      local label, rest = line:match('^ ? ? ?%[([^%]]+)%]:%s*(.*)$')
      local url, title = rest:match('^<([^>]*)>%s*(.*)$')
      if not url then url, title = rest:match('^(%S+)%s*(.*)$') end
      if url then
        title = title and (title:match('^"(.*)"$') or title:match("^'(.*)'$") or title:match('^%((.*)%)$'))
        st.refs[I.normlabel(label)] = { url = url, title = title }
        i = i + 1
      else
        add({ t = 'para', text = U.trim(line), line = ln })
        i = i + 1
      end

    elseif html_start(line) then
      local kind = html_start(line)
      local j, body = i, {}
      local closer = kind == 'comment' and '-->' or (kind == 'script' or kind == 'style' or kind == 'pre' or kind == 'textarea') and ('</' .. kind .. '>')
      while j <= n do
        local l = lines[j]
        if not closer and U.is_blank(l) then break end
        body[#body + 1] = l
        j = j + 1
        if closer and l:lower():find(closer, 1, true) then break end
      end
      add({ t = 'html', text = table.concat(body, '\n'), line = ln })
      i = j

    elseif U.indent(line) >= 4 then
      local j, body = i, {}
      while j <= n and (U.is_blank(lines[j]) or U.indent(lines[j]) >= 4) do
        body[#body + 1] = lines[j]:sub(5)
        j = j + 1
      end
      while #body > 0 and U.is_blank(body[#body]) do body[#body] = nil; j = j - 1 end
      add({ t = 'code', lang = '', attrs = U.parse_attrs(nil), code = table.concat(body, '\n'), line = ln, indented = true })
      i = j

    else
      -- Table?
      local align = line:find('|', 1, true) and lines[i + 1] and delimiter_row(lines[i + 1])
      local head = align and split_row(line)
      if head and #head == #align then
        local rows, j = {}, i + 2
        while j <= n and not U.is_blank(lines[j]) and lines[j]:find('|', 1, true) and not interrupts(lines[j]) do
          local cells = split_row(lines[j])
          for k = #cells + 1, #align do cells[k] = '' end
          rows[#rows + 1] = cells
          j = j + 1
        end
        local caption, cap_attrs
        local cap_line = lines[j] and U.is_blank(lines[j]) and lines[j + 1] or lines[j]
        local cap = cap_line and (cap_line:match('^:%s+(.*)$') or cap_line:match('^Table:%s*(.*)$'))
        if cap then
          local text, attr_s = U.split_trailing_attrs(cap)
          caption, cap_attrs = text, U.parse_attrs(attr_s)
          j = (cap_line == lines[j]) and j + 1 or j + 2
        end
        add({ t = 'table', align = align, head = head, rows = rows, caption = caption,
          attrs = cap_attrs or U.parse_attrs(nil), line = ln })
        i = j
      else
        local buf, j = { line }, i + 1
        local heading_level
        while j <= n do
          local l = lines[j]
          if U.is_blank(l) then break end
          if l:find('^ ? ? ?=+%s*$') then heading_level = 1; j = j + 1; break end
          if l:find('^ ? ? ?%-+%s*$') then heading_level = 2; j = j + 1; break end
          if interrupts(l) then break end
          buf[#buf + 1] = l
          j = j + 1
        end
        local text = para_text(buf)
        if heading_level then
          local htext, attr_s = U.split_trailing_attrs(text:gsub('\n', ' '))
          add({ t = 'heading', level = heading_level, text = htext, attrs = U.parse_attrs(attr_s), line = ln })
        else
          local alt, rest = text:match('^!(%b[])(.*)$')
          local fig = alt and (rest:match('^%b()%s*%b{}$') or rest:match('^%b()$'))
          if fig and alt ~= '[]' then
            local src_part, attr_s = rest:match('^(%b())%s*(%b{})$')
            src_part = src_part or rest
            local attrs = U.parse_attrs(attr_s)
            add({ t = 'figure', alt = alt:sub(2, -2), src = src_part, attr_text = attr_s, attrs = attrs, line = ln, text = text })
          else
            add({ t = 'para', text = text, line = ln })
          end
        end
        i = j
      end
    end
  end
  return nodes
end

---------------------------------------------------------------------------
-- Numbering / labels
---------------------------------------------------------------------------
local function is_unnumbered(node)
  if not node.attrs then return false end
  if node.attrs.kv and (node.attrs.kv.numbered == 'false' or node.attrs.kv.unnumbered == true) then
    return true
  end
  for _, c in ipairs(node.attrs.classes or {}) do
    if c == 'unnumbered' or c == '-' then return true end
  end
  return false
end

local function number(doc, opts)
  local labels, counters, seen = doc.labels, { thm = 0, eq = 0, fig = 0, tbl = 0, cell = 0 }, {}
  doc.toc = {}
  local envs = opts.envs or B.ENVS
  local runnable = opts.runnable or B.RUNNABLE
  local number_sections = doc.meta['number-sections'] or doc.meta.number_sections or opts.number_sections
  local sec = { 0, 0, 0, 0, 0, 0 }
  local min_level = 6
  local function scan_min(nodes)
    for _, node in ipairs(nodes) do
      if node.t == 'heading' then min_level = math.min(min_level, node.level) end
    end
  end
  scan_min(doc.blocks)
  local function unique(id)
    local base, k = id, 1
    while seen[id] do
      id = base .. '-' .. k
      k = k + 1
    end
    seen[id] = true
    return id
  end
  local function label(id, ref, line)
    if not id then return end
    if labels[id] then doc.diags[#doc.diags + 1] = { line = line, message = 'Duplicate label ' .. id } end
    labels[id] = { ref = ref }
  end
  local walk
  walk = function(nodes, top_level)
    for _, node in ipairs(nodes) do
      local t = node.t
      if t == 'heading' then
        local id = node.attrs.id or U.slug(I.plain(node.text))
        node.id = unique(id)
        if number_sections and not is_unnumbered(node) then
          local lvl = node.level - min_level + 1
          if lvl >= 1 then
            sec[lvl] = sec[lvl] + 1
            for k = lvl + 1, 6 do sec[k] = 0 end
            local parts = {}
            for k = 1, lvl do parts[k] = sec[k] end
            node.number = table.concat(parts, '.')
          end
        end
        if top_level then
          doc.toc[#doc.toc + 1] = { id = node.id, level = node.level, text = node.text, number = node.number }
        end
        label(node.id, node.number and ('§' .. node.number) or U.esc(I.plain(node.text)), node.line)
      elseif t == 'math' then
        if node.id or node.numbered then
          if node.tag then
            node.number = node.tag
          else
            counters.eq = counters.eq + 1
            node.number = tostring(counters.eq)
          end
          node.id = node.id or ('eq-' .. counters.eq)
          seen[node.id] = true
          label(node.id, '(' .. U.esc(node.number) .. ')', node.line)
        end
      elseif t == 'div' then
        local env = envs[node.name]
        if env and env[3] and not is_unnumbered(node) then
          counters.thm = counters.thm + 1
          node.number = counters.thm
          if node.attrs.id then label(node.attrs.id, U.esc(env[1]) .. ' ' .. node.number, node.line) end
        elseif node.attrs.id and env then
          label(node.attrs.id, U.esc(env[1]), node.line)
        end
        walk(node.children, false)
      elseif t == 'figure' then
        if node.attrs.id or node.alt ~= '' then
          counters.fig = counters.fig + 1
          node.number = counters.fig
          if node.attrs.id then label(node.attrs.id, 'Figure ' .. node.number, node.line) end
        end
      elseif t == 'table' then
        if node.caption then
          counters.tbl = counters.tbl + 1
          node.number = counters.tbl
          if node.attrs.id then label(node.attrs.id, 'Table ' .. node.number, node.line) end
        end
      elseif t == 'code' then
        local kv = node.attrs.kv
        local run = kv.run
        local is_cell = (runnable[node.lang] and run ~= 'never' and run ~= 'false')
          or (node.output ~= nil and node.lang ~= '')
        if is_cell and not node.indented then
          counters.cell = counters.cell + 1
          node.cell = counters.cell
          if node.attrs.id then label(node.attrs.id, 'Cell ' .. node.cell, node.line) end
        end
      elseif t == 'quote' then
        walk(node.children, false)
      elseif t == 'list' then
        for _, item in ipairs(node.items) do walk(item.children, false) end
      end
    end
  end
  walk(doc.blocks, true)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Parse a list of lines (or a string) into a document:
--- { meta, blocks, refs, footnotes, labels, diags }
function B.parse(input, opts)
  opts = opts or {}
  local lines = type(input) == 'string' and U.split_lines(input) or input
  local start = 1
  local doc = { meta = {}, refs = {}, footnotes = {}, labels = {}, diags = {} }
  if lines[1] and lines[1]:find('^%-%-%-%s*$') then
    for k = 2, math.min(#lines, 500) do
      if lines[k]:find('^%-%-%-%s*$') or lines[k]:find('^%.%.%.%s*$') then
        local fm = {}
        for m = 2, k - 1 do fm[#fm + 1] = lines[m] end
        local meta, err = Y.parse(fm)
        doc.meta = meta
        if err then doc.diags[#doc.diags + 1] = { line = 1, message = 'Front matter: ' .. err } end
        start = k + 1
        break
      end
    end
  end
  local body, nums = {}, {}
  for k = start, #lines do
    body[#body + 1] = U.detab(lines[k])
    nums[#nums + 1] = k
  end
  doc.front_matter_end = start - 1
  doc.blocks = parse(body, nums, doc)
  number(doc, opts)
  return doc
end

--- Parse a fragment (e.g. a Markdown cell output) sharing a document's refs/footnotes.
function B.parse_fragment(text, doc, line)
  local lines = U.split_lines(text)
  local nums = {}
  for k = 1, #lines do
    lines[k] = U.detab(lines[k])
    nums[k] = line or k
  end
  local st = { refs = doc.refs, footnotes = doc.footnotes, diags = {} }
  return parse(lines, nums, st)
end

B._list_marker = list_marker
B._fence_open = fence_open
B._fence_close = fence_close
return B
