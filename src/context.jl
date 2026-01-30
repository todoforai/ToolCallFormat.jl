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
    Context(; wrapper=nothing, client=nothing, flow=nothing, ...)

Universal runtime context injected into tools by the system.
Contains everything tools might need - wrapper, client, flow, paths, etc.

# Fields
- `wrapper::Any` - IO wrapper for sending payloads (TodoIOWrapper, AbstractIOWrapper)
- `client::Any` - Direct client access
- `flow::Any` - Current workflow (STDFlow, etc.)
- `root_path::String` - Workspace/project root directory
- `user_id::String` - Current user identifier
- `session_id::String` - Current session identifier
- `extras::Dict{Symbol,Any}` - Extensible key-value storage for additional context

# Example
```julia
@deftool "Navigate to URL" function browser_navigate(
    url::String => (desc="URL to navigate to",);
    ctx::Context
)
    client = ctx.wrapper.client
    browser_execute(client, "browser_navigate", Dict("url" => url); session_id=ctx.wrapper.todo_id)
end

# System calls execute with context
execute(tool; ctx=Context(wrapper=io, root_path="/project"))
```
"""
@kwdef struct Context <: AbstractContext
    # Common tool dependencies
    wrapper::Any = nothing      # TodoIOWrapper for sending payloads
    client::Any = nothing       # Direct client access
    flow::Any = nothing         # Current workflow

    # Path and identity
    root_path::String = ""
    user_id::String = ""
    session_id::String = ""

    # Extensible storage for anything else
    extras::Dict{Symbol,Any} = Dict{Symbol,Any}()
end

# Convenience accessor for extras - allows ctx.anything syntax
Base.getproperty(ctx::Context, name::Symbol) =
    name in fieldnames(Context) ? getfield(ctx, name) : get(ctx.extras, name, nothing)

Base.setproperty!(ctx::Context, name::Symbol, value) =
    name in fieldnames(Context) ? setfield!(ctx, name, value) : (ctx.extras[name] = value)
