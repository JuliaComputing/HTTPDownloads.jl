using HTTPDownloads
using Test

using HTTP
import JSON

HTTPDownloads.set_downloads_backend()

server = "https://httpbingo.julialang.org"

jsonbody(res::HTTP.Response) = JSON.parse(String(copy(res.body)))

@testset "Basic functionality" begin
    res = HTTP.get("$server/get?a=1&b=2")
    @test res isa HTTP.Response
    body = jsonbody(res)
    @test body["args"]["a"] == ["1"]
    @test body["args"]["b"] == ["2"]

    # Errors mapped to HTTP StatusError
    @test_throws HTTP.ExceptionRequest.StatusError HTTP.get("$server/status/400")
    @test HTTP.status(HTTP.get("$server/status/400", status_exception=false)) == 400
end

@testset "Input body data" begin
    postbody_roundtrip(body) = jsonbody(HTTP.post("$server/post", body=body))["data"]

    data = "hi\x00\x01"
    @test postbody_roundtrip(data) == data
    @test postbody_roundtrip(Vector{UInt8}(codeunits(data))) == data

    # Streams
    @test postbody_roundtrip(IOBuffer(data)) == data
    @test postbody_roundtrip(IOBuffer(codeunits(data))) == data
    @test begin
        io = Base.BufferStream()
        write(io, data)
        close(io) # Should be closewrite()? But that doesn't exist until Julia-1.8
        postbody_roundtrip(io)
    end == data
end

@testset "Output body data" begin
    @test begin
        # Check explicitly provided streams work.
        # Downloads.jl is arguably more correct here than HTTP itself. See:
        # https://github.com/JuliaWeb/HTTP.jl/issues/543
        stream = IOBuffer()
        HTTP.get("$server/get?a=1", response_stream=stream)
        JSON.parse(String(take!(stream)))["args"]["a"]
    end == ["1"]
    # Right now, HTTP.open() falls through to HTTP.jl internals rather than
    # using Downloads.jl. Check that this works:
    @test begin
        body = nothing
        HTTP.open("GET", "$server/get?xx=100") do http
            body = String(read(http))
        end
        JSON.parse(body)["args"]["xx"]
    end == ["100"]
end

@testset "Timeouts" begin
    @test HTTP.get("$server/delay/2", readtimeout=10) isa HTTP.Response
    @test_throws HTTP.TimeoutRequest.ReadTimeoutError HTTP.get("$server/delay/5", readtimeout=1)
    # TODO: connect_timeout
end

@testset "Redirects" begin
    # Test that redirects can be disabled
    @test begin
        response = HTTP.get("$(server)/redirect/1", redirect=false)
        haskey(Dict(HTTP.headers(response)), "location")
    end
    @test begin
        response = HTTP.get("$(server)/redirect/1", redirect=true)
        !haskey(Dict(HTTP.headers(response)), "location")
    end
end
