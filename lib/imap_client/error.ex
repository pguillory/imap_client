defmodule IMAPClient.Error do
  @moduledoc """
  A safe IMAP failure. Messages never include server text, credentials or mail.

  `code` distinguishes refusals from poisoned connections. `stage` names the
  operation, `timeout_ms` its deadline, and `outcome_unknown?` warns that a
  mutation may have completed. For a tagged NO or BAD, `response_code` is the
  bracketed response code when it is on a fixed allowlist (such as
  `"AUTHENTICATIONFAILED"` or `"NONEXISTENT"`), `"other"` for any other code and `nil`
  for none, and `hint` is a coarse reading of the refusal text (such as
  `:app_password_required` or `:too_many_connections`) or `nil`. No operation is retried by this library, except a
  session sign-in whose greeting or authentication timed out, once.
  """

  defexception [:code, :stage, :timeout_ms, :response_code, :hint, outcome_unknown?: false]

  @type t :: %__MODULE__{
          code: atom(),
          stage: atom() | nil,
          timeout_ms: pos_integer() | nil,
          response_code: binary() | nil,
          hint: atom() | nil,
          outcome_unknown?: boolean()
        }

  @doc false
  def new(code, stage \\ nil, opts \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [
          code: code,
          stage: stage,
          outcome_unknown?: mutation?(stage) and code in [:timeout, :closed, :protocol]
        ],
        opts
      )
    )
  end

  defp mutation?(stage) do
    stage in [:store, :copy, :move, :expunge, :append]
  end

  @impl true
  def message(error) do
    label = if error.stage, do: " during #{error.stage}", else: ""
    timeout = if error.timeout_ms, do: " after #{error.timeout_ms} ms", else: ""

    ambiguity =
      if error.outcome_unknown?,
        do: "; server outcome is unknown, do not retry automatically",
        else: ""

    "IMAP #{error.code}#{label}#{timeout}#{ambiguity}"
  end

  # Only fixed categories survive a server refusal; server prose can echo LOGIN.
  @response_codes ~w(ALERT WEBALERT AUTHENTICATIONFAILED AUTHORIZATIONFAILED UNAVAILABLE EXPIRED PRIVACYREQUIRED CONTACTADMIN LIMIT INUSE SERVERBUG OVERQUOTA CANNOT NOPERM PARSE CLIENTBUG TRYCREATE NONEXISTENT)

  @doc false
  def refusal(status, line, stage) when status in [:no, :bad] do
    response_code =
      case Regex.run(~r/^\S+\s+(?:NO|BAD)\s+\[([^\]\s]*)/i, line) do
        [_, code] ->
          code = String.upcase(code)
          if code in @response_codes, do: code, else: "other"

        _ ->
          nil
      end

    hint = response_hint(line)

    code =
      cond do
        stage == :authentication and status == :no and
            Regex.match?(~r/too many simultaneous connections/i, line) ->
          :connection_limit

        stage == :authentication and status == :no and
            Regex.match?(~r/\[AUTHENTICATIONFAILED\]|invalid credentials/i, line) ->
          :auth_rejected

        stage == :select and status == :no ->
          :mailbox_no

        stage in [:copy, :move] and status == :no and
            response_code in ["TRYCREATE", "NONEXISTENT"] ->
          :mailbox_no

        true ->
          status
      end

    new(code, stage, response_code: response_code, hint: hint)
  end

  defp response_hint(line) do
    cond do
      Regex.match?(~r/too many (simultaneous )?connections|maximum number of connections/i, line) ->
        :too_many_connections

      Regex.match?(~r/web ?login|via your web browser|WEBLOGINREQUIRED/i, line) ->
        :web_login_required

      Regex.match?(~r/application-specific password|app(lication)?[- ]password required/i, line) ->
        :app_password_required

      Regex.match?(
        ~r/exceeded|bandwidth|rate.?limit|throttl|too many (login |authentication |failed )?(attempts|requests|logins)/i,
        line
      ) ->
        :rate_limited

      Regex.match?(
        ~r/\[AUTHENTICATIONFAILED\]|invalid credentials|authentication failed|incorrect password|invalid password|login failed/i,
        line
      ) ->
        :invalid_credentials

      Regex.match?(~r/temporar|try again|\[UNAVAILABLE\]|system problem/i, line) ->
        :temporary

      true ->
        :other
    end
  end
end
