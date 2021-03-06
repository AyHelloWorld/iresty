local require      = require
local server       = require "resty.websocket.server"
local setmetatable = setmetatable
local ngx          = ngx
local var          = ngx.var
local flush        = ngx.flush
local abort        = ngx.on_abort
local kill         = ngx.thread.kill
local spawn        = ngx.thread.spawn
local sub          = string.sub
local ipairs       = ipairs
local select       = select
local mt, handler  = {}, {}
local noop         = function() end
function mt:__call(self, context, ...)
    local self = setmetatable(self, handler)
    self.n = select("#", ...)
    self.args = { ... }
    self.context = context
    self.route = context.route
    self:upgrade()
    local websocket, e = server:new(self)
    if not websocket then self.route:error(e) end
    self.websocket = websocket
    abort(self.abort(self))
    self:connect()
    flush(true)
    local d, t = websocket:recv_frame()
    while not websocket.fatal do
        if not d then
            self:timeout()
        else
            if not t then t = "unknown" end
            if self[t] then self[t](self, d) end
        end
        d, t = websocket:recv_frame()
    end
    self:close()
end
handler.__index = handler
function handler:upgrading() end
function handler:upgrade()
    self.upgrade = noop
    self:upgrading();
    local host = var.host
    local s =  #var.scheme + 4
    local e = #host + s - 1
    if sub(var.http_origin or "", s, e) ~= host then
        return self:forbidden()
    end
    self:upgraded();
end
function handler:upgraded() end
function handler:connect() end
function handler:timeout()
    local websocket = self.websocket
    local _, e = websocket:send_ping()
    if websocket.fatal then
        self:error(e)
    end
end
function handler:continuation() end
function handler:text() end
function handler:binary() end
function handler:closign() end
function handler:close()
    self.close = noop
    self:closing();
    local threads = self.threads
    if threads then
        for _, v in ipairs(self.threads) do
            kill(v)
        end
    end
    self.threads = {}
    if not self.websocket.fatal then
        local b, e = self.websocket:send_close()
        if not b and self.websocket.fatal then
            return self:error(e)
        else
            return self.websocket.fatal and self:error(e) or self.route:exit()
        end
    end
    self:closed();
end
function handler:closed() end
function handler:forbidden()
    return self.route:forbidden()
end
function handler:error(message)
    local threads = self.threads
    if threads then
        for _, v in ipairs(self.threads) do
            kill(v)
        end
    end
    self.threads = {}
    if not self.websocket.fatal then
        local d, e = self.websocket:send_close()
        if not d and self.websocket.fatal then
            return self.route:error(message or e)
        else
            return self.websocket.fatal and self.route:error(message or e) or self.route:exit()
        end
    end
end
function handler.abort(self)
    return function() self:close() end
end
function handler:ping()
    local b, e = self.websocket:send_pong()
    if not b and self.websocket.fatal then
        if not b then return self:error(e) end
    end
end
function handler:pong() end
function handler:unknown() end
function handler:send(text)
    local b, e = self.websocket:send_text(text)
    if not b and self.websocket.fatal then
        return self:error(e)
    end
end
function handler:spawn(...)
    if not self.threads then self.threads = {} end
    self.threads[#self.threads+1] = spawn(...)
end
return setmetatable(handler, mt)