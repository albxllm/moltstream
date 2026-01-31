-- moltstream.nvim
-- Real-time bidirectional communication with OpenClaw

local M = {}

-- State
local job_id = nil
local session_buf = nil
local config = {}
local response_in_progress = false
local pending_response = ""
local response_start_line = nil  -- Track where response content begins

-- Default configuration
local defaults = {
  binary = "moltstream",
  keymap = {
    send = "<leader>ms",
    new_message = "<leader>mn",
    open = "<leader>mo",
    archive = "<leader>ma",
  },
  auto_scroll = true,
  max_file_size = 1024 * 1024 * 1024, -- 1GB
  user_name = "User",
}

-- Setup function
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Create commands
  vim.api.nvim_create_user_command("MoltOpen", M.open, {})
  vim.api.nvim_create_user_command("MoltSend", M.send, {})
  vim.api.nvim_create_user_command("MoltNew", M.new_message, {})
  vim.api.nvim_create_user_command("MoltArchive", M.archive, {})
  vim.api.nvim_create_user_command("MoltStatus", M.status, {})
  vim.api.nvim_create_user_command("MoltReconnect", M.reconnect, {})

  -- Setup keymaps
  if config.keymap.open then
    vim.keymap.set("n", config.keymap.open, M.open, { desc = "Moltstream: Open" })
  end
  if config.keymap.send then
    vim.keymap.set("n", config.keymap.send, M.send, { desc = "Moltstream: Send" })
  end
  if config.keymap.new_message then
    vim.keymap.set("n", config.keymap.new_message, M.new_message, { desc = "Moltstream: New message" })
  end
  if config.keymap.archive then
    vim.keymap.set("n", config.keymap.archive, M.archive, { desc = "Moltstream: Archive" })
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
          vim.notify("[moltstream] " .. line, vim.log.levels.WARN)
        end
      end
    end,
    on_exit = function(_, code, _)
      job_id = nil
      if code ~= 0 then
        vim.notify("[moltstream] Bridge exited with code " .. code, vim.log.levels.ERROR)
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
local function rpc_request(method, params, callback)
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
      vim.notify("[moltstream] Connected to gateway", vim.log.levels.INFO)
    elseif msg.method == "error" then
      vim.notify("[moltstream] Error: " .. (msg.params.message or "unknown"), vim.log.levels.ERROR)
    end
    return
  end

  -- Handle responses
  if msg.result then
    if msg.result.status == "ok" then
      finalize_response()
    elseif msg.result.path then
      open_session_file(msg.result.path)
    end
  elseif msg.error then
    vim.notify("[moltstream] " .. msg.error.message, vim.log.levels.ERROR)
  end
end

-- Handle streaming response
function handle_stream(params)
  if not session_buf or not vim.api.nvim_buf_is_valid(session_buf) then
    return
  end

  -- Schedule on main thread to avoid race conditions
  vim.schedule(function()
    -- Start new response block if needed
    if not response_in_progress then
      response_in_progress = true
      pending_response = ""
      
      -- Insert response header
      local timestamp = os.date("%H:%M")
      local header = {
        "",
        "---",
        "",
        "## Assistant [" .. timestamp .. "]",
        "",
      }
      vim.api.nvim_buf_set_lines(session_buf, -1, -1, false, header)
      -- Store the line where content will start (0-indexed)
      response_start_line = vim.api.nvim_buf_line_count(session_buf)
    end

    -- Append delta
    if params.delta and params.delta ~= "" then
      pending_response = pending_response .. params.delta
      
      -- Update buffer with current response
      local lines = vim.split(pending_response, "\n", { plain = true })
      
      -- Replace from stored start line to end
      if response_start_line then
        vim.api.nvim_buf_set_lines(session_buf, response_start_line, -1, false, lines)
      end
      
      -- Auto-scroll
      if config.auto_scroll then
        local win = find_buffer_window(session_buf)
        if win then
          local new_line_count = vim.api.nvim_buf_line_count(session_buf)
          vim.api.nvim_win_set_cursor(win, { new_line_count, 0 })
        end
      end
    end
  end)
end

