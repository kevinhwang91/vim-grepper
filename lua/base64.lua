-- -- LuaJIT
-- local extract
-- if _G.bit then
--     local lsh, rsh, band = _G.bit.lshift, _G.bit.rshift, _G.bit.band
--     extract = function(v, from, width)
--         return band(rsh(v, from), lsh(1, width) - 1)
--     end
-- else
--     extract = function(v, from, width)
--         local w = 0
--         local flag = 2 ^ from
--         for i = 0, width - 1 do
--             local flag2 = flag + flag
--             if v % flag2 >= flag then
--                 w = w + 2 ^ i
--             end
--             flag = flag2
--         end
--         return w
--     end
-- end
-- local encoder = {}
-- local function new(c62, c63, cpad)
--     for i, c in pairs {
--         'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R',
--         'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j',
--         'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '0', '1',
--         '2', '3', '4', '5', '6', '7', '8', '9', c62 or '+', c63 or '/', cpad or '='
--     } do
--         encoder[i] = c:byte()
--     end
-- end
-- function encode(str)
--     local dst = {}
--     local n = math.floor(#str / 3) * 3
--     local si = 0
--     while si < n do
--         local sb1, sb2, sb3 = str:byte(si, si + 2)
--         local val = bit.band(bit.lshift(sb1, 16), bit.lshift(sb2, 8), sb3)
--         table.insert(dst, string.char(encoder[ex], ...))
--     end
-- end
--
--
local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function _G.dec(data)
    data = string.gsub(data, '[^' .. b .. '=]', '')
    return data:gsub('.', function(x)
        if (x == '=') then
            return ''
        end
        local r, f = '', (b:find(x) - 1)
        for i = 6, 1, -1 do
            r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0')
        end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then
            return ''
        end
        local c = 0
        for i = 1, 8 do
            c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0)
        end
        return string.char(c)
    end)
end

