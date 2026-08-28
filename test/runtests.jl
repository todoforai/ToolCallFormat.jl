using Test
using ToolCallFormat

# Simple context for testing
struct TestContext <: AbstractContext end
const test_ctx = TestContext()

@testset "ToolCallFormat.jl" begin

    @testset "Types" begin
        # ParsedValue
        pv = ParsedValue(value="test", raw="\"test\"")
        @test pv.value == "test"
        @test pv.raw == "\"test\""

        # ParsedCall
        pc = ParsedCall(name="test_tool", kwargs=Dict("a" => ParsedValue(1)))
        @test pc.name == "test_tool"
        @test pc.kwargs["a"].value == 1

        # ToolSchema
        ts = ToolSchema(
            name="read_file",
            params=[ParamSchema(name="path", type="string", required=true)],
            description="Read a file"
        )
        @test ts.name == "read_file"
        @test length(ts.params) == 1

        println("✓ Types tests passed")
    end

    @testset "Serializer" begin
        # Value serialization
        @test serialize_value("hello") == "\"hello\""
        @test serialize_value(42) == "42"
        @test serialize_value(true) == "true"
        @test serialize_value(nothing) == "null"
        @test serialize_value([1, 2, 3]) == "[1, 2, 3]"

        # Python style
        @test serialize_value(true; style=PYTHON) == "True"
        @test serialize_value(nothing; style=PYTHON) == "None"

        # Tool call
        @test serialize_tool_call("test", Dict("a" => 1)) == "test(a: 1)"
        @test serialize_tool_call("test", Dict("a" => 1); style=PYTHON) == "test(a=1)"

        # ParsedCall serialization
        call = ParsedCall(name="read_file",
            kwargs=Dict("path" => ParsedValue(value="/test.txt", raw="\"/test.txt\"")))
        serialized = serialize_parsed_call(call)
        @test serialized == "read_file(path: \"/test.txt\")"

        # --- Variable-length fence serializer ---

        # required_fence_length: no backticks -> 3
        @test required_fence_length("hello world") == 3

        # required_fence_length: single backtick -> 3
        @test required_fence_length("use `code` here") == 3

        # required_fence_length: triple backticks -> 4
        @test required_fence_length("use ```code``` here") == 4

        # required_fence_length: 4 backticks -> 5
        @test required_fence_length("use ````code```` here") == 5

        # serialize_codeblock_value: no backticks uses 3
        cb = serialize_codeblock_value("hello")
        @test startswith(cb, "```\n")
        @test endswith(cb, "```")

        # serialize_codeblock_value: content with ``` uses 4
        cb2 = serialize_codeblock_value("echo ```code```")
        @test startswith(cb2, "````\n")
        @test endswith(cb2, "````")

        # serialize_tool_call_with_content: content fenced with 4 backticks (content has ```)
        content_with_bt = "echo ```hello```"
        serialized_tc = serialize_tool_call_with_content("shell", Dict("lang" => "sh"), content_with_bt)
        @test occursin("shell(lang: \"sh\")", serialized_tc)
        @test occursin("````\n" * content_with_bt * "\n````", serialized_tc)

        # --- Triple-quote text value serialization ---

        # required_quote_fence_length: no quotes -> 3
        @test required_quote_fence_length("hello world") == 3

        # required_quote_fence_length: single quote -> 3
        @test required_quote_fence_length("say \"hello\"") == 3

        # required_quote_fence_length: triple quotes -> 4
        @test required_quote_fence_length("use \"\"\"text\"\"\" here") == 4

        # serialize_text_value: no quotes uses 3
        tv = serialize_text_value("hello")
        @test startswith(tv, "\"\"\"\n")
        @test endswith(tv, "\"\"\"")

        # serialize_text_value: content with """ uses 4
        tv2 = serialize_text_value("has \"\"\"triple\"\"\" quotes")
        @test startswith(tv2, "\"\"\"\"\n")
        @test endswith(tv2, "\"\"\"\"")

        # serialize_text_value: exact content pass-through inside a triple-quote fence
        tv3 = serialize_text_value("Hello, world!")
        @test tv3 == "\"\"\"\nHello, world!\"\"\""

        println("✓ Serializer tests passed")
    end

    @testset "@deftool Parameter Descriptions" begin
        # Tool with description and default (description-first syntax)
        @deftool "Test tool" test_desc(
            "The name" => name::String,
            "How many" => count::Int = 5
        ) = "name=$name, count=$count"

        schema = get_tool_schema(TestDescTool)
        @test schema.name == "test_desc"
        @test length(schema.params) == 2

        # Check first param (required, with desc)
        p1 = schema.params[1]
        @test p1.name == "name"
        @test p1.description == "The name"
        @test p1.required == true

        # Check second param (optional with default, with desc)
        p2 = schema.params[2]
        @test p2.name == "count"
        @test p2.description == "How many"
        @test p2.required == false

        # Test tool execution
        tool = create_tool(TestDescTool, ParsedCall(name="test_desc",
            kwargs=Dict("name" => ParsedValue(value="alice", raw="\"alice\""))))
        execute(tool, test_ctx)
        @test result_text(tool.process_result) == "name=alice, count=5"

        # Description-first syntax with various types
        @deftool "Description first test" test_desc_first(
            "The path to read" => path::String,
            "Maximum lines" => limit::Int = 10
        ) = "path=$path, limit=$limit"

        schema2 = get_tool_schema(TestDescFirstTool)
        @test schema2.name == "test_desc_first"
        @test length(schema2.params) == 2

        # Check first param (required, desc-first)
        p1 = schema2.params[1]
        @test p1.name == "path"
        @test p1.description == "The path to read"
        @test p1.required == true

        # Check second param (optional with default, desc-first)
        p2 = schema2.params[2]
        @test p2.name == "limit"
        @test p2.description == "Maximum lines"
        @test p2.required == false

        # Test execution
        tool2 = create_tool(TestDescFirstTool, ParsedCall(name="test_desc_first",
            kwargs=Dict("path" => ParsedValue(value="/foo", raw="\"/foo\""))))
        execute(tool2, test_ctx)
        @test result_text(tool2.process_result) == "path=/foo, limit=10"

        println("✓ @deftool parameter descriptions tests passed")
    end

    @testset "Structured argument coercion" begin
        @deftool "Object-array coercion test" test_object_array(
            "Structured rows" => rows::Vector{Dict{String,Any}}
        ) = string(length(rows))

        json_rows = "[{\"id\":\"one\",\"options\":[{\"label\":\"A\",\"description\":\"desc\"}]}]"
        call = ParsedCall(name="test_object_array", kwargs=Dict("rows" => ParsedValue(json_rows)))
        tool = create_tool(TestObjectArrayTool, call)
        @test tool.rows isa Vector{Dict{String,Any}}
        @test tool.rows[1]["id"] == "one"
        @test tool.rows[1]["options"][1]["label"] == "A"

        # Lone object where an array is expected: wrapped into a 1-element vector.
        lone_obj = "{\"id\":\"one\",\"options\":[{\"label\":\"A\",\"description\":\"desc\"}]}"
        lone_call = ParsedCall(name="test_object_array", kwargs=Dict("rows" => ParsedValue(lone_obj)))
        lone_tool = create_tool(TestObjectArrayTool, lone_call)
        @test lone_tool.rows isa Vector{Dict{String,Any}}
        @test length(lone_tool.rows) == 1
        @test lone_tool.rows[1]["id"] == "one"

        bad_call = ParsedCall(name="test_object_array", kwargs=Dict("rows" => ParsedValue("not json")))
        @test_throws ToolArgumentError create_tool(TestObjectArrayTool, bad_call)

        # Real JSON escapes/numbers a hand-rolled parser used to botch: \uXXXX
        # (incl. surrogate pairs), \/, and exponent numbers — all handled by JSON3.
        json_escapes = "[{\"id\":\"caf\\u00e9\",\"emoji\":\"\\ud83d\\ude00\",\"path\":\"a\\/b\",\"n\":1e3}]"
        esc_tool = create_tool(TestObjectArrayTool,
            ParsedCall(name="test_object_array", kwargs=Dict("rows" => ParsedValue(json_escapes))))
        @test esc_tool.rows[1]["id"] == "café"
        @test esc_tool.rows[1]["emoji"] == "😀"
        @test esc_tool.rows[1]["path"] == "a/b"
        @test esc_tool.rows[1]["n"] == 1000

        # Regressions: object-looking text stays literal for String fields,
        # parses for Dict fields, and arbitrary scalars still fail for vectors.
        @deftool "String coercion regression" test_string_arg(
            "Literal value" => value::String
        ) = value
        object_text = "{\"id\":\"one\"}"
        string_tool = create_tool(TestStringArgTool,
            ParsedCall(name="test_string_arg", kwargs=Dict("value" => ParsedValue(object_text))))
        @test string_tool.value == object_text

        @deftool "Dict coercion regression" test_dict_arg(
            "Object value" => value::Dict{String,Any}
        ) = string(value)
        dict_tool = create_tool(TestDictArgTool,
            ParsedCall(name="test_dict_arg", kwargs=Dict("value" => ParsedValue(object_text))))
        @test dict_tool.value == Dict{String,Any}("id" => "one")

        @deftool "Generic array coercion" test_any_array(
            "Values" => values::Vector{Any}
        ) = string(values)
        bad_scalar = ParsedCall(name="test_any_array", kwargs=Dict("values" => ParsedValue("not json")))
        @test_throws ToolArgumentError create_tool(TestAnyArrayTool, bad_scalar)

        # Models / MCP gateways stringify integers ("120") and sometimes send
        # JSON floats (120.0) for integer fields generated as Union{Int,Nothing}.
        @deftool "Int coercion" test_int_arg(
            "Seconds" => timeout::Int = 30
        ) = string(timeout)
        int_from_str = create_tool(TestIntArgTool,
            ParsedCall(name="test_int_arg", kwargs=Dict("timeout" => ParsedValue("120"))))
        @test int_from_str.timeout == 120
        int_from_float_str = create_tool(TestIntArgTool,
            ParsedCall(name="test_int_arg", kwargs=Dict("timeout" => ParsedValue("120.0"))))
        @test int_from_float_str.timeout == 120
        int_from_float = create_tool(TestIntArgTool,
            ParsedCall(name="test_int_arg", kwargs=Dict("timeout" => ParsedValue(120.0))))
        @test int_from_float.timeout == 120
        @test_throws ToolArgumentError create_tool(TestIntArgTool,
            ParsedCall(name="test_int_arg", kwargs=Dict("timeout" => ParsedValue("soon"))))

        # A `Union{T,Nothing}` param is unwrapped to T for the LLM-facing schema, but
        # the struct field must stay nullable: `group::String = nothing` threw
        # `convert(String, nothing)` on every construction of the tool.
        @deftool "Nullable default" test_nullable_arg(
            "Group slug" => group::Union{String,Nothing} = nothing
        ) = string(group)
        @test fieldtype(TestNullableArgTool, :group) == Union{String,Nothing}
        @test TestNullableArgTool().group === nothing
        @test create_tool(TestNullableArgTool, ParsedCall(name="test_nullable_arg")).group === nothing
        @test create_tool(TestNullableArgTool,
            ParsedCall(name="test_nullable_arg", kwargs=Dict("group" => ParsedValue("g")))).group == "g"
        # The LLM-facing schema is unchanged by the nullable field type.
        nullable_param = only(get_tool_schema(TestNullableArgTool).params)
        @test nullable_param.type == "string"
        @test nullable_param.required == false
        @test nullable_param.default == "nothing"

        # Same in `function ... end` form, and for a non-nullable neighbour param.
        @deftool "Nullable default, function form" function test_nullable_fn(
            "Group slug" => group::Union{String,Nothing} = nothing,
            "Name" => name::String = "";
            ctx = nothing
        )
            string(group, name)
        end
        @test fieldtype(TestNullableFnTool, :group) == Union{String,Nothing}
        @test fieldtype(TestNullableFnTool, :name) == String
        @test TestNullableFnTool().group === nothing

        # Member order must not matter, and a nullable non-string keeps its schema type.
        @deftool "Reversed union" test_nullable_rev(
            "Group slug" => group::Union{Nothing,String} = nothing,
            "Seconds" => timeout::Union{Nothing,Int} = nothing
        ) = string(group, timeout)
        @test fieldtype(TestNullableRevTool, :group) == Union{String,Nothing}
        @test TestNullableRevTool().group === nothing
        @test [p.type for p in get_tool_schema(TestNullableRevTool).params] == ["string", "integer"]

        # A union that isn't `Union{T,Nothing}` used to be silently reduced to its first
        # member (dropping Int here); it's now a macro-expansion error.
        @test_throws LoadError @eval @deftool "Bad union" test_bad_union(
            "Value" => value::Union{String,Int}
        ) = string(value)

        println("✓ Structured argument coercion tests passed")
    end

    @testset "Schema Generation" begin
        schema = ToolSchema(
            name="read_file",
            params=[
                ParamSchema(name="path", type="string", description="File path", required=true),
                ParamSchema(name="limit", type="number", description="Max lines", required=false)
            ],
            description="Read file contents"
        )

        # Generate definition
        def = generate_tool_definition(schema)
        @test occursin("read_file", def)
        @test occursin("path", def)

        # Format documentation
        docs = generate_format_documentation()
        @test occursin("Tool Call Format", docs)
        @test occursin("tool_name", docs)

        # System prompt
        prompt = generate_system_prompt([schema])
        @test occursin("Tool Call Format", prompt)
        @test occursin("read_file", prompt)

        println("✓ Schema generation tests passed")
    end

end

println("\n" * "=" ^ 50)
println("All ToolCallFormat tests passed!")
println("=" ^ 50)
