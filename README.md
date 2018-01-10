# FIX.jl - WIP

[FIX](https://www.fixtrading.org/what-is-fix/) API client written in Julia.

## Installation
```julia
julia> Pkg.clone("git@github.com:DatName/FIX.jl.git")
```

## Usage
```julia
julia> using FIX
julia> sock = MbedTLS.connect("127.0.0.1", 1498)
julia> client = FIXClient(sock, message_handler, header)
```
where `message_handler` is a subtype of `AbstractMessageHandler`.

```julia
julia> FIX.send_message(client, Dict(1 => "a", 2 => "5"))
```
and so on.

```julia
@benchmark fix.placeOrder(client, "buy", "BTC-EUR", 0.0001001, 12000.0)

BenchmarkTools.Trial:
  memory estimate:  19.06 KiB
  allocs estimate:  299
  --------------
  minimum time:     15.816 μs (0.00% GC)
  median time:      22.110 μs (0.00% GC)
  mean time:        44.368 μs (41.69% GC)
  maximum time:     28.548 ms (99.69% GC)
  --------------
  samples:          10000
  evals/sample:     1
```
