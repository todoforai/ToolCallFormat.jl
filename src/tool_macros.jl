# Tool definition macros

export @deftool, CodeBlock

using UUIDs: UUID, uuid4

#==============================================================================#
# CodeBlock type
#==============================================================================#

"""Marker type for codeblock parameters (tells LLM to use code formatting)."""
struct CodeBlock
    content::String
end
CodeBlock() = CodeBlock("")
Base.convert(::Type{CodeBlock}, s::String) = CodeBlock(s)
Base.string(cb::CodeBlock) = cb.content

#==============================================================================#
# Valid schema types
#==============================================================================#

const VALID_SCHEMA_TYPES = Set(["string", "codeblock", "number", "integer", "boolean", "array", "object"])
const RESERVED_FIELD_NAMES = Set([:id, :result])

#==============================================================================#
# @deftool - Function-style macro
#==============================================================================#

"""
    @deftool "description" name(args...; kwargs...) = ...
    @deftool "description" function name(args...; kwargs...) ... end
    @deftool "description" (internal_fields...) function name(args...) ... end

Define a tool using function syntax. Description is passed as first argument.
Struct name is auto-generated: `snake_case` → `CamelCaseTool`.

# Parameter descriptions

Use `"description" => param` syntax (description first) for documented parameters:

```julia
@deftool "Send message" send(
    "The message content to send" => text::String,
    "Priority level (1-5)" => priority::Int = 3
) = ...
```

Supported parameter forms:
- `x::Type`                       → required, no description
- `x::Type = val`                 → optional with default, no description
- `"desc" => x::Type`             → required, with description
- `"desc" => x::Type = val`       → optional with default and description

# Context parameters

Context kwargs (typed as `Context` or `<:AbstractContext`) are NOT exposed to AI.
They are system-injected via execute kwargs.

# Internal fields

Internal fields (in tuple after description) become struct fields but are NOT in schema.
Useful for preprocess hooks that need to store computed state.

# Examples

```julia
@deftool "Send keyboard input" send_key(
    "The text to type" => text::String
) = "Sending keys: \$text"

@deftool "Click coordinates" click(
    "X coordinate in pixels" => x::Int,
    "Y coordinate in pixels" => y::Int
) = "Click at (\$x, \$y)"

@deftool "Search with options" search(
    "Search query" => query::String,
    "Max results to return" => limit::Int = 10
) = "Searching for \$query (limit \$limit)"

@deftool "Read file" function cat_file(
    "Path to the file to read" => path::String;
    ctx::Context
)
    full_path = joinpath(ctx.root_path, path)
    read(full_path, String)
end

# With internal fields for preprocess hook
@deftool "Modify file" (postcontent::String="", model=["gpt4o"]) function modify_file(
    "Path to the file to modify" => file_path::String,
    "New content for the file" => content::CodeBlock;
    ctx::Context
)
    # postcontent is set by preprocess, not by AI
    apply_changes(file_path, postcontent, ctx)
end
```
"""
macro deftool(args...)
    # Parse args: "description" [internal_fields_tuple] func_expr
    func_expr = nothing
    description = ""
    internal_fields_expr = nothing

    for arg in args
        if arg isa String
            description = arg
        elseif arg isa Expr && arg.head == :tuple
            # Multiple internal fields: (a::String="", b::Int=0)
            internal_fields_expr = arg
        elseif arg isa Expr && arg.head == :(=) && _looks_like_internal_field(arg)
            # Single internal field: (a::String="") parses as just the assignment
            internal_fields_expr = Expr(:tuple, arg)  # Wrap in tuple for uniform handling
        elseif arg isa Expr && arg.head == :(::) && !(arg.args[1] isa Expr)
            # Single uninitialized internal field: (a::String)
            internal_fields_expr = Expr(:tuple, arg)
        elseif arg isa Expr
            func_expr = arg
        else
            error("@deftool: unexpected argument: $arg")
        end
    end

    func_expr === nothing && error("@deftool: missing function expression")

    func_name, params, body = _parse_func(func_expr)
    struct_name = Symbol(_to_camel_case(string(func_name)), :Tool)

    # Parse internal fields
    internal_fields = _parse_internal_fields(internal_fields_expr)

    # Separate schema params (for AI) from context param (always named 'ctx', after semicolon)
    schema_params = filter(p -> p.name != :ctx, params)

    # Convert to format for code generation: [(name, schema_type, desc, required, default), ...]
    params_for_gen = [(p.name, _type_to_schema(p.type), p.desc, p.required, p.default)
                      for p in schema_params]

    # Validate params
    for (i, p) in enumerate(params_for_gen)
        _validate_param(p, i)
    end

    # Convert internal fields: [(name, type, default), ...]
    internal_for_gen = [(f.name, f.type, f.default) for f in internal_fields]

    # Transform body: schema params -> tool.field, internal fields -> tool.field
    # ctx stays as ctx (passed directly to execute)
    schema_names = Set(p.name for p in schema_params)
    internal_names = Set(f.name for f in internal_fields)
    new_body = _transform_body(body, union(schema_names, internal_names))

    execute_body = :(tool.result = string($new_body))
    func_name_str = string(func_name)
    # Execute takes (tool, ctx) - ctx is always available in the body
    execute_lambda = :((tool, ctx) -> $execute_body)

    sn = esc(struct_name)
    is_passive = isempty(params_for_gen) && isempty(internal_for_gen)

    if is_passive
        _generate_passive_tool(sn, func_name_str, description)
    else
        _generate_active_tool(sn, func_name_str, description, params_for_gen, execute_lambda, internal_for_gen)
    end
