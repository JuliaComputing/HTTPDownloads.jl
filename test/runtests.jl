using HTTPDownloads

using Test
using Sockets

using HTTP
import MbedTLS
import JSON

# Find a free port on `network_interface`
function find_free_port(network_interface)
    # listen on port 0 => kernel chooses a free port. See, for example,
    # https://stackoverflow.com/questions/44875422/how-to-pick-a-free-port-for-a-subprocess
    server = listen(network_interface, 0)
    _, free_port = getsockname(server)
    close(server)
    # The kernel can reuse free_port here after $some_time_delay, but apprently
    # this is large enough for Selenium to have used this technique for ten
    # years...
    return free_port
end

# Return SSL config for running a server under self-signed certs
function test_server_ssl_config()
    MbedTLS.SSLConfig(joinpath(@__DIR__, "resources", "server.pem"),
                      joinpath(@__DIR__, "resources", "server.key"))
end

# Return SSL config for running client
function test_client_ssl_config()
    MbedTLS.SSLConfig()

    conf = MbedTLS.SSLConfig()
    MbedTLS.config_defaults!(conf)

    entropy = MbedTLS.Entropy()
    rng = MbedTLS.CtrDrbg()
    MbedTLS.seed!(rng, entropy)
    MbedTLS.rng!(conf, rng)

    MbedTLS.authmode!(conf, MbedTLS.MBEDTLS_SSL_VERIFY_REQUIRED)

    # Trust the test root CA that we self-signed
    root_ca_cert = MbedTLS.crt_parse_file(joinpath(@__DIR__, "resources", "root_ca.crt"))
    MbedTLS.ca_chain!(conf, root_ca_cert)

    return conf
end

function jsonbody(res::HTTP.Response)
    JSON.parse(String(copy(res.body)))
end


#-------------------------------------------------------------------------------

HTTPDownloads.set_downloads_backend()

bingoserver = "https://httpbingo.julialang.org"

@testset "Basic functionality" begin
    res = HTTP.get("$bingoserver/get?a=1&b=2")
    @test res isa HTTP.Response
    body = jsonbody(res)
    @test body["args"]["a"] == ["1"]
    @test body["args"]["b"] == ["2"]

    # Errors mapped to HTTP StatusError
    @test_throws HTTP.ExceptionRequest.StatusError HTTP.get("$bingoserver/status/400")
    @test HTTP.status(HTTP.get("$bingoserver/status/400", status_exception=false)) == 400
end

@testset "Input body data" begin
    postbody_roundtrip(body) = jsonbody(HTTP.post("$bingoserver/post", body=body))["data"]

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
        HTTP.get("$bingoserver/get?a=1", response_stream=stream)
        JSON.parse(String(take!(stream)))["args"]["a"]
    end == ["1"]
    # Right now, HTTP.open() falls through to HTTP.jl internals rather than
    # using Downloads.jl. Check that this works:
    @test begin
        body = nothing
        HTTP.open("GET", "$bingoserver/get?xx=100") do http
            body = String(read(http))
        end
        JSON.parse(body)["args"]["xx"]
    end == ["100"]
end

@testset "Timeouts" begin
    @test HTTP.get("$bingoserver/delay/2", readtimeout=10) isa HTTP.Response
    @test_throws HTTP.TimeoutRequest.ReadTimeoutError HTTP.get("$bingoserver/delay/5", readtimeout=1)

    # Test connection timeout by attempting to connect to an unroutable IP
    # address. Discussion at
    # https://stackoverflow.com/questions/100841/artificially-create-a-connection-timeout-error/37465639
    @test_throws HTTP.TimeoutRequest.ReadTimeoutError HTTP.get("http://10.255.255.1", connect_timeout=1)
end

@testset "Redirects" begin
    # Test that redirects can be disabled
    @test begin
        response = HTTP.get("$bingoserver/redirect/1", redirect=false)
        haskey(Dict(HTTP.headers(response)), "location")
    end
    @test begin
        response = HTTP.get("$bingoserver/redirect/1", redirect=true)
        !haskey(Dict(HTTP.headers(response)), "location")
    end
end

@testset "SSL Config" begin
    test_port = find_free_port(Sockets.localhost)
    server = listen(Sockets.localhost, test_port)

    # Run a local https server with self-signed certificate
    tsk = @async try
        HTTP.listen(Sockets.localhost, test_port; server=server,
                    sslconfig=test_server_ssl_config()) do http
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            HTTP.write(http, "hello, world")
        end
    finally exc
        close(server)
        @error "Error running server" exception=exc,catch_backtrace()
    end

    # Test that we can access this server if we trust our test CA
    response = HTTP.get("https://localhost:$test_port",
                        sslconfig=test_client_ssl_config(),
                        require_ssl_verification=true,
                        retries=0)
    @test String(response.body) == "hello, world"
    @test response.status == 200

    response = HTTP.get("https://localhost:$test_port",
                        require_ssl_verification=false,
                        retries=0)
    @test String(response.body) == "hello, world"
    @test response.status == 200

    close(server)
end

