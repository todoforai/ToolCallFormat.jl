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

# Build a tool call and execute it
call = ParsedCall(name="send_key", kwargs=Dict("text" => ParsedValue(value="hello", raw="hello")))
tool = create_tool(SendKeyTool, call)
result = execute(tool)
```
"""
module ToolCallFormat

# Core types (ParsedCall, ToolSchema, CallStyle, etc.)
include("types.jl")

# Serialization (tool schema → LLM-facing text)
include("serializer.jl")

# Schema generation for prompts
include("schema.jl")

# Context for system-injected runtime data (must be before abstract_tool.jl)
include("context.jl")

# AbstractTool interface
include("abstract_tool.jl")

# Tool definition macros (@deftool)
include("tool_macros.jl")

# Registry for @deftool type lookup
include("registry.jl")

# Universal process output types
include("process_result.jl")

end # module ToolCallFormat
