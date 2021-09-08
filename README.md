# HTTPDownloads

[![Build Status](https://github.com/JuliaComputing/HTTPDownloads.jl/workflows/CI/badge.svg)](https://github.com/JuliaComputing/HTTPDownloads.jl/actions)

A package which allows [Downloads.jl](https://github.com/JuliaLang/Downloads.jl/)
to be used as a backend for HTTP client requests when using the
[HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) package.

Usage:

```julia
import HTTPDownloads

HTTPDownloads.set_downloads_backend()

# Now use HTTP.jl as normal
using HTTP
HTTP.get("https://httpbingo.julialang.org/get")
```

`HTTPDownloads` works by modifying the default `HTTP.stack()` to intercept
requests before they get to HTTP's `ConnectionPoolLayer`.

To be a feature-complete drop in replacement, this means it should support all
keyword arguments within the HTTP layers `ConnectionPoolLayer`, `TimeoutLayer`
and `StreamLayer`. However, not all of these are implemented yet (see the
source for `request()`)

