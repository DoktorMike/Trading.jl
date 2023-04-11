"""
    Trader(broker::AbstractBroker; strategies = Strategy[])

This is the heart of the entire framework. It holds all the data, systems and references to runtime tasks.
It can be constructed with an [`AbstractBroker`](@ref) and potentially a set of [Strategies](@ref Strategies) and starting time.

Upon construction with a realtime broker, the [Portfolio](@ref) will be filled out with the account information retrieved through the
broker's API.

# Default Systems
There are a set of default systems that facilitate handling trade orders and other bookkeeping tasks.
These are [`StrategyRunner`](@ref), [`Purchaser`](@ref), [`Seller`](@ref), [`Filler`](@ref), [`SnapShotter`](@ref), [`Timer`](@ref) and [`DayCloser`](@ref).

# Runtime and Control
After calling [`start`](@ref) on the [`Trader`](@ref), the systems will run in sequence periodically in the `main_task`, performing the tasks that make everything tick.
Aside from this `main_task` there are two other tasks:
- `trading_task`: streams in portfolio and order updates
- `data_task`: streams in updates to the registered tickers and updates their [`TickerLedgers`](@ref TickerLedger)

Aside from [`start`](@ref) there are some other functions to control the runtime:
- [`stop_main`](@ref):     stops the `main_task`
- [`stop_trading`](@ref):  stops the `trading_task`
- [`stop_data`](@ref):     stops the `data_task`
- [`stop`](@ref):          combines the previous 3
- [`start_main`](@ref):    starts the `main_task`
- [`start_trading`](@ref): starts the `trading_task`
- [`start_data`](@ref):    stops the `data_task`

# AbstractLedger interface
[`Trader`](@ref) is a subtype of the `AbstractLedger` type defined in [Overseer.jl](https://github.com/louisponet/Overseer.jl), meaning that
it can be extended by adding more `Systems` and `Components` to it.
This lies at the heart of the extreme extensibility of this framework. You can think of the current implementation as one working
example of an algorithmic trader implementation, but it can be tuned and tweaked with all the freedom. 
"""
mutable struct Trader{B<:AbstractBroker} <: AbstractLedger
    l              :: Ledger
    broker         :: B
    ticker_ledgers :: Dict{String,TickerLedger}
    data_task      :: Union{Task,Nothing}
    trading_task   :: Union{Task,Nothing}
    main_task      :: Union{Task,Nothing}
    stop_main      :: Bool
    stop_trading   :: Bool
    is_trading     :: Bool
    stop_data      :: Bool
    new_data_event :: Base.Event
end

Overseer.ledger(t::Trader) = t.l

function Overseer.Entity(t::Trader, args...)
    e = Entity(Overseer.ledger(t), TimeStamp(current_time(t)), args...)
    notify(t.new_data_event)
    return e
end
function Overseer.Entity(t::Trader{<:HistoricalBroker}, args...)
    return Entity(Overseer.ledger(t), TimeStamp(current_time(t)), args...)
end

Base.getindex(t::Trader, id::String) = t.ticker_ledgers[id]

function main_stage()
    return Stage(:main,
                 [StrategyRunner(), Purchaser(), Seller(), Filler(), SnapShotter(), Timer(),
                  DayCloser()])
end

function Trader(broker::AbstractBroker; strategies::Vector{Strategy} = Strategy[],
                start = current_time())
    l = Ledger(main_stage())
    ticker_ledgers = Dict{String,TickerLedger}()

    for strat in strategies
        for c in Overseer.requested_components(strat.stage)
            Overseer.ensure_component!(l, c)
        end

        Entity(l, strat)

        for ticker in strat.tickers
            tl = get!(ticker_ledgers, ticker, TickerLedger(ticker))
            register_strategy!(tl, strat)

            if current_position(l, ticker) === nothing
                Entity(l, Position(ticker, 0.0))
            end
        end

        combined = join(strat.tickers, "_")
        tl = get!(ticker_ledgers, combined, TickerLedger(combined))
        register_strategy!(tl, strat)
    end

    for ledger in values(ticker_ledgers)
        ensure_systems!(ledger)
    end
    Entity(l, Clock(start, Minute(0)))

    trader = Trader(l, broker, ticker_ledgers, nothing, nothing, nothing, false, false,
                    false, false, Base.Event())

    fill_account!(trader)

    return trader
end

"""
    current_position(trader, ticker::String)

Returns the current portfolio position for `ticker`.
Returns `nothing` if `ticker` is not found in the portfolio.
"""
function current_position(t::AbstractLedger, ticker::String)
    pos_id = findfirst(x -> x.ticker == ticker, t[Position])
    pos_id === nothing && return 0.0
    return t[Position][pos_id].quantity
end

"""
    current_cash(trader)

Returns the current cash balance of the trader.
"""
current_cash(t::AbstractLedger) = singleton(t, Cash).cash

