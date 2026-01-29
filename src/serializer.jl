# Serializer for function-call style tool calls
# Supports multiple CallStyle formats (CONCISE, PYTHON, MINIMAL, TYPESCRIPT)

export serialize_value, serialize_tool_call, serialize_parsed_call
export serialize_tool_call_with_content, serialize_tool_call_multiline
export serialize_tool_schema, get_kv_separator

# ═══════════════════════════════════════════════════════════════════════════════
# Value Serialization
# ═══════════════════════════════════════════════════════════════════════════════

"""
Serialize a value to string format.
Style affects boolean/null representation.
"""
function serialize_value(value::Nothing; style::CallStyle=CONCISE)::String
    return style == PYTHON ? "None" : "null"
end

function serialize_value(value::Bool; style::CallStyle=CONCISE)::String
    if style == PYTHON
        return value ? "True" : "False"
    else
        return value ? "true" : "false"
    end
end

function serialize_value(value::Number; style::CallStyle=CONCISE)::String
    return string(value)
end

function serialize_value(value::AbstractString; style::CallStyle=CONCISE)::String
    escaped = replace(value,
        '\\' => "\\\\",
        '"' => "\\\"",
        '\n' => "\\n",
        '\t' => "\\t",
        '\r' => "\\r"
    )
    return "\"$escaped\""
end

function serialize_value(value::AbstractVector; style::CallStyle=CONCISE)::String
    elements = [serialize_value(v; style) for v in value]
    return "[" * join(elements, ", ") * "]"
end

function serialize_value(value::AbstractDict; style::CallStyle=CONCISE)::String
    pairs = ["$k: $(serialize_value(v; style))" for (k, v) in value]
    return "{" * join(pairs, ", ") * "}"
end

function serialize_value(pv::ParsedValue; style::CallStyle=CONCISE)::String
    return serialize_value(pv.value; style)
end

# Fallback
function serialize_value(value::Any; style::CallStyle=CONCISE)::String
    return serialize_value(string(value); style)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Tool Call Serialization
# ═══════════════════════════════════════════════════════════════════════════════

"""
Get the key-value separator for a given CallStyle.
PYTHON uses `=`, all others use `: `.
"""
function get_kv_separator(style::CallStyle)::String
    return style == PYTHON ? "=" : ": "
end

"""
Serialize a tool call with kwargs.
- CONCISE/MINIMAL/TYPESCRIPT: `name(key: value, key2: value2)`
- PYTHON: `name(key=value, key2=value2)`
"""
function serialize_tool_call(name::String, kwargs::AbstractDict; style::CallStyle=CONCISE)::String
    if isempty(kwargs)
        return "$(name)()"
    end

    sep = get_kv_separator(style)
    pairs = ["$k$(sep)$(serialize_value(v; style))" for (k, v) in kwargs]
    return "$(name)($(join(pairs, ", ")))"
end

"""
Serialize a tool call with content block.
```
shell(lang: "sh") ```
ls -la
```
```
"""
function serialize_tool_call_with_content(name::String, kwargs::AbstractDict, content::String, lang::String=""; style::CallStyle=CONCISE)::String
    call = serialize_tool_call(name, kwargs; style)
    if isempty(content)
        return call
    end
    return "$(call) ```$(lang)\n$(content)```"
end

"""Serialize a ParsedCall back to string format."""
function serialize_parsed_call(call::ParsedCall; style::CallStyle=CONCISE)::String
    kwargs_dict = Dict{String, Any}(k => v.value for (k, v) in call.kwargs)

    if isempty(call.content)
        return serialize_tool_call(call.name, kwargs_dict; style)
    else
        return serialize_tool_call_with_content(call.name, kwargs_dict, call.content; style)
    end
end

"""Generate multi-line formatted tool call for readability."""
function serialize_tool_call_multiline(name::String, kwargs::AbstractDict; style::CallStyle=CONCISE)::String
    if isempty(kwargs)
        return "$(name)()"
    end

    sep = get_kv_separator(style)
    io = IOBuffer()
    write(io, "$(name)(\n")
    pairs = collect(kwargs)
    for (i, (k, v)) in enumerate(pairs)
        write(io, "    $k$(sep)$(serialize_value(v; style))")
        if i < length(pairs)
            write(io, ",")
        end
        write(io, "\n")
    end
    write(io, ")")

    return String(take!(io))
end

# ═══════════════════════════════════════════════════════════════════════════════
# Schema Serialization
# ═══════════════════════════════════════════════════════════════════════════════

"""
Serialize a tool schema (definition) for system prompts.
"""
function serialize_tool_schema(schema::ToolSchema; style::CallStyle=CONCISE)::String
    io = IOBuffer()
    sep = get_kv_separator(style)

    write(io, "tool $(schema.name)(")

    if isempty(schema.params)
        write(io, ")")
    else
        write(io, "\n")
        for (i, param) in enumerate(schema.params)
            optional_marker = param.required ? "" : "?"
            desc_str = isempty(param.description) ? "" : "     \"$(param.description)\""
            write(io, "    $(param.name)$(optional_marker)$(sep)$(param.type)$(desc_str)")
            if i < length(schema.params)
                write(io, "\n")
            end
        end
        write(io, "\n)")
    end

    return String(take!(io))
end

# ═══════════════════════════════════════════════════════════════════════════════
# Config-based Convenience Functions
# ═══════════════════════════════════════════════════════════════════════════════

"""Serialize a tool call using a ToolFormatConfig."""
function serialize_tool_call(name::String, kwargs::AbstractDict, config::ToolFormatConfig)::String
    return serialize_tool_call(name, kwargs; style=config.style)
end
