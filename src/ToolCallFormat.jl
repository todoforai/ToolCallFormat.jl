"""
ToolCallFormat.jl - Parse, define, and execute LLM tool calls

A unified Julia package for:
- Parsing function-call style tool invocations from LLM output
- Defining tools with @deftool macro
- Generating tool schemas for system prompts
- AbstractTool interface for tool execution

# Quick Start

```julia
using ToolCallFormat

# Define a tool with @deftool
@deftool "Send keyboard input" send_key(
    "The text to send" => text::String
) = "Sending: \$text"

@deftool "Read file" function cat_file(
    "File path" => path::String
)
    read(path, String)
end

# Parse a tool call from LLM output
call = parse_tool_call("send_key(text: \\"hello\\")")
tool = create_tool(SendKeyTool, call)
result = execute(tool)
```
"""
module ToolCallFormat

# Core types (ParsedCall, ToolSchema, CallStyle, etc.)
include("types.jl")

# Parsing and serialization
include("parser.jl")
include("stream_processor.jl")
include("serializer.jl")

# Schema generation for prompts
include("schema.jl")

# Context for system-injected runtime data (must be before abstract_tool.jl)
include("context.jl")

# AbstractTool interface
include("abstract_tool.jl")

# Tool definition macros (@deftool)
include("tool_macros.jl")

# Registry for dynamic tool lookup (optional, for handler-based tools)
include("registry.jl")

end # module ToolCallFormat
