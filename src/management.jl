const DICTMSG = OrderedDict{Int64, String}

struct FIXIncomingMessages
    login::DICTMSG
    logout::DICTMSG
    executionReports::Dict{String, Vector{DICTMSG}} #type -> reports
    orderCancelReject::Vector{DICTMSG}
    orderReject::Vector{DICTMSG}
    resend::Vector{DICTMSG}
    heartbeat::Vector{DICTMSG}
    msgseqnum::Container{String}
    function FIXIncomingMessages()
        return new(DICTMSG(),
                DICTMSG(),
                Dict{String, Vector{DICTMSG}}(),
                Vector{DICTMSG}(0),
                Vector{DICTMSG}(0),
                Vector{DICTMSG}(0),
                Vector{DICTMSG}(0),
                Container("0"))
    end
end

struct FIXOutgoingMessages
    login::DICTMSG
    logout::DICTMSG
    newOrderSingle::Dict{String, DICTMSG} #client order id ->
    orderCancelRequest::Dict{String, DICTMSG} #client order id ->
    orderStatusRequest::Vector{DICTMSG}
    msgseqnum::Container{Int64}
    function FIXOutgoingMessages()
        return new(DICTMSG(),
                DICTMSG(),
                Dict{String, DICTMSG}(),
                Dict{String, DICTMSG}(),
                Vector{DICTMSG}(0),
                Container(0))
    end
end

const ClientOrderID = String
const ExchangeOrderID = String

struct FIXOpenOrders
    client_id::Dict{String, DICTMSG}
    exchng_id::Dict{String, DICTMSG}
    verbose::Bool
    function FIXOpenOrders(verbose::Bool = false)
        return new(Dict{String, DICTMSG}(),
                    Dict{String, DICTMSG}(),
                    verbose)
    end
end

struct FIXMessageManagement
    incoming::FIXIncomingMessages
    outgoing::FIXOutgoingMessages
    open::FIXOpenOrders
    function FIXMessageManagement(verbose::Bool = false)
        return new(FIXIncomingMessages(),
                    FIXOutgoingMessages(),
                    FIXOpenOrders(verbose))

    end
end

function getPosition(this::FIXIncomingMessages, instrument::String)
    out = 0.0
    if !haskey(this.executionReports, "1")
        return out
    end

    for report in this.executionReports["1"]
        if report[55] ≠ instrument
            continue
        end

        if report[54] == "1"
            out += parse(Float64, report[32])
        else
            out -= parse(Float64, report[32])
        end
    end

    return out
end

function getPositions(this::FIXIncomingMessages)
    out = Dict{String, Float64}()

    if !haskey(this.executionReports, "1")
        return out
    end

    for report in this.executionReports["1"]
        if !haskey(out, report[55])
            out[report[55]] = 0.0
        end

        sz = parse(Float64, report[32])
        if report[54] == "1"
            out[report[55]] = out[report[55]] + sz
        else
            out[report[55]] = out[report[55]] - sz
        end
    end

    return out
end

function onNewMessage(this::FIXIncomingMessages, msg::DICTMSG)
    this.msgseqnum.data = msg[34]
    msg_type = msg[35]

    if msg_type == "8"
        addExecutionReport(this, msg)
    elseif msg_type == "9"
        addOrderCancelRequest(this, msg)
    elseif msg_type == "3"
        @printf("[%ls][FIX:ER] received order reject\n", now())
        addOrderReject(this, msg)
    elseif msg_type == "0"
        addHeartbeat(this, msg)
    elseif msg_type == "A"
        addLogin(this, msg)
    elseif msg_type == "5"
        addLogout(this, msg)
    elseif msg_type == "2"
        addResend(this, msg)
    else
        @printf("[%ls] Unknown INCOMING message type: %ls\n", now(), msg_type)
    end
end

function addLogin(this::FIXIncomingMessages, msg::DICTMSG)
    [this.login[k] = v for (k, v) in msg]
end

function addLogout(this::FIXIncomingMessages, msg::DICTMSG)
    [this.logout[k] = v for (k, v) in msg]
end

function addExecutionReport(this::FIXIncomingMessages, msg::DICTMSG)
    exec_type = msg[150]
    if !haskey(this.executionReports, exec_type)
        this.executionReports[exec_type] = DICTMSG[]
    end

    push!(this.executionReports[msg[150]], msg)
end

function addOrderCancelReject(this::FIXIncomingMessages, msg::DICTMSG)
    push!(this.orderCancelReject, msg)
end

function addOrderReject(this::FIXIncomingMessages, msg::DICTMSG)
    push!(this.orderReject, msg)
end

function addHeartbeat(this::FIXIncomingMessages, msg::DICTMSG)
    push!(this.heartbeat, msg)
end

function addResend(this::FIXIncomingMessages, msg::DICTMSG)
    push!(this.resend, msg)
end

