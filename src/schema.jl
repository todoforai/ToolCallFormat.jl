# Schema generation for LLM system prompts
# Generates tool definitions and format documentation in various styles

export generate_format_documentation, generate_tool_definition
export generate_tool_definitions, generate_system_prompt
export simple_tool_schema, code_tool_schema
export short_type, python_type

# ═══════════════════════════════════════════════════════════════════════════════
# Format Documentation (teaches LLM how to make tool calls)
# ═══════════════════════════════════════════════════════════════════════════════

"""
Generate the tool call format documentation for system prompts.
This teaches the LLM how to make tool calls in the specified format style.
"""
function generate_format_documentation(style::CallStyle=get_default_call_style())::String
    if style == PYTHON
        return generate_python_format_docs()
    elseif style == MINIMAL
        return generate_minimal_format_docs()
    elseif style == TYPESCRIPT
        return generate_typescript_format_docs()
    else
        return generate_concise_format_docs()
    end
end

function generate_concise_format_docs()::String
    """
## Tool Call Format

tool_name(value)
tool_name(param: value)

**Rules:**
- Tool call must start at the **beginning of a line**
- Tool call must end with `)` followed by **newline**
- Positional args (no name needed) come first, then named args with `:`
- **Codeblocks** use backtick fences (N >= 3). Use ``` for normal code. If your code contains ```, use ```` (4 backticks) as the fence. If it contains ````, use ````` (5), and so on. The fence closes only when exactly N backticks appear.

**Types:** `str`, `int`, `bool`, `null`, `list`, `obj`, `codeblock`

**Examples:**
read_file("/file.txt")

read_file("/file.txt", limit: 100)

create("/tmp/hello.txt", content: ```Hello, world!```)

edit("/test.txt", old: "hello", new: "goodbye")

bash(```ls -la```)

bash(
  ```
  ls -la
  echo "hello"
  ```
  timeout: 60000
)

When code contains backticks (e.g. markdown, shell substitution), increase the fence:
bash(
  ````
  cat <<'EOF'
  ```python
  print("hello")
  ```
  EOF
  ````
)
"""
end

function generate_typescript_format_docs()::String
    """
## Tool Call Format

tool_name(value)
tool_name(param: value, param2: value2)

**Rules:**
- Tool call must start at the **beginning of a line**
- Tool call must end with `)` followed by **newline**
- Positional args (no name needed) come first, then named args with `:`
- **Codeblocks** use backtick fences (N >= 3). Use ``` for normal code. If your code contains ```, use ```` (4 backticks) as the fence. If it contains ````, use ````` (5), and so on. The fence closes only when exactly N backticks appear.

**Types:** `string` ("text"), `number` (42, 3.14), `boolean` (true/false), `null`, `string[]` (["a","b"]), `object` ({k: v}), `codeblock` (``` fenced block ```)

**Examples:**
read_file("/file.txt")

read_file(path: "/file.txt", limit: 100)

create("/tmp/hello.txt", content: ```Hello, world!```)

edit(file_path: "/test.txt", old_string: "hello", new_string: "goodbye")

bash(```ls -la```)

bash(
  ```
  ls -la
  echo "hello"
  ```
  timeout: 60000
)

When code contains backticks (e.g. markdown, shell substitution), increase the fence:
bash(
  ````
  cat <<'EOF'
  ```python
  print("hello")
  ```
  EOF
  ````
)
"""
end

function generate_python_format_docs()::String
    """
## Tool Call Format

tool_name(value)
tool_name(param=value, param2=value2)

**Rules:**
- Tool call must start at the **beginning of a line**
- Tool call must end with `)` followed by **newline**
- Positional args (no name needed) come first, then named args with `=`
- **Codeblocks** use backtick fences (N >= 3). Use ``` for normal code. If your code contains ```, use ```` (4 backticks) as the fence. If it contains ````, use ````` (5), and so on. The fence closes only when exactly N backticks appear.

**Types:** `str` ("text"), `int`/`float` (42, 3.14), `bool` (True/False), `None`, `list` (["a","b"]), `dict` ({k: v}), `codeblock` (``` fenced block ```)

**Examples:**
read_file("/file.txt")

read_file("/file.txt", limit=100)

create("/tmp/hello.txt", content=```Hello, world!```)

edit(file_path="/test.txt", old_string="hello", new_string="goodbye")

bash(```ls -la```)

bash(```
ls -la
echo "hello"
```, timeout=60000)

When code contains backticks, increase the fence:
bash(````
echo "use ```code``` in markdown"
````, timeout=60000)
"""
end

