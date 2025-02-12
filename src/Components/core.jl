import Base: zero, +, -, /, *, sqrt, ^
@trait Indicator

@implement Is{Indicator} by zero(_)
@implement Is{Indicator} by (+)(_, _)
@implement Is{Indicator} by (-)(_, _)
@implement Is{Indicator} by (*)(_, _)
@implement Is{Indicator} by (/)(_, ::Int)
@implement Is{Indicator} by (*)(_, ::AbstractFloat)
@implement Is{Indicator} by (*)(::AbstractFloat, _)
@implement Is{Indicator} by (*)(::Integer, _)
@implement Is{Indicator} by (sqrt)(_)
@implement Is{Indicator} by (^)(_, ::Int)

"""
    Clock

Represents the internal time of a [`Trader`](@ref) or [`AbstractBroker`](@ref).
Its `time` is updated by [`Timer`](@ref) and returned by [`current_time`](@ref) if it is called on the [`Trader`](@ref) or [`AbstractBroker`](@ref). 
It also stores `dt`, the timestamp interval when the `Clock` is updated manually, for example when being used with a [`HistoricalBroker`](@ref).
"""
@component Base.@kwdef mutable struct Clock
    time::TimeDate = TimeDate(now())
    dtime::Period  = Minute(1)
end

"""
    SingleValIndicator

A Component with a single value (usually `v`) that can be used by [`Indicator Systems`](@ref Indicators) to calculate various `Indicators`.
If the single value is not stored in the `v` field of the Component, overload [`Trading.value`](@ref).
"""
abstract type SingleValIndicator{T} end

"""
    Open

The opening price of a given bar.
"""
@component struct Open <: SingleValIndicator{Float64}
    v::Float64
end

"""
    Close

The closing price of a given bar.
"""
@component struct Close <: SingleValIndicator{Float64}
    v::Float64
end

"""
    High

The highest price of a given bar.
"""
@component struct High <: SingleValIndicator{Float64}
    v::Float64
end

"""
    Low

The lowest price of a given bar.
"""
@component struct Low <: SingleValIndicator{Float64}
    v::Float64
end

"""
    Volume

The traded volume of a given bar.
"""
@component struct Volume <: SingleValIndicator{Float64}
    v::Float64
end

"""
    LogVal

The logarithm of a value.
"""
@component struct LogVal{T} <: SingleValIndicator{T}
    v::T
end
prefixes(::Type{<:LogVal}) = ("LogVal",)

for op in (:+, :-, :*, :/, :^)
    @eval @inline Base.$op(b1::T, b2::T) where {T<:SingleValIndicator}      = T(eltype(T)($op(value(b1), value(b2))))
    @eval @inline Base.$op(b1::T, b2::Number) where {T<:SingleValIndicator} = T(eltype(T)($op(value(b1), b2)))
    @eval @inline Base.$op(b1::Number, b2::T) where {T<:SingleValIndicator} = T(eltype(T)($op(b1, value(b2))))
end

for op in (:(<), :(>), :(>=), :(<=), :(==))
    @eval @inline Base.$op(b1::SingleValIndicator, b2::SingleValIndicator) = $op(value(b1), value(b2))
    @eval @inline Base.$op(b1::SingleValIndicator, b2::Number)             = $op(value(b1), b2)
    @eval @inline Base.$op(b1::Number, b2::SingleValIndicator)             = $op(b1, value(b2))
end

Base.zero(::T) where {T<:SingleValIndicator} = T(0.0)
@inline Base.sqrt(b::T) where {T<:SingleValIndicator} = T(sqrt(value(b)))
@inline Base.isless(b::SingleValIndicator, i) = value(b) < i

"""
    value(b::SingleValIndicator)

Returns the number that is stored in the [`SingleValIndicator`](@ref). This is by default the `v` field.
"""
@inline value(b::SingleValIndicator) = value(b.v)

TimeSeries.colnames(::Type{T}) where {T <: SingleValIndicator} = [String(replace("$(T)", "Trading." => ""))]

@inline value(b::Number) = b
@inline function Base.convert(::Type{T}, b::SingleValIndicator) where {T<:Number}
    return convert(T, value(b))
end
Base.eltype(::Type{<:SingleValIndicator{T}}) where {T} = T
Base.zero(::Type{T}) where {T<:SingleValIndicator} = T(zero(eltype(T)))

@assign SingleValIndicator with Is{Indicator}

"""
Associates a time to an `Entity`.
"""
@component struct TimeStamp
    t::TimeDate
end

TimeStamp(args...) = TimeStamp(current_time(args...))

"""
    Strategy(name::Symbol, systems::Vector{System}; only_day = false, assets = Asset[])

A strategy embodies a set of `Systems` that will run periodically, where each of the `Systems` should have a defined
`update(s::System, trader, asset_ledgers)` function, with `asset_ledgers` being the [`AssetLedgers`](@ref AssetLedger)
associated with each of the `assets` that the strategy should be applied on.

!!! note

   The last [`AssetLedger`](@ref) in `asset_ledgers` is a "combined" ledger which can store data shared between all `assets` for this strategy.

`only_day`: whether this strategy should only run during a trading day
"""
@component Base.@kwdef struct Strategy
    stage::Stage
    only_day::Bool = false
    assets::Vector{Asset} = Asset[]
end

Strategy(name::Symbol, steps; kwargs...) = Strategy(; stage = Stage(name, steps), kwargs...)
