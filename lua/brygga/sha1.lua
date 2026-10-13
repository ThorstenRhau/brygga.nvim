-- SHA-1 for the WebSocket handshake (RFC 6455 requires it; Neovim only ships sha256).
local bit = require('bit')
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rol, tobit = bit.rol, bit.tobit

local M = {}

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
end

local function word_bytes(n)
  return string.char(
    band(bit.rshift(n, 24), 0xff),
    band(bit.rshift(n, 16), 0xff),
    band(bit.rshift(n, 8), 0xff),
    band(n, 0xff)
  )
end

--- Returns the 20-byte binary SHA-1 digest of `msg`.
---@param msg string
---@return string
function M.binary(msg)
  local len = #msg
  local bits = len * 8
  -- Pad: 0x80, zeros, then the 64-bit big-endian message length.
  local pad = 64 - ((len + 9) % 64)
  if pad == 64 then
    pad = 0
  end
  msg = msg
    .. '\128'
    .. string.rep('\0', pad)
    .. word_bytes(math.floor(bits / 0x100000000))
    .. word_bytes(tobit(bits % 0x100000000))

  local h0, h1, h2, h3, h4 =
    tobit(0x67452301), tobit(0xEFCDAB89), tobit(0x98BADCFE), tobit(0x10325476), tobit(0xC3D2E1F0)
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      w[i] = be32(msg, chunk + i * 4)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local temp = tobit(rol(a, 5) + f + e + k + w[i])
      a, b, c, d, e = temp, a, rol(b, 30), c, d
    end
    h0, h1, h2 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c)
    h3, h4 = tobit(h3 + d), tobit(h4 + e)
  end
  return word_bytes(h0) .. word_bytes(h1) .. word_bytes(h2) .. word_bytes(h3) .. word_bytes(h4)
end

return M