function generate_minimal_format_docs()::String
    """
## Tool Call Format

tool_name(value)
tool_name(param: value, param2: value2)

**Rules:**
- Tool call must start at the **beginning of a line**
- Tool call must end with `)` followed by **newline**
- Positional args (no name needed) come first, then named args with `:`
- **Codeblocks** use backtick fences (N >= 3). Use ``` for normal code. If your code contains ```, use ```` (4 backticks) as the fence. If it contains ````, use ````` (5), and so on. The fence closes only when exactly N backticks appear.

**Types:** `string`, `int`, `bool` (true/false), `null`, `string[]`, `object`, `codeblock`

**Examples:**
read_file("/file.txt")

read_file("/file.txt", limit: 100)

create("/tmp/hello.txt", content: ```Hello, world!```)

edit(file_path: "/test.txt", old_string: "hello", new_string: "goodbye")

bash(```ls -la```)

bash(
    ```
    ls -la
    echo "hello"
    ```
    timeout: 60000
)

When code contains backticks (e.g. markdown, shell substitution), increase the fence:
bash(
    ````
    echo "use ```code``` in markdown"
    ````
)
"""
end

# ═══════════════════════════════════════════════════════════════════════════════
# Tool Definition Generation
# ═══════════════════════════════════════════════════════════════════════════════

"""
Generate a single tool definition in the specified style.
"""
function generate_tool_definition(schema::ToolSchema; style::CallStyle=get_default_call_style())::String
    if style == PYTHON
        return generate_tool_definition_python(schema)
    elseif style == MINIMAL
        return generate_tool_definition_minimal(schema)
    elseif style == TYPESCRIPT
        return generate_tool_definition_typescript(schema)
    else
        return generate_tool_definition_concise(schema)
    end
end

function generate_tool_definition_concise(schema::ToolSchema)::String
    io = IOBuffer()

    if !isempty(schema.description)
        write(io, "/// $(schema.description)\n")
    end

    write(io, "$(schema.name)(")

    if !isempty(schema.params)
        if length(schema.params) <= 2
            param_strs = String[]
            for param in schema.params
                opt = param.required ? "" : "?"
                t = short_type(param.type)
                push!(param_strs, "$(param.name)$(opt): $(t)")
            end
            write(io, join(param_strs, ", "))
        else
            write(io, "\n")
            for param in schema.params
                opt = param.required ? "" : "?"
                t = short_type(param.type)
                desc = isempty(param.description) ? "" : " # $(param.description)"
                write(io, "  $(param.name)$(opt): $(t)$(desc)\n")
            end
        end
    end

    write(io, ")\n")
    return String(take!(io))
end

function generate_tool_definition_typescript(schema::ToolSchema)::String
    io = IOBuffer()

    if !isempty(schema.description)
        write(io, "// $(schema.description)\n")
    end

    write(io, "$(schema.name)(")

    if !isempty(schema.params)
        if length(schema.params) <= 2
            param_strs = String[]
            for param in schema.params
                opt = param.required ? "" : "?"
                push!(param_strs, "$(param.name)$(opt): $(param.type)")
            end
            write(io, join(param_strs, ", "))
        else
            write(io, "\n")
            for param in schema.params
                opt = param.required ? "" : "?"
                desc = isempty(param.description) ? "" : " // $(param.description)"
                write(io, "  $(param.name)$(opt): $(param.type),$(desc)\n")
            end
        end
    end

    write(io, ")\n")
    return String(take!(io))
end

function generate_tool_definition_python(schema::ToolSchema)::String
    io = IOBuffer()

    if !isempty(schema.description)
        write(io, "# $(schema.description)\n")
    end

    write(io, "$(schema.name)(")

    if !isempty(schema.params)
        if length(schema.params) <= 2
            param_strs = String[]
            for param in schema.params
                type_hint = python_type(param.type)
                if param.required
                    push!(param_strs, "$(param.name): $(type_hint)")
                else
                    push!(param_strs, "$(param.name): $(type_hint) = None")
                end
            end
            write(io, join(param_strs, ", "))
        else
            write(io, "\n")
            for param in schema.params
                type_hint = python_type(param.type)
                opt = param.required ? "" : " = None"
                desc = isempty(param.description) ? "" : "  # $(param.description)"
                write(io, "  $(param.name): $(type_hint)$(opt),$(desc)\n")
            end
        end
    end

    write(io, ")\n")
    return String(take!(io))
