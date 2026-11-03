defmodule IMAPClient.Transport do
  # Internal to IMAPClient.
  @moduledoc false

  def connect_tcp(config, timeout_ms) do
    host = String.to_charlist(config.host)

    host =
      case :inet.parse_address(host) do
        {:ok, address} -> address
        _ -> host
      end

    options = [
      :binary,
      active: false,
      packet: :raw,
      nodelay: true,
      # Abort must discard queued output. OTP's default TCP close can wait up to
      # three minutes for a full driver queue, even with linger disabled.
      linger: {true, 0},
      send_timeout: timeout_ms,
      send_timeout_close: true
    ]

    port = Map.get(config, :port, if(Map.get(config, :use_tls, true), do: 993, else: 143))

    case :gen_tcp.connect(host, port, options, timeout_ms) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  # The clock and TLS connector are internal seams for exact deadline assertions.
  def upgrade(socket, config, deadline_ms, opts \\ []) do
    if Map.get(config, :use_tls, true) do
      trust =
        case Map.get(config, :cacertfile) do
          nil -> [cacerts: :public_key.cacerts_get()]
          path -> [cacertfile: String.to_charlist(path)]
        end

      # The existing-TCP overload has no DNS host argument. Supply the original
      # name explicitly; for IPs OTP derives the IP SAN reference from peername.
      # SNI=disable would also disable hostname verification, so never use it.
      sni =
        case :inet.parse_address(String.to_charlist(config.host)) do
          {:ok, _address} -> []
          _ -> [server_name_indication: String.to_charlist(config.host)]
        end

      tls = [
        verify: :verify_peer,
        versions: [:"tlsv1.3", :"tlsv1.2"],
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      # Loading the system trust store can itself take part of the connect
      # budget. Never start a new full handshake timeout after that work.
      clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
      remaining_ms = deadline_ms - clock.()

      if remaining_ms > 0 do
        tls_connect = Keyword.get(opts, :tls_connect, &:ssl.connect/3)

        case tls_connect.(socket, tls ++ trust ++ sni, remaining_ms) do
          {:ok, socket} -> {:ok, {:ssl, socket}}
          {:error, reason} -> {:error, classify(reason)}
        end
      else
        {:error, :timeout}
      end
    else
      {:ok, {:gen_tcp, socket}}
    end
  end

  defp classify(:timeout) do
    :timeout
  end

  defp classify(_) do
    :closed
  end

  def activate({:ssl, socket}) do
    :ssl.setopts(socket, active: :once)
  end

  def activate({:gen_tcp, socket}) do
    :inet.setopts(socket, active: :once)
  end

  def transfer({transport, socket}, owner) do
    transport.controlling_process(socket, owner)
  end

  def send_bytes({transport, socket}, bytes, timeout_ms) do
    options = [send_timeout: max(timeout_ms, 1), send_timeout_close: true]

    set =
      if transport == :ssl,
        do: :ssl.setopts(socket, options),
        else: :inet.setopts(socket, options)

    with :ok <- set, do: transport.send(socket, bytes)
  end

  # Keep the public TCP handle when upgrading to SSL, so cancellation bypasses
  # SSL's synchronous close-notify and sender waits. Never inspect SSL internals.
  def abort(nil) do
    :ok
  end

  def abort(socket) do
    :gen_tcp.close(socket)
  end
end
