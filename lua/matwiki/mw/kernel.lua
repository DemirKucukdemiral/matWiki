-- Lightweight, zero-dependency persistent kernels for Python and Node in .mw notes.
-- Keeps variables alive across cells, prints the final expression value like Jupyter,
-- and auto-captures matplotlib figures into `<note>.assets/`.
local U = require('matwiki.mw.util')
local K = {}

local sessions = {}

local PY_WORKER = [=[
import ast, builtins, io, json, os, sys, traceback

namespace = {"__name__": "__main__"}

def install_mpl_hook(assets_dir, rel_assets, cell_id, emitted, fig_counter):
    if "matplotlib.pyplot" not in sys.modules:
        return
    plt = sys.modules["matplotlib.pyplot"]
    if not all(hasattr(plt, name) for name in ("figure", "get_fignums", "close")):
        return
    def show(*args, **kwargs):
        figs = [plt.figure(n) for n in plt.get_fignums()]
        if not figs:
            return
        os.makedirs(assets_dir, exist_ok=True)
        for fig in figs:
            fig_counter[0] += 1
            suffix = f"-{fig_counter[0]}" if len(figs) > 1 or fig_counter[0] > 1 else ""
            fname = f"cell-{cell_id}{suffix}.png"
            full = os.path.join(assets_dir, fname)
            fig.savefig(full, dpi=144, bbox_inches="tight")
            emitted.append(f"![figure]({rel_assets}/{fname})")
        plt.close("all")
    plt.show = show

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    req = json.loads(raw)
    code = req.get("code", "")
    cwd = req.get("cwd")
    assets_dir = req.get("assets_dir", "")
    rel_assets = req.get("rel_assets", "")
    cell_id = req.get("cell", 1)
    if cwd and os.path.isdir(cwd):
        os.chdir(cwd)
    buf = io.StringIO()
    emitted = []
    fig_counter = [0]
    ok = True
    old_out, old_err = sys.stdout, sys.stderr
    old_import = builtins.__import__
    def import_with_mpl_hook(*args, **kwargs):
        module = old_import(*args, **kwargs)
        install_mpl_hook(assets_dir, rel_assets, cell_id, emitted, fig_counter)
        return module
    sys.stdout = sys.stderr = buf
    builtins.__import__ = import_with_mpl_hook
    try:
        install_mpl_hook(assets_dir, rel_assets, cell_id, emitted, fig_counter)
        tree = ast.parse(code, filename=f"<cell-{cell_id}>", mode="exec")
        last_expr = None
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            last_expr = ast.Expression(tree.body.pop().value)
        exec(compile(tree, f"<cell-{cell_id}>", "exec"), namespace)
        if last_expr is not None:
            val = eval(compile(last_expr, f"<cell-{cell_id}>", "eval"), namespace)
            if val is not None:
                print(repr(val))
    except Exception:
        ok = False
        traceback.print_exc(limit=6)
    finally:
        sys.stdout, sys.stderr = old_out, old_err
        builtins.__import__ = old_import
    text = buf.getvalue()
    lines = text.splitlines() if text else []
    lines.extend(emitted)
    old_out.write("__MW_RES__" + json.dumps({"ok": ok, "lines": lines}) + "\n")
    old_out.flush()
]=]

local NODE_WORKER = [=[
const readline = require('readline');
const vm = require('vm');
const util = require('util');
const ctx = vm.createContext({ console, require, process, Buffer, setTimeout, clearTimeout });
const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', (raw) => {
  if (!raw.trim()) return;
  const req = JSON.parse(raw);
  const logs = [];
  const capture = (...args) => logs.push(args.map(a => typeof a === 'string' ? a : util.inspect(a, { depth: 3 })).join(' '));
  ctx.console = { log: capture, info: capture, warn: capture, error: capture };
  let ok = true;
  try {
    if (req.cwd) process.chdir(req.cwd);
    const val = vm.runInContext(req.code, ctx, { filename: `cell-${req.cell || 1}.js` });
    if (val !== undefined) logs.push(typeof val === 'string' ? val : util.inspect(val, { depth: 3 }));
  } catch (e) {
    ok = false;
    logs.push(e && e.stack ? e.stack : String(e));
  }
  process.stdout.write('__MW_RES__' + JSON.stringify({ ok, lines: logs.join('\n').split('\n').filter((_, i, a) => !(a.length === 1 && a[0] === '')) }) + '\n');
});
]=]

