# Context - System-injected runtime context for tools
#
# Tools can declare `ctx::AbstractContext` as a kwarg to receive system context.
# Any type ending in "Context" is recognized as a context type.
# This is NOT exposed to the AI - it's injected by the system at execute time.

export AbstractContext

"""
Base type for tool execution context.

Tools should use `ctx::AbstractContext` and duck-type on fields they need.
Applications define concrete subtypes (e.g., RuntimeContext) with typed fields.

Common fields by convention:
- `root_path::String` - workspace root path

Example:
```julia
@deftool "Read file" function cat_file(path::String; ctx::AbstractContext)
    full_path = joinpath(ctx.root_path, path)  # duck-typed access
    read(full_path, String)
end
```
"""
abstract type AbstractContext end
