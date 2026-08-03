-- Verilog/SystemVerilog project indexing for verible-verilog-ls.
--
-- Generates <root>/verible.filelist from <root>/build/flists, then restarts
-- the server.
--
-- Keymaps:
--   <leader>vi  index every flist under build/flists  (:VeribleIndex)
--   <leader>vf  pick one flist to index               (:VeribleIndexPick)
--   <leader>vr  restart the verible LSP               (:VeribleRestart)
--   <leader>vc  regenerate ctags "tags" file           (:VeribleCtags)

local M = {}

-- ============================================================
-- Config
-- ============================================================

--- Shared verible lint/style rule set.
M.rules = {
  '+line-length=length:200',
  '-no-tabs',
  'one-module-per-file',
  'parameter-name-style=localparam_style:ALL_CAPS',
  '-no-trailing-spaces',
}

--- Rule set as a `--rules=` value.
function M.rules_string() return table.concat(M.rules, ',') end

--- CLI flags for `--rules_config_search` + fallback `--rules=`.
---@return string[] flags
function M.lint_args() return { '--rules_config_search', '--rules=' .. M.rules_string() } end

--- Column limit for verible-verilog-format.
M.column_limit = 200

--- Emit absolute paths into verible.filelist.
M.use_absolute_paths = false

local BUILD_SUBDIR = 'build'
local FLIST_SUBDIR = BUILD_SUBDIR .. '/flists'
local FLIST_EXT = { ['f'] = true, ['fl'] = true, ['flist'] = true }
local OUTPUT = 'verible.filelist'

-- Max depth for the build-tree scan (build/ may be a symlink; follows links).
local BUILD_SCAN_DEPTH = 12

-- ============================================================
-- Project root discovery
-- ============================================================

--- Project root: nearest ancestor with build/flists, else git root, else cwd.
---@param start string|nil directory or file path to search upward from
---@return string|nil root
function M.project_root(start)
  start = start or vim.api.nvim_buf_get_name(0)
  if start == '' then start = vim.uv.cwd() end
  local root = vim.fs.root(start, function(name, path) return name == 'build' and vim.uv.fs_stat(vim.fs.joinpath(path, FLIST_SUBDIR)) ~= nil end)
  return root or vim.fs.root(start, '.git') or vim.uv.cwd()
end

--- `<root>/verible.filelist`, warning and returning nil if missing.
---@param root string
---@return string|nil filelist
local function require_filelist(root)
  local filelist = vim.fs.joinpath(root, OUTPUT)
  if not vim.uv.fs_stat(filelist) then
    vim.notify('verible: no ' .. OUTPUT .. ' yet -- run :VeribleIndex first', vim.log.levels.WARN)
    return nil
  end
  return filelist
end

