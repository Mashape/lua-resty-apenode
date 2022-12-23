-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"
local Schema = require "kong.db.schema"

local PROTECTED_TAGS = {
  "error",
  "http.method",
  "http.path",
  "http.status_code",
  "kong.balancer.state",
  "kong.balancer.try",
  "kong.consumer",
  "kong.credential",
  "kong.node.id",
  "kong.route",
  "kong.service",
  "lc",
  "peer.hostname",
}

local static_tag = Schema.define {
  type = "record",
  fields = {
    { name = { type = "string", required = true, not_one_of = PROTECTED_TAGS } },
    { value = { type = "string", required = true } },
  },
}

local validate_static_tags = function(tags)
  if type(tags) ~= "table" then
    return true
  end
  local found = {}
  for i = 1, #tags do
    local name = tags[i].name
    if found[name] then
      return nil, "repeated tags are not allowed: " .. name
    end
    found[name] = true
  end
  return true
end

return {
  name = "zipkin",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
        type = "record",
        fields = {
          { local_service_name = { type = "string", required = true, default = "kong" } },
          { http_endpoint = typedefs.url },
          { sample_ratio = { type = "number",
                             default = 0.001,
                             between = { 0, 1 } } },
          { default_service_name = { type = "string", default = nil } },
          { include_credential = { type = "boolean", required = true, default = true } },
          { traceid_byte_count = { type = "integer", required = true, default = 16, one_of = { 8, 16 } } },
          { header_type = { type = "string", required = true, default = "preserve",
                            one_of = { "preserve", "ignore", "b3", "b3-single", "w3c", "jaeger", "ot", "datadog" } } },
          { default_header_type = { type = "string", required = true, default = "b3",
                                    one_of = { "b3", "b3-single", "w3c", "jaeger", "ot", "datadog" } } },
          { tags_header = { type = "string", required = true, default = "Zipkin-Tags" } },
          { static_tags = { type = "array", elements = static_tag,
                            custom_validator = validate_static_tags } },
          { http_span_name = { type = "string", required = true, default = "method", one_of = { "method", "method_path" } } },
          { connect_timeout = typedefs.timeout { default = 2000 } },
          { send_timeout = typedefs.timeout { default = 5000 } },
          { read_timeout = typedefs.timeout { default = 5000 } },
          { http_response_header_for_traceid = { type = "string", default = nil }},
          { phase_duration_flavor = { type = "string", required = true, default = "annotations",
                                      one_of = { "annotations", "tags" } } },
        },
    }, },
  },
}