end

"""Parse internal fields from tuple expression: (name::Type=default, ...)"""
function _parse_internal_fields(expr)
    expr === nothing && return NamedTuple{(:name, :type, :default), Tuple{Symbol, Any, Any}}[]

    fields = NamedTuple{(:name, :type, :default), Tuple{Symbol, Any, Any}}[]
    items = expr.head == :tuple ? expr.args : [expr]

    for item in items
        if item isa Expr && item.head == :(=)
            # name::Type = default  or  name = default
            lhs, default = item.args
            if lhs isa Expr && lhs.head == :(::)
                name, type = lhs.args
            else
                name, type = lhs, :Any
            end
            push!(fields, (name=name, type=type, default=default))
        elseif item isa Expr && item.head == :(::)
            # name::Type (no default)
            name, type = item.args
            push!(fields, (name=name, type=type, default=nothing))
        elseif item isa Symbol
            # just name
            push!(fields, (name=item, type=:Any, default=nothing))
        end
    end
    fields
end

"""Check if an assignment expression looks like an internal field (name::Type=default)."""
function _looks_like_internal_field(expr)
    # Internal field: name::Type = default
    # Function def: f(x) = body
    expr.head == :(=) || return false
    lhs = expr.args[1]
    # If LHS is typed (name::Type), it's an internal field
    lhs isa Expr && lhs.head == :(::) && return true
    # If LHS is a symbol, it could be internal field with inferred type: name = default
    lhs isa Symbol && return true
    false
end

#==============================================================================#
# Passive tool generation (no params)
#==============================================================================#

function _generate_passive_tool(sn, tool_name, description)
    quote
        @kwdef mutable struct $sn <: AbstractTool
            id::UUID = uuid4()
            content::String = ""
            result::String = ""
        end

        ToolCallFormat.toolname(::Type{$sn}) = $tool_name
        ToolCallFormat.toolname(::$sn) = $tool_name

        function ToolCallFormat.get_description(::Type{$sn}, style::CallStyle=get_default_call_style())
            generate_tool_definition(ToolSchema(name=$tool_name, description=$description, params=ParamSchema[]); style=style)
        end
        ToolCallFormat.get_description(t::$sn, style::CallStyle=get_default_call_style()) = ToolCallFormat.get_description(typeof(t), style)

        ToolCallFormat.get_tool_schema(::Type{$sn}) = (name=$tool_name, description=$description, params=[])
        ToolCallFormat.create_tool(::Type{$sn}, call::ParsedCall) = $sn(content=call.content)
        ToolCallFormat.result2string(tool::$sn)::String = tool.result
    end
end

#==============================================================================#
# Active tool generation (with params)
#==============================================================================#

function _generate_active_tool(sn, tool_name, description, params, execute_expr, internal_fields=[])
    base_fields = [(:id, UUID, :(uuid4())), (:result, String, :(""))]

    # Schema params become struct fields
    user_fields = [(name, _schema_to_julia_type(type_str), default === nothing ? _default_value_expr(_schema_to_julia_type(type_str)) : default)
                   for (name, type_str, _, _, default) in params]

    # Internal fields also become struct fields (but NOT in schema)
    internal_struct_fields = [(name, type, default === nothing ? _default_value_expr_for_type(type) : default)
                              for (name, type, default) in internal_fields]

    all_fields = vcat(base_fields, user_fields, internal_struct_fields)
    struct_field_exprs = [:($name::$jl_type) for (name, jl_type, _) in all_fields]
    kwarg_exprs = [Expr(:kw, name, def_expr) for (name, _, def_expr) in all_fields]
    call_arg_exprs = [name for (name, _, _) in all_fields]

    # Schema only includes user params, NOT internal fields
    schema_exprs = [:(ParamSchema(name=$(string(name)), type=$type_str, description=$desc, required=$req))
                    for (name, type_str, desc, req, _) in params]

    result = quote
        mutable struct $sn <: AbstractTool
            $(struct_field_exprs...)
        end

        function $sn(; $(kwarg_exprs...))
            $sn($(call_arg_exprs...))
        end

        ToolCallFormat.toolname(::Type{$sn}) = $tool_name
        ToolCallFormat.toolname(::$sn) = $tool_name

        function ToolCallFormat.get_description(::Type{$sn}, style::CallStyle=get_default_call_style())
            generate_tool_definition(ToolSchema(name=$tool_name, description=$description, params=ParamSchema[$(schema_exprs...)]); style=style)
        end
        ToolCallFormat.get_description(t::$sn, style::CallStyle=get_default_call_style()) = ToolCallFormat.get_description(typeof(t), style)

        function ToolCallFormat.get_tool_schema(::Type{$sn})
            (name=$tool_name, description=$description,
             params=[$([:(( name=$(string(name)), type=$type_str, description=$desc, required=$req ))
                       for (name, type_str, desc, req, _) in params]...)])
        end
    end

    _add_create_tool!(result, sn, params)

    if execute_expr !== nothing
        push!(result.args, :(ToolCallFormat.execute(tool::$sn, ctx::AbstractContext) = $(esc(execute_expr))(tool, ctx)))
    end

    push!(result.args, :(ToolCallFormat.result2string(tool::$sn)::String = tool.result))

    result
