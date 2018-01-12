module FIXQuoting

using FIXClient
const DICTMSG = Dict{Int64, String}

"Mutable to make in changable online"
mutable struct FIXQuoteParameters
    lots::Float64
    price::Float64
    refill::Bool
    price_tolerance::Float64
    lots_tolerance::Float64
end

mutable struct FIXQuoteState
    queue::Dict{String, DICTMSG}
    lots::Float64 #set on sonfirmed
    price::Float64 #set on confirmed
    order_request::Pair{String, String} #client_id -> exchange_id
    cancel_request::Pair{String, Pair{String, String}} #client_id -> (request client_id -> request exchange_id)
    got_reject::Bool
    function FIXQuoteState()
        return new(Dict{String, DICTMSG}(), 0.0, NaN, "", "", false)
    end
end

struct FIXQuote
    client::FIXClient
    side::String
    parameters::FIXQuoteParameters
    state::FIXQuoteState
    function FIXQuote(client::FIXClient,
                        instrument::String,
                        side::String,
                        price::Float64,
                        lots::Float64,
                        price_tolerance::Float64,
                        lots_tolerance::Float64,
                        refill::Bool)
        return new(side,
                    FIXQuoteParameters(instrument,
                                        lots,
                                        price,
                                        refill,
                                        price_tolerance,
                                        lots_tolerance),
                    FIXQuoteState())
    end
end

function out_of_tolerance(this::FIXQuote)
    price_ok = abs(this.state.price - price) < this.parameters.price_tolerance
    lots_ok  = abs(this.state.lots - lots) < this.parameters.lots_tolerance

    return !price_ok || !lots_ok
end

# 21 	HandlInst 	Must be 1 (Automated)
# 11 	ClOrdID 	UUID selected by client to identify the order
# 55 	Symbol 	E.g. BTC-USD
# 54 	Side 	Must be 1 to buy or 2 to sell
# 44 	Price 	Limit price (e.g. in USD) (Limit order only)
# 38 	OrderQty 	Order size in base units (e.g. BTC)
# 152 	CashOrderQty 	Order size in quote units (e.g. USD) (Market order only)
# 40 	OrdType 	Must be 1 for Market, 2 for Limit or 3 for Stop Market
# 99 	StopPx 	Stop price for order. (Stop Market order only)
# 59 	TimeInForce 	Must be a valid TimeInForce value. See the table below (Limit order only)
# 7928 	SelfTradePrevention 	Optional, see the table below
function send(this::FIXQuote)
    price = this.parameters.price
    lots  = this.parameters.lots - this.state.lots

    id = string(Base.Random.uuid4())
    ord = Dict{Int64, String}(35=>"D",
                            21 => "1",
                            11 => id,
                            55 => this.instrument,
                            54 => this.parameters.side,
                            44 => price,
                            38 => lots,
                            40 => "2",
                            59 => "1",
                            7928 => "B")

    this.state.queue[id] = ord
    this.state.order_request = Pair(id, "")
    return send_message(this.client, ord)
end

# 11 	ClOrdID 	UUID selected by client for the order
# 37 	OrderID 	OrderID from the ExecutionReport with OrdStatus=New (39=0)
# 41 	OrigClOrdID 	ClOrdID of the order to cancel (originally assigned by the client)
# 55 	Symbol 	Symbol of the order to cancel (must match Symbol of the Order)
function cancel(this::FIXQuote)
    id = string(Base.Random.uuid4())
    ord = Dict{Int64, String}(35 => "F",
                            11 => id,
                            37 => this.state.order_request.first,
                            41 => this.state.order_request.second,
                            55 => this.instrument)
    this.state.cancel_request = Pair(id, "")
    return send_message(this.client, ord)
end

function request_status(this::FIXQuote)
    ord = Dict{Int64, String}(35 => "H",
                            37 => this.state.order_request.second)
    return send_message(this.client, ord)
end

function onMessage(this::FIXQuote, msg::DICTMSG)::Void
    msg_type = msg[35]
    if msg_type == "8"
        onExecutionReport(this, msg)
    elseif msg_type == "9"
        onCancelReject(this, msg)
    elseif msg_type ==  "3"
        onOrderReject(this, msg)
    end
end

# 11 	ClOrdID 	Only present on order acknowledgements, ExecType=New (150=0)
# 37 	OrderID 	OrderID from the ExecutionReport with ExecType=New (39=0)
# 55 	Symbol 	Symbol of the original order
# 54 	Side 	Must be 1 to buy or 2 to sell
# 32 	LastShares 	Amount filled (if ExecType=1). Also called LastQty as of FIX 4.3
# 44 	Price 	Price of the fill if ExecType indicates a fill, otherwise the order price
# 38 	OrderQty 	OrderQty as accepted (may be less than requested upon self-trade prevention)
# 60 	TransactTime 	Time the event occurred
# 150 	ExecType 	May be 1 (Partial fill) for fills, D for self-trade prevention, etc.
# 136 	NoMiscFees 	1 (Order Status Request response only)
# 137 	MiscFeeAmt 	Fee (Order Status Request response only)
# 139 	MiscFeeType 	4 (Exchange fees) (Order Status Request response only)
function onExecutionReport(this::FIXQuote, msg::DICTMSG)
    exec_type = msg[150]
    if exec_type == "0"
        onNewOrder(this, msg)
    elseif exec_type == "1"
        onFill(this, msg)
    elseif exec_type == "3"
        onDone(this, msg)
    elseif exec_type == "7"
        onStop(this, msg)
    elseif exec_type == "8"
        onRejected(this, msg)
    elseif exec_type == "D"
        onChanged(this, msg)
    elseif exec_type == "I"
        onOrderStatus(this, msg)
    end
end

#11 	ClOrdID 	As on the cancel request
#37 	OrderID 	As on the cancel request
#41 	OrigClOrdID 	As on the cancel request
#39 	OrdStatus 	4 if too late to cancel
#434 	CxlRejResponseTo 	1 (Order Cancel Request)
function onCancelReject(this::FIXQuote, msg::DICTMST)
    client_id       = msg[11]
    exchng_id       = msg[37]
    orig_client_id  = msg[41]
    status          = msg[41]

    if client_id != this.state.cancel_request.first
        return
    end

    if orig_client_id != this.state.cancel_request.second.first
        println("fail 1")
    end

    if exchng_id != this.state.cancel_request.second.second
        println("fail 2")
    end

    println("FIXQuote: Cancel reject: ", status)
    this.state.cancel_request = Pair("", "")
    return nothing
end

# 45 	RefSeqNum 	MsgSeqNum of the rejected incoming message
# 371 	RefTagID 	Tag number of the field which caused the reject (optional)
# 372 	RefMsgType 	MsgType of the rejected incoming message
# 58 	Text 	Human-readable description of the error (optional)
# 373 	SessionRejectReason 	Code to identify reason for reject
function onOrderReject(this::FIXQuote, msg::DICTMST)
    this.state.got_reject = true
end

function onNewOrder(this::FIXQuote, msg::DICTMSG)

end

function onFill(this::FIXQuote, msg::DICTMSG)

end

function onDone(this::FIXQuote, msg::DICTMSG)

end

function onStop(this::FIXQuote, msg::DICTMSG)

end

function onRejected(this::FIXQuote, msg::DICTMSG)

end

function onChanged(this::FXIQuote, msg::DICTMSG)

end

function onOrderStatus(this::FIXQuote, msg::DICTMSG)

end

end
