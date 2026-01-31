-- Git metadata extraction for openclaw.nvim
local M = {}

-- Run git command and return output
local function git_cmd(args, cwd)
  local cmd = { "git", "-C", cwd or vim.fn.getcwd() }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end
  
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

-- Check if current directory is a git repo
function M.is_git_repo(cwd)
  local result = git_cmd({ "rev-parse", "--is-inside-work-tree" }, cwd)
  return result and result[1] == "true"
end

-- Get remote URL (prefer origin)
function M.get_remote_url(cwd)
  local result = git_cmd({ "remote", "get-url", "origin" }, cwd)
  if result and result[1] then
    local url = result[1]
    -- Convert SSH to HTTPS for readability
    url = url:gsub("^git@github%.com:", "https://github.com/")
    url = url:gsub("%.git$", "")
    return url
  end
  return nil
end

-- Get current branch
function M.get_branch(cwd)
  local result = git_cmd({ "branch", "--show-current" }, cwd)
  return result and result[1] or nil
end

-- Get repo root path
function M.get_root(cwd)
  local result = git_cmd({ "rev-parse", "--show-toplevel" }, cwd)
  return result and result[1] or nil
end

-- Get relative path from repo root
function M.get_relative_path(filepath, cwd)
  local root = M.get_root(cwd)
  if not root then return filepath end
  
  local abs_path = vim.fn.fnamemodify(filepath, ":p")
  if abs_path:sub(1, #root) == root then
    return abs_path:sub(#root + 2) -- +2 to skip the trailing slash
  end
  return filepath
end

-- Get current commit hash (short)
function M.get_commit(cwd)
  local result = git_cmd({ "rev-parse", "--short", "HEAD" }, cwd)
  return result and result[1] or nil
end

-- Get repo name from remote or directory
function M.get_repo_name(cwd)
  local url = M.get_remote_url(cwd)
  if url then
    -- Extract owner/repo from URL
    local match = url:match("github%.com/(.+)$") or url:match("gitlab%.com/(.+)$")
    if match then return match end
  end
  
  -- Fallback to directory name
  local root = M.get_root(cwd)
  if root then
    return vim.fn.fnamemodify(root, ":t")
  end
  return nil
end

-- Build full metadata table
function M.get_metadata(filepath, start_line, end_line)
  local cwd = vim.fn.fnamemodify(filepath, ":h")
  
  if not M.is_git_repo(cwd) then
    return {
      is_git = false,
      file = filepath,
      start_line = start_line,
      end_line = end_line,
    }
  end
  
  return {
    is_git = true,
    repo = M.get_repo_name(cwd),
    remote_url = M.get_remote_url(cwd),
    branch = M.get_branch(cwd),
    commit = M.get_commit(cwd),
    file = M.get_relative_path(filepath, cwd),
    abs_path = filepath,
    start_line = start_line,
    end_line = end_line,
    root = M.get_root(cwd),
  }
end

-- Format metadata as markdown header for agent context
function M.format_context(meta, code)
  local lines = {}
  
  if meta.is_git then
    table.insert(lines, "## Code Context")
    table.insert(lines, "")
    table.insert(lines, string.format("**Repo:** `%s`", meta.repo or "unknown"))
    if meta.remote_url then
      table.insert(lines, string.format("**Remote:** %s", meta.remote_url))
    end
    table.insert(lines, string.format("**Branch:** `%s`", meta.branch or "unknown"))
    table.insert(lines, string.format("**Commit:** `%s`", meta.commit or "unknown"))
    table.insert(lines, string.format("**File:** `%s`", meta.file))
    table.insert(lines, string.format("**Lines:** %d-%d", meta.start_line, meta.end_line))
    table.insert(lines, "")
    
    -- GitHub permalink if possible
    if meta.remote_url and meta.remote_url:match("github%.com") then
      local permalink = string.format("%s/blob/%s/%s#L%d-L%d",
        meta.remote_url, meta.commit or meta.branch or "main",
        meta.file, meta.start_line, meta.end_line)
      table.insert(lines, string.format("**Permalink:** %s", permalink))
      table.insert(lines, "")
    end
  else
    table.insert(lines, "## Code Context (not a git repo)")
    table.insert(lines, "")
    table.insert(lines, string.format("**File:** `%s`", meta.file))
    table.insert(lines, string.format("**Lines:** %d-%d", meta.start_line, meta.end_line))
    table.insert(lines, "")
    table.insert(lines, "⚠️ *This file is not in a git repository. I cannot create a PR directly.*")
    table.insert(lines, "")
  end
  
  -- Add code block with language detection
  local ext = vim.fn.fnamemodify(meta.file, ":e")
  local lang_map = {
    lua = "lua", py = "python", js = "javascript", ts = "typescript",
    tsx = "tsx", jsx = "jsx", rs = "rust", go = "go", rb = "ruby",
    sh = "bash", zsh = "zsh", fish = "fish", md = "markdown",
    json = "json", yaml = "yaml", yml = "yaml", toml = "toml",
  }
  local lang = lang_map[ext] or ext or ""
  
  table.insert(lines, string.format("```%s", lang))
  table.insert(lines, code)
  table.insert(lines, "```")
  
  return table.concat(lines, "\n")
end

return M
