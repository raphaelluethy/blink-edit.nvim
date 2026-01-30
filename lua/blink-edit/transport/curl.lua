--- curl transport for HTTPS connections
--- Uses vim.system (Neovim 0.10+) for async execution
--- Requires: Neovim 0.11+

local M = {}

local log = require("blink-edit.log")

--- Check if jq is available
---@return boolean
local function jq_available()
  return vim.fn.executable("jq") == 1
end

--- Make an HTTP request using curl via vim.system
---@param opts { url: string, method?: string, headers?: table<string, string>, body?: string, timeout?: number }
---@param callback fun(err: { type: string, message: string }|nil, response: { status: number, headers: table, body: string }|nil)
---@return table|nil job handle for cancellation
function M.request(opts, callback)
  local url = opts.url
  local method = opts.method or "POST"
  local timeout = opts.timeout or 5000
  local body = opts.body or ""

  -- Build curl arguments - output only body, use jq to extract status
  local args = {
    "-s", -- Silent mode
    "-S", -- Show errors
    "--compressed", -- Automatically decompress responses (brotli, gzip, etc.)
    "-X", method,
    "--max-time", tostring(timeout / 1000),
    "-w", "\n%{http_code}", -- Append status code
  }

  -- Add custom headers
  if opts.headers then
    for key, value in pairs(opts.headers) do
      table.insert(args, "-H")
      table.insert(args, string.format("%s: %s", key, value))
    end
  end

  -- Add body via stdin for binary data support
  if body and #body > 0 then
    table.insert(args, "--data-binary")
    table.insert(args, "@-") -- Read from stdin
  end

  -- Add URL
  table.insert(args, url)

  log.debug("curl command: curl " .. table.concat(args, " "))
  log.debug("curl body length: " .. #body)
  
  local job = vim.system({"curl", unpack(args)}, {
    stdin = body and #body > 0 and body or nil,
    timeout = timeout,
  }, function(result)
    vim.schedule(function()
      log.debug(string.format("curl exit code: %d", result.code))
      if result.stderr and #result.stderr > 0 then
        log.debug(string.format("curl stderr: %s", result.stderr))
      end
      
      if result.code ~= 0 then
        local error_msg = result.stderr or ""
        if error_msg == "" then
          if result.code == 7 then
            error_msg = "Connection refused"
          elseif result.code == 28 then
            error_msg = "Request timed out"
          elseif result.code == 6 then
            error_msg = "Could not resolve host"
          else
            error_msg = "curl exited with code " .. result.code
          end
        end

        log.error(error_msg)
        callback({
          type = result.code == 28 and "timeout" or "curl_error",
          message = error_msg,
        }, nil)
        return
      end

      -- Parse response - split into body and status code
      local raw_output = result.stdout or ""
      log.debug(string.format("curl raw output length: %d", #raw_output))
      
      -- Find last newline to separate body from status code
      local last_newline = raw_output:find("\n[^\n]*$")
      local response_body = ""
      local status_code = 0
      
      if last_newline then
        response_body = raw_output:sub(1, last_newline - 1)
        local status_str = raw_output:sub(last_newline + 1):match("^%d+")
        if status_str then
          status_code = tonumber(status_str) or 0
        end
      else
        -- No newline found, entire output is body
        response_body = raw_output
      end
      
      log.debug(string.format("curl status code: %d", status_code))
      log.debug(string.format("curl response body length: %d", #response_body))

      -- Parse JSON if possible
      local json_body = nil
      if response_body and #response_body > 0 then
        local ok, decoded = pcall(vim.json.decode, response_body)
        if ok then
          json_body = decoded
        end
      end

      callback(nil, {
        status = status_code,
        headers = {}, -- Headers not parsed, but not needed for Sweep API
        body = json_body or response_body,
      })
    end)
  end)

  return job
end

--- Cancel a running curl request
---@param job table|nil The job handle returned by request()
function M.cancel(job)
  if job and job.kill then
    pcall(function() job:kill(9) end)
  end
end

return M
