--- curl transport for HTTPS connections
--- Uses vim.system (Neovim 0.10+) for async execution
--- Requires: Neovim 0.11+

local M = {}

local log = require("blink-edit.log")

--- Make an HTTP request using curl via vim.system
---@param opts { url: string, method?: string, headers?: table<string, string>, body?: string, timeout?: number }
---@param callback fun(err: { type: string, message: string }|nil, response: { status: number, headers: table, body: string }|nil)
---@return table|nil job handle for cancellation
function M.request(opts, callback)
  local url = opts.url
  local method = opts.method or "POST"
  local timeout = opts.timeout or 5000
  local body = opts.body or ""

  -- Build curl arguments
  local args = {
    "-s", -- Silent mode
    "-S", -- Show errors
    "--compressed", -- Automatically decompress responses (brotli, gzip, etc.)
    "-X", method,
    "--max-time", tostring(timeout / 1000),
    "-w", "\n%{http_code}", -- Append status code
    "-D", "-", -- Dump headers to stdout
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

  local job = vim.system({"curl", unpack(args)}, {
    stdin = body and #body > 0 and body or nil,
    timeout = timeout,
  }, function(result)
    vim.schedule(function()
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

      -- Parse response
      local raw_output = result.stdout or ""
      log.debug(string.format("curl raw output length: %d", #raw_output))
      
      local output_lines = vim.split(raw_output, "\n")

      -- Find status code (last numeric line)
      local status_code = nil
      for i = #output_lines, 1, -1 do
        local line = output_lines[i]
        if line:match("^%d+$") then
          status_code = tonumber(line)
          table.remove(output_lines, i)
          break
        end
      end
      
      log.debug(string.format("curl status code: %s", tostring(status_code)))

      -- Parse headers and body
      local headers = {}
      local body_start = 1
      local in_headers = true

      for i, line in ipairs(output_lines) do
        if in_headers then
          if line == "" or line:match("^%s*$") then
            body_start = i + 1
            in_headers = false
          else
            local key, value = line:match("^([^:]+):%s*(.+)$")
            if key then
              headers[key:lower()] = value
            end
          end
        end
      end
      
      log.debug(string.format("curl body starts at line: %d of %d", body_start, #output_lines))

      -- Extract body
      local body_lines = {}
      for i = body_start, #output_lines do
        table.insert(body_lines, output_lines[i])
      end
      local response_body = table.concat(body_lines, "\n")
      log.debug(string.format("curl response body length: %d", #response_body))

      -- Parse JSON if applicable
      local json_body = nil
      if headers["content-type"] and headers["content-type"]:find("application/json") then
        local ok, decoded = pcall(vim.json.decode, response_body)
        if ok then
          json_body = decoded
        end
      end

      callback(nil, {
        status = status_code or 0,
        headers = headers,
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