"""
    current_purchasepower(trader)

Returns the current [`PurchasePower`](@ref).
"""
current_purchasepower(t::AbstractLedger) = singleton(t, PurchasePower).cash

function Base.show(io::IO, ::MIME"text/plain", trader::Trader)
    positions = Matrix{Any}(undef, length(trader[Position]), 3)
    for (i, p) in enumerate(trader[Position])
        positions[i, 1] = p.ticker
        positions[i, 2] = p.quantity
        positions[i, 3] = current_price(trader.broker, p.ticker) * p.quantity
    end

    println(io, "Trader\n")
    println(io, "Main task:    $(trader.main_task)")
    println(io, "Trading task: $(trader.trading_task)")
    println(io, "Data task:    $(trader.data_task)")
    println(io)

    positions_value = sum(positions[:, 3]; init = 0)
    cash            = trader[Cash][1].cash

    println(io,
            "Portfolio -- positions: $positions_value, cash: $cash, tot: $(cash + positions_value)\n")

    println(io, "Current positions:")
    pretty_table(io, positions; header = ["Ticker", "Quantity", "Value"])
    println(io)

    println(io, "Strategies:")
    for s in stages(trader)
        if s.name in (:main, :indicators)
            continue
        end
        print(io, "$(s.name): ")
        for sys in s.steps
            print(io, "$sys ")
        end
        println(io)
    end
    println(io)

    println(io, "Trades:")

    header = ["Time", "Ticker", "Side", "Quantity", "Avg Price", "Tot Price"]
    trades = Matrix{Any}(undef, length(trader[Filled]), length(header))

    for (i, e) in enumerate(@entities_in(trader, TimeStamp && Filled && Order))
        trades[i, 1] = e.filled_at
        trades[i, 2] = e.ticker
        trades[i, 3] = e in trader[Purchase] ? "buy" : "sell"
        trades[i, 4] = e.quantity
        trades[i, 5] = e.avg_price
        trades[i, 6] = e.avg_price * e.quantity
    end
    pretty_table(io, trades; header = header)

    println(io)
    show(io, "text/plain", trader.l)
    return nothing
end

function ensure_systems!(l::AbstractLedger)
    stageid = findfirst(x -> x.name == :indicators, stages(l))
    if stageid !== nothing
        ind_stage = stages(l)[stageid]
    else
        ind_stage = Stage(:indicators, System[])
    end

    n_steps = 0
    n_components = 0
    while length(ind_stage.steps) != n_steps || n_components != length(keys(components(l)))
        n_steps      = length(ind_stage.steps)
        n_components = length(keys(components(l)))

        for T in keys(components(l))
            eT = eltype(T)
            if !(eT <: Number)
                Overseer.ensure_component!(l, eltype(T))
            end

            if T <: SMA && SMACalculator() ∉ ind_stage
                push!(ind_stage, SMACalculator())
            elseif T <: MovingStdDev && MovingStdDevCalculator() ∉ ind_stage
                push!(ind_stage, MovingStdDevCalculator())
            elseif T <: EMA && EMACalculator() ∉ ind_stage
                push!(ind_stage, EMACalculator())
            elseif T <: UpDown && UpDownSeparator() ∉ ind_stage
                push!(ind_stage, UpDownSeparator())
            elseif T <: Difference && DifferenceCalculator() ∉ ind_stage
                push!(ind_stage, DifferenceCalculator())
            elseif T <: RelativeDifference && RelativeDifferenceCalculator() ∉ ind_stage
                push!(ind_stage, RelativeDifferenceCalculator())

            elseif T <: Sharpe && SharpeCalculator() ∉ ind_stage
                horizon = T.parameters[1]
                comp_T  = T.parameters[2]

                sma_T = SMA{horizon,comp_T}
                std_T = MovingStdDev{horizon,comp_T}
                Overseer.ensure_component!(l, sma_T)
                Overseer.ensure_component!(l, std_T)

                push!(ind_stage, sharpe_systems()...)

            elseif T <: LogVal && LogValCalculator() ∉ ind_stage
                push!(ind_stage, LogValCalculator())

            elseif T <: RSI && RSICalculator() ∉ ind_stage
                ema_T = EMA{T.parameters[1],UpDown{Difference{T.parameters[2]}}}
                Overseer.ensure_component!(l, ema_T)
                push!(ind_stage, rsi_systems()...)

            elseif T <: Bollinger && BollingerCalculator() ∉ ind_stage
                sma_T = SMA{T.parameters...}
                ind_T = T.parameters[2]
                Overseer.ensure_component!(l, sma_T)
                Overseer.ensure_component!(l, ind_T)

                push!(ind_stage, bollinger_systems()...)
            end
        end
        unique!(ind_stage.steps)
    end

    # Now insert the indicators stage in the most appropriate spot
    if stageid === nothing
        mainid = findfirst(x -> x.name == :main, stages(l))
        if mainid === nothing
            push!(l, ind_stage)
        else
            insert!(stages(l), mainid + 1, ind_stage)
        end
    end
end
