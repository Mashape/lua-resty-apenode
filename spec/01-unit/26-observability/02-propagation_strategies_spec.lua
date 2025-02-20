local propagation_utils = require "kong.observability.tracing.propagation.utils"
local bn = require "resty.openssl.bn"

local from_hex = propagation_utils.from_hex
local to_hex = require "resty.string".to_hex

local shallow_copy = require("kong.tools.table").shallow_copy
local fmt          = string.format
local sub          = string.sub

local EXTRACTORS_PATH = "kong.observability.tracing.propagation.extractors."
local INJECTORS_PATH  = "kong.observability.tracing.propagation.injectors."

local trace_id_16     = "0af7651916cd43dd8448eb211c80319c"
local trace_id_8      = "8448eb211c80319c"
local trace_id_8_dec  = "9532127138774266268" -- 8448eb211c80319c to decimal
local span_id_8_1     = "b7ad6b7169203331"
local span_id_8_1_dec = "13235353014750950193" -- b7ad6b7169203331 to decimal
local span_id_8_2     = "b7ad6b7169203332"

local big_trace_id     = "fffffffffffffff1"
local big_trace_id_16  = "fffffffffffffffffffffffffffffff1"
local big_span_id      = "fffffffffffffff3"
local big_dec_trace_id = bn.from_hex(big_trace_id):to_dec()
local big_dec_span_id  = bn.from_hex(big_span_id):to_dec()
local big_dec_trace_id_16 = bn.from_hex(big_trace_id_16):to_dec()

-- invalid IDs:
local too_long_id      = "1234567890123456789012345678901234567890"


local function from_hex_ids(t)
  local t1 = shallow_copy(t)
  t1.trace_id = t.trace_id and from_hex(t.trace_id) or nil
  t1.span_id = t.span_id and from_hex(t.span_id) or nil
  t1.parent_id = t.parent_id and from_hex(t.parent_id) or nil
  return t1
end

local function to_hex_ids(t)
  local t1 = shallow_copy(t)
  t1.trace_id = t.trace_id and to_hex(t.trace_id) or nil
  t1.span_id = t.span_id and to_hex(t.span_id) or nil
  t1.parent_id = t.parent_id and to_hex(t.parent_id) or nil
  return t1
end

local padding_prefix = string.rep("0", 16)