local function norm_lang(lang)
  lang = (lang or ''):lower()
  if lang == 'python' or lang == 'python3' or lang == 'py' then return 'python' end
  if lang == 'javascript' or lang == 'js' or lang == 'node' then return 'node' end
  return nil
end
K.supports = norm_lang

local function session_key(buf, lang, session_name)
  return tostring(buf) .. ':' .. lang .. ':' .. (session_name or 'default')
end

local function start_session(key, kind, cwd)
  local argv
  if kind == 'python' then
    if vim.fn.executable('python3') ~= 1 then return nil, 'python3 is not installed' end
    argv = { 'python3', '-u', '-c', PY_WORKER }
  elseif kind == 'node' then
    if vim.fn.executable('node') ~= 1 then return nil, 'node is not installed' end
    argv = { 'node', '-e', NODE_WORKER }
  else
    return nil, 'Unsupported kernel: ' .. tostring(kind)
  end

  local sess = { key = key, kind = kind, queue = {}, partial = '' }
  local id = vim.fn.jobstart(argv, {
    cwd = cwd,
    on_stdout = function(_, data)
      if not data then return end
      sess.partial = sess.partial .. table.concat(data, '\n')
      while true do
        local nl = sess.partial:find('\n', 1, true)
        if not nl then break end
        local line = sess.partial:sub(1, nl - 1)
        sess.partial = sess.partial:sub(nl + 1)
        local payload = line:match('^__MW_RES__(.+)$')
        if payload then
          local cb = table.remove(sess.queue, 1)
          if cb then
            local ok, decoded = pcall(vim.json.decode, payload)
            cb(ok and decoded or { ok = false, lines = { 'Kernel decode error' } })
          end
        end
      end
    end,
    on_exit = function()
      -- A restarted process can exit after its replacement has already started.
      if sessions[key] == sess then sessions[key] = nil end
      while #sess.queue > 0 do
        local cb = table.remove(sess.queue, 1)
        cb({ ok = false, lines = { '[Kernel exited]' } })
      end
    end,
  })
  if id <= 0 then return nil, 'Failed to start kernel process' end
  sess.id = id
  sessions[key] = sess
  return sess
end

--- Execute a cell in a persistent kernel session and invoke `callback({ ok, lines })`.
function K.eval(buf, lang, code, opts, callback)
  opts = opts or {}
  local kind = norm_lang(lang)
  if not kind then
    callback({ ok = false, lines = { 'No persistent kernel for ' .. tostring(lang) } })
    return false
  end
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ''
  local cwd = name ~= '' and vim.fs.dirname(name) or vim.fn.getcwd()
  local stem = name ~= '' and U.stem(name) or 'note'
  local rel_assets = stem .. '.assets'
  local assets_dir = cwd .. '/' .. rel_assets

  local key = session_key(buf, kind, opts.session)
  local sess = sessions[key]
  if not sess then
    local err
    sess, err = start_session(key, kind, cwd)
    if not sess then
      callback({ ok = false, lines = { err } })
      return false
    end
  end

  sess.queue[#sess.queue + 1] = callback
  local payload = vim.json.encode({
    code = table.concat(code, '\n'),
    cwd = cwd,
    assets_dir = assets_dir,
    rel_assets = rel_assets,
    cell = opts.cell or 1,
  }) .. '\n'
  local sent, err = pcall(vim.fn.chansend, sess.id, payload)
  if not sent then
    table.remove(sess.queue)
    callback({ ok = false, lines = { 'Could not send code to kernel: ' .. tostring(err) } })
    return false
  end
  return true
end

function K.stop(buf, lang, session_name)
  local kind = norm_lang(lang)
  if not kind then return false end
  local key = session_key(buf, kind, session_name)
  local sess = sessions[key]
  if not sess then return false end
  sessions[key] = nil
  return pcall(vim.fn.jobstop, sess.id)
end

function K.restart(buf)
  local prefix = buf and (tostring(buf) .. ':') or ''
  local count = 0
  for k, sess in pairs(sessions) do
    if prefix == '' or k:sub(1, #prefix) == prefix then
      if sess.id then pcall(vim.fn.jobstop, sess.id) end
      sessions[k] = nil
      count = count + 1
    end
  end
  return count
end

return K
