# ProcessResult — universal output from any process/tool execution.
# EVERYTHING is a process. This is the atom-level abstraction.

export Blob, ProcessResult
export blob_raw, blob_b64, is_error, has_blobs, result_text, decode_data_url

using Base64

"""Universal binary blob from any process/tool execution.
`data` holds whatever arrived — String (base64/data URL) or Vector{UInt8} (raw bytes). No eager conversions."""
struct Blob
    name::String
    mime::String
    data::Union{Vector{UInt8}, String}
end

"""Construct Blob from a data URL — extracts mime, keeps the full data URL string as data."""
function Blob(name::String, data_url::String)
    mime_match = match(r"^data:([^;,]+)", data_url)
    Blob(name, mime_match !== nothing ? mime_match.captures[1] : "", data_url)
end

"""Decode a base64 string or data URL (`data:mime;base64,...`) into raw bytes."""
function decode_data_url(s::String)::Vector{UInt8}
    if startswith(s, "data:")
        parts = split(s, ",", limit=2)
        return length(parts) == 2 ? base64decode(parts[2]) : base64decode(s)
    end
    base64decode(s)
end

"""Get raw bytes (decodes base64/data URL only if needed)."""
function blob_raw(b::Blob)::Vector{UInt8}
    b.data isa Vector{UInt8} && return b.data
    decode_data_url(b.data::String)
end

"""Get base64 string (encodes raw bytes only if needed). Strips data URL prefix if present."""
function blob_b64(b::Blob)::String
    b.data isa Vector{UInt8} && return base64encode(b.data)
    s = b.data::String
    if startswith(s, "data:")
        parts = split(s, ",", limit=2)
        return length(parts) == 2 ? parts[2] : s
    end
    s
end

"""Universal result from any process/tool execution. Everything is a process.
Text is just a blob with text/plain mime — no special field needed."""
@kwdef struct ProcessResult
    blobs::Vector{Blob} = Blob[]
    code::Int = 0
end

# Convenience: text is just a blob
ProcessResult(text::String) = ProcessResult([Blob("result", "text/plain", text)], 0)
ProcessResult(text::String, code::Int) = ProcessResult([Blob("result", "text/plain", text)], code)

"""Find the first text/plain blob and return its content as a String."""
function result_text(r::ProcessResult)::String
    for b in r.blobs
        b.mime == "text/plain" && return b.data isa String ? b.data : String(b.data)
    end
    ""
end

is_error(r::ProcessResult) = r.code != 0
has_blobs(r::ProcessResult) = !isempty(r.blobs)
