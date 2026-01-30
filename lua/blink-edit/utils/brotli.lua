--- Brotli compression using LuaJIT FFI
-- Pure Lua implementation, no IO required
-- Based on https://github.com/sjnam/luajit-brotli

local M = {}

local has_ffi, ffi = pcall(require, "ffi")
if not has_ffi then
  -- Fallback: return nil to indicate brotli is not available
  M.compress = function() return nil, "FFI not available" end
  M.is_available = function() return false end
  return M
end

-- Try to load the brotli library
local brotli_lib = nil
local lib_names = {
  "libbrotlienc.so.1",
  "libbrotlienc.so",
  "libbrotlienc.dylib",
  "brotlienc.dll",
}

for _, name in ipairs(lib_names) do
  local ok, lib = pcall(ffi.load, name)
  if ok then
    brotli_lib = lib
    break
  end
end

if not brotli_lib then
  -- Fallback: brotli library not found
  M.compress = function() return nil, "brotli library not found" end
  M.is_available = function() return false end
  return M
end

-- Brotli encoder FFI definitions
ffi.cdef[[
  typedef enum {
    BROTLI_MODE_GENERIC = 0,
    BROTLI_MODE_TEXT = 1,
    BROTLI_MODE_FONT = 2
  } BrotliEncoderMode;

  typedef struct BrotliEncoderStateStruct BrotliEncoderState;

  BrotliEncoderState* BrotliEncoderCreateInstance(
    void* alloc_func,
    void* free_func,
    void* opaque
  );

  void BrotliEncoderDestroyInstance(BrotliEncoderState* state);

  int BrotliEncoderCompressStream(
    BrotliEncoderState* state,
    int op,
    size_t* available_in,
    const uint8_t** next_in,
    size_t* available_out,
    uint8_t** next_out,
    size_t* total_out
  );

  int BrotliEncoderIsFinished(BrotliEncoderState* state);

  size_t BrotliEncoderMaxCompressedSize(size_t input_size);

  int BrotliEncoderCompress(
    int quality,
    int lgwin,
    int mode,
    size_t input_size,
    const uint8_t* input_buffer,
    size_t* encoded_size,
    uint8_t* encoded_buffer
  );
]]

-- Operation codes for streaming API
local BROTLI_OPERATION_PROCESS = 0
local BROTLI_OPERATION_FLUSH = 1
local BROTLI_OPERATION_FINISH = 2

--- Check if brotli compression is available
---@return boolean
function M.is_available()
  return true
end

--- Compress data using brotli
---@param input string The data to compress
---@param quality number|nil Compression quality (0-11, default: 1)
---@return string|nil compressed The compressed data, or nil on error
---@return string|nil error Error message if compression failed
function M.compress(input, quality)
  quality = quality or 1
  local lgwin = 22  -- Window size (as used by Zed)
  local mode = 0    -- BROTLI_MODE_GENERIC

  -- Calculate max compressed size
  local max_size = brotli_lib.BrotliEncoderMaxCompressedSize(#input)

  -- Allocate output buffer
  local output_buf = ffi.new("uint8_t[?]", max_size)
  local output_size = ffi.new("size_t[1]", max_size)

  -- Compress
  local result = brotli_lib.BrotliEncoderCompress(
    quality,
    lgwin,
    mode,
    #input,
    input,
    output_size,
    output_buf
  )

  if result == 0 then
    return nil, "Brotli compression failed"
  end

  -- Convert to Lua string
  return ffi.string(output_buf, output_size[0])
end

return M
