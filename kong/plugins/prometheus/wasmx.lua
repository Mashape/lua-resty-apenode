local buffer = require "string.buffer"
local wasm = require "kong.runloop.wasm"
local wasmx_shm


local pcall = pcall
local str_sub = string.sub
local table_insert = table.insert
local table_sort = table.sort
local buf_new = buffer.new
local ngx_say = ngx.say
local ngx_re_match = ngx.re.match


local _M = {}


local FLUSH_EVERY = 100
local GET_METRIC_OPTS = { prefix = false }

local export_enabled = false

local metrics_data_buf = buf_new()
local labels_serialization_buf = buf_new()
local sum_lines_buf = buf_new()
local count_lines_buf = buf_new()


local function sorted_iter(ctx, i)
  i = i + 1

  local v = ctx.t[ctx.sorted_keys[i]]

  if v ~= nil then
    return i, v
  end
end


local function sorted_pairs(t)
  local sorted_keys = {}

  for k, _ in pairs(t) do
    table_insert(sorted_keys, k)
  end

  table_sort(sorted_keys)

  return sorted_iter, { t = t, sorted_keys = sorted_keys }, 0
end

--
-- Convert a pw_key into a pair of metric name and labels
--
-- pw_key follows the form `pw:<filter_name>:<metric_name>`
-- `<metric_name>` might contain labels, e.g. a_metric_label1="v1";
-- if it does, the position of the first label corresponds to the end of the
-- metric name and is used to discard labels from <metric_name>.
local function parse_pw_key(pw_key)
  local m_name = pw_key
  local m_labels = {}
  local m_1st_label_pos = #pw_key

  local matches = ngx_re_match(pw_key, [[pw:([\w\.]+):]], "oj")
  local f_name = matches[1]
  local f_meta = wasm.filter_meta[f_name] or {}
  local l_patterns = f_meta.metrics and f_meta.metrics.label_patterns or {}

  local match_ctx = {}

  for _, pair in ipairs(l_patterns) do
    matches = ngx_re_match(pw_key, pair.pattern, "oj", match_ctx)

    if matches then
      local l_pos, value = match_ctx.pos - #matches[1], matches[2]

      table_insert(m_labels, { pair.label, value })

      m_1st_label_pos = (l_pos < m_1st_label_pos) and l_pos or m_1st_label_pos
    end
  end

  if m_1st_label_pos ~= #pw_key then
    -- discarding labels from m_name
    m_name = str_sub(pw_key, 1, m_1st_label_pos - 1)
  end

  return m_name, m_labels
end


--
-- Parse potential labels stored in the metric key
--
-- If no labels are present, key is simply the metric name.
local function parse_key(key)
  local name = key
  local labels

  if #key > 3 and key:sub(1, 3) == "pw:" then
    name, labels = parse_pw_key(key)
  end

  name = name:gsub(":", "_")

  return name, labels or {}
end


local function serialize_labels(labels)
  labels_serialization_buf:reset()

  for _, pair in ipairs(labels) do
    labels_serialization_buf:putf(',%s="%s"', pair[1], pair[2])
  end

  labels_serialization_buf:skip(1)  -- discard leading comma

  return "{" .. labels_serialization_buf:get() .. "}"
end


local function serialize_metric(m, buf)
  buf:putf("# HELP %s\n# TYPE %s %s", m.name, m.name, m.type)

  if m.type == "histogram" then
    sum_lines_buf:reset()
    count_lines_buf:reset()

    for _, pair in ipairs(m.labels) do
      local count, sum = 0, 0
      local labels, labeled_m = pair[1], pair[2]
      local slabels, blabels = "", "{"

      if #labels > 0 then
        slabels = serialize_labels(labels)
        blabels = slabels:sub(1, #slabels - 1) .. ","
      end

      for _, bin in ipairs(labeled_m.value) do
        count = count + bin.count

        buf:putf('\n%s%sle="%s"} %s',
                 m.name,
                 blabels,
                 (bin.ub ~= 4294967295 and bin.ub or "+Inf"),
                 count)
      end

      sum = sum + labeled_m.sum

      sum_lines_buf:putf("\n%s_sum%s %s", m.name, slabels, sum)
      count_lines_buf:putf("\n%s_count%s %s", m.name, slabels, count)
    end

    buf:put(sum_lines_buf:get())
    buf:put(count_lines_buf:get())

  else
    assert(m.type == "gauge" or m.type == "counter", "unknown metric type")

    for _, pair in ipairs(m.labels) do
      local labels, labeled_m = pair[1], pair[2]
      local slabels = (#labels > 0) and serialize_labels(labels) or ""

      buf:putf("\n%s%s %s", m.name, slabels, labeled_m.value)
    end
  end

  buf:put("\n")
end


local function require_wasmx()
  if not wasmx_shm then
    local ok, _wasmx_shm = pcall(require, "resty.wasmx.shm")
    if ok then
      wasmx_shm = _wasmx_shm
    end
  end
end


_M.metrics_data = function()
  if not export_enabled or not wasm.enabled() then
    return
  end

  local metrics = {}
  local parsed = {}

  -- delayed require of the WasmX module, to ensure it is loaded
  -- after ngx_wasm_module.so is loaded.
  require_wasmx()

  if not wasmx_shm then
    return
  end

  wasmx_shm.metrics:lock()

  for key in wasmx_shm.metrics:iterate_keys() do
    local pair = { key, wasmx_shm.metrics:get_by_name(key, GET_METRIC_OPTS) }
    table_insert(metrics, pair)
  end

  wasmx_shm.metrics:unlock()

  -- in WasmX the different labels of a metric are stored as separate metrics;
  -- aggregate those separate metrics into a single one.
  for _, pair in ipairs(metrics) do
    local key = pair[1]
    local m = pair[2]
    local name, labels = parse_key(key)

    parsed[name] = parsed[name] or { name = name, type = m.type, labels = {} }

    table_insert(parsed[name].labels, { labels, m })
  end

  metrics_data_buf:reset()

  for i, metric_by_label in sorted_pairs(parsed) do
    metrics_data_buf:put(serialize_metric(metric_by_label, metrics_data_buf))

    if i % FLUSH_EVERY == 0 then
      ngx_say(metrics_data_buf:get())
    end
  end

  ngx_say(metrics_data_buf:get())
end


function _M.set_enabled(enabled)
  export_enabled = enabled
end

return _M
