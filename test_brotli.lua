-- Test script to verify brotli compression and curl request

local brotli = require("blink-edit.utils.brotli")

-- Test payload
local payload = vim.json.encode({
  debug_info = "test",
  repo_name = "test",
  file_path = "test.lua",
  file_contents = "local x = 1",
  cursor_position = 0,
  original_file_contents = "local x = 1",
  recent_changes = "",
  file_chunks = {},
  retrieval_chunks = {},
  recent_user_actions = {},
  multiple_suggestions = false,
  privacy_mode_enabled = false,
  changes_above_cursor = true,
  use_bytes = true,
})

print("Original payload length: " .. #payload)

-- Compress
if not brotli.is_available() then
  print("ERROR: Brotli not available")
  return
end

local compressed, err = brotli.compress(payload, 1)
if not compressed then
  print("ERROR: Compression failed: " .. (err or "unknown"))
  return
end

print("Compressed length: " .. #compressed)
print("Compressed data (hex): " .. vim.fn.str2hex(compressed:sub(1, 50)))

-- Save to temp file for verification
local temp_file = vim.fn.tempname() .. ".br"
local f = io.open(temp_file, "wb")
if f then
  f:write(compressed)
  f:close()
  print("Saved to: " .. temp_file)
  
  -- Verify with brotli CLI
  local cmd = "brotli -t " .. temp_file .. " 2>&1"
  local result = vim.fn.system(cmd)
  if vim.v.shell_error == 0 then
    print("Brotli CLI verification: OK")
  else
    print("Brotli CLI verification: FAILED - " .. result)
  end
  
  os.remove(temp_file)
else
  print("ERROR: Could not write temp file")
end

-- Test vim.system with binary data
local token = os.getenv("SWEEP_AI_TOKEN")
if not token then
  print("ERROR: SWEEP_AI_TOKEN not set")
  return
end

print("\nTesting vim.system with binary data...")

local job = vim.system({
  "curl", "-s", "-S",
  "-X", "POST",
  "-H", "Content-Type: application/json",
  "-H", "Authorization: Bearer " .. token,
  "-H", "Content-Encoding: br",
  "--max-time", "10",
  "-w", "\n%{http_code}",
  "-D", "-",
  "--data-binary", "@-",
  "https://autocomplete.sweep.dev/backend/next_edit_autocomplete"
}, {
  stdin = compressed,
  timeout = 10000,
}, function(result)
  vim.schedule(function()
    print("Exit code: " .. result.code)
    if result.stderr and #result.stderr > 0 then
      print("Stderr: " .. result.stderr)
    end
    if result.stdout then
      print("Stdout length: " .. #result.stdout)
      print("Stdout preview: " .. result.stdout:sub(1, 200))
    end
  end)
end)

-- Wait for job to complete
vim.wait(15000, function()
  return job.is_closing == true
end)
