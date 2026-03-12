# AbstractTool - Base type for all executable tools
#
# Provides the interface that all tools must implement.

export AbstractTool
export create_tool, execute, get_id, get_tool_call_id, set_tool_call_id!, is_cancelled
export toolname, get_description, get_tool_schema, get_extra_description
export result2string, resultimg2base64, resultaudio2base64
export is_executable, get_cost
export description_from_schema, permission_pattern
export get_timeout, DEFAULT_TOOL_TIMEOUT

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
function create_tool(::Type{T}, call::ParsedCall; extra_kwargs...) where T <: AbstractTool
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

        if p.type in ("text", "codeblock")
            # Text/codeblock can come from kwargs or fall back to call.content
            kwargs[name_sym] = pv !== nothing ? pv.value : call.content
        elseif pv !== nothing
            # Only set if present - let constructor handle defaults
            kwargs[name_sym] = pv.value
        end
    end
    T(; kwargs..., extra_kwargs...)
end
# Execute with ctx - ctx is required, subtype AbstractContext for your runtime needs
execute(tool::AbstractTool, ctx::AbstractContext) = @warn "Unimplemented execute for $(typeof(tool))"
toolname(::Type{T}) where T <: AbstractTool = (@warn "Unimplemented toolname for $T"; "")
toolname(tool::AbstractTool) = toolname(typeof(tool))

# Optional interface with defaults
get_id(tool::AbstractTool) = hasproperty(tool, :_id) ? tool._id : uuid4()
get_tool_call_id(tool::AbstractTool) = hasproperty(tool, :_tool_call_id) ? tool._tool_call_id : nothing
set_tool_call_id!(tool::AbstractTool, id) = hasproperty(tool, :_tool_call_id) && (tool._tool_call_id = id; true)
is_cancelled(::AbstractTool) = false
get_cost(::AbstractTool) = nothing

const DEFAULT_TOOL_TIMEOUT = 15.0

"""Get effective timeout for a tool. Uses tool's own timeout field (+ buffer) if present, otherwise 15s default."""
function get_timeout(tool::AbstractTool)::Float64
    if hasproperty(tool, :timeout)
        t = tool.timeout
        t !== nothing && return Float64(t) + 10.0
    end
    return DEFAULT_TOOL_TIMEOUT
end

get_description(::Type{T}) where T <: AbstractTool = (@warn "Unimplemented get_description for $T"; "unknown tool")
get_description(tool::AbstractTool) = get_description(typeof(tool))

get_extra_description(::Type{<:AbstractTool}) = nothing
get_extra_description(::AbstractTool) = nothing

get_tool_schema(::Type{<:AbstractTool}) = nothing
get_tool_schema(tool::AbstractTool) = get_tool_schema(typeof(tool))

result2string(tool::AbstractTool)::String = hasproperty(tool, :result) ? string(tool.result) : ""

"""Default: if tool has a process_result field with image blobs, extract them as data URLs."""
function resultimg2base64(tool::AbstractTool)::Vector{String}
    hasproperty(tool, :process_result) || return String[]
    pr = tool.process_result
    isnothing(pr) && return String[]
    urls = String[]
    for b in pr.blobs
        startswith(b.mime, "image/") || continue
        if b.data isa String && startswith(b.data, "data:")
            push!(urls, b.data)
        else
            push!(urls, "data:$(b.mime);base64,$(blob_b64(b))")
        end
    end
    urls
end

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
        params = [ParamSchema(name=p.name, type=p.type, description=get(p, :description, ""), required=get(p, :required, true),
                             default=get(p, :default, nothing))
                  for p in get(schema, :params, [])]
    )
    generate_tool_definition(tool_schema)
end
