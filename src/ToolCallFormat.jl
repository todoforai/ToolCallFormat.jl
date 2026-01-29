"""
ToolCallFormat.jl - Parse and generate LLM tool call formats

A standalone Julia package for:
- Parsing function-call style tool invocations from LLM output
- Streaming parsing with character-by-character state machine
- Generating tool definitions and format documentation for prompts
- Serializing tool calls back to text
- Registering and dispatching tools via registry

# Quick Start

```julia
using ToolCallFormat

# Parse a tool call
call = parse_tool_call("read_file(path: \"/test.txt\")")
call.name       # "read_file"
call.kwargs     # Dict("path" => ParsedValue("/test.txt"))

# Define a tool with @tool macro
@tool "cat_file" "Read a file" [
    (:path, "string", "File path", true),
] (call; kw...) -> read(kwargs(call).path, String)

# Or register manually
register_tool(:shell,
    schema = ToolSchema(name="shell", description="Run command"),
    handler = (call; kw...) -> run_command(kwargs(call).cmd)
)

# Execute via registry
def = get_tool(:cat_file)
result = def.handler(call)
```
"""
module ToolCallFormat

# Include all components
include("types.jl")         # Core types (ParsedCall, ToolSchema, CallStyle, etc.)
include("parser.jl")        # Recursive descent parser
include("stream_processor.jl")  # Streaming state machine
include("serializer.jl")    # Tool call → string
include("schema.jl")        # Schema generation for prompts
include("registry.jl")      # Tool registry (ToolDef, register_tool, etc.)
include("macros.jl")        # @tool macro

end # module ToolCallFormat
