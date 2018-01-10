module FIX

using DataStructures

global const TAGS_INT_STRING = Dict{Int64, String}()
global const TAGS_STRING_INT = Dict{String, Int64}()

import Base: start, next, done, length, collect

abstract type AbstractFIXHandler end
export AbstractFIXHandler, FIXClient, send_message, start, next, done, length

function onFIXMessage(this::AbstractFIXHandler, x::Any)
    T = typeof(this)
    X = typeof(x)
    throw(ErrorException("Method `onFIXMessage` is not implemented by $T for argument type $X"))
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

mutable struct Container{T}
    data::T
end

include("management.jl")

struct FIXClient{T <: IO, H <: AbstractFIXHandler}
    stream::T
    handler::H
    delimiter::Char
    m_head::Dict{Int64, String}
    m_tasks::FIXClientTasks
    m_messages::FIXMessageManagement
    function FIXClient(stream::T,
                        handler::H,
                        header::Dict{Int64, String};
                        delimiter::Char = Char(1)) where {T <: IO, H <: AbstractFIXHandler}
        return new{T, H}(stream,
                        handler,
                        delimiter,
                        header,
                        FIXClientTasks(),
                        FIXMessageManagement())
    end
end

checksum(this::String)::Int64 = sum([Int(x) for x in this]) % 256
fixjoin(this::OrderedDict{Int64, String}, delimiter::Char)::String = join([string(k) * "=" * v for (k, v) in this], delimiter) * delimiter
fixjoin(this::Dict{Int64, String}, delimiter::Char)::String = join([string(k) * "=" * v for (k, v) in this], delimiter) * delimiter

function fixmessage(this::FIXClient, msg::Dict{Int64, String})::OrderedDict{Int64, String}
    ordered = OrderedDict{Int64, String}()

    #header
    ordered[8] = this.m_head[8]
    ordered[9] = ""
    ordered[35] = msg[35] #message type
    ordered[49] = this.m_head[49] #SenderCompID
    ordered[56] = this.m_head[56] #TargetCompID
    ordered[34] = getNextOutgoingMsgSeqNum(this)
    ordered[52] = ""
    #body
    body_length = 0
    for (k, v) in msg
        if k != 8 && k != 9 && k != 10
            ordered[k] = v
        end
    end

    for (k, v) in ordered
        if k != 8 && k != 9
            body_length += length(string(k)) + 1 + length(v) + 1 #tag=value|
        end
    end
    ordered[9] = string(body_length)

    #tail
    msg = fixjoin(ordered, this.delimiter)
    c = checksum(msg)
    c_str = string(c)
    while length(c_str) < 3
        c_str = '0' * c_str
    end
    ordered[10] = c_str

    #done
    return ordered
end

function send_message(this::FIXClient, msg::Dict{Int64, String})
    msg = fixmessage(this, msg)
    msg_str = fixjoin(msg, this.delimiter)

    write(this.stream, msg_str)
    onSent(this.m_messages, msg)

    return (msg, msg_str)
end

function start(this::FIXClient)
    this.m_tasks.read = Nullable( @async begin
        while true
            incoming = readavailable(this.stream)
            if isempty(incoming)
                @printf("[%ls] EMPTY FIX MESSAGE\n", now())
                break
            end

            for (_, msg) in fixparse(incoming)
                onGet(this.m_messages, msg)
                onFIXMessage(this.handler, msg)
            end
        end
        @printf("[%ls] FIX: read task done\n", now())
    end
    )
    return this.m_tasks
end

include("parse.jl")
function getOpenOrders(this::FIXClient)::Vector{Dict{Int64, String}}
    return getOpenOrders(this.m_messages)
end

function getNextOutgoingMsgSeqNum(this::FIXClient)
    return getNextOutgoingMsgSeqNum(this.m_messages)
end

end
