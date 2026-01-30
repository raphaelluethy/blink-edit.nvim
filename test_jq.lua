package.path = package.path .. ';./lua/?.lua;./lua/?/init.lua'

local brotli = require('blink-edit.utils.brotli')
local token = os.getenv('SWEEP_AI_TOKEN')

local payload = vim.json.encode({
  debug_info = 'test',
  repo_name = 'test',
  file_path = 'test.lua',
  file_contents = 'local x = 1',
  cursor_position = 0,
  original_file_contents = 'local x = 1',
  recent_changes = '',
  file_chunks = {},
  retrieval_chunks = {},
  recent_user_actions = {},
  multiple_suggestions = false,
  privacy_mode_enabled = false,
  changes_above_cursor = true,
  use_bytes = true,
})

local compressed = brotli.compress(payload, 1)

-- Write compressed data to temp file
local tmpfile = vim.fn.tempname() .. '.br'
local f = io.open(tmpfile, 'wb')
f:write(compressed)
f:close()

-- Use jq to parse the response
local cmd = string.format(
  'curl -s -S -X POST -H "Content-Type: application/json" -H "Authorization: Bearer %s" -H "Content-Encoding: br" --max-time 10 --data-binary @%s https://autocomplete.sweep.dev/backend/next_edit_autocomplete | jq -r .',
  token, tmpfile
)

vim.system({'bash', '-c', cmd}, {timeout = 10000}, function(result)
  vim.schedule(function()
    print('Exit code: ' .. result.code)
    print('Stdout: ' .. (result.stdout or 'empty'))
    if result.stderr and #result.stderr > 0 then
      print('Stderr: ' .. result.stderr)
    end
    os.remove(tmpfile)
  end)
end)