-- Find the content line after last Assistant header
function find_last_assistant_content_line()
  if not session_buf then return nil end
  
  local lines = vim.api.nvim_buf_get_lines(session_buf, 0, -1, false)
  local last_header = nil
  
  for i = #lines, 1, -1 do
    if lines[i]:match("^## Assistant") then
      -- Return the line after the empty line after header
      return i + 1
    end
  end
  
  return #lines
end

-- Finalize the response
function finalize_response()
  response_in_progress = false
  pending_response = ""
  response_start_line = nil
  
  if session_buf and vim.api.nvim_buf_is_valid(session_buf) then
    -- Add trailing newline and separator
    vim.api.nvim_buf_set_lines(session_buf, -1, -1, false, { "", "" })
    
    -- Save the buffer
    local bufname = vim.api.nvim_buf_get_name(session_buf)
    if bufname ~= "" then
      vim.api.nvim_buf_call(session_buf, function()
        vim.cmd("silent write")
      end)
    end
  end
end

-- Find window displaying buffer
function find_buffer_window(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

-- Open session file
function open_session_file(path)
  vim.cmd("edit " .. path)
  session_buf = vim.api.nvim_get_current_buf()
  
  -- Set buffer options
  vim.bo[session_buf].filetype = "markdown"
  
  -- Go to end
  vim.cmd("normal! G")
end

-- Extract last user message from buffer
local function extract_last_message()
  if not session_buf or not vim.api.nvim_buf_is_valid(session_buf) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(session_buf, 0, -1, false)
  local in_user_block = false
  local message_lines = {}
  local last_user_start = nil

  -- Find the last User block
  for i = #lines, 1, -1 do
    local line = lines[i]
    if line:match("^## " .. config.user_name) then
      last_user_start = i
      break
    end
  end

  if not last_user_start then
    return nil
  end

  -- Extract content from that block
  for i = last_user_start + 1, #lines do
    local line = lines[i]
    if line:match("^---$") or line:match("^## ") then
      break
    end
    table.insert(message_lines, line)
  end

  -- Trim empty lines
  while #message_lines > 0 and message_lines[1] == "" do
    table.remove(message_lines, 1)
  end
  while #message_lines > 0 and message_lines[#message_lines] == "" do
    table.remove(message_lines)
  end

  if #message_lines == 0 then
    return nil
  end

  return table.concat(message_lines, "\n")
end

-- Public API

function M.open()
  if not start_bridge() then
    return
  end
  rpc_request("session_path", {})
end

function M.send()
  local message = extract_last_message()
  if not message then
    vim.notify("[moltstream] No message to send", vim.log.levels.WARN)
    return
  end

  if response_in_progress then
    vim.notify("[moltstream] Response in progress", vim.log.levels.WARN)
    return
  end

  -- Save buffer first
  if session_buf and vim.api.nvim_buf_is_valid(session_buf) then
    vim.api.nvim_buf_call(session_buf, function()
      vim.cmd("silent write")
    end)
  end

  rpc_request("send", { content = message })
end

function M.new_message()
  if not session_buf or not vim.api.nvim_buf_is_valid(session_buf) then
    M.open()
    -- Wait a bit for file to open
    vim.defer_fn(M.new_message, 100)
    return
  end

  local timestamp = os.date("%H:%M")
  local template = {
    "",
    "---",
    "",
    "## " .. config.user_name .. " [" .. timestamp .. "]",
    "",
    "",
  }

  vim.api.nvim_buf_set_lines(session_buf, -1, -1, false, template)
  
  -- Move cursor to message area and enter insert mode
  local line_count = vim.api.nvim_buf_line_count(session_buf)
  local win = find_buffer_window(session_buf)
  if win then
    vim.api.nvim_win_set_cursor(win, { line_count, 0 })
    vim.cmd("startinsert")
  end
end

function M.archive()
  rpc_request("archive", {})
  vim.notify("[moltstream] Session archived", vim.log.levels.INFO)
end

function M.status()
  rpc_request("status", {})
end

function M.reconnect()
  rpc_request("reconnect", {})
end

function M.stop()
  if job_id then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
end

return M
