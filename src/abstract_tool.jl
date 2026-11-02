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
using JSON3

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

"""Thrown when an LLM-supplied tool argument can't be coerced to the field's
declared type. Caught at the extraction layer to produce a retryable ErrorTool,
so it stays distinct from any `ArgumentError` a tool constructor may throw."""
struct ToolArgumentError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ToolArgumentError) = print(io, e.msg)
export ToolArgumentError


# Some native tool-call providers occasionally stringify structured arguments
# even when the JSON schema says the field is an array/object. Be forgiving for
# container-typed fields by parsing a JSON/tool-call-like string (the parser
# accepts standard JSON arrays/objects as well as the concise syntax) before the
# final typed conversion. Scalar strings stay strings.
# A Vector field also accepts a stringified lone object (`{...}`): models often
# send a single element where an array is expected, so we wrap it below.
_wants_stringified_container(ftype::Type, s::AbstractString) = begin
    stripped = strip(String(s))
    isempty(stripped) && return false
    ((ftype <: AbstractVector) && (startswith(stripped, "[") || startswith(stripped, "{"))) ||
    ((ftype <: AbstractDict) && startswith(stripped, "{"))
end

# A double-stringified container field is plain JSON: the model JSON-encoded a
# value that was already meant to be a JSON array/object. Decode it with the same
# real JSON parser (JSON3) that decoded the surrounding tool-call arguments, so
# `\uXXXX`, `\/`, exponents etc. all just work. JSON3 returns immutable views, so
# copy into the plain Dict/Vector that field conversion expects.
_json_to_plain(x::JSON3.Object) = Dict{String,Any}(String(k) => _json_to_plain(v) for (k, v) in x)
_json_to_plain(x::JSON3.Array)  = Any[_json_to_plain(v) for v in x]
_json_to_plain(x) = x

_parse_stringified_container(s::AbstractString) = _json_to_plain(JSON3.read(strip(String(s)), Any))

# @deftool maps integer/number schema types to Union{T,Nothing}. Models (and MCP
# gateways) often send those as strings ("120") or JSON floats (120.0). convert()
# cannot do String→Int or Float64→Union{Nothing,Int}, so peel Nothing and parse.
_inner_type(::Type{Union{T,Nothing}}) where T = T
_inner_type(::Type{T}) where T = T

function _parse_scalar_string(::Type{T}, s::AbstractString) where T
    str = strip(String(s))
    if T <: Integer
        n = tryparse(Int, str)
        n !== nothing && return n
        f = tryparse(Float64, str)
        return (f !== nothing && isinteger(f)) ? Int(f) : nothing
    elseif T <: AbstractFloat
        return tryparse(Float64, str)
    elseif T <: Bool
        str == "true" && return true
        str == "false" && return false
        return nothing
    end
    nothing
end

function _coerce_tool_arg(ftype::Type, val)
    val isa ftype && return val
    inner = _inner_type(ftype)
    parsed_from_string = val isa AbstractString &&
        (_wants_stringified_container(ftype, val) || _wants_stringified_container(inner, val))
    candidate = parsed_from_string ? _parse_stringified_container(val) : val
    candidate isa ftype && return candidate
    # Stringified lone `{...}` object for a Vector field (model should have sent
    # `[{...}]`) — wrap the parsed object into a 1-element vector. Only for the
    # parsed-dict case so arbitrary scalars still fail conversion.
    if parsed_from_string && (ftype <: AbstractVector || inner <: AbstractVector) && candidate isa AbstractDict
        candidate = [candidate]
    end
    if candidate isa AbstractString
        parsed = _parse_scalar_string(inner, candidate)
        parsed !== nothing && return convert(ftype, parsed)
    elseif candidate isa AbstractFloat && inner <: Integer && isinteger(candidate)
        return convert(ftype, inner(candidate))
    end
    convert(ftype, candidate)
end

# Some models (seen on Claude Haiku) leak Anthropic's XML call syntax into native JSON
# args: `{"timeout": "120\">\n<parameter name=\"cmd\">ls"}` — the next param is inside
# the previous string. Split such values back into their keys, but only at a leaked
# name that is a schema param still missing from the call, so a legit value that merely
# contains `<parameter name="…">` text (e.g. a heredoc) is left alone.
const LEAKED_PARAM = r"(?:\">|</parameter>)\s*<parameter name=\"([^\"]+)\">"
_strip_leaked_close(s) = String(replace(s, r"\s*</parameter>\s*(?:</invoke>\s*)?(?:</function_calls>\s*)?$" => ""))

