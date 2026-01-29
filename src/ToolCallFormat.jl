"""
ToolCallFormat.jl - Parse, define, and execute LLM tool calls

A unified Julia package for:
- Parsing function-call style tool invocations from LLM output
- Defining tools with @deftool (recommended) or @tool macros
- Generating tool schemas for system prompts
- AbstractTool interface for tool execution

# Quick Start

```julia
using ToolCallFormat

# Define a tool with @deftool (recommended)
"Send keyboard input"
@deftool send_key(text::String) = "Sending: \$text"

# Or with @tool for advanced cases
@tool CatFileTool "cat_file" "Read file" [
    (:path, "string", "File path", true, nothing),
] (tool; kw...) -> read(tool.path, String)

# Parse a tool call from LLM output
call = parse_tool_call("send_key(text: \\"hello\\")")
tool = create_tool(Send_keyTool, call)
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

# AbstractTool interface
include("abstract_tool.jl")

# Tool definition macros (@deftool, @tool)
include("tool_macros.jl")

# Registry for dynamic tool lookup (optional, for handler-based tools)
include("registry.jl")

end # module ToolCallFormat
