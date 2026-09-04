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
    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @responses = []
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
            socket.gets # request line — path/method aren't used, only sequencing
            socket.readline until socket.gets.to_s.chomp.empty? # drain headers
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

    def write_response(socket, status, headers, body)
      socket.write "HTTP/1.1 #{status} #{reason(status)}\r\n"
      socket.write "Content-Length: #{body.bytesize}\r\n"
      socket.write "Connection: close\r\n"
      headers.each { |k, v| socket.write "#{k}: #{v}\r\n" }
      socket.write "\r\n"
      socket.write body
    end

    def reason(status)
      { 200 => "OK", 301 => "Moved Permanently", 404 => "Not Found" }.fetch(status, "Unknown")
    end
  end
end
