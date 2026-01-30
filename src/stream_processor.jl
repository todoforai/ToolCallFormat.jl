# StreamProcessor - Live parsing of LLM output with immediate text streaming
#
# Key behaviors:
# - Only matches tool calls at LINE START (after \n or at beginning)
# - Waits for content blocks (``` ... ```) if present after )
# - Uses parse_tool_call for actual parsing/validation

export StreamProcessor, process_chunk!, finalize!, reset!
export StreamState, STREAMING_TEXT, BUFFERING_IDENTIFIER, IN_TOOL_CALL, AFTER_PAREN, IN_CONTENT_BLOCK

# ═══════════════════════════════════════════════════════════════════════════════
# State Enums
# ═══════════════════════════════════════════════════════════════════════════════

@enum StreamState begin
    STREAMING_TEXT        # Default: streaming text to output
    BUFFERING_IDENTIFIER  # Saw letter at line start, might be tool name
    IN_TOOL_CALL          # Inside tool_name(...), collecting until close
    AFTER_PAREN           # After ), checking for content block or newline
    IN_CONTENT_BLOCK      # Inside ``` content ```, waiting for closing ```
end

@enum StringState begin
    STRING_NONE
    STRING_SINGLE    # '...'
    STRING_DOUBLE    # "..."
    STRING_TRIPLE    # """..."""
    STRING_BACKTICK  # ```...``` (inside tool call args, not content block)
end

# ═══════════════════════════════════════════════════════════════════════════════
# StreamProcessor
# ═══════════════════════════════════════════════════════════════════════════════

"""
StreamProcessor - Character-by-character state machine for parsing LLM output.

Key behaviors:
- Text streams immediately via emit_text callback
- Tool calls only detected at LINE START (after newline or at beginning)
- Handles content blocks: tool(args) ```code```
- Uses parse_tool_call for actual parsing/validation

# Constructor
```julia
sp = StreamProcessor(
    known_tools = Set([:read_file, :shell, :edit]),
    emit_text = text -> print(text),
    emit_tool = call -> handle_tool(call)
)
```

# Usage
```julia
for chunk in llm_stream
    process_chunk!(sp, chunk)
end
finalize!(sp)
```
"""
mutable struct StreamProcessor
    # State
    state::StreamState
    string_state::StringState
    paren_depth::Int
    escape_next::Bool
    at_line_start::Bool  # Track if we're at beginning of a line

    # Buffers
    text_buf::IOBuffer
    ident_buf::IOBuffer
    tool_buf::IOBuffer

    # For detecting """ and ``` (need last 3 chars)
    recent_chars::Vector{Char}

    # Content block tracking
    backtick_count::Int          # Count consecutive backticks
    in_content_body::Bool        # True after opening ``` + newline

    # Tool detection
    known_tools::Set{Symbol}

    # Callbacks
    emit_text::Function      # (String) -> ()
    emit_tool::Function      # (ParsedCall) -> ()
    emit_status::Function    # (String) -> ()
end

