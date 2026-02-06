# Parser for function-call style tool calls
# Recursive descent parser with full Unicode support

export ParserState, parse_tool_call, try_parse_tool_call
export is_at_line_start, has_valid_line_ending

# ═══════════════════════════════════════════════════════════════════════════════
# Parser State
# ═══════════════════════════════════════════════════════════════════════════════

"""
Parser state for tracking position and context during parsing.
Uses byte indices for proper Unicode support.
"""
mutable struct ParserState
    text::String
    pos::Int      # Current byte position
    endpos::Int   # Last valid byte position
end

ParserState(text::AbstractString) = ParserState(String(text), 1, lastindex(String(text)))

# ═══════════════════════════════════════════════════════════════════════════════
# Character Helpers
# ═══════════════════════════════════════════════════════════════════════════════

current_char(ps::ParserState) = ps.pos <= ps.endpos ? ps.text[ps.pos] : '\0'

function peek_char(ps::ParserState, offset::Int=1)
    peek_pos = ps.pos
    for _ in 1:offset
        peek_pos > ps.endpos && return '\0'
        peek_pos = nextind(ps.text, peek_pos)
    end
    peek_pos > ps.endpos ? '\0' : ps.text[peek_pos]
end

is_eof(ps::ParserState) = ps.pos > ps.endpos

function advance!(ps::ParserState)
    if ps.pos <= ps.endpos
        ps.pos = nextind(ps.text, ps.pos)
    end
end

function advance_n!(ps::ParserState, n::Int)
    for _ in 1:n
        advance!(ps)
    end
end

function skip_whitespace!(ps::ParserState)
    while !is_eof(ps) && current_char(ps) in (' ', '\t', '\n', '\r')
        advance!(ps)
    end
end

# Character classification
is_ident_start(c::Char) = isletter(c) || c == '_'
is_ident_char(c::Char) = isletter(c) || isdigit(c) || c == '_'

# ═══════════════════════════════════════════════════════════════════════════════
# Value Parsers
# ═══════════════════════════════════════════════════════════════════════════════

"""Parse an identifier (function name or parameter name)."""
function parse_identifier!(ps::ParserState)::Union{String, Nothing}
    skip_whitespace!(ps)
    start = ps.pos

    !is_ident_start(current_char(ps)) && return nothing

    while !is_eof(ps) && is_ident_char(current_char(ps))
        advance!(ps)
    end

    return ps.text[start:prevind(ps.text, ps.pos)]
end

"""Parse a string literal (double or single quoted)."""
function parse_string!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)
    quote_char = current_char(ps)
    (quote_char != '"' && quote_char != '\'') && return nothing

    start = ps.pos
    advance!(ps)  # Skip opening quote

    result = IOBuffer()
    while !is_eof(ps)
        c = current_char(ps)
        if c == '\\'
            advance!(ps)
            if !is_eof(ps)
                escaped = current_char(ps)
                if escaped == 'n'
                    write(result, '\n')
                elseif escaped == 't'
                    write(result, '\t')
                elseif escaped == 'r'
                    write(result, '\r')
                elseif escaped == '\\'
                    write(result, '\\')
                elseif escaped == quote_char
                    write(result, quote_char)
                else
                    write(result, '\\')
                    write(result, escaped)
                end
                advance!(ps)
            end
        elseif c == quote_char
            advance!(ps)  # Skip closing quote
            raw = ps.text[start:prevind(ps.text, ps.pos)]
            return ParsedValue(value=String(take!(result)), raw=raw)
        else
            write(result, c)
            advance!(ps)
        end
    end

    return nothing  # Unterminated string
end

"""Parse a number (integer or float, positive or negative)."""
function parse_number!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)
    start = ps.pos

    if current_char(ps) == '-'
        advance!(ps)
    end

    !isdigit(current_char(ps)) && return nothing

    while !is_eof(ps) && isdigit(current_char(ps))
        advance!(ps)
    end

    if current_char(ps) == '.' && isdigit(peek_char(ps))
        advance!(ps)
        while !is_eof(ps) && isdigit(current_char(ps))
            advance!(ps)
        end
    end

    raw = ps.text[start:prevind(ps.text, ps.pos)]
    value = occursin('.', raw) ? parse(Float64, raw) : parse(Int, raw)
    return ParsedValue(value=value, raw=raw)
