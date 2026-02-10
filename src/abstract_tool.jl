# AbstractTool - Base type for all executable tools
#
# Provides the interface that all tools must implement.

export AbstractTool
export create_tool, execute, get_id, is_cancelled
export toolname, get_description, get_tool_schema, get_extra_description
export result2string, resultimg2base64, resultaudio2base64
export is_executable, get_cost
export description_from_schema, permission_pattern

using UUIDs: UUID, uuid4

"""
Tool execution flow:

    ParsedCall (from LLM)
         │
         ▼
    create_tool(Type, call) → Tool instance
         │
         ▼
    is_executable(tool) → Skip if false (wrapper tools)
         │
         ▼
    execute(tool, ctx) → Perform action with runtime context
         │
         ▼
    result2string(tool) → Format result for LLM

Interface methods to implement:
- `create_tool(::Type{T}, call::ParsedCall)` - Create instance from parsed call
- `execute(tool::T, ctx::AbstractContext)` - Main operation with runtime context
- `toolname(::Type{T})` - Tool's identifier
- `get_description(::Type{T})` - Usage documentation

Optional:
- `result2string(tool)` - Custom result formatting
- `get_tool_schema(::Type{T})` - Schema for dynamic description
- `is_executable(::Type{T})` - Whether tool can be executed (default true, false for wrappers)
"""
abstract type AbstractTool end


# Default create_tool using schema - tools can override for custom parsing
function create_tool(::Type{T}, call::ParsedCall) where T <: AbstractTool
    schema = get_tool_schema(T)

    # Passive tools (no schema or no params) - set content field if present
    if schema === nothing || isempty(get(schema, :params, []))
        return hasproperty(T, :content) ? T(content=call.content) : T()
    end

    # Active tools - extract params from call.kwargs
    kwargs = Dict{Symbol,Any}()
    for p in schema.params
        name_str = p.name isa Symbol ? string(p.name) : p.name
        name_sym = p.name isa Symbol ? p.name : Symbol(p.name)
        pv = get(call.kwargs, name_str, nothing)

        if p.type == "codeblock"
            # Codeblock can come from kwargs or fall back to call.content
            kwargs[name_sym] = pv !== nothing ? pv.value : call.content
        elseif pv !== nothing
            # Only set if present - let constructor handle defaults
            kwargs[name_sym] = pv.value
        end
    end
    T(; kwargs...)
end
# Execute with ctx - ctx is required, subtype AbstractContext for your runtime needs
execute(tool::AbstractTool, ctx::AbstractContext) = @warn "Unimplemented execute for $(typeof(tool))"
toolname(::Type{T}) where T <: AbstractTool = (@warn "Unimplemented toolname for $T"; "")
toolname(tool::AbstractTool) = toolname(typeof(tool))

# Optional interface with defaults
get_id(tool::AbstractTool) = hasproperty(tool, :_id) ? tool._id : uuid4()
is_cancelled(::AbstractTool) = false
get_cost(::AbstractTool) = nothing

get_description(::Type{T}) where T <: AbstractTool = (@warn "Unimplemented get_description for $T"; "unknown tool")
get_description(tool::AbstractTool) = get_description(typeof(tool))

get_extra_description(::Type{<:AbstractTool}) = nothing
get_extra_description(::AbstractTool) = nothing

get_tool_schema(::Type{<:AbstractTool}) = nothing
get_tool_schema(tool::AbstractTool) = get_tool_schema(typeof(tool))

result2string(tool::AbstractTool)::String = hasproperty(tool, :result) ? string(tool.result) : ""
resultimg2base64(::AbstractTool)::String = ""
resultaudio2base64(::AbstractTool)::String = ""

# Whether this tool can be executed (false for wrapper tools like TextTool, ReasonTool)
is_executable(::Type{<:AbstractTool}) = true
is_executable(tool::AbstractTool) = is_executable(typeof(tool))

# Permission pattern for permission checking - tools can override this
# Returns nothing by default, meaning use the fallback logic in get_tool_pattern
permission_pattern(::Type{<:AbstractTool}) = nothing
permission_pattern(tool::AbstractTool) = permission_pattern(typeof(tool))

"""Generate description from a schema NamedTuple."""
function description_from_schema(schema)
    schema === nothing && return "Unknown tool"
    tool_schema = ToolSchema(
        name = schema.name,
        description = get(schema, :description, ""),
        params = [ParamSchema(name=p.name, type=p.type, description=get(p, :description, ""), required=get(p, :required, true))
                  for p in get(schema, :params, [])]
    )
    generate_tool_definition(tool_schema)
end
