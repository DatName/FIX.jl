module FIX

global const TAGS_INT_STRING = Dict{Int64, String}()
global const TAGS_STRING_INT = Dict{String, Int64}()

import Base: start

abstract type AbstractFIXHandler end
export AbstractFIXHandler, FIXClient, send_message, start

function onFIXMessage(this::AbstractFIXHandler, x::Any)
    T = typeof(this)
    X = typeof(x)
    throw(ErrorException("Method `onFixMessage` is not implemented by $T for argument type $X"))
end

function __init__()
    global TAGS_INT_STRING
    global TAGS_STRING_INT

    fid = open(joinpath(@__DIR__, "../etc/tags.csv"), "r");
    line_number = 0
    while !eof(fid)
        line_number += 1
        line = readline(fid);
        data = split(line, ",");
        if length(data) != 2
            close(fid)
            throw(ErrorException("Invalid data in 'etc/tags.csv' file on line $line_number: $line"))
        end
        tag = parse(Int64, String(data[1]))
        val = String(data[2])

        TAGS_INT_STRING[tag] = val
        TAGS_STRING_INT[val] = tag
    end
    close(fid)

    return nothing
end

mutable struct FIXClientTasks
    read::Nullable{Task}
    function FIXClientTasks()
        return new(Nullable{Task}())
    end
end

struct FIXClient{T <: IO, H <: AbstractFIXHandler}
    stream::T
    handler::H
    tags::Dict{Int64, String}
    values::Dict{String, Int64}
    delimiter::Char
    m_head::String
    m_tasks::FIXClientTasks
    m_parselevel::Int64 #0: raw bytes, 1 Dict Int64 => String, 2 Dict String => String
    function FIXClient(stream::T,
                        handler::H,
                        header::Dict{Int64, String};
                        delimiter::Char = Char(1),
                        parselevel::Int64 = 2) where {T <: IO, H <: AbstractFIXHandler}
        global TAGS_INT_STRING
        global TAGS_STRING_INT
        m_header = join([string("$k=$v") for (k, v) in header], delimiter)
        m_header *= delimiter
        if !(parselevel ∈ [0, 1, 2])
            throw(ErrorException("Parse level must be in [0, 1, 2]"))
        end

        return new{T, H}(stream,
                        handler,
                        deepcopy(TAGS_INT_STRING),
                        deepcopy(TAGS_STRING_INT),
                        delimiter,
                        m_header,
                        FIXClientTasks(),
                        parselevel)
    end
end

checksum(this::String)::Int64 = sum([Int(x) for x in this]) % 256
fixjoin(this::Dict{Int64, String}, delimiter::Char)::String = join([string(k) * "=" * v for (k, v) in this], delimiter) * delimiter
body_length_tag(body_length::Int64)::String = "9=" * string(body_length)

function checksum_tag(this::String)::String
    c_sum = string(checksum(this))
    while length(c_sum) < 3
        c_sum = '0' * c_sum
    end
    return "10=" * c_sum
end

function message(this::FIXClient, body::Dict{Int64, String})::String
    body_string = fixjoin(body, this.delimiter)
    body_length = length(body_string)
    msg = this.m_head * body_length_tag(body_length) * this.delimiter * body_string
    msg = msg * checksum_tag(msg) * this.delimiter
    return msg
end

"Very slow"
function fixparse(data::Vector{UInt8})::Dict{Int64, String}
    delims = find(data .== 0x01);
    istart = 1
    out = Dict{Int64, String}()
    for k in eachindex(delims)
        istop = delims[k] - 1
        tag_value = data[istart:istop]
        tag_value_str = String(Char.(tag_value))
        idx = searchindex(tag_value_str, "=")
        tag = tag_value_str[1:(idx-1)]
        value = tag_value_str[(idx+1):end]
        out[parse(Int64, String(tag))] = value
        istart = istop + 2
    end
    return out
end

function fixconvert(tags::Dict{Int64, String}, msg::Dict{Int64, String})::Dict{String, String}
    out = Dict{String, String}()
    for (k, v) in msg
        out[tags[k]] = v
    end
    return out
end

function send_message(this::FIXClient, body::Dict{Int64, String})
    write(this.stream, message(this, body))
end

function start(this::FIXClient)
    this.m_tasks.read = Nullable( @async begin
        while true
            incoming = readavailable(this.stream)
            if this.m_parselevel == 0
                onFIXMessage(this.handler, incoming)
            elseif this.m_parselevel == 1
                onFIXMessage(this.handler, fixparse(incoming))
            else
                onFIXMessage(this.handler, fixconvert(this.tags, fixparse(incoming)))
            end
        end
    end
    )
    return this.m_tasks
end


end
