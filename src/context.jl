# Context - System-injected runtime context for tools
#
# Tools can declare `ctx::Context` as a kwarg to receive system context.
# This is NOT exposed to the AI - it's injected by the system at execute time.

export AbstractContext, Context

"""
Base type for tool execution context.
Subtypes can add domain-specific fields.
"""
abstract type AbstractContext end

"""
    Context(; root_path="", user_id="", kwargs...)

Runtime context injected into tools by the system.
Contains information like workspace root, user identity, agent settings, etc.

# Fields
- `root_path::String` - Workspace/project root directory
- `user_id::String` - Current user identifier
- `session_id::String` - Current session identifier
- `extras::Dict{Symbol,Any}` - Extensible key-value storage for additional context

# Example
```julia
@deftool "Read file" function cat_file(path::String; ctx::Context)
    full_path = joinpath(ctx.root_path, path)
    read(full_path, String)
end

# System calls execute with context
execute(tool; ctx=Context(root_path="/project", user_id="user123"))
```
"""
@kwdef struct Context <: AbstractContext
    root_path::String = ""
    user_id::String = ""
    session_id::String = ""
    extras::Dict{Symbol,Any} = Dict{Symbol,Any}()
end

# Convenience accessor for extras
Base.getproperty(ctx::Context, name::Symbol) =
    name in fieldnames(Context) ? getfield(ctx, name) : get(ctx.extras, name, nothing)

Base.setproperty!(ctx::Context, name::Symbol, value) =
    name in fieldnames(Context) ? setfield!(ctx, name, value) : (ctx.extras[name] = value)
