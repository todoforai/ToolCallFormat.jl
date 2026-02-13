# Types for ToolCallFormat
# Core types for parsing LLM output and generating tool schemas

export ParsedValue, ParsedCall
export ParamSchema, ToolSchema
export CallStyle, CONCISE, PYTHON, MINIMAL, TYPESCRIPT
export ToolFormatConfig, CallFormatConfig
export get_default_call_style, set_default_call_style!

# ═══════════════════════════════════════════════════════════════════════════════
# Call Styles
# ═══════════════════════════════════════════════════════════════════════════════

"""
Call format styles for function-call syntax.
Each style uses different syntax conventions familiar to different programming communities.
"""
@enum CallStyle begin
    CONCISE      # Default - upgraded TypeScript with positional + named args (key: value)
    PYTHON       # Python-like with = for named args (key=value)
    MINIMAL      # Clean with # comments (key: value)
    TYPESCRIPT   # Strict TS compat (key: value)
end

# Global default style (can be changed at runtime)
const DEFAULT_CALL_STYLE = Ref{CallStyle}(CONCISE)

"""Get the default CallStyle."""
get_default_call_style()::CallStyle = DEFAULT_CALL_STYLE[]

"""Set the default CallStyle."""
function set_default_call_style!(style::CallStyle)
    DEFAULT_CALL_STYLE[] = style
end

"""Configuration for tool format."""
@kwdef struct ToolFormatConfig
    style::CallStyle = CONCISE
end

# Convenience constructor
CallFormatConfig(style::CallStyle=CONCISE) = ToolFormatConfig(style=style)

# ═══════════════════════════════════════════════════════════════════════════════
# Parsed Types (from LLM output)
# ═══════════════════════════════════════════════════════════════════════════════

"""
A parsed value from the tool call, preserving both the typed value and original text.
Supports: String, Number, Bool, Nothing, Vector, Dict
"""
@kwdef struct ParsedValue
    value::Any             # String, Number, Bool, Nothing, Vector, Dict
    raw::String = ""       # Original text
end

# Helper constructor
ParsedValue(v) = ParsedValue(value=v, raw=string(v))

"""
A parsed tool call extracted from LLM output.

# Fields
- `name`: Tool name (e.g., "read_file")
- `kwargs`: Named arguments as Dict{String, ParsedValue}
- `content`: Content block text (for tools with backtick content blocks after `)`)
- `raw`: Original text that was parsed
"""
@kwdef mutable struct ParsedCall
    name::String
    kwargs::Dict{String, ParsedValue} = Dict{String, ParsedValue}()
    content::String = ""   # For content block tools (code after closing paren)
    raw::String = ""       # Full original text
end

# ═══════════════════════════════════════════════════════════════════════════════
# Schema Types (for generating prompts)
# ═══════════════════════════════════════════════════════════════════════════════

"""
Parameter schema for a single tool parameter.
Used when generating tool definitions for system prompts.
"""
@kwdef struct ParamSchema
    name::String
    type::String           # "string", "number", "boolean", "null", "string[]", "object", "text", "codeblock"
    description::String = ""
    required::Bool = true
end

"""
Tool schema representing a complete tool definition.
Used when generating tool definitions for system prompts.
"""
@kwdef struct ToolSchema
    name::String
    params::Vector{ParamSchema} = ParamSchema[]
    description::String = ""
end
