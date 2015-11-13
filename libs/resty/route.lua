local require = require
local encode = require "cjson.safe".encode
local handler = require "resty.route.websocket.handler"
local setmetatable = setmetatable
local select = select
local ipairs = ipairs
local pairs = pairs
local type = type
local unpack = table.unpack or unpack
local pack = table.pack
local ngx = ngx
local var = ngx.var
local log = ngx.log
local redirect = ngx.redirect
local header = ngx.header
local exit = ngx.exit
local exec = ngx.exec
local print = ngx.print
local ngx_ok = ngx.OK
local ngx_err = ngx.ERR
local http_ok = ngx.HTTP_OK
local http_error = ngx.HTTP_INTERNAL_SERVER_ERROR
local http_forbidden = ngx.HTTP_FORBIDDEN
local http_not_found = ngx.HTTP_NOT_FOUND
if not pack then
    pack = function(...)
        return { n = select("#", ...), ... }
    end
end
local methods = {
    get       = "GET",
    head      = "HEAD",
    post      = "POST",
    put       = "PUT",
    patch     = "PATCH",
    delete    = "DELETE",
    options   = "OPTIONS",
    link      = "LINK",
    unlink    = "UNLINK",
    trace     = "TRACE",
    websocket = "websocket"
}
local verbs = {}
for k, v in pairs(methods) do
    verbs[v] = k
end
local function tofunction(f, m)
    local t = type(f)
    if t == "function" then
        return f
    elseif t == "table" then
        if m then
            return tofunction(f[m])
        else
            return f
        end
    elseif t == "string" then
        return tofunction(require(f), m)
    end
    return nil
end
local function websocket(route, location, pattern, self)
    local match = route.matcher
    return (function(...)
        if select(1, ...) then
            return true, handler(self, route, ...)
        end
    end)(match(location, pattern))
end
local function router(route, location, pattern, self)
    local match = route.matcher
    return (function(...)
        if select(1, ...) then
            return true, self(route, ...)
        end
    end)(match(location, pattern))
end
local function filter(route, location, pattern, self)
    if pattern then
        return router(route, location, pattern, self)
    else
        return true, self(route)
    end
end
local function runfilters(location, method, filters)
    if filters then
        for _, filter in ipairs(filters) do
            filter(location)
        end
        local mfilters = filters[method]
        if mfilters then
            for _, filter in ipairs(mfilters) do
                filter(location)
            end
        end
    end
end
local route = {}
route.__index = route
function route.new(opts)
    local m, t = "simple", type(opts)
    if t == "table" then
        if opts.matcher then m = opts.matcher end
    end
    local self = setmetatable({}, route)
    self.context = { route = self }
    self.context.context = self.context
    if m then
        self:with(m)
    end
    return self
end
function route:use(middleware)
    return tofunction("resty.route.middleware." .. middleware)(self)
end
function route:with(matcher)
    self.matcher = require("resty.route.matchers." .. matcher)
    return self
end
function route:match(location, pattern)
    return self.matcher(location, pattern)
