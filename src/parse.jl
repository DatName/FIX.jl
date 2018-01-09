mutable struct FIXMessageIterator
    data::Vector{UInt8}
    messages::OrderedDict{Int64, OrderedDict{Int64, String}}
    tag::Vector{Char}
    value::Vector{Char}
    state::Bool
    message_id::Int64
    function FIXMessageIterator(data::Vector{UInt8})
        return new(data, OrderedDict{Int64, OrderedDict{Int64, String}}(), Char[], Char[], true, 0)
    end
end

length(this::FIXMessageIterator) = length(this.data)
function start(this::FIXMessageIterator)::Int64
    return 1
end

function next(this::FIXMessageIterator, idx::Int64)::Tuple{FIXMessageIterator, Int64}
    x = this.data[idx]
    if x == 0x01
        int_tag = parse(Int64, String(this.tag))
        str_value = String(this.value)
        !haskey(this.messages, this.message_id) && (this.messages[this.message_id] = OrderedDict{Int64, String}())
        this.messages[this.message_id][int_tag] = str_value
        resize!(this.tag, 0)
        resize!(this.value, 0)
        if int_tag == 10
            this.message_id += 1
        end
        this.state = true
    elseif x == 0x3d
        this.state = !this.state
    else
        if this.state
            push!(this.tag, Char(x))
        else
            push!(this.value, Char(x))
        end
    end

    return (this, idx + 1)
end

function done(this::FIXMessageIterator, idx::Int64)
    return length(this.data) > idx
end

function fixparse(data::Vector{UInt8})::OrderedDict{Int64, OrderedDict{Int64, String}}
    f = FIXMessageIterator(data)
    for k in eachindex(data)
        next(f, k)
    end
    return f.messages
end

function fixconvert(tags::Dict{Int64, String}, msg::OrderedDict{Int64, String})::OrderedDict{String, String}
    out = OrderedDict{String, String}()
    for (k, v) in msg
        out[tags[k]] = v
    end
    return out
end
