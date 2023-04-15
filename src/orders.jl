"""
    trades(broker, ticker, start, stop)

Returns the trades made for `ticker` between `start` and `stop`.
When using [`AlpacaBroker`](@ref) see the [Trade Object](https://alpaca.markets/docs/api-references/market-data-api/stock-pricing-data/historical/#trades)
documentation for further reference.

# Example
```julia
broker = AlpacaBroker(<key_id>, <secret_key>)

trades(broker, "AAPL", DateTime("2022-01-01T14:30:00"), DateTime("2022-01-01T14:31:00"))
```
"""
trades(b::AbstractBroker) = broker(b).cache.trades_data
function trades(broker::AbstractBroker, ticker, args...; kwargs...)
    return retrieve_data(broker, trades(broker), ticker, args...; section = "trades",
                         kwargs...)
end

function failed_order(broker, order, exc)
    t = current_time(broker)
    b = IOBuffer()
    showerror(b, exc)
    return Order(order.ticker, "", uuid1(), uuid1(), t, t, t, nothing, nothing, nothing, t, 0.0,
                 0.0, "failed\n$(String(take!(b)))", order.quantity, 0.0)
end

side(::AlpacaBroker, ::EntityState{Tuple{Component{Purchase}}}) = "buy"
side(::AlpacaBroker, ::EntityState{Tuple{Component{Sale}}})     = "sell"

function order_body(b::AlpacaBroker, order::EntityState)
    body = Dict("symbol"        => string(order.ticker),
                "qty"           => string(order.quantity),
                "side"          => side(b, order),
                "type"          => string(order.type),
                "time_in_force" => string(order.time_in_force))

    if order.type == OrderType.Limit
        body["limit_price"] = string(order.price)
    end

    return JSON3.write(body)
end

function parse_order(b::AlpacaBroker, resp::HTTP.Response)
    if resp.status != 200
        error("something went wrong while submitting order")
    end

    parse_body = JSON3.read(resp.body)
    return parse_order(b, parse_body)
end

function parse_order(::AlpacaBroker, parse_body)
    return Order(parse_body[:symbol],
                 parse_body[:side],
                 UUID(parse_body[:id]),
                 UUID(parse_body[:client_order_id]),
                 parse_body[:created_at] !== nothing ? parse_time(parse_body[:created_at]) :
                 nothing,
                 parse_body[:updated_at] !== nothing ? parse_time(parse_body[:updated_at]) :
                 nothing,
                 parse_body[:submitted_at] !== nothing ?
                 parse_time(parse_body[:submitted_at]) : nothing,
                 parse_body[:filled_at] !== nothing ? parse_time(parse_body[:filled_at]) :
                 nothing,
                 parse_body[:expired_at] !== nothing ? parse_time(parse_body[:expired_at]) :
                 nothing,
                 parse_body[:canceled_at] !== nothing ?
                 parse_time(parse_body[:canceled_at]) : nothing,
                 parse_body[:failed_at] !== nothing ? parse_time(parse_body[:failed_at]) :
                 nothing,
                 parse(Float64, parse_body[:filled_qty]),
                 parse_body[:filled_avg_price] !== nothing ?
                 parse(Float64, parse_body[:filled_avg_price]) : 0.0,
                 parse_body[:status],
                 parse(Float64, parse_body[:qty]),
                 0.0)
end

function receive_order(b::AlpacaBroker, ws)
    msg = JSON3.read(receive(ws))
    if msg[:stream] == "trade_updates"
        return parse_order(b, msg[:data][:order])
    end
end

function receive_order(broker::HistoricalBroker, args...)
    sleep(1)
    return nothing
end

"""
    submit_order(broker, order::Union{Purchase,Sale})

Submits the `order` to a `broker` for execution.
"""
function submit_order(broker::AlpacaBroker, order)
    uri = order_url(broker)
    h   = header(broker)
    try
        resp = HTTP.post(uri, h, order_body(broker, order))
        return parse_order(broker, resp)
    catch e
        if e isa HTTP.Exceptions.StatusError
            msg = JSON3.read(e.response.body)
            
            if msg[:message] == "insufficient day trading buying power"
                order.quantity = round(0.9 * order.quantity)
                return submit_order(broker, order)
                
            elseif occursin("insufficient qty available for order", msg[:message])
                m = match(r"available: (\d+)\)", msg[:message])
                
                if m !== nothing
                    order.quantity = parse(Float64, m.captures[1])
                    return submit_order(broker, order)
                end
                
            end

            return failed_order(broker, order, e)
        else
            rethrow()
        end
    end
end

order_side(order::EntityState{Tuple{Component{Purchase}}}) = "buy"
order_side(order::EntityState{Tuple{Component{Sale}}})     = "sell"

function submit_order(broker::HistoricalBroker, order)
    try
        p = price(broker, broker.clock.time + broker.clock.dtime, order.ticker)
        max_fee = 0.005 * abs(order.quantity) * p
        fee = abs(order.quantity) *
              (p * broker.variable_transaction_fee + broker.fee_per_share) +
              broker.fixed_transaction_fee
        fee = min(fee, max_fee)
        return Order(order.ticker,
                     order_side(order),
                     uuid1(),
                     uuid1(),
                     current_time(broker),
                     current_time(broker),
                     current_time(broker),
                     current_time(broker),
                     nothing,
                     nothing,
                     nothing,
                     order.quantity,
                     p,
                     "filled",
                     order.quantity,
                     fee)
    catch e
        return failed_order(broker, order, e)
    end
end

function submit_order(t::Trader, e)
    return t[e] = submit_order(t.broker, e)
end

delete_all_orders!(b::AbstractBroker) = HTTP.delete(order_url(b), header(b))
delete_all_orders!(::HistoricalBroker) = nothing
delete_all_orders!(t::Trader) = delete_all_orders!(t.broker)

"""
    OrderStream

Interface to support executing trades and retrieving account updates.
"""
Base.@kwdef struct OrderStream{B<:AbstractBroker}
    broker::B
    ws::Union{Nothing,WebSocket} = nothing
end

OrderStream(b::AbstractBroker; kwargs...) = OrderStream(; broker = b, kwargs...)

HTTP.receive(order_link::OrderStream) = receive_order(order_link.broker, order_link.ws)
WebSockets.isclosed(order_link::OrderStream) = order_link.ws === nothing || order_link.ws.readclosed || order_link.ws.writeclosed
WebSockets.isclosed(order_link::OrderStream{<:HistoricalBroker}) = false

"""
    order_stream(f::Function, broker::AbstractBroker)

Creates an [`OrderStream`](@ref) to stream order data.
Uses the same semantics as a standard `HTTP.WebSocket`.

# Example
```julia
broker = AlpacaBroker(<key_id>, <secret_key>)

order_stream(broker) do stream
    order = receive(stream)
end
```
"""
function order_stream(f::Function, broker::AlpacaBroker)
    HTTP.open(trading_stream_url(broker)) do ws
        if !authenticate_trading(broker, ws)
            error("couldn't authenticate")
        end
        @info "Authenticated trading"
        send(ws,
             JSON3.write(Dict("action" => "listen",
                              "data" => Dict("streams" => ["trade_updates"]))))
        try
            f(OrderStream(broker, ws))
        catch e
            showerror(stdout, e, catch_backtrace())
            if !(e isa InterruptException)
                rethrow()
            end
        end
    end
end

order_stream(f::Function, broker::HistoricalBroker) = f(OrderStream(broker, nothing))
