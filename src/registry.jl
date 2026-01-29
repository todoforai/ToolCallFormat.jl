# Registry for tool definitions
# Maps tool names to handlers for dynamic dispatch

using UUIDs: UUID, uuid4

export ToolDef, ToolDefInstance
export register_tool, unregister_tool, get_tool, has_tool, list_tools, clear_registry!
export kwargs, create_instance
export toolname, get_id, needs_approval, execute!, result2string, execute_required

"""
A registered tool definition with schema and handler.

# Fields
- `schema`: ToolSchema for prompt generation
- `handler`: Function (call::ParsedCall; kw...) -> String
- `needs_approval`: Whether tool requires user approval before execution
"""
@kwdef struct ToolDef
    schema::ToolSchema
    handler::Function
    needs_approval::Bool = true
end

# Global tool registry
const TOOLS = Dict{Symbol, ToolDef}()

"""
    register_tool(name; schema, handler, needs_approval=true)

Register a tool in the global registry.

# Example
```julia
register_tool(:cat_file,
    schema = ToolSchema(name="cat_file", description="Read a file", params=[
        ParamSchema(name="path", type="string", required=true)
    ]),
    handler = (call; kw...) -> read(kwargs(call).path, String),
    needs_approval = false
)
```
"""
function register_tool(name::Union{Symbol, String}; schema::ToolSchema, handler::Function, needs_approval::Bool=true)
    TOOLS[Symbol(name)] = ToolDef(; schema, handler, needs_approval)
end

"""
    unregister_tool(name)

Remove a tool from the registry. Returns true if tool existed.
"""
function unregister_tool(name::Union{Symbol, String})::Bool
    delete!(TOOLS, Symbol(name)) !== nothing
end

"""
    get_tool(name) -> Union{ToolDef, Nothing}

Get a tool definition by name, or nothing if not found.
"""
get_tool(name::Union{Symbol, String}) = get(TOOLS, Symbol(name), nothing)

"""
    has_tool(name) -> Bool

Check if a tool is registered.
"""
has_tool(name::Union{Symbol, String}) = haskey(TOOLS, Symbol(name))

"""
    list_tools() -> Vector{Symbol}

List all registered tool names.
"""
list_tools() = collect(keys(TOOLS))

"""
    clear_registry!()

Remove all tools from registry. Useful for testing.
"""
clear_registry!() = empty!(TOOLS)

"""
    kwargs(call::ParsedCall) -> NamedTuple

Extract kwargs from ParsedCall as a NamedTuple for convenient access.

# Example
```julia
call = ParsedCall(name="cat_file", kwargs=Dict("path" => ParsedValue("/test.txt")))
kw = kwargs(call)
kw.path  # "/test.txt"
```
"""
function kwargs(call::ParsedCall)
    pairs = [Symbol(k) => v.value for (k, v) in call.kwargs]
    isempty(pairs) ? NamedTuple() : (; pairs...)
end

# ═══════════════════════════════════════════════════════════════════════════════
# ToolDefInstance - Runtime wrapper for registry tools
# ═══════════════════════════════════════════════════════════════════════════════

"""
Runtime instance of a registry tool, providing AbstractTool-compatible interface.

Created by `create_instance(def, call)` when a tool is looked up from registry.
Provides: id, result storage, execute via handler, needs_approval check.
"""
@kwdef mutable struct ToolDefInstance
    def::ToolDef
    call::ParsedCall
    id::UUID = uuid4()
    result::String = ""
end

"""
    create_instance(def::ToolDef, call::ParsedCall) -> ToolDefInstance

Create a runtime instance from a tool definition and parsed call.
"""
create_instance(def::ToolDef, call::ParsedCall) = ToolDefInstance(def=def, call=call)

"""
    create_instance(name, call::ParsedCall) -> Union{ToolDefInstance, Nothing}

Look up tool by name and create instance, or return nothing if not found.
"""
function create_instance(name::Union{Symbol, String}, call::ParsedCall)
    def = get_tool(name)
    def === nothing && return nothing
    create_instance(def, call)
end

# Instance methods (compatible with AbstractTool interface expectations)

"""Get tool name from instance."""
toolname(inst::ToolDefInstance) = inst.def.schema.name

"""Get instance ID."""
get_id(inst::ToolDefInstance) = inst.id

"""Check if tool requires approval."""
needs_approval(inst::ToolDefInstance) = inst.def.needs_approval

"""Execute the tool handler and store result."""
function execute!(inst::ToolDefInstance; kwargs...)
    inst.result = string(inst.def.handler(inst.call; kwargs...))
    inst.result
end

"""Get result as string."""
result2string(inst::ToolDefInstance) = inst.result

"""Check if tool should auto-execute (inverse of needs_approval)."""
execute_required(inst::ToolDefInstance) = !inst.def.needs_approval