end

"""Check if text at current position matches a keyword."""
function matches_keyword(ps::ParserState, keyword::String)::Bool
    remaining = SubString(ps.text, ps.pos)
    return startswith(remaining, keyword)
end

"""Parse a boolean value (true/false)."""
function parse_boolean!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)

    if matches_keyword(ps, "true")
        advance_n!(ps, 4)
        return ParsedValue(value=true, raw="true")
    elseif matches_keyword(ps, "false")
        advance_n!(ps, 5)
        return ParsedValue(value=false, raw="false")
    end

    return nothing
end

"""Parse null value."""
function parse_null!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)

    if matches_keyword(ps, "null")
        advance_n!(ps, 4)
        return ParsedValue(value=nothing, raw="null")
    end

    return nothing
end

"""Parse an array value: [elem1, elem2, ...]"""
function parse_array!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)
    current_char(ps) != '[' && return nothing

    start = ps.pos
    advance!(ps)

    elements = Any[]
    skip_whitespace!(ps)

    if current_char(ps) == ']'
        advance!(ps)
        return ParsedValue(value=elements, raw=ps.text[start:prevind(ps.text, ps.pos)])
    end

    while !is_eof(ps)
        val = parse_value!(ps)
        val === nothing && return nothing
        push!(elements, val.value)

        skip_whitespace!(ps)
        c = current_char(ps)

        if c == ']'
            advance!(ps)
            return ParsedValue(value=elements, raw=ps.text[start:prevind(ps.text, ps.pos)])
        elseif c == ','
            advance!(ps)
        else
            return nothing
        end
    end

    return nothing
end

"""Parse an object value: {key: value, ...}"""
function parse_object!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)
    current_char(ps) != '{' && return nothing

    start = ps.pos
    advance!(ps)

    obj = Dict{String, Any}()
    skip_whitespace!(ps)

    if current_char(ps) == '}'
        advance!(ps)
        return ParsedValue(value=obj, raw=ps.text[start:prevind(ps.text, ps.pos)])
    end

    while !is_eof(ps)
        skip_whitespace!(ps)
        key = parse_identifier!(ps)
        if key === nothing
            str_key = parse_string!(ps)
            str_key === nothing && return nothing
            key = str_key.value
        end

        skip_whitespace!(ps)
        current_char(ps) != ':' && return nothing
        advance!(ps)

        val = parse_value!(ps)
        val === nothing && return nothing
        obj[key] = val.value

        skip_whitespace!(ps)
        c = current_char(ps)

        if c == '}'
            advance!(ps)
            return ParsedValue(value=obj, raw=ps.text[start:prevind(ps.text, ps.pos)])
        elseif c == ','
            advance!(ps)
        else
            return nothing
        end
    end

    return nothing
end

"""Dedent a multi-line string by removing common leading whitespace."""
function dedent(s::AbstractString)::String
    lines = split(s, '\n')

    # Find minimum indentation (ignoring empty lines)
    min_indent = typemax(Int)
    for line in lines
        isempty(line) && continue
        indent = length(line) - length(lstrip(line))
        if indent < min_indent
            min_indent = indent
        end
    end

    # If no indentation found or only empty lines, return as-is
    (min_indent == 0 || min_indent == typemax(Int)) && return String(s)

    # Remove the common indentation from each line
    result = IOBuffer()
    for (i, line) in enumerate(lines)
        i > 1 && write(result, '\n')
        if length(line) >= min_indent
            write(result, line[nextind(line, 0, min_indent+1):end])
        else
            write(result, line)
        end
    end

    return String(take!(result))
end

"""Count consecutive backticks at current position without advancing."""
function count_backticks_at(ps::ParserState)::Int
    count = 0
    pos = ps.pos
    while pos <= ps.endpos && ps.text[pos] == '`'
        count += 1
        pos = nextind(ps.text, pos)
    end
    return count
end

