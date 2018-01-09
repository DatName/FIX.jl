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

struct FIXIncomingMessages
    login::Dict{Int64, String}
    logout::Dict{Int64, String}
    executionReport::Vector{Dict{Int64, String}}
    orderCancelReject::Dict{String, Dict{Int64, String}}
    orderReject::Vector{Dict{Int64, String}}
    heartbeat::Vector{Dict{Int64, String}}
    msgseqnum::Container{String}
    function FIXIncomingMessages()
        return new(Dict{Int64, String}(),
                Dict{Int64, String}(),
                Vector{Dict{Int64, String}}(0),
                Dict{String, Dict{Int64, String}}(),
                Vector{Dict{Int64, String}}(0),
                Vector{Dict{Int64, String}}(0),
                Container("0"))
    end
end

struct FIXOutgoingMessages
    login::Dict{Int64, String}
    logout::Dict{Int64, String}
    newOrderSingle::Dict{String, Dict{Int64, String}}
    orderCancelRequest::Dict{String, Dict{Int64, String}}
    orderStatusRequest::Dict{String, Dict{Int64, String}}
    msgseqnum::Container{Int64}
    function FIXOutgoingMessages()
        return new(Dict{Int64, String}(),
                Dict{Int64, String}(),
                Dict{String, Dict{Int64, String}}(),
                Dict{String, Dict{Int64, String}}(),
                Dict{String, Dict{Int64, String}}(),
                Container(0))
    end
end

struct FIXMessageManagement
    incoming::FIXIncomingMessages
    outgoing::FIXOutgoingMessages
    function FIXMessageManagement()
        return new(FIXIncomingMessages(),
                    FIXOutgoingMessages())

    end
end

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

function fixmessage(this::FIXClient, msg::Dict{Int64, String})
    ordered = OrderedDict{Int64, String}()

    #header
    ordered[8] = this.m_head[8]
    ordered[9] = ""
    ordered[35] = msg[35] #message type
    ordered[49] = this.m_head[49] #SenderCompID
    ordered[56] = this.m_head[56] #TargetCompID
    ordered[34] = string(this.m_messages.outgoing.msgseqnum.data + 1) #MsgSeqNum
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
    msg_type = msg[35]
    if msg_type == "D"
        this.m_messages.outgoing.newOrderSingle[msg[11]] = msg
    elseif msg_type == "F"
        this.m_messages.outgoing.orderCancelRequest[msg[11]] = msg
    elseif msg_type == "H"
        this.m_messages.outgoing.orderStatusRequest[msg[37]] = msg
    elseif msg_type == "A"
        [this.m_messages.outgoing.login[k] = v for (k, v) in msg]
    elseif msg_type == "5"
        [this.m_messages.outgoing.logout[k] = v for (k, v) in msg]
    else
        @printf("[%ls] Unknown OUTGOING msg type %ls\n", now(), msg_type)
    end

    msg_str = fixjoin(msg, this.delimiter)
    write(this.stream, msg_str)
    this.m_messages.outgoing.msgseqnum.data = parse(Int64, msg[34])

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
                this.m_messages.incoming.msgseqnum.data = msg[34]

                msg_type = msg[35]
                if msg_type == "8"
                    push!(this.m_messages.incoming.executionReport, msg)
                elseif msg_type == "9"
                    this.m_messages.incoming.orderCancelReject[msg[11]] = msg
                elseif msg_type == "3"
                    push!(this.m_messages.incoming.orderReject, msg)
                elseif msg_type == "0"
                    push!(this.m_messages.incoming.heartbeat, msg)
                elseif msg_type == "A"
                    [this.m_messages.incoming.login[k] = v for (k, v) in msg]
                elseif msg_type == "5"
                    [this.m_messages.incoming.logout[k] = v for (k, v) in msg]
                else
                    @printf("[%ls] Unknown INCOMING message type: %ls\n", now(), msg_type)
                end

                onFIXMessage(this.handler, msg)
            end
        end
        @printf("[%ls] FIX: read task done\n", now())
    end
    )
    return this.m_tasks
end

include("parse.jl")

end
