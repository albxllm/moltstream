-- moltstream.nvim
-- Real-time bidirectional communication with OpenClaw

local M = {}
local git = require("moltstream.git")

-- State
local job_id = nil
local agent_buf = nil      -- Buffer for agent responses
local user_buf = nil       -- Buffer for user message history
local agent_win = nil      -- Window for agent responses
local user_win = nil       -- Window for user messages
local config = {}
local response_in_progress = false
local pending_response = ""
local response_start_line = nil

-- Default configuration
local defaults = {
  binary = "moltstream",
  keymap = {
    send = "<leader>ms",
    send_code = "<leader>mc",  -- Send code with git context
    open = "<leader>mo",
    history = "<leader>mu",
  },
  auto_scroll = true,
  split_width = 80,  -- Width of the right split
}

-- Setup function
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Create commands
  vim.api.nvim_create_user_command("MoltOpen", M.open, {})
  vim.api.nvim_create_user_command("MoltClose", M.close, {})
  vim.api.nvim_create_user_command("MoltToggle", M.toggle, {})
  vim.api.nvim_create_user_command("MoltSend", M.send_visual, {})
  vim.api.nvim_create_user_command("MoltSendCode", M.send_code, {})
  vim.api.nvim_create_user_command("MoltHistory", M.fetch_history, {})
  vim.api.nvim_create_user_command("MoltStatus", M.status, {})

  -- Setup keymaps
  if config.keymap.open then
    vim.keymap.set("n", config.keymap.open, M.toggle, { desc = "Moltstream: Toggle" })
  end
  if config.keymap.send then
    vim.keymap.set("v", config.keymap.send, M.send_visual, { desc = "Moltstream: Send selection" })
    vim.keymap.set("n", config.keymap.send, M.send_line, { desc = "Moltstream: Send line/paragraph" })
  end
  if config.keymap.send_code then
    vim.keymap.set("v", config.keymap.send_code, M.send_code, { desc = "Moltstream: Send code with git context" })
  end
  if config.keymap.history then
    vim.keymap.set("n", config.keymap.history, M.fetch_history, { desc = "Moltstream: Fetch history" })
  end
end

-- Start the bridge process
local function start_bridge()
  if job_id then
    return true
  end

  job_id = vim.fn.jobstart({ config.binary }, {
    on_stdout = function(_, data, _)
      for _, line in ipairs(data) do
        if line ~= "" then
          handle_message(line)
        end
      end
    end,
    on_stderr = function(_, data, _)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.schedule(function()
            vim.notify("[moltstream] " .. line, vim.log.levels.WARN)
          end)
        end
      end
    end,
    on_exit = function(_, code, _)
      job_id = nil
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("[moltstream] Bridge exited with code " .. code, vim.log.levels.ERROR)
        end)
      end
    end,
    stdin = "pipe",
    stdout_buffered = false,
  })

  if job_id <= 0 then
    vim.notify("[moltstream] Failed to start bridge", vim.log.levels.ERROR)
    job_id = nil
    return false
  end

  return true
end

-- Send RPC request to bridge
local function rpc_request(method, params)
  if not start_bridge() then
    return
  end

  local req = vim.fn.json_encode({
    jsonrpc = "2.0",
    method = method,
    params = params or {},
    id = math.random(1, 1000000),
  })

  vim.fn.chansend(job_id, req .. "\n")
end

-- Handle incoming messages from bridge
function handle_message(line)
  local ok, msg = pcall(vim.fn.json_decode, line)
  if not ok then
    return
  end

  -- Handle notifications
  if msg.method then
    if msg.method == "stream" then
      handle_stream(msg.params)
    elseif msg.method == "connected" then
      vim.schedule(function()
        vim.notify("[moltstream] Connected to gateway", vim.log.levels.INFO)
      end)
    elseif msg.method == "error" then
      vim.schedule(function()
        vim.notify("[moltstream] Error: " .. (msg.params.message or "unknown"), vim.log.levels.ERROR)
      end)
    elseif msg.method == "history" then
      handle_history(msg.params)
    end
    return
  end

  -- Handle responses
  if msg.result then
    if msg.result.status == "ok" then
      finalize_response()
    end
  elseif msg.error then
    vim.schedule(function()
      vim.notify("[moltstream] " .. (msg.error.message or "unknown error"), vim.log.levels.ERROR)
    end)
  end
end