end

"""Get default value expression for a Julia type (used for internal fields)."""
function _default_value_expr_for_type(type)
    type == :String ? :("") :
    type == :Int ? :(0) :
    type == :Bool ? :(false) :
    type == :Float64 ? :(0.0) :
    (type isa Expr && type.head == :curly && type.args[1] == :Vector) ? :($(type)()) :
    :(nothing)
end

#==============================================================================#
# create_tool generation
#==============================================================================#

function _add_create_tool!(result, sn, params)
    kwarg_assignments = Expr[]

    for (name, type_str, _, required, default) in params
        name_str = string(name)
        default_val = default === nothing ? _default_value_for_type(type_str) : default

        value_expr = if type_str == "codeblock"
            :(let v = get(call.kwargs, $name_str, nothing)
                v !== nothing ? v.value : (isempty(call.content) ? $default_val : call.content)
            end)
        else
            :(let pv = get(call.kwargs, $name_str, nothing)
                pv === nothing ? $default_val : pv.value
            end)
        end

        push!(kwarg_assignments, Expr(:kw, name, value_expr))
    end

    push!(result.args, :(function ToolCallFormat.create_tool(::Type{$sn}, call::ParsedCall)
        $sn(; $(kwarg_assignments...))
    end))
end

#==============================================================================#
# Parsing helpers
#==============================================================================#

"""Convert snake_case to CamelCase: send_key → SendKey"""
function _to_camel_case(s::String)
    join(uppercasefirst.(split(s, '_')))
end

function _parse_func(expr)
    if expr isa Expr && expr.head == :(=)
        sig, body = expr.args
    elseif expr isa Expr && expr.head == :function
        sig, body = expr.args
    else
        error("@deftool: expected function, got $(expr.head)")
    end
    func_name, params = _parse_sig(sig)
    (func_name, params, body)
end

function _parse_sig(sig)
    sig.head == :call || error("@deftool: invalid signature")
    func_name = sig.args[1]
    params = NamedTuple{(:name, :type, :required, :default, :desc), Tuple{Symbol, Any, Bool, Any, String}}[]

    for arg in sig.args[2:end]
        if arg isa Expr && arg.head == :parameters
            for kw in arg.args
                push!(params, _parse_param(kw, false))
            end
        else
            push!(params, _parse_param(arg, true))
        end
    end
    (func_name, params)
end

"""
Parse a parameter expression into normalized (name, type, required, default, desc) tuple.

Supported forms (recommended - description first):
- `x::Type`                              → required, no description
- `x::Type = val`                        → optional with default, no description
- `"desc" => x::Type`                    → required with description
- `"desc" => x::Type = val`              → optional with description and default

Legacy forms (still supported):
- `x::Type => "desc"`                    → required with description
- `x::Type => (desc="...", default=val)` → optional with both

The `is_positional` flag determines if params without defaults are required.
"""
function _parse_param(expr, is_positional)
    # Case 1: Has top-level default (head == :kw means `something = default`)
    if expr isa Expr && expr.head == :kw
        lhs = expr.args[1]
        default = expr.args[2]

        # New style: "desc" => x::Type = val (description-first with default)
        if lhs isa Expr && lhs.head == :call && lhs.args[1] == :(=>)
            desc = lhs.args[2]
            typed_part = lhs.args[3]
            if desc isa String
                name, type = _parse_typed(typed_part)
                return (name=name, type=type, required=false, default=default, desc=desc)
            end
            # Fall through to legacy handling if first arg isn't a string
        end

        # Regular: x::Type = val (no description)
        name, type = _parse_typed(lhs)
        return (name=name, type=type, required=false, default=default, desc="")
    end

    # Case 2: Has `=>` - could be new description-first or legacy style
    if expr isa Expr && expr.head == :call && expr.args[1] == :(=>)
        first_arg = expr.args[2]
        second_arg = expr.args[3]

        # New style: "desc" => x::Type (description first, no default)
        if first_arg isa String
            name, type = _parse_typed(second_arg)
            return (name=name, type=type, required=is_positional, default=nothing, desc=first_arg)
        end

        # Legacy style: x::Type => "desc" or x::Type => (desc="...", default=...)
        typed_part = first_arg
        spec = second_arg
        name, type = _parse_typed(typed_part)
        desc, default = _parse_param_spec(spec)
        has_default = default !== nothing
        required = !has_default && is_positional
        return (name=name, type=type, required=required, default=default, desc=desc)
    end

    # Case 3: Just typed, no description: `x::Type`
    if expr isa Expr && expr.head == :(::)
        name, type = _parse_typed(expr)
        return (name=name, type=type, required=is_positional, default=nothing, desc="")
    end

    # Case 4: Just a symbol (untyped): `x`
    if expr isa Symbol
        return (name=expr, type=:String, required=is_positional, default=nothing, desc="")
    end

    error("@deftool: cannot parse param: $expr")