"""Parse an inline codeblock value with variable-length fences: N backticks open, exactly N close (N >= 3)."""
function parse_codeblock!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)

    # Must start with at least 3 backticks
    opening_count = count_backticks_at(ps)
    opening_count < 3 && return nothing

    start = ps.pos
    advance_n!(ps, opening_count)  # Skip opening fence

    # Content starts immediately after opening fence
    content_start = ps.pos

    # Find closing fence: exactly opening_count backticks followed by non-backtick (or EOF)
    while !is_eof(ps)
        if current_char(ps) == '`'
            run_start = ps.pos
            run_count = count_backticks_at(ps)
            if run_count == opening_count
                # Check that the run is followed by non-backtick (or EOF)
                content_end = prevind(ps.text, run_start)
                advance_n!(ps, run_count)
                if is_eof(ps) || current_char(ps) != '`'
                    content = content_start <= content_end ? ps.text[content_start:content_end] : ""
                    raw = ps.text[start:prevind(ps.text, ps.pos)]
                    # Strip surrounding newlines and dedent
                    content = strip(content, '\n')
                    content = dedent(content)
                    return ParsedValue(value=content, raw=raw)
                end
                # More backticks follow — this wasn't the closing fence, continue scanning
            else
                # Skip the entire run of backticks
                advance_n!(ps, run_count)
            end
        else
            advance!(ps)
        end
    end

    return nothing  # Unterminated codeblock
end

"""Parse any value (string, number, boolean, null, array, object, or codeblock)."""
function parse_value!(ps::ParserState)::Union{ParsedValue, Nothing}
    skip_whitespace!(ps)
    c = current_char(ps)

    (c == '"' || c == '\'') && return parse_string!(ps)
    (isdigit(c) || (c == '-' && isdigit(peek_char(ps)))) && return parse_number!(ps)
    c == '[' && return parse_array!(ps)
    c == '{' && return parse_object!(ps)
    c == '`' && return parse_codeblock!(ps)

    if c == 't' || c == 'f'
        return parse_boolean!(ps)
    elseif c == 'n'
        return parse_null!(ps)
    end

    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════════
# Tool Call Parsing
# ═══════════════════════════════════════════════════════════════════════════════

"""Parse function parameters: supports both positional and named arguments.
Positional: tool("value", 123)
Named: tool(key: "value", count: 123)
Mixed: tool("positional", key: "named")
"""
function parse_params!(ps::ParserState)::Union{Dict{String, ParsedValue}, Nothing}
    kwargs = Dict{String, ParsedValue}()
    positional_index = 0

    skip_whitespace!(ps)
    current_char(ps) == ')' && return kwargs

    while !is_eof(ps)
        skip_whitespace!(ps)

        # Save position to potentially backtrack
        saved_pos = ps.pos

        # Try to parse as named argument (identifier: value)
        name = parse_identifier!(ps)

        if name !== nothing
            skip_whitespace!(ps)
            if current_char(ps) == ':'
                # Named argument: name: value
                advance!(ps)
                val = parse_value!(ps)
                val === nothing && return nothing
                kwargs[name] = val
            else
                # No colon - backtrack and try as positional value
                # (the identifier might be true/false/null or just not a named arg)
                ps.pos = saved_pos
                val = parse_value!(ps)
                val === nothing && return nothing
                kwargs["_$positional_index"] = val
                positional_index += 1
            end
        else
            # Not an identifier - must be a positional value
            val = parse_value!(ps)
            val === nothing && return nothing
            kwargs["_$positional_index"] = val
            positional_index += 1
        end

        skip_whitespace!(ps)
        c = current_char(ps)

        if c == ')'
            return kwargs
        elseif c == ','
            advance!(ps)
            # Continue to next parameter
        else
            # Allow comma-less separation (newline or space separated params)
            # If we see something that could start a new param, continue
            # Otherwise fail
            if is_ident_start(c) || c == '"' || c == '\'' || c == '`' ||
               c == '[' || c == '{' || isdigit(c) || c == '-'
                # Looks like another parameter, continue without comma
            else
                return nothing
            end
        end
    end

    return nothing
end