-- Create or get the agent buffer
local function ensure_agent_buf()
  if agent_buf and vim.api.nvim_buf_is_valid(agent_buf) then
    return agent_buf
  end

  agent_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(agent_buf, "[Moltstream Agent]")
  vim.bo[agent_buf].filetype = "markdown"
  vim.bo[agent_buf].buftype = "nofile"
  vim.bo[agent_buf].swapfile = false
  
  -- Add header
  vim.api.nvim_buf_set_lines(agent_buf, 0, -1, false, {
    "# Agent Responses",
    "",
  })
  
  return agent_buf
end

-- Create or get the user buffer
local function ensure_user_buf()
  if user_buf and vim.api.nvim_buf_is_valid(user_buf) then
    return user_buf
  end

  user_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(user_buf, "[Moltstream History]")
  vim.bo[user_buf].filetype = "markdown"
  vim.bo[user_buf].buftype = "nofile"
  vim.bo[user_buf].swapfile = false
  
  -- Add header
  vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, {
    "# Message History",
    "",
    "Press <leader>mu to fetch history",
    "",
  })
  
  return user_buf
end

-- Handle streaming response
function handle_stream(params)
  vim.schedule(function()
    local buf = ensure_agent_buf()
    
    -- Start new response block if needed
    if not response_in_progress then
      response_in_progress = true
      pending_response = ""
      
      -- Insert response header
      local timestamp = os.date("%H:%M")
      local line_count = vim.api.nvim_buf_line_count(buf)
      local header = {
        "---",
        "",
        "## [" .. timestamp .. "]",
        "",
      }
      vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, header)
      response_start_line = vim.api.nvim_buf_line_count(buf)
    end

    -- Append delta
    if params.delta and params.delta ~= "" then
      pending_response = pending_response .. params.delta
      
      -- Update buffer with current response
      local lines = vim.split(pending_response, "\n", { plain = true })
      
      if response_start_line then
        vim.api.nvim_buf_set_lines(buf, response_start_line, -1, false, lines)
      end
      
      -- Auto-scroll agent window
      if config.auto_scroll and agent_win and vim.api.nvim_win_is_valid(agent_win) then
        local new_line_count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_win_set_cursor(agent_win, { new_line_count, 0 })
      end
    end
  end)
end

-- Handle history response
function handle_history(params)
  vim.schedule(function()
    local buf = ensure_user_buf()
    
    local lines = {
      "# Message History",
      "",
    }
    
    if params.messages then
      for _, msg in ipairs(params.messages) do
        table.insert(lines, "---")
        table.insert(lines, "")
        table.insert(lines, "## " .. (msg.role or "user") .. " [" .. (msg.timestamp or "") .. "]")
        table.insert(lines, "")
        if msg.content then
          for _, line in ipairs(vim.split(msg.content, "\n", { plain = true })) do
            table.insert(lines, line)
          end
        end
        table.insert(lines, "")
      end
    else
      table.insert(lines, "_No history available_")
    end
    
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end)
end

-- Finalize the response
function finalize_response()
  response_in_progress = false
  pending_response = ""
  response_start_line = nil
  
  vim.schedule(function()
    if agent_buf and vim.api.nvim_buf_is_valid(agent_buf) then
      vim.api.nvim_buf_set_lines(agent_buf, -1, -1, false, { "", "" })
    end
  end)
end

-- Open the moltstream layout
function M.open()
  if not start_bridge() then
    return
  end

  -- Create buffers
  ensure_agent_buf()
  ensure_user_buf()

  -- Create vertical split on the right
  vim.cmd("vsplit")
  vim.cmd("wincmd l")
  
  -- Set width
  vim.cmd("vertical resize " .. config.split_width)
  
  -- Show agent buffer in top
  vim.api.nvim_win_set_buf(0, agent_buf)
  agent_win = vim.api.nvim_get_current_win()
  
  -- Create horizontal split for user history
  vim.cmd("split")
  vim.cmd("wincmd j")
  vim.api.nvim_win_set_buf(0, user_buf)
  user_win = vim.api.nvim_get_current_win()
  
  -- Resize to give more space to agent
  vim.cmd("resize 10")
  
  -- Go back to original window
  vim.cmd("wincmd h")
  
  vim.notify("[moltstream] Layout opened. Use <leader>ms to send selection.", vim.log.levels.INFO)
end

-- Close the moltstream layout
function M.close()
  if agent_win and vim.api.nvim_win_is_valid(agent_win) then
    vim.api.nvim_win_close(agent_win, true)
  end
  if user_win and vim.api.nvim_win_is_valid(user_win) then
    vim.api.nvim_win_close(user_win, true)
  end
  agent_win = nil
  user_win = nil
