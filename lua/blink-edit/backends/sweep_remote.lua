--- Sweep Remote API backend for blink-edit
--- Connects to Sweep AI cloud service (https://autocomplete.sweep.dev)

local M = {}

local transport = require("blink-edit.transport")
local config = require("blink-edit.config")
local log = require("blink-edit.log")

-- =============================================================================
-- Byte Offset Conversion Helpers
-- =============================================================================

--- Convert line and column to byte offset in file content
---@param lines string[] Array of lines (without newline characters)
---@param line number 1-indexed line number
---@param col number 0-indexed column
---@return number byte_offset 0-indexed byte offset
local function line_col_to_byte_offset(lines, line, col)
  local offset = 0

  -- Add bytes for all complete lines before target line
  for i = 1, line - 1 do
    if lines[i] then
      offset = offset + #lines[i] + 1 -- +1 for newline
    end
  end

  -- Add column offset within the target line
  offset = offset + col

  return offset
end

--- Convert byte offset to line and column
---@param text string Full file content
---@param byte_offset number 0-indexed byte offset
---@return number line 1-indexed line number
---@return number col 0-indexed column
local function byte_offset_to_line_col(text, byte_offset)
  local line = 1
  local col = 0
  local current_offset = 0

  for i = 1, #text do
    if current_offset >= byte_offset then
      break
    end

    local char = text:sub(i, i)
    if char == "\n" then
      line = line + 1
      col = 0
    else
      col = col + 1
    end
    current_offset = current_offset + 1
  end

  return line, col
end

--- Apply completion at byte range and return modified content
---@param file_contents string Original file content
---@param start_index number Start byte offset (0-indexed)
---@param end_index number End byte offset (0-indexed)
---@param completion string Replacement text
---@return string modified_content
local function apply_byte_replacement(file_contents, start_index, end_index, completion)
  local before = file_contents:sub(1, start_index)
  local after = file_contents:sub(end_index + 1)
  return before .. completion .. after
end

-- =============================================================================
-- Request Payload Building
-- =============================================================================

--- Get project/repo name from git or directory
---@return string
local function get_repo_name()
  -- Try to get git repo name
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
      result = result:gsub("\n", "")
      return vim.fn.fnamemodify(result, ":t")
    end
  end

  -- Fallback to cwd name
  return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

--- Build diff string from history entries
---@param history BlinkEditHistoryEntry[]
---@return string
local function build_recent_changes(history)
  if not history or #history == 0 then
    return ""
  end

  local changes = {}
  for _, entry in ipairs(history) do
    local diff_str = string.format(
      "--- %s\n+++ %s\n@@ -%d +%d @@\n-%s\n+%s",
      entry.filepath or "file",
      entry.filepath or "file",
      entry.start_line_old or 1,
      entry.start_line_new or 1,
      entry.original or "",
      entry.updated or ""
    )
    table.insert(changes, diff_str)
  end

  return table.concat(changes, "\n\n")
end

--- Build file_chunks from LSP locations and recent files
---@param lsp_definitions BlinkEditLspLocation[]
---@param lsp_references BlinkEditLspLocation[]
---@param recent_files table[]|nil
---@return table[]
local function build_file_chunks(lsp_definitions, lsp_references, recent_files)
  local chunks = {}
  local seen = {}

  -- Add LSP definitions
  for _, loc in ipairs(lsp_definitions or {}) do
    local key = string.format("%s:%d:%d", loc.filepath, loc.start_line, loc.end_line)
    if not seen[key] then
      seen[key] = true
      table.insert(chunks, {
        file_path = loc.filepath,
        start_line = loc.start_line,
        end_line = loc.end_line,
        content = table.concat(loc.lines, "\n"),
      })
    end
  end

  -- Add LSP references
  for _, loc in ipairs(lsp_references or {}) do
    local key = string.format("%s:%d:%d", loc.filepath, loc.start_line, loc.end_line)
    if not seen[key] then
      seen[key] = true
      table.insert(chunks, {
        file_path = loc.filepath,
        start_line = loc.start_line,
        end_line = loc.end_line,
        content = table.concat(loc.lines, "\n"),
      })
    end
  end

  -- Add recent files
  for _, file in ipairs(recent_files or {}) do
    local key = string.format("%s:%d:%d", file.filepath, 1, file.end_line or 30)
    if not seen[key] then
      seen[key] = true
      table.insert(chunks, {
        file_path = file.filepath,
        start_line = 1,
        end_line = file.end_line or 30,
        content = file.content or "",
      })
    end
  end

  return chunks
end

--- Build the Sweep API request payload
---@param context BlinkEditContextData
---@param baseline table
---@param snapshot table
---@param user_actions table[]|nil
---@param recent_files table[]|nil
---@return table
local function build_request_payload(context, baseline, snapshot, user_actions, recent_files)
  -- Join lines to get full file content
  local file_contents = table.concat(context.full_file_lines, "\n")
  local original_file_contents = table.concat(baseline.lines or {}, "\n")

  -- Calculate cursor byte position
  local cursor_position = line_col_to_byte_offset(context.full_file_lines, context.cursor.line, context.cursor.col)

  -- Build file chunks from LSP locations and recent files
  local file_chunks = build_file_chunks(context.lsp_definitions, context.lsp_references, recent_files)

  -- Build recent changes diff
  local recent_changes = build_recent_changes(context.history)

  return {
    debug_info = "blink-edit-nvim/1.0",
    repo_name = get_repo_name(),
    file_path = context.filepath,
    file_contents = file_contents,
    cursor_position = cursor_position,
    original_file_contents = original_file_contents,
    recent_changes = recent_changes,
    file_chunks = file_chunks,
    retrieval_chunks = {},
    recent_user_actions = user_actions or {},
    multiple_suggestions = false,
    privacy_mode_enabled = false,
    changes_above_cursor = true,
    use_bytes = true,
  }
end

-- =============================================================================
-- Response Processing
-- =============================================================================

--- Parse Sweep API response and extract window lines
---@param response table Sweep API response
---@param context BlinkEditContextData
---@return table|nil result { text: string, lines: string[] }
---@return string|nil error
local function parse_response(response, context)
  if not response then
    return nil, "empty response"
  end

  -- Check for empty/no completion
  if response.completion == nil or response.completion == "" then
    return nil, "no completion"
  end

  -- Get byte offsets
  local start_index = response.start_index
  local end_index = response.end_index
  local completion = response.completion

  if start_index == nil or end_index == nil then
    return nil, "missing byte offsets"
  end

  -- Get original file content
  local file_contents = table.concat(context.full_file_lines, "\n")

  -- Apply the completion at byte range
  local modified_content = apply_byte_replacement(file_contents, start_index, end_index, completion)

  -- Split back into lines
  local modified_lines = vim.split(modified_content, "\n", { plain = true })

  -- Extract only the window region
  local window_start = context.current_window.start_line
  local window_end = context.current_window.end_line

  -- Adjust window_end if file got longer/shorter
  local new_window_end = window_start + (window_end - context.current_window.start_line)
  new_window_end = math.min(new_window_end, #modified_lines)

  local window_lines = {}
  for i = window_start, new_window_end do
    table.insert(window_lines, modified_lines[i] or "")
  end

  return {
    text = table.concat(window_lines, "\n"),
    lines = window_lines,
    confidence = response.confidence,
    autocomplete_id = response.autocomplete_id,
  }, nil
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Send a completion request to Sweep Remote API
---@param opts table { context: BlinkEditContextData, baseline: table, snapshot: table }
---@param callback fun(err: { type: string, message: string, code?: number }|nil, result: table|nil)
---@return number request_id for cancellation
function M.complete(opts, callback)
  local cfg = config.get()
  local sweep_cfg = cfg.backends.sweep_remote or {}

  -- Get API token from environment
  local token = os.getenv("SWEEP_AI_TOKEN")
  if not token or token == "" then
    vim.schedule(function()
      callback({ type = "auth", message = "SWEEP_AI_TOKEN environment variable not set" }, nil)
    end)
    return -1
  end

  -- Get user actions and recent files from state (if available)
  local user_actions = nil
  local recent_files = nil

  local ok_actions, user_actions_module = pcall(require, "blink-edit.core.user_actions")
  if ok_actions and user_actions_module then
    local bufnr = vim.api.nvim_get_current_buf()
    user_actions = user_actions_module.get_recent_actions(bufnr, 50)
  end

  local ok_state, state_module = pcall(require, "blink-edit.core.state")
  if ok_state and state_module and state_module.get_recent_files then
    recent_files = state_module.get_recent_files(opts.context.filepath, 3)
  end

  -- Build request payload
  local payload = build_request_payload(opts.context, opts.baseline, opts.snapshot, user_actions, recent_files)

  -- Build URL
  local url = sweep_cfg.url or "https://autocomplete.sweep.dev"
  local endpoint = sweep_cfg.endpoint or "/backend/next_edit_autocomplete"

  local request_id = transport.request({
    url = url .. endpoint,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. token,
    },
    body = vim.json.encode(payload),
    timeout = cfg.llm.timeout_ms,
  }, function(err, response)
    if err then
      callback(err, nil)
      return
    end

    -- Parse response
    local body = response.body
    if type(body) == "string" then
      local ok, decoded = pcall(vim.json.decode, body)
      if not ok then
        callback({ type = "parse", message = "Failed to parse JSON response" }, nil)
        return
      end
      body = decoded
    end

    -- Check for API errors
    if body.error then
      local error_msg = body.error.message or body.error or vim.inspect(body.error)
      callback({
        type = "server",
        message = "API error: " .. tostring(error_msg),
        code = response.status,
      }, nil)
      return
    end

    -- Parse the response and extract window lines
    local result, parse_err = parse_response(body, opts.context)
    if not result then
      callback({ type = "parse", message = parse_err or "Failed to parse response" }, nil)
      return
    end

    -- Log confidence if debugging
    if vim.g.blink_edit_debug and result.confidence then
      log.debug(string.format("Sweep confidence: %.2f", result.confidence))
    end

    callback(nil, {
      text = result.text,
      lines = result.lines,
    })
  end)

  return request_id
end

--- Check if Sweep Remote backend is available
---@param callback fun(available: boolean, message: string)
function M.health_check(callback)
  local token = os.getenv("SWEEP_AI_TOKEN")
  if not token or token == "" then
    callback(false, "SWEEP_AI_TOKEN environment variable not set")
    return
  end

  -- Just verify token is set - we can't easily ping the API without a request
  callback(true, "SWEEP_AI_TOKEN is configured")
end

return M