"""Parse content block after closing paren with variable-length fences."""
function parse_content_block!(ps::ParserState)::String
    skip_whitespace!(ps)

    opening_count = count_backticks_at(ps)
    if opening_count >= 3
        advance_n!(ps, opening_count)

        # Content starts immediately after opening fence
        content_start = ps.pos

        # Find closing fence: exactly opening_count backticks followed by non-backtick (or EOF)
        while !is_eof(ps)
            if current_char(ps) == '`'
                run_start = ps.pos
                run_count = count_backticks_at(ps)
                if run_count == opening_count
                    content_end = prevind(ps.text, run_start)
                    advance_n!(ps, run_count)
                    if is_eof(ps) || current_char(ps) != '`'
                        content = content_start <= content_end ? ps.text[content_start:content_end] : ""
                        return strip(content, '\n')
                    end
                else
                    advance_n!(ps, run_count)
                end
            else
                advance!(ps)
            end
        end
    end

    return ""
end

"""Check if position is at line start (beginning of text or after newline)."""
function is_at_line_start(text::String, pos::Int)::Bool
    pos == 1 && return true
    prev_pos = prevind(text, pos)
    return text[prev_pos] == '\n'
end

"""
Check if we have valid line ending after closing paren.
Valid endings: newline, end of string, or content block (N >= 3 backticks)
"""
function has_valid_line_ending(ps::ParserState)::Bool
    is_eof(ps) && return true

    c = current_char(ps)
    c == '\n' && return true

    if c in (' ', '\t')
        temp_pos = ps.pos
        while temp_pos <= ps.endpos && ps.text[temp_pos] in (' ', '\t')
            temp_pos = nextind(ps.text, temp_pos)
        end
        # Count backticks at temp_pos
        bt_count = 0
        bt_pos = temp_pos
        while bt_pos <= ps.endpos && ps.text[bt_pos] == '`'
            bt_count += 1
            bt_pos = nextind(ps.text, bt_pos)
        end
        bt_count >= 3 && return true
    end

    count_backticks_at(ps) >= 3 && return true

    return false
end

"""
Parse a complete tool call from text.

# Arguments
- `text`: The tool call text to parse
- `require_line_end`: If true, requires newline/EOF/content block after closing paren

# Returns
- `ParsedCall` on success, `nothing` on failure

# Supported Formats
- Simple: `read_file(path: "/file.txt")`
- Multi-line: `edit(\\n  file_path: "/test.txt"\\n)`
- With content: `shell(cmd: "ls") ```\\nls -la\\n```
"""
function parse_tool_call(text::AbstractString; require_line_end::Bool=true)::Union{ParsedCall, Nothing}
    ps = ParserState(text)

    name = parse_identifier!(ps)
    name === nothing && return nothing

    skip_whitespace!(ps)
    current_char(ps) != '(' && return nothing
    advance!(ps)

    kwargs = parse_params!(ps)
    kwargs === nothing && return nothing

    skip_whitespace!(ps)
    current_char(ps) != ')' && return nothing
    advance!(ps)

    if require_line_end && !has_valid_line_ending(ps)
        return nothing
    end

    content = parse_content_block!(ps)

    return ParsedCall(
        name=name,
        kwargs=kwargs,
        content=content,
        raw=String(text)[1:prevind(String(text), ps.pos)]
    )
end

"""
Try to find and parse a tool call at the beginning of text.
Returns (ParsedCall, remaining_text) or (nothing, original_text).
"""
function try_parse_tool_call(text::String, tool_names::Set{String})::Tuple{Union{ParsedCall, Nothing}, String}
    ps = ParserState(text)
    skip_whitespace!(ps)

    start = ps.pos
    name = parse_identifier!(ps)
    name === nothing && return (nothing, text)

    name ∉ tool_names && return (nothing, text)

    skip_whitespace!(ps)
    current_char(ps) != '(' && return (nothing, text)

    call = parse_tool_call(text[start:end])
    if call !== nothing
        consumed = start - 1 + length(call.raw)
        remaining = consumed < length(text) ? text[nextind(text, consumed):end] : ""
        return (call, remaining)
    end

    return (nothing, text)
end