-- Input data (array) for running tests to test extraction and injection
-- (headers-to-context and context-to-headers):
--    {
--      extractor = "extractor-name",
--      injector = "injector-name",
--      headers_data = { {
--        description = "passing Tracing-Header-Name header",
--        extract = true, -- set to false to do skip extraction on this header data
--        inject = true,  -- set to false to do skip injection on this header data
--        trace_id = "123abcde",
--        headers = {
--          ["Tracing-Header-Name"] = "123abcde:12345:1",
--        },
--        ctx = {
--          trace_id = "123abcde",
--          span_id = "12345",
--          should_sample = true,
--        }
--      }
--    }
--
-- Headers_data item to test extraction error case:
--    {
--      description = "invalid ids",
--      extract = true,
--      headers = {
--        ["traceparent"] = "00-1-2-00",
--      },
--      err = "invalid trace ID; ignoring."
--    }
--
-- Headers_data item to test injection error cases:
--    {
--      description = "missing trace id",
--      inject = true,
--      ctx = {
--        span_id = "abcdef",
--      },
--      err = "injector context is invalid"
--    }

local test_data = { {
  extractor = "w3c",
  injector = "w3c",
  headers_data = { {
    description = "base case",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-01", trace_id_16, span_id_8_1),
    },
    ctx = {
      w3c_flags = 0x01,
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "extraction with sampling mask (on)",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-09", trace_id_16, span_id_8_1),
    },
    ctx = {
      w3c_flags = 0x09,
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "extraction with sampling mask (off)",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-08", trace_id_16, span_id_8_1),
    },
    ctx = {
      w3c_flags = 0x08,
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 16,
    }
  }, {
    description = "extraction with hex flags",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-ef", trace_id_16, span_id_8_1),
    },
    ctx = {
      w3c_flags = 0xef,
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-00", trace_id_16, span_id_8_1),
    },
    ctx = {
      w3c_flags = 0x00,
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 16,
    }
  }, {
    description = "default injection size is 16B",
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-01", trace_id_16, span_id_8_1),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
    }
  }, { -- extraction error cases
    description = "invalid header 1",
    extract = true,
    headers = {
      ["traceparent"] = fmt("vv-%s-%s-00", trace_id_16, span_id_8_1),
    },
    err = "invalid W3C traceparent header; ignoring."
  }, {
    description = "invalid header 2",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv-%s-00", span_id_8_1),
    },
    err = "invalid W3C traceparent header; ignoring."
  }, {
    description = "invalid header 3",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-vvvvvvvvvvvvvvvv-00", trace_id_16),
    },
    err = "invalid W3C traceparent header; ignoring."
  }, {
    description = "invalid header 4",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-vv", trace_id_16, span_id_8_1),
    },
    err = "invalid W3C traceparent header; ignoring."
  }, {
    description = "invalid trace id (too short)",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-00", "123", span_id_8_1),
    },
    err = "invalid W3C trace context trace ID; ignoring."
  }, {
    description = "invalid trace id (all zero)",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-00", "00000000000000000000000000000000", span_id_8_1),
    },
    err = "invalid W3C trace context trace ID; ignoring."
  }, {
    description = "invalid trace id (too long)",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-00", too_long_id, span_id_8_1),
    },
    err = "invalid W3C trace context trace ID; ignoring."
  }, {
    description = "invalid parent id (too short)",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-00", trace_id_16, "123"),
    },
    err = "invalid W3C trace context parent ID; ignoring."
  }, {
    description = "invalid parent id (too long)",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-00", trace_id_16, too_long_id),
    },
    err = "invalid W3C trace context parent ID; ignoring."
  }, {
    description = "invalid parent id (all zero)",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-00", trace_id_16, "0000000000000000"),
    },
    err = "invalid W3C trace context parent ID; ignoring."
  }, {
    description = "invalid version",
    extract = true,
    headers = {
      ["traceparent"] = fmt("01-%s-%s-00", trace_id_16, span_id_8_1),
    },
    err = "invalid W3C Trace Context version; ignoring."
  }, {
    description = "invalid flags 1",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-000", trace_id_16, span_id_8_1),
    },
    err = "invalid W3C trace context flags; ignoring."
  }, {
    description = "invalid flags 2",
    extract = true,
    headers = {
      ["traceparent"] = fmt("00-%s-%s-0", trace_id_16, span_id_8_1),
    },
    err = "invalid W3C trace context flags; ignoring."
  }, { -- injection error cases
    description = "missing trace id",
    inject = true,
    ctx = {
      span_id = span_id_8_1,
      should_sample = false,
    },
    err = "w3c injector context is invalid: field trace_id not found in context"
  }, {
    description = "missing span id",
    inject = true,
    ctx = {
      trace_id = trace_id_16,
      should_sample = false,
    },
    err = "w3c injector context is invalid: field span_id not found in context"
  } }
}, {
  extractor = "b3",
  injector = "b3",
  headers_data = { {
    description = "base case",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-b3-traceid"] = trace_id_16,
      ["x-b3-spanid"] = span_id_8_1,
      ["x-b3-parentspanid"] = span_id_8_2,
      ["x-b3-sampled"] = "1",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      flags = nil,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "sampling decision only",
    extract = true,
    inject = true,
    trace_id = "",
    headers = {
      ["x-b3-sampled"] = "0",
    },
    ctx = {
      should_sample = false,
      reuse_span_id = true,
    },
  }, {
    description = "sampled set via flags",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-b3-traceid"] = trace_id_16,
      ["x-b3-spanid"] = span_id_8_1,
      ["x-b3-parentspanid"] = span_id_8_2,
      ["x-b3-flags"] = "1",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      flags = "1",
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-b3-traceid"] = trace_id_16,
      ["x-b3-spanid"] = span_id_8_1,
      ["x-b3-parentspanid"] = span_id_8_2,
      ["x-b3-sampled"] = "0",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = false,
      flags = nil,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "8-byte trace ID",
    extract = true,
    inject = true,
    trace_id = trace_id_8,
    headers = {
      ["x-b3-traceid"] = trace_id_8,
      ["x-b3-spanid"] = span_id_8_1,
      ["x-b3-parentspanid"] = span_id_8_2,
      ["x-b3-sampled"] = "1",
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      flags = nil,
      trace_id_original_size = 8,
      reuse_span_id = true,
    }
  }, {
    description = "default injection size is 16B",
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-b3-traceid"] = trace_id_16,
      ["x-b3-spanid"] = span_id_8_1,
      ["x-b3-parentspanid"] = span_id_8_2,
      ["x-b3-sampled"] = "1",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      flags = nil,
    }
  }, { -- extraction error cases
    description = "invalid trace id",
    extract = true,
    trace_id = "x",
    headers = {
      ["x-b3-traceid"] = "x",
      ["x-b3-spanid"] = span_id_8_1,
      ["x-b3-parentspanid"] = span_id_8_2,
      ["x-b3-sampled"] = "0",
    },
    err = "x-b3-traceid header invalid; ignoring."
  } }
}, {
  extractor = "b3",
  injector = "b3-single",
  headers_data = { {
    description = "1-char header, sampled = true",
    extract = true,
    inject = true,
    trace_id = "",
    headers = {
      ["b3"] = "1",
    },
    ctx = {
      single_header = true,
      should_sample = true,
      reuse_span_id = true,
    }
  }, {
    description = "1-char header, sampled = false",
    extract = true,
    inject = true,
    trace_id = "",
    headers = {
      ["b3"] = "0",
    },
    ctx = {
      single_header = true,
      should_sample = false,
      reuse_span_id = true,
    }
  }, {
    description = "1-char header, debug",
    extract = true,
    inject = true,
    trace_id = "",
    headers = {
      ["b3"] = "d",
    },
    ctx = {
      single_header = true,
      should_sample = true,
      flags = "1",
      reuse_span_id = true,
    }
  }, {
    description = "all fields",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "1", span_id_8_2),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      single_header = true,
      should_sample = true,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "all fields, sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "0", span_id_8_2),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      single_header = true,
      should_sample = false,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "all fields, debug",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "d", span_id_8_2),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      single_header = true,
      should_sample = true,
      flags = "1",
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "extraction from tracestate",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["tracestate"] = "b3=" .. fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "d", span_id_8_2),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      single_header = true,
      should_sample = true,
      flags = "1",
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "extraction from tracestate multi-value",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["tracestate"] = {
        "test",
        "b3=" .. fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "1", span_id_8_2),
        "test2",
      }
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      single_header = true,
      should_sample = true,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "trace id and span id only: no sampled and no parent",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["b3"] = fmt("%s-%s", trace_id_16, span_id_8_1),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      single_header = true,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "no parent",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["b3"] = fmt("%s-%s-%s", trace_id_16, span_id_8_1, "1"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      single_header = true,
      should_sample = true,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "8-byte trace ID",
    extract = true,
    inject = true,
    trace_id = trace_id_8,
    headers = {
      ["b3"] = fmt("%s-%s-%s", trace_id_8, span_id_8_1, "1"),
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      single_header = true,
      should_sample = true,
      trace_id_original_size = 8,
      reuse_span_id = true,
    }
  }, {
    description = "default injection size is 16B",
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "d", span_id_8_2),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      single_header = true,
      should_sample = true,
      flags = "1",
    }
  }, {
    description = "big 16B trace ID",
    inject = true,
    trace_id = big_trace_id_16,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", big_trace_id_16, span_id_8_1, "d", span_id_8_2),
    },
    ctx = {
      trace_id = big_trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      single_header = true,
      should_sample = true,
      flags = "1",
    }
  }, { -- extraction error cases
    description = "invalid trace ID (non hex)",
    extract = true,
    trace_id = "abc",
    headers = {
      ["b3"] = fmt("xxx-%s-%s-%s", span_id_8_1, "1", span_id_8_2),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid trace ID (too long)",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", too_long_id, span_id_8_1, "1", span_id_8_2),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid trace ID (too short)",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", "123", span_id_8_1, "1", span_id_8_2),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "empty header",
    extract = true,
    headers = {
      ["b3"] = "",
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "no span id",
    extract = true,
    headers = {
      ["b3"] = trace_id_16 .. "-",
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "non hex span id",
    extract = true,
    headers = {
      ["b3"] = trace_id_16 .. "-xxx",
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid span id (too long)",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, too_long_id, "1", span_id_8_2),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid span id (too short)",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, "123", "1", span_id_8_2),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid sampled",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s", trace_id_16, span_id_8_1, "x"),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid parent",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "d", "xxx"),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid parent (too long)",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "d", too_long_id),
    },
    err = "b3 single header invalid; ignoring."
  }, {
    description = "invalid parent (too short)",
    extract = true,
    headers = {
      ["b3"] = fmt("%s-%s-%s-%s", trace_id_16, span_id_8_1, "d", "123"),
    },
    err = "b3 single header invalid; ignoring."
  } }
}, {
  extractor = "jaeger",
  injector = "jaeger",
  headers_data = { {
    description = "base case",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id_16, span_id_8_1, span_id_8_2, "01"),
      ["uberctx-foo"] = "bar",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      baggage = { foo = "bar" },
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id_16, span_id_8_1, span_id_8_2, "00"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = false,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "parent = 0",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id_16, span_id_8_1, "0", "01"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = "0000000000000000",
      should_sample = true,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "0-pad shorter span ID",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id_16, "123", span_id_8_2, "01"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = "0000000000000123",
      parent_id = span_id_8_2,
      should_sample = true,
      trace_id_original_size = 16,
      reuse_span_id = true,
    }
  }, {
    description = "0-pad shorter trace ID",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", "1234", span_id_8_1, span_id_8_2, "01"),
    },
    ctx = {
      trace_id = "00000000000000000000000000001234",
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      trace_id_original_size = 2,
      reuse_span_id = true,
    }
  }, {
    description = "8B trace ID",
    extract = true,
    inject = true,
    trace_id = trace_id_8,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id_8, span_id_8_1, span_id_8_2, "01"),
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      trace_id_original_size = 8,
      reuse_span_id = true,
    }
  }, {
    description = "default injection size is 16B",
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:%s", trace_id_16, span_id_8_1, span_id_8_2, "01"),
      ["uberctx-foo"] = "bar",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      parent_id = span_id_8_2,
      should_sample = true,
      baggage = { foo = "bar" },
    }
  }, { -- extraction error cases
    description = "invalid header 1",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("vv:%s:%s:%s", span_id_8_1, span_id_8_2, "00"),
    },
    err = "invalid jaeger uber-trace-id header; ignoring."
  }, {
    description = "invalid header 2",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:vv:%s:%s", trace_id_8, span_id_8_2, "00"),
    },
    err = "invalid jaeger uber-trace-id header; ignoring."
  }, {
    description = "invalid header 3",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:vv:%s", trace_id_8, span_id_8_1, "00"),
    },
    err = "invalid jaeger uber-trace-id header; ignoring."
  }, {
    description = "invalid header 4",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:vv", trace_id_8, span_id_8_1, span_id_8_2),
    },
    err = "invalid jaeger uber-trace-id header; ignoring."
  }, {
    description = "invalid trace id (too long)",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:00", too_long_id, span_id_8_1, span_id_8_2),
    },
    err = "invalid jaeger trace ID; ignoring."
  }, {
    description = "invalid trace id (all zero)",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:00", "00000000000000000000000000000000", span_id_8_1, span_id_8_2),
    },
    err = "invalid jaeger trace ID; ignoring."
  }, {
    description = "invalid parent id (too short)",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:00", trace_id_16, span_id_8_1, "ff"),
    },
    err = "invalid jaeger parent ID; ignoring."
  }, {
    description = "invalid parent id (too long)",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:00", trace_id_16, span_id_8_1, too_long_id),
    },
    err = "invalid jaeger parent ID; ignoring."
  }, {
    description = "invalid span id (too long)",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:00", trace_id_16, too_long_id, span_id_8_1),
    },
    err = "invalid jaeger span ID; ignoring."
  }, {
    description = "invalid span id (all zero)",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:00", trace_id_16, "00000000000000000000000000000000", span_id_8_1),
    },
    err = "invalid jaeger span ID; ignoring."
  }, {
    description = "invalid flags",
    extract = true,
    headers = {
      ["uber-trace-id"] = fmt("%s:%s:%s:123", trace_id_16, span_id_8_1, span_id_8_2),
    },
    err = "invalid jaeger flags; ignoring."
  }, { -- injection error cases
    description = "missing trace id",
    inject = true,
    ctx = {
      span_id = span_id_8_1,
      should_sample = false,
    },
    err = "jaeger injector context is invalid: field trace_id not found in context"
  }, {
    description = "missing span id",
    inject = true,
    ctx = {
      trace_id = trace_id_16,
      should_sample = false,
    },
    err = "jaeger injector context is invalid: field span_id not found in context"
  } }
}, {
  extractor = "ot",
  injector = "ot",
  headers_data = { {
    description = "base case",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["ot-tracer-traceid"] = trace_id_16,
      ["ot-tracer-spanid"] = span_id_8_1,
      ["ot-tracer-sampled"] = "1",
      ["ot-baggage-foo"] = "bar",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      baggage = { foo = "bar" },
      trace_id_original_size = 16,
    }
  }, {
    description = "sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["ot-tracer-traceid"] = trace_id_16,
      ["ot-tracer-spanid"] = span_id_8_1,
      ["ot-tracer-sampled"] = "0",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 16,
    }
  }, {
    description = "missing sampled flag",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["ot-tracer-traceid"] = trace_id_16,
      ["ot-tracer-spanid"] = span_id_8_1,
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      trace_id_original_size = 16,
    }
  }, {
    description = "large trace and span ids",
    extract = true,
    inject = true,
    trace_id = big_trace_id_16,
    headers = {
      ["ot-tracer-traceid"] = big_trace_id_16,
      ["ot-tracer-spanid"] = big_span_id,
      ["ot-baggage-foo"] = "bar",
    },
    ctx = {
      trace_id = big_trace_id_16,
      span_id = big_span_id,
      baggage = { foo = "bar" },
      trace_id_original_size = 16,
    }
  }, {
    description = "8B trace id",
    extract = true,
    inject = true,
    trace_id = trace_id_8,
    headers = {
      ["ot-tracer-traceid"] = trace_id_8,
      ["ot-tracer-spanid"] = span_id_8_1,
      ["ot-tracer-sampled"] = "0",
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 8,
    }
  }, {
    description = "default injection size is 8B",
    inject = true,
    trace_id = trace_id_8,
    headers = {
      ["ot-tracer-traceid"] = trace_id_8,
      ["ot-tracer-spanid"] = span_id_8_1,
      ["ot-tracer-sampled"] = "1",
      ["ot-baggage-foo"] = "bar",
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      should_sample = true,
      baggage = { foo = "bar" },
    }
  }, {
    description = "invalid baggage",
    extract = true,
    trace_id = trace_id_16,
    headers = {
      ["ot-tracer-traceid"] = trace_id_16,
      ["ot-tracer-spanid"] = span_id_8_1,
      ["ot-tracer-sampled"] = "1",
      ["otttttbaggage-foo"] = "bar",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      baggage = nil,
      trace_id_original_size = 16,
    }
  }, { -- extraction error cases
    description = "invalid header",
    extract = true,
    headers = {
      ["ot-tracer-traceid"] = "xx",
    },
    err = "ot-tracer-traceid header invalid; ignoring."
  }, { -- injection error cases
    description = "missing trace id",
    inject = true,
    ctx = {
      span_id = span_id_8_1,
      should_sample = false,
    },
    err = "ot injector context is invalid: field trace_id not found in context"
  }, {
    description = "missing span id",
    inject = true,
    ctx = {
      trace_id = trace_id_16,
      should_sample = false,
    },
    err = "ot injector context is invalid: field span_id not found in context"
  } }
}, {
  extractor = "datadog",
  injector = "datadog",
  headers_data = { {
    description = "base case",
    extract = true,
    inject = true,
    trace_id = trace_id_8_dec,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = span_id_8_1_dec,
      ["x-datadog-sampling-priority"] = "1",
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 8,
    }
  }, {
    description = "sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_8_dec,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = span_id_8_1_dec,
      ["x-datadog-sampling-priority"] = "0",
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 8,
    }
  }, {
    description = "missing trace id ignores parent id",
    extract = true,
    headers = {
      ["x-datadog-parent-id"] = span_id_8_1_dec,
      ["x-datadog-sampling-priority"] = "1",
    },
    ctx = {
      should_sample = true,
    }
  }, {
    description = "missing parent id",
    extract = true,
    inject = true,
    trace_id = trace_id_8_dec,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-sampling-priority"] = "1",
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      should_sample = true,
      trace_id_original_size = 8,
    }
  }, {
    description = "missing sampled",
    extract = true,
    inject = true,
    trace_id = trace_id_8_dec,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = span_id_8_1_dec,
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = span_id_8_1,
      trace_id_original_size = 8,
    }
  }, {
    description = "big dec trace id",
    extract = true,
    inject = true,
    trace_id = big_dec_trace_id,
    headers = {
      ["x-datadog-trace-id"] = big_dec_trace_id,
      ["x-datadog-parent-id"] = span_id_8_1_dec,
    },
    ctx = {
      trace_id = padding_prefix .. big_trace_id,
      span_id = span_id_8_1,
      trace_id_original_size = 8,
    }
  }, {
    description = "big dec span id",
    extract = true,
    inject = true,
    trace_id = trace_id_8_dec,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = big_dec_span_id,
    },
    ctx = {
      trace_id = padding_prefix .. trace_id_8,
      span_id = big_span_id,
      trace_id_original_size = 8,
    }
  }, {
    description = "(can extract invalid) big dec trace id 16",
    extract = true,
    trace_id = big_dec_trace_id,
    headers = {
      ["x-datadog-trace-id"] = big_dec_trace_id_16,
      ["x-datadog-parent-id"] = span_id_8_1_dec,
    },
    ctx = {
      trace_id = big_trace_id_16,
      span_id = span_id_8_1,
      trace_id_original_size = 16,
    }
  }, {
    description = "default injection size is 8B",
    inject = true,
    trace_id = trace_id_8_dec,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = span_id_8_1_dec,
      ["x-datadog-sampling-priority"] = "1",
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
    }
  }, { -- extraction error cases
    description = "invalid trace id",
    extract = true,
    trace_id = trace_id_16,
    headers = {
      ["x-datadog-trace-id"] = trace_id_16,
      ["x-datadog-parent-id"] = span_id_8_1_dec,
      ["x-datadog-sampling-priority"] = "1",
    },
    err = "x-datadog-trace-id header invalid; ignoring."
  }, {
    description = "invalid parent id",
    extract = true,
    trace_id = trace_id_16,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = span_id_8_1,
      ["x-datadog-sampling-priority"] = "1",
    },
    err = "x-datadog-parent-id header invalid; ignoring."
  }, {
    description = "empty string trace id",
    extract = true,
    trace_id = "",
    headers = {
      ["x-datadog-trace-id"] = "",
      ["x-datadog-parent-id"] = span_id_8_1_dec,
      ["x-datadog-sampling-priority"] = "1",
    },
    err = "x-datadog-trace-id header invalid; ignoring."
  }, {
    description = "invalid parent id",
    extract = true,
    trace_id = trace_id_16,
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = span_id_8_1,
      ["x-datadog-sampling-priority"] = "1",
    },
    err = "x-datadog-parent-id header invalid; ignoring."
  }, {
    description = "empty string parent id",
    extract = true,
    trace_id = "",
    headers = {
      ["x-datadog-trace-id"] = trace_id_8_dec,
      ["x-datadog-parent-id"] = "",
      ["x-datadog-sampling-priority"] = "1",
    },
    err = "x-datadog-parent-id header invalid; ignoring."
  } }
}, {
  extractor = "aws",
  injector = "aws",
  headers_data = { {
    description = "base case",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            span_id_8_1, "1"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "with spaces",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("  Root =   1-%s-%s  ;  Parent= %s;  Sampled   =%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            span_id_8_1, "1"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "parent first",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("Parent=%s;Root=1-%s-%s;Sampled=%s",
                            span_id_8_1,
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            "1"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "extra fields",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("Foo=bar;Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            span_id_8_1,
                            "1"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "large id",
    extract = true,
    inject = true,
    trace_id = big_trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(big_trace_id_16, 1, 8),
                            sub(big_trace_id_16, 9, #big_trace_id_16),
                            span_id_8_1,
                            "1"),
    },
    ctx = {
      trace_id = big_trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            span_id_8_1, "0"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 16,
    }
  }, {
    description = "default injection size is 16B",
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            span_id_8_1, "1"),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
    }
  }, { -- extraction error cases
    description = "invalid trace id 1",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=0-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_8, 1, 8),
                            sub(trace_id_8, 9, #trace_id_8),
                            span_id_8_1, "0"),
    },
    err = "invalid aws header trace id; ignoring."
  }, {
    description = "invalid trace id 2",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-vv-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_8, 9, #trace_id_8),
                            span_id_8_1, "0"),
    },
    err = "invalid aws header trace id; ignoring."
  }, {
    description = "invalid trace id 3",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-vv;Parent=%s;Sampled=%s",
                            sub(trace_id_8, 1, 8),
                            span_id_8_1, "0"),
    },
    err = "invalid aws header trace id; ignoring."
  }, {
    description = "invalid trace id (too short)",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_8, 1, 8),
                            sub(trace_id_8, 9, #trace_id_8),
                            span_id_8_1, "0"),
    },
    err = "invalid aws header trace id; ignoring."
  }, {
    description = "invalid trace id (too long)",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(too_long_id, 1, 8),
                            sub(too_long_id, 9, #too_long_id),
                            span_id_8_1, "0"),
    },
    err = "invalid aws header trace id; ignoring."
  }, {
    description = "missing trace id",
    extract = true,
    trace_id = trace_id_16,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=;Parent=%s;Sampled=%s",
                            span_id_8_1, "0"),
    },
    err = "invalid aws header trace id; ignoring."
  }, {
    description = "invalid parent id 1",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=vv;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            "0"),
    },
    err = "invalid aws header parent id; ignoring."
  }, {
    description = "invalid parent id (too long)",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            too_long_id, "0"),
    },
    err = "invalid aws header parent id; ignoring."
  }, {
    description = "invalid parent id (too short)",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            "123", "0"),
    },
    err = "invalid aws header parent id; ignoring."
  }, {
    description = "missing parent id",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=;Sampled=%s",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            "0"),
    },
    err = "invalid aws header parent id; ignoring."
  }, {
    description = "invalid sampled flag",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=2",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            span_id_8_1, "0"),
    },
    err = "invalid aws header sampled flag; ignoring."
  }, {
    description = "missing sampled flag",
    extract = true,
    headers = {
      ["x-amzn-trace-id"] = fmt("Root=1-%s-%s;Parent=%s;Sampled=",
                            sub(trace_id_16, 1, 8),
                            sub(trace_id_16, 9, #trace_id_16),
                            span_id_8_1),
    },
    err = "invalid aws header sampled flag; ignoring."
  }, { -- injection error cases
    description = "missing trace id",
    inject = true,
    ctx = {
      span_id = span_id_8_1,
      should_sample = false,
    },
    err = "aws injector context is invalid: field trace_id not found in context"
  }, {
    description = "missing span id",
    inject = true,
    ctx = {
      trace_id = trace_id_16,
      should_sample = false,
    },
    err = "aws injector context is invalid: field span_id not found in context"
  } }
}, {
  extractor = "gcp",
  injector = "gcp",
  headers_data = { {
    description = "base case",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=1", trace_id_16, span_id_8_1_dec),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
      trace_id_original_size = 16,
    }
  }, {
    description = "sampled = false",
    extract = true,
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=0", trace_id_16, span_id_8_1_dec),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 16,
    }
  }, {
    description = "no flag",
    extract = true,
    inject = false,
    trace_id = trace_id_16,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s", trace_id_16, span_id_8_1_dec),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = false,
      trace_id_original_size = 16,
    }
  }, {
    description = "default injection size is 16B",
    inject = true,
    trace_id = trace_id_16,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=1", trace_id_16, span_id_8_1_dec),
    },
    ctx = {
      trace_id = trace_id_16,
      span_id = span_id_8_1,
      should_sample = true,
    }
  }, { -- extraction error cases
    description = "invalid trace id (too short)",
    extract = true,
    trace_id = "123",
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=0", "123", span_id_8_1_dec),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "invalid trace id (too long)",
    extract = true,
    trace_id = too_long_id,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=0", too_long_id, span_id_8_1_dec),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "invalid trace id (no hex)",
    extract = true,
    trace_id = trace_id_8,
    headers = {
      ["x-cloud-trace-context"] = fmt("vvv/%s;o=0", span_id_8_1_dec),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "missing span id",
    extract = true,
    trace_id = trace_id_8,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/;o=0", trace_id_16),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "invalid span id (non digit)",
    extract = true,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=0", trace_id_16, span_id_8_1),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "invalid span id (too large)",
    extract = true,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=0", trace_id_16, span_id_8_1_dec .. "0"),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "invalid sampling value (01)",
    extract = true,
    trace_id = trace_id_8,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=01", trace_id_16, span_id_8_1_dec),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "invalid sampling value (missing)",
    extract = true,
    trace_id = trace_id_8,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=", trace_id_16, span_id_8_1_dec),
    },
    err = "invalid GCP header; ignoring."
  }, {
    description = "invalid sampling value (non digit)",
    extract = true,
    trace_id = trace_id_8,
    headers = {
      ["x-cloud-trace-context"] = fmt("%s/%s;o=v", trace_id_16, span_id_8_1_dec),
    },
    err = "invalid GCP header; ignoring."
  }, { -- injection error cases
    description = "missing trace id",
    inject = true,
    ctx = {
      span_id = span_id_8_1,
      should_sample = false,
    },
    err = "gcp injector context is invalid: field trace_id not found in context"
  }, {
    description = "missing span id",
    inject = true,
    ctx = {
      trace_id = trace_id_16,
      should_sample = false,
    },
    err = "gcp injector context is invalid: field span_id not found in context"
  } }
}, {
    extractor = "instana",
    injector = "instana",
    headers_data = { {
      description = "base case",
      extract = true,
      inject = true,
      trace_id = trace_id_16,
      headers = {
        ["x-instana-t"] = trace_id_16,
        ["x-instana-s"] = span_id_8_1,
        ["x-instana-l"] = "1",
      },
      ctx = {
        trace_id = trace_id_16,
        span_id = span_id_8_1,
        should_sample = true,
        trace_id_original_size = 16,
      }
    }, {
      description = "sampled = false",
      extract = true,
      inject = true,
      trace_id = trace_id_16,
      headers = {
        ["x-instana-t"] = trace_id_16,
        ["x-instana-s"] = span_id_8_1,
        ["x-instana-l"] = "0",
      },
      ctx = {
        trace_id = trace_id_16,
        span_id = span_id_8_1,
        should_sample = false,
        trace_id_original_size = 16,
      }
    }, {
      description = "8B trace id",
      extract = true,
      inject = true,
      trace_id = trace_id_8,
      headers = {
        ["x-instana-t"] = trace_id_8,
        ["x-instana-s"] = span_id_8_1,
        ["x-instana-l"] = "0",
      },
      ctx = {
        trace_id = padding_prefix .. trace_id_8,
        span_id = span_id_8_1,
        should_sample = false,
        trace_id_original_size = 8,
      }
    }, {
      description = "big 16B trace ID",
      inject = true,
      trace_id = big_trace_id_16,
      headers = {
        ["x-instana-t"]  = big_trace_id_16,
        ["x-instana-s"] = span_id_8_1,
      },
      ctx = {
        trace_id = big_trace_id_16,
        span_id = span_id_8_1,
      }
    }, {
      description = "invalid flag",
      extractor = true,
      trace_id = trace_id_16,
      headers = {
        ["x-instana-t"] = trace_id_16,
        ["x-instana-s"] = span_id_8_1,
        ["x-instana-l"] = "5",
      },
      ctx = {
        trace_id = big_trace_id_16,
        span_id = span_id_8_1,
        should_sample = true,
      }
    },{ -- extraction error cases
    description = "invalid trace ID (non hex)",
    extract = true,
    trace_id = "abcdefghijklmnop",
    headers = {
      ["x-instana-t"] = "abcdefghijklmnop",
      ["x-instana-s"] = span_id_8_1,
    },
    err = "x-instana-t header invalid; ignoring."
  }, {
    description = "invalid trace ID (too long)",
    extract = true,
    headers = {
      ["x-instana-t"] = too_long_id,
    },
    err = "x-instana-t header invalid; ignoring."
  }, {
    description = "invalid trace ID (too short)",
    extract = true,
    headers = {
      ["x-instana-t"] = "abc",
    },
    err = "x-instana-t header invalid; ignoring."
  }, {
    description = "empty header",
    extract = true,
    headers = {
      ["x-instana-t"] = "",
    },
    err = "x-instana-t header invalid; ignoring."
  },}
} }


