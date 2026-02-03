# Registry for @deftool type lookup
# Maps tool names to AbstractTool subtypes for dynamic dispatch

export register_tool_type!, get_tool_type

# Runtime type registry (for @deftool AbstractTool subtypes)
# Populated at runtime via register_tool_type! calls in __init__
const TOOL_TYPES = Dict{Symbol, DataType}()

"""
    register_tool_type!(name, T)

Register an AbstractTool subtype in the global type registry.
Should be called at runtime (in __init__) for persistence.
"""
function register_tool_type!(name::Union{Symbol, String}, T::DataType)
    TOOL_TYPES[Symbol(name)] = T
end

"""
    get_tool_type(name) -> Union{DataType, Nothing}

Get an AbstractTool subtype by name, or nothing if not found.
"""
get_tool_type(name::Union{Symbol, String}) = get(TOOL_TYPES, Symbol(name), nothing)
