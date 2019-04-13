local basic_serializer = require "kong.plugins.log-serializers.basic"
local BasePlugin = require "kong.plugins.base_plugin"
local BatchQueue = require "kong.tools.batch_queue"
local cjson = require "cjson"
local url = require "socket.url"
local http = require "resty.http"


local cjson_encode = cjson.encode
local ngx_encode_base64 = ngx.encode_base64


local HttpLogHandler = BasePlugin:extend()


HttpLogHandler.PRIORITY = 12
HttpLogHandler.VERSION = "1.0.0"


local queues = {} -- queues per-route


-- Parse host url.
-- @param `url` host url
-- @return `parsed_url` a table with host details:
-- scheme, host, port, path, query, userinfo
local function parse_url(host_url)
  local parsed_url = url.parse(host_url)
  if not parsed_url.port then
    if parsed_url.scheme == "http" then
      parsed_url.port = 80
    elseif parsed_url.scheme == "https" then
      parsed_url.port = 443
    end
  end
  if not parsed_url.path then
    parsed_url.path = "/"
  end
  return parsed_url
end


-- Sends the provided payload (a string) to the configured plugin host
-- @return true if everything was sent correctly, falsy if error
-- @return error message if there was an error
local function send_payload(self, conf, payload)
  local method = conf.method
  local timeout = conf.timeout
  local keepalive = conf.keepalive
  local content_type = conf.content_type
  local http_endpoint = conf.http_endpoint

  local ok, err
  local parsed_url = parse_url(http_endpoint)
  local host = parsed_url.host
  local port = tonumber(parsed_url.port)

  local httpc = http.new()
  httpc:set_timeout(timeout)
  ok, err = httpc:connect(host, port)
  if not ok then
    kong.log.err("failed to connect to ", host, ":", tostring(port), ": ", err)
    return false
  end

  if parsed_url.scheme == "https" then
    local _, err = httpc:ssl_handshake(true, host, false)
    if err then
      kong.log.err("failed to do SSL handshake with ",
                   host, ":", tostring(port), ": ", err)
      return false
    end
  end

  local res, err = httpc:request({
    method = method,
    path = parsed_url.path,
    query = parsed_url.query,
    headers = {
      ["Host"] = parsed_url.host,
      ["Content-Type"] = content_type,
      ["Content-Length"] = #payload,
      ["Authorization"] = parsed_url.userinfo and (
        "Basic " .. ngx_encode_base64(parsed_url.userinfo)
      ),
    },
    body = payload,
  })
  if not res then
    kong.log.err("failed request to ", host, ":", tostring(port), ": ", err)
    httpc:set_keepalive(keepalive)
    return false
  end

  -- read and discard response body
  -- TODO should we fail if response status was >= 500 ?
  res:read_body()

  ok, err = httpc:set_keepalive(keepalive)
  if not ok then
    kong.log.err("failed keepalive for ", host, ":", tostring(port), ": ", err)
  end

  return true
end


local function json_array_concat(entries)
  return "[" .. table.concat(entries, ",") .. "]"
end


-- Only provide `name` when deriving from this class,
-- not when initializing an instance.
function HttpLogHandler:new(name)
  name = name or "http-log"
  HttpLogHandler.super.new(self, name)

  self.name = name
end


function HttpLogHandler:log(conf)
  HttpLogHandler.super.log(self)

  local entry = cjson_encode(basic_serializer.serialize(ngx))

  local route_id = conf.route_id or "global"
  local q = queues[route_id]
  if not q then
    -- base delay between batched sends
    conf.send_delay = 0

    -- batch_max_size <==> conf.queue_size
    local batch_max_size = conf.queue_size or 1
    local process = function(entries)
      local payload = batch_max_size == 1
                      and entries[1]
                      or  json_array_concat(entries)
      return send_payload(self, conf, payload)
    end

    local opts = {
      retry_count    = conf.retry_count,
      flush_timeout  = conf.flush_timeout,
      batch_max_size = batch_max_size,
      process_delay  = conf.send_delay, -- process_delay <==> conf.send_delay
    }

    local err
    q, err = BatchQueue.new(process, opts)
    if not q then
      kong.log.err("could not create queue: ", err)
      return
    end
    queues[route_id] = q
  end

  q:add(entry)
end

return HttpLogHandler
