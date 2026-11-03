defmodule IMAPClient.Session do
  # Internal to IMAPClient.
  @moduledoc false

  alias IMAPClient
  alias IMAPClient.Diagnostic
  alias IMAPClient.Error
  alias IMAPClient.MIME
  alias IMAPClient.Protocol
  alias IMAPClient.SignIn

  # Message metadata for search and read; BODY.PEEK never marks read.
  @metadata_items "FLAGS ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (List-Unsubscribe)]"

  def test_connection(config) do
    case with_session(config, nil, fn _ -> :ok end) do
      :ok ->
        %{ok: true}

      {:error, %Error{code: code}} ->
        reason =
          case code do
            :auth_rejected -> :auth
            :connection_limit -> :busy
            code when code in [:no, :bad] -> :refused
            _ -> :unreachable
          end

        connection_test_failure(config, reason)
    end
  end

  defp connection_test_failure(config, reason) do
    Diagnostic.emit(config, %{event: :connection_test_failed, reason: reason})
    %{ok: false, reason: reason}
  end

  defp gap(config, folder, stage, requested, missing, response, search \\ nil) do
    event = %{
      event: :fetch_incomplete,
      folder: folder,
      stage: stage,
      requested_count: requested,
      missing: missing,
      other_lines: response.other_lines,
      completion: response.completion
    }

    Diagnostic.emit(config, if(search, do: Map.put(event, :search, search), else: event))
  end

  def folders(config, special?) do
    with_session(config, nil, fn connection ->
      if special?, do: IMAPClient.list_special_use(connection), else: IMAPClient.list(connection)
    end)
  end

  def append(config, folder, message, opts) do
    with_session(config, nil, &IMAPClient.append(&1, folder, message, opts))
  end

  def search(config, criteria) do
    folder = Map.get(criteria, :folder) || "INBOX"

    with {:ok, command} <- Protocol.build_search(criteria) do
      with_session(config, folder, fn connection ->
        with {:ok, uids} <- IMAPClient.search_uids(connection, command) do
          uids = Enum.sort(uids, :desc)
          limit = Map.get(criteria, :limit)
          uids = if is_integer(limit) and limit > 0, do: Enum.take(uids, limit), else: uids

          with {:ok, data} <- IMAPClient.fetch(connection, uids, @metadata_items) do
            missing =
              uids
              |> Enum.reject(&Map.has_key?(data.messages, &1))
              |> Enum.map(&%{uid: &1, reason: :withheld})

            if missing != [],
              do: gap(config, folder, :search, length(uids), missing, data)

            results =
              Enum.flat_map(uids, fn uid ->
                case Map.fetch(data.messages, uid) do
                  {:ok, items} ->
                    parsed = parse_metadata(items, config)

                    attachments =
                      MIME.collect_attachments(
                        parsed.structure,
                        MIME.select_text_parts(parsed.structure),
                        decoder(config)
                      )

                    [
                      %{
                        uid: uid,
                        flags: parsed.flags,
                        envelope: parsed.envelope,
                        has_attachments: attachments != [],
                        list_unsubscribe: parsed.list_unsubscribe
                      }
                    ]

                  :error ->
                    []
                end
              end)

            {:ok, %{results: results, unreturned: length(uids) - length(results)}}
          end
        end
      end)
    else
      {:error, :invalid_argument} -> {:error, Error.new(:invalid_argument, :search)}
    end
  end

  def read(config, uid, folder) do
    with {:ok, [result]} <- read_many(config, [uid], folder), do: {:ok, result}
  end

  def read_many(config, uids, folder) do
    with_session(config, folder, fn connection ->
      with {:ok, data} <- IMAPClient.fetch(connection, uids, @metadata_items),
           {:ok, reasons} <- explain_missing(config, folder, connection, uids, data) do
        Enum.reduce_while(uids, {:ok, []}, fn uid, {:ok, results} ->
          result =
            case Map.fetch(data.messages, uid) do
              {:ok, items} ->
                read_found(
                  {config, folder, length(uids)},
                  connection,
                  uid,
                  parse_metadata(items, config)
                )

              :error ->
                {:ok, %{kind: :missing, uid: uid, reason: Map.get(reasons, uid, :unchecked)}}
            end

          case result do
            {:ok, result} -> {:cont, {:ok, [result | results]}}
            error -> {:halt, error}
          end
        end)
        |> reverse_results()
      end
    end)
  end

  defp reverse_results({:ok, results}) do
    {:ok, Enum.reverse(results)}
  end

  defp reverse_results(error) do
    error
  end

  defp read_found({config, _folder, _requested} = context, connection, uid, parsed) do
    case fetch_email_body(context, connection, uid, parsed.structure) do
      {:ok, body} ->
        email =
          Map.merge(body, %{
            uid: uid,
            flags: parsed.flags,
            envelope: parsed.envelope,
            attachments:
              MIME.collect_attachments(
                parsed.structure,
                MIME.select_text_parts(parsed.structure),
                decoder(config)
              ),
            list_unsubscribe: parsed.list_unsubscribe
          })

        {:ok, %{kind: :found, email: email}}

      {:error, %Error{code: :no_data}} ->
        {:ok, %{kind: :missing, uid: uid, reason: :withheld}}

      error ->
        error
    end
  end

  defp parse_metadata(items, config) do
    structure = MIME.parse_mime_structure(Map.get(items, "BODYSTRUCTURE"))

    header =
      Enum.find_value(items, fn {key, value} ->
        if String.starts_with?(key, "BODY[HEADER.FIELDS") and is_binary(value), do: value
      end)

    %{
      flags: Map.get(items, "FLAGS", []),
      envelope: Protocol.envelope(Map.get(items, "ENVELOPE", []), decoder(config)),
      structure: structure,
      list_unsubscribe: Protocol.list_unsubscribe(header)
    }
  end

  defp fetch_email_body(context, connection, uid, structure) do
    parts = MIME.select_text_parts(structure)

    with {:ok, plain} <- fetch_text(context, connection, uid, parts.plain),
         {:ok, html} <- fetch_text(context, connection, uid, parts.html) do
      had_parts? = parts.plain != nil or parts.html != nil

      if structure == nil or (had_parts? and plain == :refused and html == :refused) do
        guess_text(context, connection, uid, ["1", "TEXT"])
      else
        {:ok, shown_body(plain, html)}
      end
    end
  end

  defp fetch_text(_context, _connection, _uid, nil) do
    {:ok, :refused}
  end

  defp fetch_text(context, connection, uid, part) do
    fetch_text_section(context, connection, uid, part.part_id, part)
  end

  defp fetch_text_section({config, _, _} = context, connection, uid, section, part) do
    case fetch_body(context, connection, uid, section) do
      {:ok, bytes} -> {:ok, bytes |> MIME.decode_text_part(part, decoder(config)) |> trim_text()}
      error -> if live_refusal?(error, connection), do: {:ok, :refused}, else: error
    end
  end

  defp guess_text(_context, _connection, _uid, []) do
    {:ok, %{}}
  end

  defp guess_text(context, connection, uid, [section | rest]) do
    case fetch_text_section(context, connection, uid, section, nil) do
      {:ok, :refused} -> guess_text(context, connection, uid, rest)
      {:ok, text} -> {:ok, shown_body(text, :refused)}
      error -> error
    end
  end

  defp fetch_body({config, folder, requested}, connection, uid, section) do
    with {:ok, response} <- IMAPClient.fetch_body_response(connection, uid, section) do
      if response.body == :missing do
        gap(config, folder, :body, requested, [%{uid: uid, reason: :withheld}], response)
        {:error, Error.new(:no_data, :body)}
      else
        {:ok, response.body}
      end
    end
  end

  # Text in an unknown charset stays raw: what counts as whitespace in it is unknown.
  defp trim_text(text) when is_binary(text) do
    String.trim(text)
  end

  defp trim_text(raw) do
    raw
  end

  defp decoder(config) do
    Map.get(config, :charset_decoder)
  end

  defp shown_body(plain, html) do
    [{:text_body, plain}, {:html_body, html}]
    |> Enum.reject(fn {_key, value} -> value in [:refused, ""] end)
    |> Map.new()
  end

  defp explain_missing(config, folder, connection, uids, data) do
    missing = Enum.reject(uids, &Map.has_key?(data.messages, &1))

    if missing == [] do
      {:ok, %{}}
    else
      case missing_reasons(connection, missing) do
        {:ok, reasons, search} ->
          outcomes = Enum.map(missing, &%{uid: &1, reason: Map.fetch!(reasons, &1)})
          gap(config, folder, :metadata, length(uids), outcomes, data, search)
          {:ok, reasons}

        {:error, error} ->
          search = %{outcome: :failed, other_lines: [], completion: Exception.message(error)}
          outcomes = Enum.map(missing, &%{uid: &1, reason: :unchecked})
          gap(config, folder, :metadata, length(uids), outcomes, data, search)
          {:error, error}
      end
    end
  end

  defp missing_reasons(connection, uids) do
    case IMAPClient.search_strict(connection, "UID #{Enum.join(uids, ",")}") do
      {:ok, %{uids: found, lines: lines, completion: completion}} ->
        reasons =
          Map.new(uids, fn uid ->
            {uid,
             cond do
               is_nil(found) -> :unchecked
               uid in found -> :withheld
               true -> :gone
             end}
          end)

        search = %{
          outcome: if(is_nil(found), do: :no_search_response, else: :answered),
          other_lines:
            Enum.reject(lines, &Regex.match?(~r/^\*\s+(?:SEARCH\b|\d+\s+FETCH\b)/i, &1)),
          completion: completion
        }

        {:ok, reasons, search}

      error ->
        if live_refusal?(error, connection) do
          {:error, refusal} = error
          search = %{outcome: :refused, other_lines: [], completion: Exception.message(refusal)}
          {:ok, Map.new(uids, &{&1, :unchecked}), search}
        else
          error
        end
    end
  end

  defp live_refusal?({:error, %Error{code: code}}, connection) when code in [:no, :bad] do
    IMAPClient.live?(connection)
  end

  defp live_refusal?(_, _) do
    false
  end

  def move(config, uids, destination, source) do
    with_session(config, source, fn connection ->
      with {:ok, existing} <- existing_uids(connection, uids),
           {:ok, unpurged} <- move_existing(connection, existing, destination) do
        {:ok, %{missing_uids: uids -- existing, unpurged_uids: unpurged}}
      end
    end)
  end

  defp move_existing(_connection, [], _destination) do
    {:ok, []}
  end

  defp move_existing(connection, uids, destination) do
    with {:ok, capabilities} <- IMAPClient.capabilities(connection) do
      cond do
        MapSet.member?(capabilities, "MOVE") ->
          with :ok <- IMAPClient.move_uids(connection, uids, destination), do: {:ok, []}

        true ->
          with :ok <- IMAPClient.copy(connection, uids, destination),
               :ok <- IMAPClient.store(connection, uids, "\\Deleted", "+") do
            if MapSet.member?(capabilities, "UIDPLUS") do
              with :ok <- IMAPClient.uid_expunge(connection, uids), do: {:ok, []}
            else
              {:ok, uids}
            end
          end
      end
    end
  end

  def mark(config, uids, folder, flags, action) when is_list(flags) and flags != [] do
    with_session(config, folder, fn connection ->
      with {:ok, existing} <- existing_uids(connection, uids),
           :ok <- IMAPClient.store(connection, existing, Enum.join(flags, " "), action) do
        {:ok, %{missing_uids: uids -- existing}}
      end
    end)
  end

  def mark(_config, _uids, _folder, _flags, _action) do
    {:error, Error.new(:invalid_argument, :store)}
  end

  defp existing_uids(_connection, []) do
    {:ok, []}
  end

  defp existing_uids(connection, uids) do
    with {:ok, found} <- IMAPClient.search_uids(connection, "UID #{Enum.join(uids, ",")}"),
         do: {:ok, Enum.filter(uids, &(&1 in found))}
  end

  def download_attachment(config, uid, part_id, folder, max_bytes) do
    if is_integer(max_bytes) and max_bytes >= 0 do
      with_session(config, folder, fn connection ->
        fetch_attachment(config, folder, connection, uid, part_id, max_bytes)
      end)
    else
      {:error, Error.new(:invalid_argument, :body)}
    end
  end

  defp fetch_attachment(config, folder, connection, uid, part_id, max_bytes) do
    result =
      with {:ok, data} <- IMAPClient.fetch(connection, [uid], "BODYSTRUCTURE") do
        case Map.fetch(data.messages, uid) do
          {:ok, items} ->
            part =
              items
              |> Map.get("BODYSTRUCTURE")
              |> MIME.parse_mime_structure()
              |> MIME.find_leaf_part(part_id)

            download_part({config, folder, 1}, connection, uid, part, max_bytes)

          :error ->
            with {:ok, reasons} <- explain_missing(config, folder, connection, [uid], data),
                 do: {:ok, %{kind: :missing, reason: Map.get(reasons, uid, :unchecked)}}
        end
      end

    case result do
      {:error, %Error{code: :no_data}} -> {:ok, %{kind: :missing, reason: :withheld}}
      error -> if live_refusal?(error, connection), do: {:ok, %{kind: :not_found}}, else: error
    end
  end

  defp download_part(_context, _connection, _uid, nil, _max_bytes) do
    {:ok, %{kind: :not_found}}
  end

  defp download_part(context, connection, uid, part, max_bytes) do
    bound = MIME.decoded_size_lower_bound(part)

    if bound != nil and bound > max_bytes do
      {:ok, %{kind: :too_large, bytes: bound}}
    else
      with {:ok, bytes} <- fetch_body(context, connection, uid, part.part_id) do
        case MIME.decode_attachment(bytes, part.encoding) do
          {:ok, content} when byte_size(content) > max_bytes ->
            {:ok, %{kind: :too_large, bytes: byte_size(content)}}

          {:ok, content} ->
            {config, _folder, _requested} = context

            {:ok,
             %{
               kind: :ok,
               content: content,
               mime_type: MIME.normalized_mime_type(part),
               filename: MIME.attachment_filename(part, decoder(config))
             }}

          {:error, :malformed_content} ->
            {:error, Error.new(:malformed_content, :body)}
        end
      end
    end
  end

  # Opens a session (sign in, then SELECT the folder when given), runs the operation,
  # and always cleans up: LOGOUT while the connection is still usable, then close.
  # Sessions retry a timed-out sign-in once and report slow sign-ins;
  # `retry_sign_in: false` in the config turns the retry off.
  defp with_session(config, folder, operation) do
    retry? = Map.get(config, :retry_sign_in, true) != false

    with {:ok, connection} <- SignIn.open(config, retry: retry?, log_slow: true) do
      try do
        with :ok <- select_folder(connection, folder), do: operation.(connection)
      after
        SignIn.close(connection)
      end
    end
  end

  defp select_folder(_connection, nil) do
    :ok
  end

  defp select_folder(connection, folder) do
    IMAPClient.select(connection, folder)
  end
end
