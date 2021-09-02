module HTTPDownloads

import Downloads: Downloads, Curl, Downloader

using Sockets: TCPSocket

using URIs
using HTTP

abstract type LibCurlLayer{Next <: HTTP.Layer} <: HTTP.Layer{Next} end

DOWNLOAD_LOCK = ReentrantLock()
DOWNLOADER = Ref{Union{Nothing,Downloader}}(nothing)

function http_easy_hook(easy, info)
    # Disable redirects - HTTP.jl will handle this.
    Curl.setopt(easy, Curl.CURLOPT_FOLLOWLOCATION, false)
end

function get_downloader()
    lock(DOWNLOAD_LOCK) do
        yield() # let other downloads finish
        downloader = DOWNLOADER[]
        if downloader === nothing
            # TODO: Install our own easy_handle here.
            downloader = DOWNLOADER[] = Downloader()
            downloader.easy_hook = http_easy_hook
        end
        downloader
    end
end

# Monkey-patch arg_read_size
# See https://github.com/JuliaLang/Downloads.jl/issues/142
Downloads.arg_read_size(io::Base.GenericIOBuffer) = bytesavailable(io)

function HTTP.request(::Type{LibCurlLayer{Next}}, url::URI, req, body;
            response_stream=nothing,
            iofunction=nothing,

            # # TimeoutLayer
            readtimeout=0,

            # # ConnectionLayer
            socket_type::Type=TCPSocket,

            verbose::Int=0,

            # List of all HTTP.jl keywords for the connection pool and stream
            # layers which we could/should consider emulating:

            # ConnectionPool / getconnection / newconnection
            #
            # * connection_limit::Int=default_connection_limit,
            #     https://curl.se/libcurl/c/CURLOPT_MAXCONNECTS.html
            # * pipeline_limit::Int=1
            #     # likely will be deprecated in HTTP.jl - ignore
            # * idle_timeout::Int=0,
            #     # Similar to the Downloader's grace parameter

            # ConnectionPool / sslconnection
            #
            # * require_ssl_verification=NetworkOptions.verify_host(host, "SSL"),
            #     https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYPEER.html
            # * sslconfig::SSLConfig=nosslconfig,
            #     ???

            # * keepalive::Bool=false,
            #     https://curl.se/libcurl/c/CURLOPT_TCP_KEEPALIVE.html
            # * connect_timeout::Int=0,
            #     https://curl.se/libcurl/c/CURLOPT_CONNECTTIMEOUT.html
            # * readtimeout::Int=0,
            #     OK - use requests `timeout` keyword

            # * sslconfig::SSLConfig=nosslconfig,
            #     FIXME ca_roots ???

            # * proxy =
            #     https://curl.se/libcurl/c/CURLOPT_PROXY.html
            # * require_ssl_verification = NetworkOptions.verify_host(host),
            #     https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYHOST.html
            # * reuse_limit =
            #     No equiv? Ignored for now

            # # StreamLayer
            # * reached_redirect_limit=false,
            #     FIXME ???
            # * response_stream=nothing,
            #     Done.
            # * iofunction=nothing,
            #     TODO: Figure out callbacks?
            # * verbose::Int=0,

            kw...) where Next

    if iofunction !== nothing || socket_type !== TCPSocket
        # Fallback to pure-Julia implementation in ConnectionPool.
        # This is required until we can figure out how to expose the iofunction
        # callback interface via libcurl
        HTTP.request(Next, url, req, body;
                     response_stream=response_stream,
                     iofunction=iofunction,
                     readtimeout=readtimeout,
                     socket_type=socket_type,
                     kw...)
    end

    input = req.body === HTTP.body_is_a_stream ? body :
            length(req.body) > 0 ? IOBuffer(req.body) : nothing

    output_buf = nothing
    output = response_stream
    if response_stream === nothing
        # HTTP.jl assumes you always want the body by default.
        output_buf = IOBuffer()
        if req.method != "HEAD"
            # Workaround https://github.com/JuliaLang/Downloads.jl/pull/131
            output = output_buf
        end
    end

    # Use Downloads.jl
    response = Downloads.request(string(url);
        downloader = get_downloader(),
        method = req.method,
        headers = req.headers,
        input = input,
        output = output,
        timeout = readtimeout <= 0 ? Inf : readtimeout,
        throw = false,
        verbose = verbose > 0)

    if response isa Downloads.RequestError
        # We couldn't even get a response. There's a huge list of possible
        # return codes in libcurl's curl.h.
        #
        # On the other hand, users of HTTP.jl largely seem to match these based
        # on whether they're "retryable", and expect to see HTTP.jl's error
        # types.
        #
        # For example, AWS.jl has the following logic:
        #
        #  # Base.IOError is needed because HTTP.jl can often have errors that aren't
        #  # caught and wrapped in an HTTP.IOError
        #  # https://github.com/JuliaWeb/HTTP.jl/issues/382
        #  @delay_retry if isa(e, Sockets.DNSError) ||
        #                  isa(e, HTTP.ParseError) ||
        #                  isa(e, HTTP.IOError) ||
        #                  isa(e, Base.IOError) ||
        #                  (isa(e, HTTP.StatusError) && _http_status(e) >= 500)
        #
        if response.code == Curl.CURLE_OPERATION_TIMEDOUT
            throw(HTTP.TimeoutRequest.ReadTimeoutError(readtimeout))
        else
            # Wrap other errors in HTTP.IOError. Downstream codes will likely
            # assume all such errors are retry-able
            #
            throw(HTTP.IOError(response, response.message))
        end
    end

    # Convert output back into HTTP.Response
    body = output_buf === nothing ?
           HTTP.MessageRequest.body_was_streamed :
           take!(output_buf)

    res = HTTP.Response(response.status, HTTP.mkheaders(response.headers);
                        body=body, request=req)
end

function has_http_layer(stack, layer)
    while true
        if stack === Union{}
            return false
        elseif stack <: layer
            return true
        end
        stack = stack.parameters[1]
    end
end

function set_downloads_backend(use_downloads::Bool=true)
    stack = HTTP.stack()
    if use_downloads && !has_http_layer(stack, LibCurlLayer)
        HTTP.insert_default!(ConnectionPoolLayer, LibCurlLayer)
    elseif !use_downloads && has_http_layer(stack, LibCurlLayer)
        HTTP.remove_default!(ConnectionPoolLayer, LibCurlLayer)
    end
    nothing
end

end