end
function route:filter(pattern, phase)
    if not self.filters then
        self.filters = {}
    end
    if not self.filters[phase] then
        self.filters[phase] = {}
    end
    local c = self.filters[phase]
    local t = type(pattern)
    if t == "string" then
        if methods[pattern] then
            if not c[pattern] then
                c[pattern] = {}
            end
            c = c[pattern]
            pattern = nil
        end
        return function(filters)
            if type(filters) == "table" then
                for _, func in ipairs(filters) do
                    local f = tofunction(func, phase)
                    c[#c+1] = function(location)
                        return filter(self, location, pattern, f)
                    end
                end
            else
                local f = tofunction(filters, phase)
                c[#c+1] = function(location)
                    return filter(self, location, pattern, f)
                end
            end
        end
    elseif t == "table" then
        for _, func in ipairs(pattern) do
            local f = tofunction(func, phase)
            c[#c+1] = function(location)
                return filter(self, location, nil, f)
            end
        end
    else
        local f = tofunction(pattern, phase)
        c[#c+1] = function(location)
            return filter(self, location, nil, f)
        end
    end
    return self
end
function route:before(pattern)
    return self:filter(pattern, "before")
end
function route:after(pattern)
    return self:filter(pattern, "after")
end
function route:__call(pattern, method, func)
    if not self.routes then
        self.routes = {}
    end
    local c = self.routes
    if func then
        if not c[method] then
            c[method] = {}
        end
        local c = c[method]
        local f = tofunction(func, method)
        if method == "websocket" then
            c[#c+1] = function(location)
                return websocket(self, location, pattern, f)

            end
        else
            c[#c+1] = function(location)
                return router(self, location, pattern, f)
            end
        end
        return self
    else
        return function(routes)
            if type(routes) == "table" then
                if method then
                    if not c[method] then
                        c[method] = {}
                    end
                    local c = c[method]
                    local f = tofunction(routes)
                    if method == "websocket" then
                        c[#c+1] = function(location)
                            return websocket(self, location, pattern, f)
                        end
                    else
                        c[#c+1] = function(location)
                            return router(self, location, pattern, f)
                        end
                    end
                else
                    for method, func in pairs(routes) do
                        if not c[method] then
                            c[method] = {}
                        end
                        local c = c[method]
                        local f = tofunction(func, method)
                        if method == "websocket" then
                            c[#c+1] = function(location)
                                return websocket(self, location, pattern, f)
                            end
                        else
                            c[#c+1] = function(location)
                                return router(self, location, pattern, f)
                            end
                        end
                    end
                end
            else
                if not c[method] then
                    c[method] = {}
                end
                local c = c[method]
                local f = tofunction(routes, method)
                if method == "websocket" then
                    c[#c+1] = function(location)
                        return websocket(self, location, pattern, f)
                    end
                else
                    c[#c+1] = function(location)
                        return router(self, location, pattern, f)
                    end
                end
            end
            return self
        end
    end
end
for _, v in pairs(verbs) do
    route[v] = function(self, pattern, func)
        return self(pattern, v, func)
    end
end
function route:exit(status, noaf)
    if not noaf then
        runfilters(self.location, self.method, self.filters and self.filters.after)
    end
    return ngx.headers_sent and exit(ngx_ok) or exit(status or ngx_ok)
end
function route:exec(uri, args, noaf)
    if not noaf then
        runfilters(self.location, self.method, self.filters and self.filters.after)
    end
    return exec(uri, args)
end
function route:redirect(uri, status, noaf)
    if not noaf then
        runfilters(self.location, self.method, self.filters and self.filters.after)
    end
    return redirect(uri, status)
end
function route:forbidden(noaf)
    return self:exit(http_forbidden, noaf)
end
function route:ok(noaf)
    return self:exit(http_ok, noaf)
end
function route:error(error, noaf)
    if error then
        log(ngx_err, error)
    end
    return self:exit(http_error, noaf)
end
function route:notfound(noaf)
    return self:exit(http_not_found, noaf)
end
function route:to(location, method)
    method = method or "get"
    self.location = location
    self.method = method
    local results
    local routes = self.routes
    if routes then
        routes = routes[method]
        if routes then
            for _, route in ipairs(routes) do
                local results = pack(route(location))
                if results.n > 0 then
                    return unpack(results, 1, results.n)
                end
            end
        end
    end
end
function route:render(content, context)
    local template = self.context.template
    if template then
        template.render(content, context or self.context)
    else
        print(content)
    end
    self:ok()
end
function route:json(data)
    if type(data) == "table" then
        data = encode(data)
    end
    header.content_type = "application/json"
    print(data)
    self:ok();
end
function route:dispatch()
    local location, method = var.uri, verbs[var.http_upgrade == "websocket" and "websocket" or var.request_method]
    runfilters(location, method, self.filters and self.filters.before)
    return self:to(location, method) and self:ok() or self:notfound()
end
return route