-- ============================================================
-- Flist parsing engine: build/flists/*.f -> <root>/verible.filelist
-- ============================================================

--- All flist files under <root>/build/flists (recursive).
---@param root string
---@return string[] absolute paths, sorted
local function discover_flists(root)
  local dir = vim.fs.joinpath(root, FLIST_SUBDIR)
  if not vim.uv.fs_stat(dir) then return {} end
  local found = {}
  for name, type in vim.fs.dir(dir, { depth = 8, follow = true }) do
    local ext = name:match '%.([%w]+)$'
    if ext and FLIST_EXT[ext:lower()] and type ~= 'directory' then table.insert(found, vim.fs.joinpath(dir, name)) end
  end
  table.sort(found)
  return found
end

--- basename -> absolute paths, for every file under <root>/build.
---@type table<string, table<string, string[]>>
local build_index_cache = {}

---@param root string
---@return table<string, string[]> index
local function build_index(root)
  local cached = build_index_cache[root]
  if cached then return cached end

  local index = {}
  local dir = vim.fs.joinpath(root, BUILD_SUBDIR)
  if vim.uv.fs_stat(dir) then
    for name, type in vim.fs.dir(dir, { depth = BUILD_SCAN_DEPTH, follow = true }) do
      if type ~= 'directory' then
        local base = vim.fs.basename(name)
        local abs = vim.fs.joinpath(dir, name)
        if index[base] then
          table.insert(index[base], abs)
        else
          index[base] = { abs }
        end
      end
    end
  end

  build_index_cache[root] = index
  return index
end

--- Find a flist entry inside the build tree by basename, preferring a tail match.
---@return string|nil abs, integer candidates
local function find_in_build(path, root)
  local candidates = build_index(root)[vim.fs.basename(path)]
  if not candidates or #candidates == 0 then return nil, 0 end

  local tail = path:gsub('^%./', ''):gsub('^%.%./', '')
  local best
  for _, abs in ipairs(candidates) do
    local suffix_match = vim.endswith(abs, '/' .. tail)
    if suffix_match and (not best or not best.suffix or #abs < #best.abs) then
      best = { abs = abs, suffix = true }
    elseif not best then
      best = { abs = abs, suffix = false }
    elseif not best.suffix and #abs < #best.abs then
      best = { abs = abs, suffix = false }
    end
  end
  return best and best.abs or nil, #candidates
end

--- Resolve a flist path: root dir, then flist's dir, then build tree.
---@return string|nil abs, integer|nil build_candidates non-nil when found via the build-tree scan
local function resolve(path, root, flist_dir)
  if path:match '^%$' then path = vim.fn.expand(path) end
  if vim.startswith(path, '/') then
    if vim.uv.fs_stat(path) then return vim.fs.normalize(path) end
  else
    for _, base in ipairs { root, flist_dir } do
      local abs = vim.fs.normalize(vim.fs.joinpath(base, path))
      if vim.uv.fs_stat(abs) then return abs end
    end
  end
  return find_in_build(path, root)
end

--- Resolve a directory (`+incdir+` entry).
---@return string|nil abs
local function resolve_dir(path, root, flist_dir)
  if path:match '^%$' then path = vim.fn.expand(path) end
  local bases = vim.startswith(path, '/') and { '' } or { root, flist_dir, vim.fs.joinpath(root, BUILD_SUBDIR) }
  for _, base in ipairs(bases) do
    local abs = vim.fs.normalize(base == '' and path or vim.fs.joinpath(base, path))
    local stat = vim.uv.fs_stat(abs)
    if stat and stat.type == 'directory' then return abs end
  end
  return nil
end

--- Parse one flist into `acc`: paths, `+incdir+`, `+define+`, `-f/-F/-file` (recursive).
---@param flist string absolute path
---@param root string
---@param acc { files: string[], seen: table<string,boolean>, incdirs: string[], seen_incdir: table<string,boolean>, defines: string[], seen_define: table<string,boolean>, missing: string[], visited: table<string,boolean> }
local function parse_flist(flist, root, acc)
  flist = vim.fs.normalize(flist)
  if acc.visited[flist] then return end
  acc.visited[flist] = true

  local ok, lines = pcall(vim.fn.readfile, flist)
  if not ok then
    table.insert(acc.missing, flist .. ' (unreadable)')
    return
  end

  local dir = vim.fs.dirname(flist)
  local pending_flist = false

  for _, raw in ipairs(lines) do
    local line = raw:gsub('//.*$', ''):gsub('^%s*#.*$', ''):gsub('%s+$', ''):gsub('^%s+', '')
    if line ~= '' then
      if pending_flist then
        pending_flist = false
        local abs = resolve(line, root, dir)
        if abs then
          parse_flist(abs, root, acc)
        else
          table.insert(acc.missing, line)
        end
      elseif line == '-f' or line == '-F' or line == '-file' then
        pending_flist = true
      elseif line:match '^%-[fF]%s' or line:match '^%-file%s' then
        local nested = line:match '^%-%a+%s+(.*)$'
        local abs = nested and resolve(nested, root, dir)
        if abs then
          parse_flist(abs, root, acc)
        elseif nested then
          table.insert(acc.missing, nested)
        end
      elseif vim.startswith(line, '+incdir+') then
        for part in line:sub(#'+incdir+' + 1):gmatch '[^+]+' do
          local abs = resolve_dir(part, root, dir)
          if abs and not acc.seen_incdir[abs] then
            acc.seen_incdir[abs] = true
            table.insert(acc.incdirs, abs)
          end
        end
      elseif vim.startswith(line, '+define+') then
        for part in line:sub(#'+define+' + 1):gmatch '[^+]+' do
          if not acc.seen_define[part] then
            acc.seen_define[part] = true
            table.insert(acc.defines, part)
          end
        end
      elseif vim.startswith(line, '+') or vim.startswith(line, '-') then
        -- ignored: +libext+, -y, -sverilog, etc.
      else
        local abs, build_candidates = resolve(line, root, dir)
        if not abs then
          table.insert(acc.missing, line)
        else
          if build_candidates then
            acc.generated = acc.generated + 1
            if build_candidates > 1 then table.insert(acc.ambiguous, ('%s -> %s (%d candidates in build/)'):format(line, abs, build_candidates)) end
          end
          if not acc.seen[abs] then
            acc.seen[abs] = true
            table.insert(acc.files, abs)
          end
        end
      end
    end
  end
end

--- Path relative to `root` if it lives inside it, else the absolute path.
local function relative(path, root)
  if vim.startswith(path, root .. '/') then return path:sub(#root + 2) end
  return path
end

--- Generate <root>/verible.filelist from the given flists.
---@param root string
---@param flists string[] absolute paths
---@return { out: string, files: integer, incdirs: integer, generated: integer, missing: string[], ambiguous: string[] }|nil result, string|nil err
function M.write_filelist(root, flists)
  local acc = {
    files = {},
    seen = {},
    incdirs = {},
    seen_incdir = {},
    defines = {},
    seen_define = {},
    missing = {},
    ambiguous = {},
    generated = 0, -- files found only inside the build tree
    visited = {},
  }
  for _, flist in ipairs(flists) do
    parse_flist(flist, root, acc)
  end
  if #acc.files == 0 then return nil, 'no source files found in ' .. #flists .. ' flist(s)' end

  -- also add every source dir as an incdir
  for _, file in ipairs(acc.files) do
    local dir = vim.fs.dirname(file)
    if not acc.seen_incdir[dir] then
      acc.seen_incdir[dir] = true
      table.insert(acc.incdirs, dir)
    end
  end

  local out = {
    '# Generated by :VeribleIndex -- do not edit by hand.',
    '# Source flists (' .. #flists .. '):',
  }
  for _, flist in ipairs(flists) do
    table.insert(out, '#   ' .. relative(flist, root))
  end
  -- M.use_absolute_paths = false emits root-relative paths instead.
  local emit = function(path) return M.use_absolute_paths and path or relative(path, root) end

  table.insert(out, '')
  for _, define in ipairs(acc.defines) do
    table.insert(out, '+define+' .. define)
  end
  for _, incdir in ipairs(acc.incdirs) do
    table.insert(out, '+incdir+' .. emit(incdir))
  end
  table.insert(out, '')
  for _, file in ipairs(acc.files) do
    table.insert(out, emit(file))
  end

  local path = vim.fs.joinpath(root, OUTPUT)
  local ok, err = pcall(vim.fn.writefile, out, path)
  if not ok then return nil, tostring(err) end
  return { out = path, files = #acc.files, incdirs = #acc.incdirs, generated = acc.generated, missing = acc.missing, ambiguous = acc.ambiguous }
end

--- Absolute source-file paths listed in `<root>/verible.filelist` (skips comments/`+incdir+`/`+define+`).
---@param root string
---@return string[] files
local function filelist_files(root)
  local filelist = vim.fs.joinpath(root, OUTPUT)
  if vim.fn.filereadable(filelist) == 0 then return {} end
  local files = {}
  for _, line in ipairs(vim.fn.readfile(filelist)) do
    if line ~= '' and not vim.startswith(line, '#') and not vim.startswith(line, '+') then table.insert(files, vim.fs.joinpath(root, line)) end
  end
  return files
end

-- ============================================================
-- verible-verilog-ls command/config + restart
-- ============================================================

--- Base verible-verilog-ls command (exe + lint flags), gated on `--helpfull`.
---@return string[] cmd
local base_cmd_cache
local function base_cmd()
  if base_cmd_cache then return vim.deepcopy(base_cmd_cache) end

  local exe = 'verible-verilog-ls'
  local cmd = { exe }
  if vim.fn.executable(exe) == 0 then
    base_cmd_cache = cmd
    return vim.deepcopy(cmd)
  end

  local help = ''
  local ok, res = pcall(function() return vim.system({ exe, '--helpfull' }, { text = true }):wait(2000) end)
  if ok and res then help = (res.stdout or '') .. (res.stderr or '') end

  if help:find '%-%-rules_config_search' then table.insert(cmd, '--rules_config_search') end
  if help:find '%-%-rules[%s=]' or help:find '%-%-rules\n' then table.insert(cmd, '--rules=' .. M.rules_string()) end
  if help:find '%-%-lsp_enable_hover' then table.insert(cmd, '--lsp_enable_hover') end

  base_cmd_cache = cmd
  return vim.deepcopy(cmd)
end

--- `--file_list_path` for `root`'s filelist.
---@param root string|nil project root, e.g. from `M.project_root()`
---@return string[] flags empty when `root` has no verible.filelist yet
function M.filelist_flags(root)
  local filelist = root and vim.fs.joinpath(root, OUTPUT)
  if filelist and vim.fn.filereadable(filelist) == 1 then return { '--file_list_path', filelist } end
  return {}
end

--- `M.filelist_flags` + `--file_list_root` (verible-verilog-project only).
---@param root string|nil project root, e.g. from `M.project_root()`
---@return string[] flags empty when `root` has no verible.filelist yet
function M.project_flags(root)
  local flags = M.filelist_flags(root)
  if #flags > 0 then vim.list_extend(flags, { '--file_list_root', root }) end
  return flags
end

--- Full verible-verilog-ls command for `root`.
---@param root string|nil project root, e.g. from `M.project_root()`
---@return string[] cmd
function M.ls_cmd(root)
  local cmd = base_cmd()
  vim.list_extend(cmd, M.filelist_flags(root))
  return cmd
end

--- Restart verible and re-attach it to all open verilog buffers.
function M.restart()
  pcall(vim.lsp.config, 'verible', { cmd = M.ls_cmd(M.project_root()) })

  local clients = vim.lsp.get_clients { name = 'verible' }
  for _, client in ipairs(clients) do
    client:stop(true)
  end
  vim.defer_fn(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local ft = vim.bo[buf].filetype
      if vim.api.nvim_buf_is_loaded(buf) and (ft == 'verilog' or ft == 'systemverilog') then vim.api.nvim_exec_autocmds('FileType', { buffer = buf, modeline = false }) end
    end
  end, 200)
  return #clients
end

-- ============================================================
-- Indexing entry points
-- ============================================================

--- Index the project: build verible.filelist, then restart verible.
---@param opts { flists: string[]|nil, root: string|nil }|nil
function M.index(opts)
  opts = opts or {}
  local root = opts.root or M.project_root()
  if not root then
    vim.notify('verible: could not determine a project root', vim.log.levels.ERROR)
    return
  end

  local flists = opts.flists or discover_flists(root)
  if #flists == 0 then
    vim.notify(('verible: no flists found in %s/%s'):format(root, FLIST_SUBDIR), vim.log.levels.WARN)
    return
  end

  build_index_cache[root] = nil
  local result, err = M.write_filelist(root, flists)
  build_index_cache[root] = nil
  if not result then
    vim.notify('verible: indexing failed -- ' .. err, vim.log.levels.ERROR)
    return
  end

  local msg = ('verible: indexed %d files (%d from build/), %d incdirs, %d flist(s)\n%s'):format(result.files, result.generated, result.incdirs, #flists, relative(result.out, root))
  local level = vim.log.levels.INFO
  if #result.ambiguous > 0 then
    local shown = vim.list_slice(result.ambiguous, 1, math.min(3, #result.ambiguous))
    msg = msg .. ('\n%d ambiguous build match%s:\n  %s'):format(#result.ambiguous, #result.ambiguous == 1 and '' or 'es', table.concat(shown, '\n  '))
  end
  if #result.missing > 0 then
    level = vim.log.levels.WARN
    local shown = vim.list_slice(result.missing, 1, math.min(5, #result.missing))
    msg = msg .. ('\n%d unresolved entr%s (build it first?):\n  %s'):format(#result.missing, #result.missing == 1 and 'y' or 'ies', table.concat(shown, '\n  '))
  end
  vim.notify(msg, level)
  M.restart()
end

--- Pick a single flist to index (useful when one repo holds many configs).
function M.index_pick()
  local root = M.project_root()
  local flists = discover_flists(root)
  if #flists == 0 then
    vim.notify(('verible: no flists found in %s/%s'):format(root, FLIST_SUBDIR), vim.log.levels.WARN)
    return
  end
  vim.ui.select(flists, {
    prompt = 'Index flist:',
    format_item = function(item) return relative(item, root) end,
  }, function(choice)
    if choice then M.index { root = root, flists = { choice } } end
  end)
end

--- Write `.rules.verible_lint` into the project root.
---@param root string|nil
function M.write_rules_config(root)
  root = root or M.project_root()
  local path = vim.fs.joinpath(root, '.rules.verible_lint')
  local ok, err = pcall(vim.fn.writefile, M.rules, path)
  if not ok then
    vim.notify('verible: could not write ' .. path .. ' -- ' .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify('verible: wrote ' .. path .. ' (' .. #M.rules .. ' rules)')
end

-- ============================================================
-- CLI tool wrappers (project, preprocessor, lint, ctags)
-- ============================================================

--- Run a verible CLI tool and drop its output in a scratch split.
---@param exe string
---@param args string[]
---@param title string
---@param ft string|nil buffer filetype for the output
local function run_tool(exe, args, title, ft)
  if vim.fn.executable(exe) == 0 then
    vim.notify('verible: ' .. exe .. ' not on PATH', vim.log.levels.ERROR)
    return
  end
  local cmd = vim.list_extend({ exe }, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      local body = res.stdout or ''
      if res.stderr and res.stderr ~= '' then body = body .. '\n--- stderr (exit ' .. res.code .. ') ---\n' .. res.stderr end
      if body:gsub('%s', '') == '' then
        vim.notify('verible: ' .. title .. ' produced no output (exit ' .. res.code .. ')', vim.log.levels.WARN)
        return
      end
      vim.cmd 'new'
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, '\n', { plain = true }))
      vim.bo[buf].buftype = 'nofile'
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].modifiable = false
      if ft then vim.bo[buf].filetype = ft end
      vim.api.nvim_buf_set_name(buf, 'verible://' .. title)
    end)
  end)
end

--- verible-verilog-project over the generated filelist.
---@param subcommand 'symbol-table-defs'|'symbol-table-refs'|'file-deps'
function M.project(subcommand)
  local root = M.project_root()
  if not require_filelist(root) then return end
  run_tool('verible-verilog-project', vim.list_extend({ subcommand }, M.project_flags(root)), 'project ' .. subcommand)
end

--- verible-verilog-preprocessor on the current buffer's file.
---@param subcommand 'preprocess'|'strip-comments'|'multiple-cu'
function M.preprocess(subcommand)
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' or not vim.uv.fs_stat(file) then
    vim.notify('verible: current buffer has no file on disk', vim.log.levels.WARN)
    return
  end
  run_tool('verible-verilog-preprocessor', { subcommand, file }, 'preprocessor ' .. subcommand, vim.bo.filetype)
end

--- verible-verilog-lint over the whole indexed project, into the quickfix list.
function M.lint_project()
  local root = M.project_root()
  if not require_filelist(root) then return end
  local files = filelist_files(root)
  if #files == 0 then
    vim.notify('verible: ' .. OUTPUT .. ' lists no sources', vim.log.levels.WARN)
    return
  end
  if vim.fn.executable 'verible-verilog-lint' == 0 then
    vim.notify('verible: verible-verilog-lint not on PATH', vim.log.levels.ERROR)
    return
  end

  local cmd = vim.list_extend(vim.list_extend({ 'verible-verilog-lint' }, M.lint_args()), files)
  vim.notify(('verible: linting %d files...'):format(#files))
  vim.system(cmd, { text = true, cwd = root }, function(res)
    vim.schedule(function()
      local lines = vim.split((res.stdout or '') .. '\n' .. (res.stderr or ''), '\n', { plain = true })
      local items = {}
      for _, line in ipairs(lines) do
        -- file:line:col: message
        local f, lnum, col, msg = line:match '^(.-):(%d+):(%d+):%s*(.*)$'
        if f then table.insert(items, { filename = f, lnum = tonumber(lnum), col = tonumber(col), text = msg, type = 'W' }) end
      end
      vim.fn.setqflist({}, ' ', { title = 'verible-verilog-lint', items = items })
      if #items > 0 then
        vim.cmd 'copen'
      else
        vim.notify(('verible: lint clean across %d files'):format(#files))
      end
    end)
  end)
end

--- `ctags` over every file in `verible.filelist`, as a `C-]`/`:tag` fallback for when the LSP
--- can't resolve something. Uses ctags' own Verilog/SystemVerilog defaults -- no extra flags.
---@param root string|nil
function M.ctags(root)
  root = root or M.project_root()
  if not require_filelist(root) then return end
  local files = filelist_files(root)
  if #files == 0 then
    vim.notify('verible: ' .. OUTPUT .. ' lists no sources', vim.log.levels.WARN)
    return
  end
  if vim.fn.executable 'ctags' == 0 then
    vim.notify('verible: ctags not on PATH', vim.log.levels.ERROR)
    return
  end

  local tagsfile = vim.fs.joinpath(root, 'tags')
  vim.system({ 'ctags', '-f', tagsfile, '-L', '-' }, { text = true, cwd = root, stdin = table.concat(files, '\n') .. '\n' }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        vim.notify('verible: ctags failed (exit ' .. res.code .. ')\n' .. (res.stderr or ''), vim.log.levels.ERROR)
        return
      end
      vim.notify(('verible: wrote %s (%d files)'):format(relative(tagsfile, root), #files))
    end)
  end)
end

-- ============================================================
-- User commands + keymaps
-- ============================================================

vim.api.nvim_create_user_command('VeribleIndex', function(cmd)
  local root = M.project_root()
  local flists = nil
  if #cmd.fargs > 0 then
    flists = {}
    for _, arg in ipairs(cmd.fargs) do
      local abs = resolve(arg, root, vim.uv.cwd())
      if abs then
        table.insert(flists, abs)
      else
        vim.notify('verible: no such flist: ' .. arg, vim.log.levels.ERROR)
        return
      end
    end
  end
  M.index { root = root, flists = flists }
end, { nargs = '*', complete = 'file', desc = 'Index the Verilog project for verible (build/flists -> verible.filelist)' })

vim.api.nvim_create_user_command('VeribleIndexPick', function() M.index_pick() end, { desc = 'Index a single Verilog flist for verible' })

vim.api.nvim_create_user_command('VeribleRestart', function()
  local n = M.restart()
  vim.notify(('verible: restarted %d client(s)'):format(n))
end, { desc = 'Restart the verible language server' })

vim.api.nvim_create_user_command('VeribleWriteRulesConfig', function() M.write_rules_config() end, { desc = 'Write .rules.verible_lint into the project root' })

vim.api.nvim_create_user_command('VeribleProject', function(cmd) M.project(cmd.args ~= '' and cmd.args or 'file-deps') end, {
  nargs = '?',
  complete = function() return { 'file-deps', 'symbol-table-defs', 'symbol-table-refs' } end,
  desc = 'Run verible-verilog-project over verible.filelist',
})

vim.api.nvim_create_user_command('VeriblePreprocess', function(cmd) M.preprocess(cmd.args ~= '' and cmd.args or 'preprocess') end, {
  nargs = '?',
  complete = function() return { 'preprocess', 'strip-comments', 'multiple-cu' } end,
  desc = 'Run verible-verilog-preprocessor on the current file',
})

vim.api.nvim_create_user_command('VeribleLintProject', function() M.lint_project() end, { desc = 'Lint every file in verible.filelist into the quickfix list' })

vim.api.nvim_create_user_command('VeribleCtags', function() M.ctags() end, { desc = 'Generate a ctags "tags" file from verible.filelist' })

vim.keymap.set('n', '<leader>vi', function() M.index() end, { desc = '[V]erilog [I]ndex project (all flists)' })
vim.keymap.set('n', '<leader>vf', function() M.index_pick() end, { desc = '[V]erilog index one [F]list' })
vim.keymap.set('n', '<leader>vr', function() M.restart() end, { desc = '[V]erilog LSP [R]estart' })
vim.keymap.set('n', '<leader>vl', function() M.lint_project() end, { desc = '[V]erilog [L]int whole project' })
vim.keymap.set('n', '<leader>vc', function() M.ctags() end, { desc = '[V]erilog [C]tags (regenerate tags file)' })
vim.keymap.set('n', '<leader>vd', function() M.project 'file-deps' end, { desc = '[V]erilog file [D]ependencies' })
vim.keymap.set('n', '<leader>vs', function() M.project 'symbol-table-defs' end, { desc = '[V]erilog [S]ymbol table' })
vim.keymap.set('n', '<leader>vp', function() M.preprocess 'preprocess' end, { desc = '[V]erilog [P]reprocess this file' })

pcall(function() require('which-key').add { { '<leader>v', group = '[V]erilog' } } end)

return M
