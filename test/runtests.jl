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

    @testset "Parser" begin
        # Simple call
        call = parse_tool_call("read_file(path: \"/test.txt\")\n")
        @test call !== nothing
        @test call.name == "read_file"
        @test call.kwargs["path"].value == "/test.txt"

        # Multiple params
        call2 = parse_tool_call("edit(file: \"/a.txt\", old: \"hello\", new: \"world\")\n")
        @test call2 !== nothing
        @test call2.name == "edit"
        @test call2.kwargs["old"].value == "hello"

        # Numbers and booleans
        call3 = parse_tool_call("config(count: 42, enabled: true, ratio: 3.14)\n")
        @test call3 !== nothing
        @test call3.kwargs["count"].value == 42
        @test call3.kwargs["enabled"].value == true
        @test call3.kwargs["ratio"].value == 3.14

        # Content block
        call4 = parse_tool_call("shell(lang: \"sh\") ```\nls -la\n```")
        @test call4 !== nothing
        @test call4.name == "shell"
        @test occursin("ls -la", call4.content)

        # Invalid (trailing text)
        call5 = parse_tool_call("read_file(path: \"/test\") some text")
        @test call5 === nothing

        # Inline codeblock as named parameter (single line)
        call6 = parse_tool_call("create(path: \"/tmp/hello.txt\", content: ```Hello, world!```)\n")
        @test call6 !== nothing
        @test call6.name == "create"
        @test call6.kwargs["path"].value == "/tmp/hello.txt"
        @test call6.kwargs["content"].value == "Hello, world!"

        # Inline codeblock with language specifier (multi-line)
        call7 = parse_tool_call("create(path: \"/tmp/test.py\", content: ```python\nprint('hello')\n```)\n")
        @test call7 !== nothing
        @test call7.name == "create"
        @test call7.kwargs["content"].value == "print('hello')"

        # Multi-line codeblock content
        call8 = parse_tool_call("bash(script: ```\necho hello\necho world\n```)\n")
        @test call8 !== nothing
        @test call8.kwargs["script"].value == "echo hello\necho world"

        # Positional arguments - single string
        call9 = parse_tool_call("read_file(\"/test.txt\")\n")
        @test call9 !== nothing
        @test call9.name == "read_file"
        @test call9.kwargs["_0"].value == "/test.txt"

        # Positional arguments - multiple values
        call10 = parse_tool_call("config(42, true, \"hello\")\n")
        @test call10 !== nothing
        @test call10.kwargs["_0"].value == 42
        @test call10.kwargs["_1"].value == true
        @test call10.kwargs["_2"].value == "hello"

        # Mixed positional and named arguments
        call11 = parse_tool_call("edit(\"/file.txt\", old: \"hello\", new: \"world\")\n")
        @test call11 !== nothing
        @test call11.kwargs["_0"].value == "/file.txt"
        @test call11.kwargs["old"].value == "hello"
        @test call11.kwargs["new"].value == "world"

        # Positional codeblock
        call12 = parse_tool_call("bash(```echo hello```)\n")
        @test call12 !== nothing
        @test call12.kwargs["_0"].value == "echo hello"

        println("✓ Parser tests passed")
    end

    @testset "StreamProcessor" begin
        # Basic text streaming
        texts = String[]
        sp = StreamProcessor(
            known_tools = Set([:read_file]),
            emit_text = s -> push!(texts, s)
        )
        process_chunk!(sp, "Hello world\n")
        finalize!(sp)
        @test join(texts) == "Hello world\n"

        # Tool detection at line start
        tools = ParsedCall[]
        sp2 = StreamProcessor(
            known_tools = Set([:read_file]),
            emit_tool = c -> push!(tools, c)
        )
        process_chunk!(sp2, "Some text\nread_file(path: \"/test\")\nMore text")
        finalize!(sp2)
        @test length(tools) == 1
        @test tools[1].name == "read_file"

        # Inline NOT detected
        tools2 = ParsedCall[]
        sp3 = StreamProcessor(
            known_tools = Set([:read_file]),
            emit_tool = c -> push!(tools2, c)
        )
        process_chunk!(sp3, "use read_file(path: \"/test\") to read")
        finalize!(sp3)
        @test length(tools2) == 0

        # Multiple tool calls
        tools3 = ParsedCall[]
        sp4 = StreamProcessor(
            known_tools = Set([:read_file, :shell]),
            emit_tool = c -> push!(tools3, c)
        )
        process_chunk!(sp4, "read_file(path: \"/a\")\nshell(cmd: \"ls\")\n")
        finalize!(sp4)
        @test length(tools3) == 2

        println("✓ StreamProcessor tests passed")
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

        # ParsedCall round-trip
        original = "read_file(path: \"/test.txt\")\n"
        call = parse_tool_call(original)
        serialized = serialize_parsed_call(call)
        @test serialized == "read_file(path: \"/test.txt\")"

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
        tool = create_tool(TestDescTool, parse_tool_call("test_desc(name: \"alice\")\n"))
        execute(tool, test_ctx)
        @test tool.result == "name=alice, count=5"

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
        tool2 = create_tool(TestDescFirstTool, parse_tool_call("test_desc_first(path: \"/foo\")\n"))
        execute(tool2, test_ctx)
        @test tool2.result == "path=/foo, limit=10"

        println("✓ @deftool parameter descriptions tests passed")
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
