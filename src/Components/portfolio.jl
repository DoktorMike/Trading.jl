"""
Enum representing the different kinds of orders that can be made.
- Market
- Limit
- Stop
- StopLimit
- TrailinStop
"""
@enumx OrderType Market Limit Stop StopLimit TrailingStop

function Base.string(t::OrderType.T)
    if t == OrderType.Market
        return "market"
    elseif t == OrderType.Limit
        return "limit"
    elseif t == OrderType.Stop
        return "stop"
    elseif t == OrderType.StopLimit
        return "stop_limit"
    elseif t == OrderType.TrailingStop
        return "trailing_stop"
    end
end

"""
Enum representing the lifetime of an order.
- Day: till the end of the trading day
- GTC: good till canceled
- OPG: executed on market open
- CLS: executed at market close
- IOC: immediate or canceled, any unfilled part of the order will be canceled
- FOK: executed only when the full quantity can be filled, otherwise canceled.
"""
@enumx TimeInForce Day GTC OPG CLS IOC FOK
function Base.string(t::TimeInForce.T)
    if t == TimeInForce.Day
        return "Day"
    elseif t == TimeInForce.GTC
        return "gtc"
    elseif t == TimeInForce.OPG
        return "opg"
    elseif t == TimeInForce.CLS
        return "cls"
    elseif t == TimeInForce.IOC
        return "ioc"
    elseif t == TimeInForce.FOK
        return "fok"
    end
end

"""
    Purchase(ticker, quantity;
             type          = OrderType.Market,
             time_in_force = TimeInForce.GTC,
             price         = 0.0,
             trail_percent = 0.0)

The local representation of a purchase order.
This will be turned into an [`Order`](@ref) by the [`Purchaser`](@ref) `System` as soon as
it's communicated to the [`broker`](@ref AbstractBroker).
See [`OrderType`](@ref) and [`TimeInForce`](@ref) for more information on those `kwargs`.
"""
@component Base.@kwdef mutable struct Purchase
    ticker::String
    quantity::Float64
    type::OrderType.T = OrderType.Market
    time_in_force::TimeInForce.T = TimeInForce.GTC

    price::Float64 = 0.0
    trail_percent::Float64 = 0.0
end

function Purchase(ticker, quantity; kwargs...)
    return Purchase(; ticker = ticker, quantity = quantity, kwargs...)
end

"""
    Sale(ticker, quantity;
             type          = OrderType.Market,
             time_in_force = TimeInForce.GTC,
             price         = 0.0,
             trail_percent = 0.0)

The local representation of a sell order.
This will be turned into an [`Order`](@ref) by the [`Seller`](@ref) `System` as soon as
it's communicated to the [`broker`](@ref AbstractBroker).
See [`OrderType`](@ref) and [`TimeInForce`](@ref) for more information on those `kwargs`.
"""
@component Base.@kwdef mutable struct Sale
    ticker::String
    quantity::Float64
    type::OrderType.T = OrderType.Market
    time_in_force::TimeInForce.T = TimeInForce.GTC

    price::Float64 = 0.0
    trail_percent::Float64 = 0.0
end

Sale(ticker, quantity; kwargs...) = Sale(; ticker = ticker, quantity = quantity, kwargs...)

"""
Representation of a [`Purchase`](@ref) or [`Sale`](@ref) order that has been
communicated to the [`broker`](@ref AbstractBroker).
Once the status goes to "filled" the filling information will be
taken by the [`Filler`](@ref) `System` to create a [`Filled`](@ref) component. 
"""
@component Base.@kwdef mutable struct Order
    ticker           :: String
    id               :: UUID
    client_order_id  :: UUID
    created_at       :: Union{TimeDate,Nothing}
    updated_at       :: Union{TimeDate,Nothing}
    submitted_at     :: Union{TimeDate,Nothing}
    filled_at        :: Union{TimeDate,Nothing}
    expired_at       :: Union{TimeDate,Nothing}
    canceled_at      :: Union{TimeDate,Nothing}
    failed_at        :: Union{TimeDate,Nothing}
    filled_qty       :: Float64
    filled_avg_price :: Float64
    status           :: String

    requested_quantity::Float64
    fee::Float64
end

"""
Represents the filled `avg_price` and `quantity` of an [`Order`](@ref).
"""
@component struct Filled
    avg_price::Float64
    quantity::Float64
end

# Dollars
"""
Represents the actual cash balance. Currently there is no particular currency tied to this.
"""
@component mutable struct Cash
    cash::Float64
end

"""
Represents the current purchasing power. This is updated at the start of each `update` cycle to the current value of the [`Cash`](@ref) singleton.
It can thus be used to determine how many purchases/trades can be made during one cycle.  
"""
@component mutable struct PurchasePower
    cash::Float64
end

"""
Represents a position held in an equity represented by ticker.
"""
@component mutable struct Position
    ticker::String
    quantity::Float64
end

"""
A snapshot of the current [`Positions`](@ref Position) and [`Cash`](@ref) value of the portfolio.
"""
@component struct PortfolioSnapshot
    positions::Vector{Position}
    cash::Float64
    value::Float64
end
Base.zero(d::PortfolioSnapshot) = PortfolioSnapshot(Position[], 0.0, 0.0)
PortfolioSnapshot(v::Float64) = PortfolioSnapshot(Position[], 0.0, v)
for op in (:+, :-, :*, :/)
    @eval @inline function Base.$op(b1::PortfolioSnapshot, b2::PortfolioSnapshot)
        return PortfolioSnapshot($op(b1.value, b2.value))
    end
end
@inline Base.:(/)(b::PortfolioSnapshot, i::Int) = PortfolioSnapshot(b.value / i)
@inline Base.:(^)(b::PortfolioSnapshot, i::Int) = PortfolioSnapshot(b.value^i)

@inline Base.:(*)(b::PortfolioSnapshot, i::AbstractFloat) = PortfolioSnapshot(b.value * i)
@inline Base.:(*)(i::AbstractFloat, b::PortfolioSnapshot) = b * i
@inline Base.:(*)(i::Integer, b::PortfolioSnapshot) = b * i
@inline Base.sqrt(b::PortfolioSnapshot) = PortfolioSnapshot(sqrt(b.value))
@inline Base.:(<)(i::Number, b::PortfolioSnapshot) = i < b.value
@inline Base.:(<)(b::PortfolioSnapshot, i::Number) = b.value < i
@inline Base.:(>)(i::Number, b::PortfolioSnapshot) = i > b.value
@inline Base.:(>)(b::PortfolioSnapshot, i::Number) = b.value > i
@inline Base.:(>=)(i::Number, b::PortfolioSnapshot) = i >= b.value
@inline Base.:(>=)(b::PortfolioSnapshot, i::Number) = b.value >= i
@inline Base.:(<=)(i::Number, b::PortfolioSnapshot) = i <= b.value
@inline Base.:(<=)(b::PortfolioSnapshot, i::Number) = b.value <= i
value(p::PortfolioSnapshot) = p.value

@assign PortfolioSnapshot with Is{Indicator}
