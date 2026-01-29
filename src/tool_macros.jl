# Tool definition macros
#
# @deftool - Primary, function-style (recommended)
# @tool    - Verbose style (for advanced cases)

export @tool, @deftool, CodeBlock

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
# @deftool - Function-style macro (primary)
#==============================================================================#

"""
    @deftool "description" name(args...; kwargs...) = ...
    @deftool "description" function name(args...; kwargs...) ... end

Define a tool using function syntax. Description is passed as first argument.
Struct name is auto-generated: `snake_case` → `CamelCaseTool`.

# Examples

```julia
@deftool "Send keyboard input" send_key(text::String) = "Sending keys: \$text"

@deftool "Execute shell commands" bash(cmd::CodeBlock) = run_shell(cmd)

@deftool "Click coordinates" click(x::Int, y::Int) = "Click at (\$x, \$y)"

@deftool "Search the web" web_search(query::String) = search_web(query)

@deftool "Read file with optional limit" function cat_file(path::String; limit::Union{Int,Nothing}=nothing)
    content = read(path, String)
    isnothing(limit) ? content : first_n_lines(content, limit)
end
```
"""
macro deftool(args...)
    # Parse args: "description" func_expr
    func_expr = nothing
    description = ""

    for arg in args
        if arg isa Expr
            func_expr = arg
        elseif arg isa String
            description = arg
        else
            error("@deftool: unexpected argument: $arg")
        end
    end

    func_expr === nothing && error("@deftool: missing function expression")

    func_name, params, body = _parse_func(func_expr)
    struct_name = Symbol(_to_camel_case(string(func_name)), :Tool)

    params_expr = _build_params_expr(params)
    param_names = Set(p.name for p in params)
    new_body = _transform_body(body, param_names)

    execute_body = :(tool.result = string($new_body))

    esc(quote
        @tool $struct_name $(string(func_name)) $description $params_expr (tool; kw...) -> $execute_body
    end)
end

#==============================================================================#
# @tool - Verbose macro (advanced)
#==============================================================================#

"""
    @tool StructName "tool_name" "description" [params] [execute_fn] [result_fn]

Define a tool with explicit schema. Use @deftool for simpler syntax.

# Params format
    [(:name, "type", "description", required, default), ...]

Types: "string", "codeblock", "number", "integer", "boolean", "array", "object"

# Example
```julia
@tool CatFileTool "cat_file" "Read file contents" [
    (:path, "string", "File path", true, nothing),
    (:limit, "integer", "Max lines", false, nothing),
] (tool; kw...) -> read(tool.path, String)
```
"""
macro tool(struct_name, tool_name, description, params_expr=:([]), execute_expr=nothing, result_expr=nothing)
    params = _parse_params_ast(params_expr)
    for (i, p) in enumerate(params)
        _validate_param(p, i)
    end

    sn = esc(struct_name)
    is_passive = isempty(params)

    if is_passive
        _generate_passive_tool(sn, tool_name, description)
    else
        _generate_active_tool(sn, tool_name, description, params, execute_expr, result_expr)
    end
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

function _generate_active_tool(sn, tool_name, description, params, execute_expr, result_expr)
    base_fields = [(:id, UUID, :(uuid4())), (:result, String, :(""))]

    user_fields = [(name, _schema_to_julia_type(type_str), default === nothing ? _default_value_expr(_schema_to_julia_type(type_str)) : default)
                   for (name, type_str, _, _, default) in params]

    all_fields = vcat(base_fields, user_fields)
    struct_field_exprs = [:($name::$jl_type) for (name, jl_type, _) in all_fields]
    kwarg_exprs = [Expr(:kw, name, def_expr) for (name, _, def_expr) in all_fields]
    call_arg_exprs = [name for (name, _, _) in all_fields]

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
        push!(result.args, :(ToolCallFormat.execute(tool::$sn; kwargs...) = $(esc(execute_expr))(tool; kwargs...)))
    end

    if result_expr !== nothing
        push!(result.args, :(ToolCallFormat.result2string(tool::$sn)::String = $(esc(result_expr))(tool)))
    else
        push!(result.args, :(ToolCallFormat.result2string(tool::$sn)::String = tool.result))
    end

    result
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
    params = NamedTuple{(:name, :type, :required, :default), Tuple{Symbol, Any, Bool, Any}}[]

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

function _parse_param(expr, is_positional)
    if expr isa Expr && expr.head == :kw
        name, type = _parse_typed(expr.args[1])
        return (name=name, type=type, required=false, default=expr.args[2])
    end
    if expr isa Expr && expr.head == :(::)
        name, type = _parse_typed(expr)
        return (name=name, type=type, required=is_positional, default=nothing)
    end
    if expr isa Symbol
        return (name=expr, type=:String, required=is_positional, default=nothing)
    end
    error("@deftool: cannot parse param: $expr")
end

function _parse_typed(expr)
    expr isa Expr && expr.head == :(::) || return (expr, :String)
    name, type = expr.args
    if type isa Expr && type.head == :curly && type.args[1] == :Union
        type = type.args[2]
    end
    (name, type)
end

function _build_params_expr(params)
    tuples = map(params) do p
        schema_type = _type_to_schema(p.type)
        default_expr = p.default === nothing ? :nothing : p.default
        :($(QuoteNode(p.name)), $schema_type, "", $(p.required), $default_expr)
    end
    Expr(:vect, tuples...)
end

function _type_to_schema(type)
    type_sym = type isa Symbol ? type : (type isa Expr ? type.args[1] : :String)
    type_map = Dict(:String => "string", :Int => "integer", :Int64 => "integer",
                    :Float64 => "number", :Bool => "boolean", :Vector => "array",
                    :Dict => "object", :CodeBlock => "codeblock")
    get(type_map, type_sym, "string")
end

function _transform_body(expr, param_names::Set{Symbol})
    if expr isa Symbol && expr in param_names
        return :(tool.$expr)
    elseif expr isa Expr
        new_args = [_transform_body(arg, param_names) for arg in expr.args]
        return Expr(expr.head, new_args...)
    end
    expr
end

function _parse_params_ast(expr)
    expr isa Expr && expr.head == :vect || error("@tool params must be [...], got: $(typeof(expr))")
    [_parse_single_param_ast(arg) for arg in expr.args]
end

function _parse_single_param_ast(expr)
    expr isa Expr && expr.head == :tuple || error("Each param must be a tuple, got: $expr")
    length(expr.args) == 5 || error("Param tuple must have 5 elements, got $(length(expr.args))")

    name = expr.args[1] isa QuoteNode ? expr.args[1].value : expr.args[1]
    type_str = expr.args[2]
    desc = expr.args[3]
    req = expr.args[4]
    default = expr.args[5]
    default = (default isa Symbol && default == :nothing) ? nothing : default

    (name, type_str, desc, req, default)
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
