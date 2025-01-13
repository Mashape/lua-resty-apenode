local typedefs = require "kong.db.schema.typedefs"


return {
  name = "file-log",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
        type = "record",
        fields = {
          { path = { description = "The file path of the output log file. The plugin creates the log file if it doesn't exist yet.", type = "string",
                     required = true,
                     match = [[^[^%s*&%%\\`]+$]],
                     err = "not a valid filename",
          }, },
          { reopen = { description = "Determines whether the log file is closed and reopened on every request.", type = "boolean", required = true, default = false }, },
          { custom_fields_by_lua = typedefs.lua_code },
        },
    }, },
  }
}
