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
where `message_handler` is a subtype of `AbstractFIXHandler`.

```julia
julia> FIX.send_message(client, Dict(1 => "a", 2 => "5"))
```
and so on.
