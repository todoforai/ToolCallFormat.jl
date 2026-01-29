"""
ToolCallFormat.jl - Parse and generate LLM tool call formats

A standalone Julia package for:
- Parsing function-call style tool invocations from LLM output
- Streaming parsing with character-by-character state machine
- Generating tool definitions and format documentation for prompts
- Serializing tool calls back to text

# Quick Start

```julia
using ToolCallFormat

# Parse a tool call
call = parse_tool_call("read_file(path: \"/test.txt\")")
call.name       # "read_file"
call.kwargs     # Dict("path" => ParsedValue("/test.txt"))

# Stream processing
sp = StreamProcessor(
    known_tools = Set([:read_file, :shell]),
    emit_text = text -> print(text),
    emit_tool = call -> handle_tool(call)
)
process_chunk!(sp, chunk)
finalize!(sp)

# Generate tool documentation
schema = ToolSchema(
    name="read_file",
    params=[ParamSchema(name="path", type="string", description="File path")],
    description="Read a file"
)
generate_tool_definition(schema)
```
"""
module ToolCallFormat

# Include all components
include("types.jl")         # Core types (ParsedCall, ToolSchema, CallStyle, etc.)
include("parser.jl")        # Recursive descent parser
include("stream_processor.jl")  # Streaming state machine
include("serializer.jl")    # Tool call → string
include("schema.jl")        # Schema generation for prompts

end # module ToolCallFormat