end

-- Check if layout is open
function M.is_open()
  return (agent_win and vim.api.nvim_win_is_valid(agent_win))
      or (user_win and vim.api.nvim_win_is_valid(user_win))
end

-- Toggle the moltstream layout
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Send selected text in visual mode
function M.send_visual()
  -- Get visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getline(start_pos[2], end_pos[2])
  
  if #lines == 0 then
    vim.notify("[moltstream] No text selected", vim.log.levels.WARN)
    return
  end
  
  -- Handle partial line selection
  if #lines == 1 then
    lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
  else
    lines[1] = string.sub(lines[1], start_pos[3])
    lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
  end
  
  local message = table.concat(lines, "\n")
  M.send_message(message)
end

-- Send current line or paragraph
function M.send_line()
  local line = vim.api.nvim_get_current_line()
  if line == "" then
    -- Try to get paragraph
    local start_line = vim.fn.search('^$', 'bnW') + 1
    local end_line = vim.fn.search('^$', 'nW') - 1
    if end_line < start_line then
      end_line = vim.fn.line('$')
    end
    local lines = vim.fn.getline(start_line, end_line)
    line = table.concat(lines, "\n")
  end
  
  if line == "" then
    vim.notify("[moltstream] No text to send", vim.log.levels.WARN)
    return
  end
  
  M.send_message(line)
end

-- Send code with git context (for PR workflows)
function M.send_code()
  -- Get visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line, end_line = start_pos[2], end_pos[2]
  local lines = vim.fn.getline(start_line, end_line)
  
  if #lines == 0 then
    vim.notify("[moltstream] No code selected", vim.log.levels.WARN)
    return
  end
  
  -- Handle partial line selection
  local start_col, end_col = start_pos[3], end_pos[3]
  if #lines == 1 then
    lines[1] = string.sub(lines[1], start_col, end_col)
  else
    lines[1] = string.sub(lines[1], start_col)
    lines[#lines] = string.sub(lines[#lines], 1, end_col)
  end
  
  local code = table.concat(lines, "\n")
  local filepath = vim.fn.expand("%:p")
  
  -- Get git metadata
  local meta = git.get_metadata(filepath, start_line, end_line)
  local context = git.format_context(meta, code)
  
  -- Add task instruction based on git status
  local instruction
  if meta.is_git and meta.remote_url then
    instruction = "\n\n**Task:** Please review this code and suggest improvements. If changes are needed, you can create a PR to `" .. (meta.repo or "the repo") .. "`."
  else
    instruction = "\n\n**Task:** Please review this code and suggest improvements. Note: This is not in a git repo I can access, so please provide the changes as a diff or updated code block."
  end
  
  M.send_message(context .. instruction)
end

-- Send any message string
function M.send_message(message)
  if response_in_progress then
    vim.notify("[moltstream] Response in progress", vim.log.levels.WARN)
    return
  end

  if not start_bridge() then
    return
  end

  -- Ensure layout is open
  if not agent_win or not vim.api.nvim_win_is_valid(agent_win) then
    M.open()
  end

  -- Add sent message to user buffer
  vim.schedule(function()
    if user_buf and vim.api.nvim_buf_is_valid(user_buf) then
      local timestamp = os.date("%H:%M")
      local lines = {
        "---",
        "",
        "## Sent [" .. timestamp .. "]",
        "",
      }
      for _, line in ipairs(vim.split(message, "\n", { plain = true })) do
        table.insert(lines, line)
      end
      table.insert(lines, "")
      
      local line_count = vim.api.nvim_buf_line_count(user_buf)
      vim.api.nvim_buf_set_lines(user_buf, line_count, line_count, false, lines)
      
      -- Scroll user window
      if user_win and vim.api.nvim_win_is_valid(user_win) then
        local new_count = vim.api.nvim_buf_line_count(user_buf)
        vim.api.nvim_win_set_cursor(user_win, { new_count, 0 })
      end
    end
  end)

  rpc_request("send", { content = message })
end

-- Fetch message history from server
function M.fetch_history()
  if not start_bridge() then
    return
  end
  
  rpc_request("history", {})
  vim.notify("[moltstream] Fetching history...", vim.log.levels.INFO)
end

-- Get connection status
function M.status()
  if not start_bridge() then
    return
  end
  
  rpc_request("status", {})
end

-- Stop the bridge
function M.stop()
  if job_id then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
end

return M