function StreamProcessor(;
    known_tools::Set{Symbol} = Set{Symbol}(),
    emit_text::Function = s -> nothing,
    emit_tool::Function = c -> nothing,
    emit_status::Function = s -> nothing
)
    StreamProcessor(
        STREAMING_TEXT,
        STRING_NONE,
        0,
        false,
        true,  # Start at line start
        IOBuffer(),
        IOBuffer(),
        IOBuffer(),
        Char[],
        0,     # backtick_count
        false, # in_content_body
        known_tools,
        emit_text,
        emit_tool,
        emit_status
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# Character Classification
# ═══════════════════════════════════════════════════════════════════════════════

_sp_is_ident_start(c::Char) = isletter(c) || c == '_'
_sp_is_ident_char(c::Char) = isletter(c) || isdigit(c) || c == '_'
_sp_is_whitespace(c::Char) = c == ' ' || c == '\t'

# ═══════════════════════════════════════════════════════════════════════════════
# Main Processing
# ═══════════════════════════════════════════════════════════════════════════════

"""Process a chunk of LLM output. Call this as chunks arrive from streaming API."""
function process_chunk!(sp::StreamProcessor, chunk::String)
    for c in chunk
        process_char!(sp, c)
    end
end

function process_char!(sp::StreamProcessor, c::Char)
    # Track recent chars for triple-quote detection
    push!(sp.recent_chars, c)
    length(sp.recent_chars) > 3 && popfirst!(sp.recent_chars)

    if sp.state == STREAMING_TEXT
        handle_text_state!(sp, c)
    elseif sp.state == BUFFERING_IDENTIFIER
        handle_ident_state!(sp, c)
    elseif sp.state == IN_TOOL_CALL
        handle_tool_state!(sp, c)
    elseif sp.state == AFTER_PAREN
        handle_after_paren_state!(sp, c)
    else  # IN_CONTENT_BLOCK
        handle_content_state!(sp, c)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# State Handlers
# ═══════════════════════════════════════════════════════════════════════════════

function handle_text_state!(sp::StreamProcessor, c::Char)
    # Only start tool detection at line start
    if sp.at_line_start && _sp_is_ident_start(c)
        # Might be start of tool name - flush text and start buffering
        flush_text!(sp)
        sp.state = BUFFERING_IDENTIFIER
        write(sp.ident_buf, c)
        sp.at_line_start = false
    elseif sp.at_line_start && _sp_is_whitespace(c)
        # Whitespace at line start - stay at line start (indented tool calls ok)
        write(sp.text_buf, c)
    else
        write(sp.text_buf, c)
        sp.at_line_start = (c == '\n')
        # Flush on newline or when buffer gets large (for responsiveness)
        if c == '\n' || sp.text_buf.size > 80
            flush_text!(sp)
        end
    end
end

function handle_ident_state!(sp::StreamProcessor, c::Char)
    if _sp_is_ident_char(c)
        write(sp.ident_buf, c)
    elseif c == '('
        name = String(take!(sp.ident_buf))
        if Symbol(name) in sp.known_tools
            # Valid tool - start capturing the call
            sp.state = IN_TOOL_CALL
            sp.paren_depth = 1
            sp.string_state = STRING_NONE
            sp.escape_next = false
            write(sp.tool_buf, name)
            write(sp.tool_buf, '(')
        else
            # Not a tool - emit as regular text
            @warn "Tool not in known_tools, emitting as text" tool_name=name known_tools=sp.known_tools
            emit_as_text!(sp, name, c)
        end
    else
        # Identifier followed by non-paren - emit as text
        emit_as_text!(sp, String(take!(sp.ident_buf)), c)
        sp.at_line_start = (c == '\n')
    end
end

function handle_tool_state!(sp::StreamProcessor, c::Char)
    write(sp.tool_buf, c)

    # Handle escape sequences
    if sp.escape_next
        sp.escape_next = false
        return
    end

    # Update string state and paren depth
    if sp.string_state == STRING_NONE
        sp.string_state = detect_string_start(sp, c)
        if sp.string_state == STRING_NONE
            c == '(' && (sp.paren_depth += 1)
            c == ')' && (sp.paren_depth -= 1)
        end
    else
        handle_string_char!(sp, c)
    end

    # Check if paren part is complete
    if sp.paren_depth == 0 && sp.string_state == STRING_NONE
        sp.state = AFTER_PAREN
        sp.backtick_count = 0
    end
end

function handle_after_paren_state!(sp::StreamProcessor, c::Char)
    if c == '`'
        write(sp.tool_buf, c)
        sp.backtick_count += 1
        if sp.backtick_count == 3
            sp.state = IN_CONTENT_BLOCK
            sp.in_content_body = false
        end
    elseif _sp_is_whitespace(c)
        # Whitespace before potential content block - DON'T add to tool_buf yet
    elseif c == '\n'
        complete_tool_call!(sp)
        sp.at_line_start = true
    else
        # Non-whitespace, non-backtick - trailing text on same line
        # Per line-end rules, this is NOT a valid tool call
        abort_tool_call!(sp, c)
    end
end

function handle_content_state!(sp::StreamProcessor, c::Char)
    write(sp.tool_buf, c)

    if !sp.in_content_body
        if c == '\n'
            sp.in_content_body = true
            sp.backtick_count = 0
        end
    else
        if c == '`'
            sp.backtick_count += 1
        else
            if sp.backtick_count >= 3
                complete_tool_call!(sp)
                return
            end
            sp.backtick_count = 0
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# String Handling (inside tool call args)
# ═══════════════════════════════════════════════════════════════════════════════

function detect_string_start(sp::StreamProcessor, c::Char)::StringState
    recent = sp.recent_chars

    if length(recent) >= 3
        last3 = @view recent[end-2:end]
        if last3 == ['"', '"', '"']
            return STRING_TRIPLE
        elseif last3 == ['`', '`', '`']
            return STRING_BACKTICK
        end
    end

    if c == '"'
        return STRING_DOUBLE
    elseif c == '\''
        return STRING_SINGLE
    end

    return STRING_NONE
end

function handle_string_char!(sp::StreamProcessor, c::Char)
    if c == '\\'
        sp.escape_next = true
        return
    end

    recent = sp.recent_chars

    sp.string_state = if sp.string_state == STRING_DOUBLE && c == '"'
        STRING_NONE
    elseif sp.string_state == STRING_SINGLE && c == '\''
        STRING_NONE
    elseif sp.string_state == STRING_TRIPLE &&
           length(recent) >= 3 && @view(recent[end-2:end]) == ['"', '"', '"']
        STRING_NONE
    elseif sp.string_state == STRING_BACKTICK &&
           length(recent) >= 3 && @view(recent[end-2:end]) == ['`', '`', '`']
        STRING_NONE
    else
        sp.string_state
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Tool Completion
# ═══════════════════════════════════════════════════════════════════════════════

function complete_tool_call!(sp::StreamProcessor)
    raw = String(take!(sp.tool_buf))
    sp.state = STREAMING_TEXT
    sp.at_line_start = false

    parsed = parse_tool_call(raw; require_line_end=false)

    if isnothing(parsed)
        sp.emit_text(raw)
    else
        sp.emit_tool(parsed)
    end
end

"""Abort a tool call when we encounter trailing text (not valid per line-end rules)."""
function abort_tool_call!(sp::StreamProcessor, c::Char)
    raw = String(take!(sp.tool_buf))
    sp.state = STREAMING_TEXT
    sp.at_line_start = false

    write(sp.text_buf, raw)
    write(sp.text_buf, c)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Buffer Operations
# ═══════════════════════════════════════════════════════════════════════════════

function flush_text!(sp::StreamProcessor)
    if sp.text_buf.size > 0
        sp.emit_text(String(take!(sp.text_buf)))
    end
end

function emit_as_text!(sp::StreamProcessor, prefix::String, c::Char)
    sp.state = STREAMING_TEXT
    write(sp.text_buf, prefix)
    write(sp.text_buf, c)
end

"""
Finalize processing - flush remaining buffers.
Call this when LLM stream ends.
"""
function finalize!(sp::StreamProcessor)
    flush_text!(sp)

    if sp.state == AFTER_PAREN
        complete_tool_call!(sp)
    elseif sp.state == IN_TOOL_CALL || sp.state == IN_CONTENT_BLOCK
        raw = String(take!(sp.tool_buf))
        parsed = parse_tool_call(raw; require_line_end=false)
        if !isnothing(parsed)
            sp.emit_tool(parsed)
        else
            sp.emit_text("[Incomplete tool call: $raw]")
        end
    elseif sp.state == BUFFERING_IDENTIFIER
        sp.emit_text(String(take!(sp.ident_buf)))
    end

    sp.state = STREAMING_TEXT
    sp.at_line_start = true
end

"""Reset processor for reuse."""
function reset!(sp::StreamProcessor)
    sp.state = STREAMING_TEXT
    sp.string_state = STRING_NONE
    sp.paren_depth = 0
    sp.escape_next = false
    sp.at_line_start = true
    sp.backtick_count = 0
    sp.in_content_body = false
    take!(sp.text_buf)
    take!(sp.ident_buf)
    take!(sp.tool_buf)
    empty!(sp.recent_chars)
end