function onNewMessage(this::FIXOutgoingMessages, msg::DICTMSG)
    msg_type = msg[35]
    this.msgseqnum.data = parse(Int64, msg[34])

    if msg_type == "D"
        addNewOrderSingle(this, msg)
    elseif msg_type == "F"
        addOrderCancelRequest(this, msg)
    elseif msg_type == "H"
        addOrderStatusRequest(this, msg)
    elseif msg_type == "A"
        addLogin(this, msg)
    elseif msg_type == "5"
        addLogout(this, msg)
    else
        @printf("[%ls] Unknown OUTGOING msg type %ls\n", now(), msg_type)
    end
    return nothing
end

function addLogin(this::FIXOutgoingMessages, msg::DICTMSG)
    [this.login[k] = v for (k, v) in msg]
end

function addLogout(this::FIXOutgoingMessages, msg::DICTMSG)
    [this.logout[k] = v for (k, v) in msg]
end

function addNewOrderSingle(this::FIXOutgoingMessages, msg::DICTMSG)
    this.newOrderSingle[msg[11]] = msg
end

function addOrderCancelRequest(this::FIXOutgoingMessages, msg::DICTMSG)
    this.orderCancelRequest[msg[11]] = msg
end

function addOrderStatusRequest(this::FIXOutgoingMessages, msg::DICTMSG)
    push!(this.orderStatusRequest, msg)
end

function onSent(this::FIXMessageManagement, msg::DICTMSG)
    onNewMessage(this.outgoing, msg)
    return nothing
end

function onGet(this::FIXMessageManagement, msg::DICTMSG)
    onNewMessage(this.incoming, msg)

    if msg[35] == "8"
        onExecutionReport(this.open, msg)
    end

    return nothing
end

function onCancelReject(this::FIXMessageManagement, msg::DICTMSG)
    addOrderCancelReject(this.incoming, msg)
end

function onOrderReject(this::FIXMessageManagement, msg::DICTMSG)
    addOrderReject(this.incoming, msg)
end

function onNewOrder(this::FIXOpenOrders, msg::DICTMSG)
    this.client_id[msg[11]] = msg
    this.exchng_id[msg[37]] = msg
    return nothing
end

function onFill(this::FIXOpenOrders, msg::DICTMSG)
    exchng_id = msg[37]
    filled = msg[32]
    orig_exec = getOrderByExchangeID(this, exchng_id)
    prev_amount = parse(Float64, orig_exec[38])
    filled_amount = parse(Float64, filled)

    cur_amount = prev_amount - filled_amount
    orig_exec[38] = string(cur_amount)
end

function onDone(this::FIXOpenOrders, msg::DICTMSG)
    deleteOrderByExchangeID(this, msg[37])
end

function onCancel(this::FIXOpenOrders, msg::DICTMSG)
    deleteOrderByExchangeID(this, msg[37])
end

function onReject(this::FIXOpenOrders, msg::DICTMSG)
    deleteOrderByExchangeID(this, msg[37])
end

function getOrderByExchangeID(this::FIXOpenOrders, exchange_id::String)
    return this.exchng_id[exchange_id]
end

function hasOrderByClientID(this::FIXOpenOrders, client_id::String)
    return haskey(this.client_id, client_id)
end

function hasOrderByExchangeID(this::FIXOpenOrders, exchange_id::String)
    return haskey(this.exchng_id, exchange_id)
end

function deleteOrderByExchangeID(this::FIXOpenOrders, exchange_id::String)::Void
    if !hasOrderByExchangeID(this, exchange_id)
        return nothing
    end

    orig_exec = getOrderByExchangeID(this, exchange_id)

    client_id = orig_exec[11]
    exchng_id = orig_exec[37]

    delete!(this.client_id, client_id)
    delete!(this.exchng_id, exchng_id)

    return nothing
end

function onExecutionReport(this::FIXOpenOrders, msg::DICTMSG)
    exec_type = msg[150]
    if exec_type == "0"
        this.verbose && @printf("[%ls][FIX:ER] new order\n", now())
        onNewOrder(this, msg)
    elseif exec_type == "1" #fill
        this.verbose && @printf("[%ls][FIX:ER] fill\n", now())
        onFill(this, msg)
    elseif exec_type == "3"
        this.verbose && @printf("[%ls][FIX:ER] done\n", now())
        onDone(this, msg)
    elseif exec_type == "4"
        this.verbose && @printf("[%ls][FIX:ER] cancel\n", now())
        onCancel(this, msg)
    elseif exec_type == "8"
        onReject(this, msg)
        this.verbose && @printf("[%ls][FIX:ER] reject\n", now())
    else
        @printf("Received unhandled execution report of type %ls\n", exec_type)
    end
end

function getOrders(this::FIXOpenOrders)::Vector{DICTMSG}
    return collect(values(this.client_id))
end

function getOpenOrders(this::FIXMessageManagement)::Vector{DICTMSG}
    return getOrders(this.open)
end

function getNextOutgoingMsgSeqNum(this::FIXMessageManagement)::String
    return getNextOutgoingMsgSeqNum(this.outgoing)
end

function getNextOutgoingMsgSeqNum(this::FIXOutgoingMessages)::String
    return string(this.msgseqnum.data + 1)
end

function getPosition(this::FIXMessageManagement, instrument::String)
    return getPosition(this.incoming, instrument)
end

function getPositions(this::FIXMessageManagement)
    return getPositions(this.incoming)
end
