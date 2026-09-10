# frozen_string_literal: true

require "socket"

module Owlook
  # A minimal real HTTP/1.1 server for exercising GithubClient's actual
  # socket-level behavior (redirects, status codes) without hitting the
  # real GitHub API or reaching for a mocking library — same spirit as
  # this codebase's own "real temp git repos, never a mocked git" rule
  # for GitRepoTest, applied to HTTP instead.
  #
  # Scripted with a queue of responses, one per request received, in
  # order — #respond_with(status, headers: {}, body: "") queues one.
  class FakeHttpServer
    # Every request actually received, in order — [{ path:, headers: }, ...]
    # (headers keyed lowercase) — lets a test assert the client sent a real
    # conditional header (If-None-Match), not just that it handled the
    # response.
    attr_reader :received_requests

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @responses = []
      @received_requests = []
    end

    def port = @server.addr[1]
    def base_url = "http://127.0.0.1:#{port}"

    def respond_with(status, headers: {}, body: "")
      @responses << [status, headers, body]
      self
    end

    # Serves exactly as many requests as responses were queued, then stops.
    def start
      @thread = Thread.new do
        @responses.length.times do
          socket = @server.accept
          begin
            @received_requests << read_request(socket)
            status, headers, body = @responses.shift
            write_response(socket, status, headers, body)
          ensure
            socket.close
          end
        end
      end
      self
    end

    def stop
      @thread&.join(2)
      @server.close
    end

    private

    def read_request(socket)
      request_line = socket.gets.to_s
      path = request_line.split[1]
      headers = {}
      while (line = socket.gets) && line.chomp != ""
        key, value = line.chomp.split(":", 2)
        headers[key.strip.downcase] = value.strip if key && value
      end
      { path: path, headers: headers }
    end

    def write_response(socket, status, headers, body)
      socket.write "HTTP/1.1 #{status} #{reason(status)}\r\n"
      socket.write "Content-Length: #{body.bytesize}\r\n"
      socket.write "Connection: close\r\n"
      headers.each { |k, v| socket.write "#{k}: #{v}\r\n" }
      socket.write "\r\n"
      socket.write body
    end

    def reason(status)
      { 200 => "OK", 301 => "Moved Permanently", 304 => "Not Modified", 404 => "Not Found" }.fetch(status, "Unknown")
    end
  end
end