function repair_leaked_params!(kwargs::Dict{String,ParsedValue}, schema_names)
    for (k, pv) in collect(kwargs)
        v = pv.value
        v isa AbstractString || continue
        ms = [m for m in eachmatch(LEAKED_PARAM, v) if (n = m.captures[1]) in schema_names && n != k && !haskey(kwargs, n)]
        (isempty(ms) || !allunique(m.captures[1] for m in ms)) && continue  # ambiguous → leave as is
        kwargs[k] = ParsedValue(_strip_leaked_close(v[1:prevind(v, ms[1].offset)]))
        for (i, m) in enumerate(ms)
            from = m.offset + ncodeunits(m.match)
            to = i < length(ms) ? prevind(v, ms[i+1].offset) : lastindex(v)
            kwargs[String(m.captures[1])] = ParsedValue(_strip_leaked_close(v[from:to]))
        end
    end
    kwargs
end

# Default create_tool using schema - tools can override for custom parsing
function create_tool(::Type{T}, call::ParsedCall; extra_kwargs...) where T <: AbstractTool
    schema = get_tool_schema(T)

    # Passive tools (no schema or no params) - set content field if present
    if schema === nothing || isempty(get(schema, :params, []))
        return hasproperty(T, :content) ? T(content=call.content) : T()
    end

    # Active tools - extract params from call.kwargs
    kwargs = Dict{Symbol,Any}()
    schema_names = Set{String}(string(p.name) for p in schema.params)
    repair_leaked_params!(call.kwargs, schema_names)
    for p in schema.params
        name_str = string(p.name)
        name_sym = Symbol(p.name)
        pv = get(call.kwargs, name_str, nothing)

        if p.type in ("text", "codeblock")
            # Text/codeblock can come from kwargs or fall back to call.content
            kwargs[name_sym] = pv !== nothing ? pv.value : call.content
        elseif pv !== nothing && pv.value !== nothing
            # Only set if present and non-null - let constructor handle defaults.
            # An explicit JSON `null` (pv.value === nothing) is treated like a
            # missing key so the field default applies, instead of forcing
            # `nothing` into a non-nullable field (e.g. `timeout::Int`) and
            # throwing `Cannot convert Nothing to Int64`.
            kwargs[name_sym] = pv.value
        end
    end
    # Inject context-routing / approval-injected kwargs into internal fields (not in schema, but needed at runtime)
    for k in ("edge_id", "root_path", "root_paths", "no_confirm", "answer", "cdp_url")
        k in schema_names && continue
        haskey(call.kwargs, k) || continue
        sym = Symbol(k)
        hasfield(T, sym) || continue
        kwargs[sym] = call.kwargs[k].value
    end

    # Coerce each value to its declared field type up front. The @kwdef constructor
    # would `convert` anyway, but a mismatch there throws a raw `MethodError`
    # (e.g. a model passing a String for a `Vector{Dict{String,Any}}` field) that
    # callers can't turn into a useful message. Convert here so a bad LLM argument
    # becomes a clear, catchable `ToolArgumentError` naming the field and expected type.
    for (sym, val) in collect(kwargs)
        ftype = fieldtype(T, sym)
        val isa ftype && continue
        # `""` / `"null"` for a non-string field means "not given" — same as a JSON null above.
        if val isa AbstractString && strip(val) in ("", "null")
            delete!(kwargs, sym)
            continue
        end
        try
            kwargs[sym] = _coerce_tool_arg(ftype, val)
        catch e
            throw(ToolArgumentError(
                "tool $(toolname(T)): argument \"$sym\" has wrong type — expected $ftype, got $(typeof(val)) $(first(repr(val), 200))"))
        end
    end

    T(; kwargs..., extra_kwargs...)
end
# Execute with ctx - ctx is required, subtype AbstractContext for your runtime needs
execute(tool::AbstractTool, ctx::AbstractContext) = @warn "Unimplemented execute for $(typeof(tool))"
toolname(::Type{T}) where T <: AbstractTool = error("Unimplemented toolname for $T — define `ToolCallFormat.toolname(::Type{$T})` or `toolname(::$T)`")
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

function result2string(tool::AbstractTool)::String
    hasproperty(tool, :process_result) || return ""
    pr = tool.process_result
    isnothing(pr) && return ""
    result_text(pr)
end

"""Default: if tool has a process_result field with image blobs, extract them as data URLs."""
function resultimg2base64(tool::AbstractTool)::Vector{String}
    hasproperty(tool, :process_result) || return String[]
    pr = tool.process_result
    isnothing(pr) && return String[]
    image_data_urls(pr)
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
