module HTTPDownloads

# We vendor a copy of Downloads.jl. This is necessary because:
#
# * We need extensions to the version of Downloads which is distributed with
#   julia-1.6
# * As a stdlib it's impossible to install newer versions without upgrading
#   Julia itself.
include("Downloads.jl")

import .Downloads: Downloads, Curl, Downloader

using Sockets: TCPSocket
import NetworkOptions

using URIs
using HTTP

abstract type LibCurlLayer{Next <: HTTP.Layer} <: HTTP.Layer{Next} end

const DOWNLOAD_LOCK = ReentrantLock()
const DOWNLOADER = Ref{Union{Nothing,Downloader}}(nothing)

function http_easy_hook(easy, info)
    # Disable redirects - HTTP.jl will handle this.
    Curl.setopt(easy, Curl.CURLOPT_FOLLOWLOCATION, false)

    # TODO: Figure out how to allow setting of
    # https://curl.se/libcurl/c/CURLMOPT_MAXCONNECTS.html
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
            #   We use the multi interface, so probably need to figure out how
            #   to use the multi CURLMOPT_MAXCONNECTS.
            #     https://curl.se/libcurl/c/CURLMOPT_MAXCONNECTS.html
            #     https://curl.se/libcurl/c/CURLOPT_MAXCONNECTS.html
            #
            # * pipeline_limit::Int=1
            #     # likely will be deprecated in HTTP.jl - ignore
            # * idle_timeout::Int=0,
            #     # Similar to the Downloader's grace parameter

            # ConnectionPool / sslconnection
            require_ssl_verification::Bool=NetworkOptions.verify_host(url.host, "SSL"),
            sslconfig=nothing,

            keepalive::Bool=false,
            connect_timeout::Int=0,

            proxy::Union{AbstractString,Nothing}=nothing,
            # * reuse_limit =
            #     No equiv? Ignored for now

            # # StreamLayer
            # * reached_redirect_limit=false,
            #     FIXME ???
            # * iofunction=nothing,
            #     TODO: Figure out callbacks?
            # * verbose::Int=0,

            kw...) where Next

    if iofunction !== nothing    || socket_type !== TCPSocket || sslconfig !== nothing
        # Fallback to pure-Julia implementation in HTTP.ConnectionPool for
        # options we can't handle with libcurl.
        #
        # FIXME: This is required until we can figure out how to expose this
        # functionality via libcurl
        if sslconfig === nothing
            sslconfig = HTTP.ConnectionPool.nosslconfig
        end
        return HTTP.request(Next, url, req, body;
                            response_stream=response_stream,
                            iofunction=iofunction,
                            readtimeout=readtimeout,
                            socket_type=socket_type,
                            sslconfig=sslconfig,
                            kw...)
    end

    input = req.body === HTTP.body_is_a_stream ? body :
            length(req.body) > 0 ? IOBuffer(req.body) : nothing

    output_buf = nothing
    output = response_stream
    if response_stream === nothing
        # HTTP.jl assumes you always want the body by default.
        output = output_buf = IOBuffer()
    end

    function per_request_easy_hook(easy)
        if !require_ssl_verification
            Curl.setopt(easy, Curl.CURLOPT_SSL_VERIFYPEER, false)
        end
        if keepalive
            Curl.setopt(easy, Curl.CURLOPT_TCP_KEEPALIVE, true)
        end
        if proxy !== nothing
            Curl.setopt(easy, Curl.CURLOPT_PROXY, proxy)
        end
        if connect_timeout > 0
            Curl.setopt(easy, Curl.CURLOPT_CONNECTTIMEOUT, connect_timeout)
            # See also https://curl.se/libcurl/c/CURLOPT_CONNECTTIMEOUT_MS.html
            # if we want to allow subsecond timeouts.
        end
    end

    response = Downloads.request(string(url);
        downloader = get_downloader(),
        method = req.method,
        headers = req.headers,
        input = input,
        output = output,
        timeout = readtimeout <= 0 ? Inf : readtimeout,
        throw = false,
        verbose = verbose > 0,
        easy_hook = per_request_easy_hook)

    if response isa Downloads.RequestError
        # We couldn't even get a response. There's a huge list of possible
        # return codes in libcurl's curl.h.
        #
        # Users of HTTP.jl largely seem to match these based on whether they're
        # "retryable", and expect to see HTTP.jl's error types. This informal
        # API is hard to match! For now:
        #
        #   * If an error "seems retryable", wrap in HTTP.IOError
        #   * For other cases, just throw the RequestError
        #   * Ugh.
        #
        #
        # As an example, AWS.jl has the following logic:
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
            # HTTP throws
            #   * HTTP.TimeoutRequest.ReadTimeoutError for readtimeout
            #   * HTTP.ConnectionPool.ConnectTimeout   for connect_timeout
            # CURL doesn't distinguish between these however, so it's not easy
            # to know which one we've hit here.
            t = readtimeout > 0 ? readtimeout : connect_timeout
            throw(HTTP.TimeoutRequest.ReadTimeoutError(t))
            # TODO: Would it be better just to throw(response) ??
        elseif response.code in (Curl.CURLE_PEER_FAILED_VERIFICATION,
                                 Curl.CURLE_SSL_CERTPROBLEM,
                                 Curl.CURLE_SSL_CIPHER,
                                 Curl.CURLE_SSL_CACERT_BADFILE,
                                 Curl.CURLE_SSL_CRL_BADFILE,
                                 Curl.CURLE_SSL_ISSUER_ERROR)
            # SSL certificate problems - not retryable, so just throw the
            # original error.
            throw(response)
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
