# FIX.jl - WIP

[FIX](https://www.fixtrading.org/what-is-fix/) API client written in Julia.

## Installation
```julia
julia> Pkg.clone("git@github.com:DatName/FIX.jl.git")
```
## Overview
This package can:
* inefficiently convert `Dict{Int64, String}` to FIX messages (attaching header and tail)
* inefficiently parse incoming messages of `Vector{UInt8}` into `Dict{Int64, String}`.
* keep track of messaging history
* give you current (confirmed) outstanding orders
* give you position change since the start of `FIXClient`
* keep track of messaging rates

## Usage
```julia
julia> using FIX
julia> sock = MbedTLS.connect("127.0.0.1", 1498)
julia> client = FIXClient(sock, message_handler, header, ratelimit)
```
where `message_handler` is a subtype of `AbstractMessageHandler`, `header` is a `Dict{Int64, String}` with keys 8, 49 and 56. `ratelimit` is an instance of `RateLimit` exported by `FIX.jl` to track order sending rates.

```julia
julia> FIX.send_message(client, Dict(1 => "a", 2 => "5"))
julia> FIX.getOpenOrders(client)
```
and so on.

## Benchmarks
Message parsing and converting can be made much faster. But for now it is (Intel® Core™ i3-6100U CPU @ 2.30GHz × 4):

Placing order benchmark:
```julia
julia @benchmark fix.placeOrder_fake(client, "buy", "BTC-EUR", 0.0001001, 12000.0)

BenchmarkTools.Trial:
  memory estimate:  13.72 KiB
  allocs estimate:  216
  --------------
  minimum time:     16.269 μs (0.00% GC)
  median time:      23.513 μs (0.00% GC)
  mean time:        40.526 μs (33.47% GC)
  maximum time:     25.061 ms (99.50% GC)
  --------------
  samples:          10000
  evals/sample:     1
```

Parsing message benchmark:
```julia
julia> (msg, msg_str) = fix.placeOrder(client, "buy", "BTC-EUR", 0.0001001, 12000.0)
julia> b = [UInt8(x) for x in msg_str]
julia> @benchmark FIX.fixparse(b)

BenchmarkTools.Trial:
  memory estimate:  15.17 KiB
  allocs estimate:  350
  --------------
  minimum time:     14.758 μs (0.00% GC)
  median time:      16.224 μs (0.00% GC)
  mean time:        22.086 μs (12.82% GC)
  maximum time:     5.826 ms (98.32% GC)
  --------------
  samples:          10000
  evals/sample:     1
```
