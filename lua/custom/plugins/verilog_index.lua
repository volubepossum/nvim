-- Verilog/SystemVerilog project indexing for verible-verilog-ls.
--
-- verible's language server builds a project-wide symbol table (cross-file
-- goto-definition, references, hover, module/port completion) when it finds a
-- `verible.filelist` in the project root. This module generates that file from
-- the build file-lists in `<root>/build/flists`, then restarts the server so it
-- picks the new index up.
--
-- Keymaps:
--   <leader>vi  index every flist under build/flists  (:VeribleIndex)
--   <leader>vf  pick one flist to index               (:VeribleIndexPick)
--   <leader>vr  restart the verible LSP               (:VeribleRestart)

local M = {}

local FLIST_SUBDIR = 'build/flists'
local FLIST_EXT = { ['f'] = true, ['fl'] = true, ['flist'] = true }
local OUTPUT = 'verible.filelist'

--- Project root = nearest ancestor of `start` containing build/flists,
--- falling back to the git root, then to the cwd.
---@param start string|nil directory or file path to search upward from
---@return string|nil root
function M.project_root(start)
  start = start or vim.api.nvim_buf_get_name(0)
  if start == '' then start = vim.uv.cwd() end
  -- The predicate is called per directory entry, so gate on 'build' before stat'ing.
  local root = vim.fs.root(start, function(name, path) return name == 'build' and vim.uv.fs_stat(vim.fs.joinpath(path, FLIST_SUBDIR)) ~= nil end)
  return root or vim.fs.root(start, '.git') or vim.uv.cwd()
end

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

--- Resolve a path from a flist. Paths are documented as relative to the project
--- root, but flists that were assembled elsewhere sometimes carry paths relative
--- to their own directory -- try the root first, then the flist's directory.
---@return string|nil abs
local function resolve(path, root, flist_dir)
  if path:match '^%$' then path = vim.fn.expand(path) end
  if vim.startswith(path, '/') then return vim.uv.fs_stat(path) and vim.fs.normalize(path) or nil end
  for _, base in ipairs { root, flist_dir } do
    local abs = vim.fs.normalize(vim.fs.joinpath(base, path))
    if vim.uv.fs_stat(abs) then return abs end
  end
  return nil
end

--- Parse one flist, accumulating into `acc`.
--- Understands plain paths, `+incdir+a+b`, `+define+X=1`, `-f/-F/-file <flist>`
--- (followed recursively) and `+libext+`/`-y` (ignored -- verible has no
--- library-scan mode).
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
          local abs = resolve(part, root, dir)
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
        -- +libext+, -y, -sverilog, tool switches: nothing for verible to do
      else
        local abs = resolve(line, root, dir)
        if not abs then
          table.insert(acc.missing, line)
        elseif not acc.seen[abs] then
          acc.seen[abs] = true
          table.insert(acc.files, abs)
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
---@return { out: string, files: integer, incdirs: integer, missing: string[] }|nil result, string|nil err
function M.write_filelist(root, flists)
  local acc = { files = {}, seen = {}, incdirs = {}, seen_incdir = {}, defines = {}, seen_define = {}, missing = {}, visited = {} }
  for _, flist in ipairs(flists) do
    parse_flist(flist, root, acc)
  end
  if #acc.files == 0 then return nil, 'no source files found in ' .. #flists .. ' flist(s)' end

  -- Every source directory is also an include search path: `include "x.svh"`
  -- inside these files resolves relative to +incdir+ entries only.
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
  table.insert(out, '')
  for _, define in ipairs(acc.defines) do
    table.insert(out, '+define+' .. define)
  end
  for _, incdir in ipairs(acc.incdirs) do
    table.insert(out, '+incdir+' .. relative(incdir, root))
  end
  table.insert(out, '')
  for _, file in ipairs(acc.files) do
    table.insert(out, relative(file, root))
  end

  local path = vim.fs.joinpath(root, OUTPUT)
  local ok, err = pcall(vim.fn.writefile, out, path)
  if not ok then return nil, tostring(err) end
  return { out = path, files = #acc.files, incdirs = #acc.incdirs, missing = acc.missing }
end

--- Stop every verible client and re-attach it to all open verilog buffers, so
--- the server re-reads verible.filelist.
function M.restart()
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

  local result, err = M.write_filelist(root, flists)
  if not result then
    vim.notify('verible: indexing failed -- ' .. err, vim.log.levels.ERROR)
    return
  end

  local msg = ('verible: indexed %d files, %d incdirs from %d flist(s)\n%s'):format(result.files, result.incdirs, #flists, relative(result.out, root))
  local level = vim.log.levels.INFO
  if #result.missing > 0 then
    level = vim.log.levels.WARN
    local shown = vim.list_slice(result.missing, 1, math.min(5, #result.missing))
    msg = msg .. ('\n%d unresolved entr%s:\n  %s'):format(#result.missing, #result.missing == 1 and 'y' or 'ies', table.concat(shown, '\n  '))
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

vim.keymap.set('n', '<leader>vi', function() M.index() end, { desc = '[V]erilog [I]ndex project (all flists)' })
vim.keymap.set('n', '<leader>vf', function() M.index_pick() end, { desc = '[V]erilog index one [F]list' })
vim.keymap.set('n', '<leader>vr', function() M.restart() end, { desc = '[V]erilog LSP [R]estart' })

pcall(function() require('which-key').add { { '<leader>v', group = '[V]erilog' } } end)

return M