end

function generate_tool_definition_minimal(schema::ToolSchema)::String
    io = IOBuffer()

    if !isempty(schema.description)
        write(io, "/// $(schema.description)\n")
    end

    write(io, "$(schema.name)(")

    if !isempty(schema.params)
        if length(schema.params) <= 2
            param_strs = String[]
            for param in schema.params
                opt = param.required ? "" : "?"
                push!(param_strs, "$(param.name)$(opt): $(param.type)")
            end
            write(io, join(param_strs, ", "))
        else
            write(io, "\n")
            for param in schema.params
                opt = param.required ? "" : "?"
                desc = isempty(param.description) ? "" : " # $(param.description)"
                write(io, "  $(param.name)$(opt): $(param.type)$(desc)\n")
            end
        end
    end

    write(io, ")\n")
    return String(take!(io))
end

# ═══════════════════════════════════════════════════════════════════════════════
# Batch Generation
# ═══════════════════════════════════════════════════════════════════════════════

"""Generate a tool definition section for the system prompt."""
function generate_tool_definitions(schemas::Vector{ToolSchema}; header::String="## Available Tools\n", style::CallStyle=get_default_call_style())::String
    io = IOBuffer()
    write(io, header)

    for (i, schema) in enumerate(schemas)
        write(io, generate_tool_definition(schema; style))
        if i < length(schemas)
            write(io, "\n")
        end
    end

    return String(take!(io))
end

"""
Generate complete system prompt section for tool calling.
Includes format documentation and tool definitions.
"""
function generate_system_prompt(schemas::Vector{ToolSchema}; style::CallStyle=get_default_call_style())::String
    io = IOBuffer()

    write(io, generate_format_documentation(style))
    write(io, "\n\n")
    write(io, generate_tool_definitions(schemas; style))

    return String(take!(io))
end

# ═══════════════════════════════════════════════════════════════════════════════
# Type Conversion Helpers
# ═══════════════════════════════════════════════════════════════════════════════

"""Convert type to Python type hint"""
function python_type(t::String)::String
    type_map = Dict(
        "string" => "str",
        "number" => "int | float",
        "integer" => "int",
        "boolean" => "bool",
        "null" => "None",
        "string[]" => "list[str]",
        "object" => "dict",
        "code" => "codeblock",
        "codeblock" => "codeblock"
    )
    get(type_map, lowercase(t), t)
end

"""Convert type to short form for concise style"""
function short_type(t::String)::String
    type_map = Dict(
        "string" => "str",
        "number" => "num",
        "integer" => "int",
        "boolean" => "bool",
        "null" => "null",
        "string[]" => "str[]",
        "object" => "obj",
        "code" => "```",
        "codeblock" => "```"
    )
    get(type_map, lowercase(t), t)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Schema Helpers
# ═══════════════════════════════════════════════════════════════════════════════

"""Create a simple tool schema (no code block)."""
function simple_tool_schema(;
    name::String,
    description::String="",
    params::Vector{Tuple{String,String,String,Bool}}=Tuple{String,String,String,Bool}[]  # (name, type, desc, required)
)::ToolSchema
    param_schemas = [
        ParamSchema(name=n, type=t, description=d, required=r)
        for (n, t, d, r) in params
    ]
    ToolSchema(name=name, params=param_schemas, description=description)
end

"""Create a tool schema with code block parameter."""
function code_tool_schema(;
    name::String,
    description::String="",
    params::Vector{Tuple{String,String,String,Bool}}=Tuple{String,String,String,Bool}[],
    code_param::Tuple{String,String,Bool}=("content", "Code content", true)  # (name, desc, required)
)::ToolSchema
    param_schemas = [
        ParamSchema(name=n, type=t, description=d, required=r)
        for (n, t, d, r) in params
    ]
    push!(param_schemas, ParamSchema(
        name=code_param[1],
        type="codeblock",
        description=code_param[2],
        required=code_param[3]
    ))
    ToolSchema(name=name, params=param_schemas, description=description)
end