end

"""
Parse the spec after `=>`. Accepts:
- String: `"description"` → returns ("description", nothing)
- Named tuple: `(desc="...", default=val)` → returns ("...", val)
"""
function _parse_param_spec(spec)
    # Simple string shorthand: `x::Type => "description"`
    if spec isa String
        return (spec, nothing)
    end

    # Named tuple: `(desc="...", default=...)`
    if spec isa Expr && spec.head == :tuple
        desc = ""
        default = nothing
        for arg in spec.args
            if arg isa Expr && arg.head == :(=)
                key, val = arg.args
                if key == :desc
                    val isa String || error("@deftool: desc must be a string literal, got: $val")
                    desc = val
                elseif key == :default
                    default = val
                else
                    error("@deftool: unknown parameter spec key: $key (expected desc or default)")
                end
            else
                error("@deftool: parameter spec must be named tuple like (desc=\"...\", default=...), got: $arg")
            end
        end
        return (desc, default)
    end

    error("@deftool: parameter spec must be a string or named tuple (desc=\"...\", default=...), got: $spec")
end

"""Extract (name, type) from `name::Type`. Unwraps `Union{T, Nothing}` to just `T`."""
function _parse_typed(expr)
    expr isa Expr && expr.head == :(::) || return (expr, :String)
    name, type = expr.args
    # Handle Union{T, Nothing} -> T (common pattern for optional fields)
    if type isa Expr && type.head == :curly && type.args[1] == :Union
        type = type.args[2]
    end
    (name, type)
end

function _type_to_schema(type)
    type_sym = type isa Symbol ? type : (type isa Expr ? type.args[1] : :String)
    type_map = Dict(:String => "string", :Int => "integer", :Int64 => "integer",
                    :Float64 => "number", :Bool => "boolean", :Vector => "array",
                    :Dict => "object", :CodeBlock => "codeblock")
    get(type_map, type_sym, "string")
end

"""Transform function body: schema/internal params -> tool.field (ctx stays as ctx)"""
function _transform_body(expr, param_names::Set{Symbol})
    if expr isa Symbol
        if expr in param_names
            return :(tool.$expr)
        end
        # ctx and tool stay as-is (available in execute scope)
    elseif expr isa Expr
        new_args = [_transform_body(arg, param_names) for arg in expr.args]
        return Expr(expr.head, new_args...)
    end
    expr
end

function _validate_param(param, index)
    name, type_str, desc, req, _ = param
    name isa Symbol || error("Param $index: name must be Symbol")
    name in RESERVED_FIELD_NAMES && error("Param $index: :$name is reserved")
    type_str in VALID_SCHEMA_TYPES || error("Param $index: invalid type \"$type_str\"")
end

function _schema_to_julia_type(type_str::String)
    type_str in ("string", "codeblock") ? String :
    type_str == "number" ? Union{Float64,Nothing} :
    type_str == "integer" ? Union{Int,Nothing} :
    type_str == "boolean" ? Bool :
    type_str == "array" ? Vector{Any} :
    type_str == "object" ? Dict{String,Any} :
    error("Unknown type: $type_str")
end

function _default_value_expr(T::Type)
    T == String ? :("") : T == Bool ? :(false) : T == Vector{Any} ? :(Any[]) :
    T == Dict{String,Any} ? :(Dict{String,Any}()) : :(nothing)
end

function _default_value_for_type(type_str::String)
    type_str in ("string", "codeblock") ? "" : type_str == "boolean" ? false :
    type_str == "array" ? Any[] : type_str == "object" ? Dict{String,Any}() : nothing
end
