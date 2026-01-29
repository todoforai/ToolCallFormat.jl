# Tool definition macro
# Simplified macro that registers tools instead of generating structs

export @tool

"""
    @tool name description params handler [needs_approval]

Define and register a tool with minimal boilerplate.

# Arguments
- `name`: Tool name as string (e.g., "cat_file")
- `description`: Tool description for LLM prompt
- `params`: Vector of parameter tuples: (name, type, description, required)
- `handler`: Function (call; kw...) -> result
- `needs_approval`: Optional, default true

# Parameter types
- "string": Single line text
- "codeblock": Multi-line code block
- "number": Numeric value (float)
- "integer": Integer value
- "boolean": Boolean value
- "array": JSON array
- "object": JSON object

# Example
```julia
@tool "cat_file" "Read file contents" [
    (:path, "string", "File path to read", true),
    (:limit, "integer", "Max lines to read", false),
] (call; kw...) -> begin
    kw = kwargs(call)
    content = read(kw.path, String)
    if hasproperty(kw, :limit) && kw.limit !== nothing
        lines = split(content, '\\n')
        content = join(lines[1:min(kw.limit, length(lines))], '\\n')
    end
    content
end false  # needs_approval = false
```
"""
macro tool(name, description, params_expr, handler_expr, needs_approval_expr=true)
    # Parse params from AST
    params = _parse_params(params_expr)

    # Build ParamSchema expressions
    schema_params = [
        :(ParamSchema(name=$(string(p.name)), type=$(p.type), description=$(p.desc), required=$(p.required)))
        for p in params
    ]

    quote
        register_tool(Symbol($name),
            schema = ToolSchema(
                name = $name,
                description = $description,
                params = ParamSchema[$(schema_params...)]
            ),
            handler = $(esc(handler_expr)),
            needs_approval = $(esc(needs_approval_expr))
        )
    end
end

# Internal: parsed param representation
struct _ParsedParam
    name::Symbol
    type::String
    desc::String
    required::Bool
end

# Internal: parse params array from AST
function _parse_params(expr)
    if !(expr isa Expr && expr.head == :vect)
        error("@tool params must be a literal array [...], got: $(typeof(expr))")
    end
    return [_parse_single_param(arg) for arg in expr.args]
end

# Internal: parse single param tuple
function _parse_single_param(expr)
    if !(expr isa Expr && expr.head == :tuple)
        error("Each param must be a tuple (name, type, desc, required), got: $expr")
    end

    args = expr.args
    if length(args) != 4
        error("Param tuple must have 4 elements (name, type, desc, required), got $(length(args))")
    end

    # Parse name (Symbol or QuoteNode)
    name = if args[1] isa QuoteNode
        args[1].value
    elseif args[1] isa Symbol
        args[1]
    else
        error("Param name must be a symbol like :path, got: $(args[1])")
    end

    # Parse type, description, required
    type_str = args[2]
    type_str isa String || error("Param type must be a string, got: $(type_str)")

    desc = args[3]
    desc isa String || error("Param description must be a string, got: $(desc)")

    req = args[4]
    req isa Bool || error("Param required must be true or false, got: $(req)")

    _ParsedParam(name, type_str, desc, req)
end
