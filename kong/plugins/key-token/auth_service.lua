local http = require "socket.http"


local default_payload = "123456"
local _M = {}

function _M.request(req)
  kong.log.inspect(req)
  if string.find(req.url, "localhost") then
    -- mock the http request
    return default_payload, 200, req.headers, "200 OK"
  else
    return http.request(req)
  end
end


return _M