describe("Tracing Headers Propagation Strategies", function()
  local req_headers
  local old_kong = _G.kong

  _G.kong = {
    log = {},
    service = {
      request = {
        set_header = function(name, value)
          req_headers[name] = value
        end,
        clear_header = function(name)
          req_headers[name] = nil
        end,
      }
    }
  }

  local warn

  lazy_setup(function()
    warn = spy.on(kong.log, "warn")
  end)

  lazy_teardown(function()
    _G.kong = old_kong
  end)

  for _, data in ipairs(test_data) do
    local extractor = data.extractor
    local injector = data.injector
    local headers_data = data.headers_data

    describe("#" .. extractor .. " extractor and " .. injector .. " injector", function()
      local ex = require(EXTRACTORS_PATH .. extractor)

      before_each(function()
        warn:clear()
        req_headers = {}
      end)

      it("handles no incoming headers correctly", function()
        local ctx, err = ex:extract({})

        assert.is_nil(err)
        assert.is_nil(ctx)
        assert.spy(warn).was_not_called()
      end)

      for _, h_info in ipairs(headers_data) do
        describe("incoming #" .. extractor .. " headers", function()
          lazy_teardown(function()
            req_headers = nil
          end)

          before_each(function()
            req_headers = {}
            for h_name, h_value in pairs(h_info.headers) do
              req_headers[h_name] = h_value
            end
            warn:clear()
          end)

          if h_info.ctx and h_info.headers and h_info.extract then
            it("with " .. h_info.description .. " extracts tracing context", function()
              local ctx, err = ex:extract(req_headers)

              assert.is_not_nil(ctx)
              assert.is_nil(err)
              assert.same(h_info.ctx, to_hex_ids(ctx))
              assert.spy(warn).was_not_called()
            end)

          elseif h_info.err and h_info.extract then -- extraction error cases
            it("with " .. h_info.description .. " fails", function()
              ex:extract(req_headers)
              assert.spy(warn).was_called_with(h_info.err)
            end)
          end
        end)
      end
    end)

    describe("#" .. injector .. " injector", function()
      local inj = require(INJECTORS_PATH .. injector)

      for _, h_info in ipairs(headers_data) do
        lazy_teardown(function()
          req_headers = nil
        end)

        before_each(function()
          req_headers = {}
          warn:clear()
        end)

        if h_info.ctx and h_info.headers and h_info.inject then
          it("with " .. h_info.description .. " injects tracing context", function()
            local formatted_trace_id, err = inj:inject(from_hex_ids(h_info.ctx))

            assert.is_nil(err)

            -- check formatted trace id (the key has the same name as
            -- the extractor)
            local format = extractor
            assert.same(formatted_trace_id, {
              [format] = h_info.trace_id,
            })

            assert.spy(warn).was_not_called()

            -- headers are injected in request correctly
            assert.same(h_info.headers, req_headers)
          end)

        elseif h_info.err and h_info.inject then   -- injection error cases
          it("with " .. h_info.description .. " fails", function()
            local formatted_trace_id, err = inj:inject(from_hex_ids(h_info.ctx))
            assert.is_nil(formatted_trace_id)
            assert.equals(h_info.err, err)
          end)
        end
      end
    end)
  end
end)
