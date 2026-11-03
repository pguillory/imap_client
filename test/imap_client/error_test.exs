defmodule IMAPClient.ErrorTest do
  use ExUnit.Case, async: true

  import IMAPClient.Error

  test "classifies authentication and connection limits with safe metadata" do
    error =
      refusal(
        :no,
        "A1 NO [AUTHENTICATIONFAILED] Invalid credentials private-secret",
        :authentication
      )

    assert error.code == :auth_rejected
    assert error.response_code == "AUTHENTICATIONFAILED"
    assert error.hint == :invalid_credentials
    refute Exception.message(error) =~ "private-secret"

    assert refusal(:no, "A1 NO [ALERT] Too many simultaneous connections", :authentication).code ==
             :connection_limit

    assert refusal(
             :bad,
             "A1 BAD [AUTHENTICATIONFAILED] Invalid credentials",
             :authentication
           ).code == :bad
  end

  test "allowlists response codes only at the start of tagged response text" do
    assert refusal(:no, "A1 NO [user-secret] other", :authentication).response_code ==
             "other"

    assert refusal(:no, "A1 NO text [ALERT]", :authentication).response_code == nil
    assert refusal(:no, "A1 NO [TRYCREATE] destination", :copy).code == :mailbox_no
    assert refusal(:no, "A1 NO rejected", :select).code == :mailbox_no
  end

  test "warns about ambiguous mutation failures without retrying" do
    for stage <- [:store, :copy, :move, :expunge, :append],
        code <- [:timeout, :closed, :protocol] do
      error = new(code, stage, timeout_ms: 40)
      assert error.outcome_unknown?
      assert Exception.message(error) =~ "server outcome is unknown"
    end

    refute new(:timeout, :search).outcome_unknown?
    refute new(:no, :append).outcome_unknown?
  end

  test "refusal hints keep categories and precedence without server prose" do
    for {status, text, hint} <- [
          {:no, "A1 NO [WEBALERT] Please sign in via your web browser", :web_login_required},
          {:no, "A1 NO [ALERT] Too many simultaneous connections", :too_many_connections},
          {:no, "A1 NO Application-specific password required", :app_password_required},
          {:no, "A1 NO Too many authentication attempts", :rate_limited},
          {:no, "A1 NO [UNAVAILABLE] Try again later", :temporary},
          {:bad, "A1 BAD [PARSE] Other failure", :other},
          {:no, "A1 NO Too many simultaneous connections; invalid credentials",
           :too_many_connections}
        ] do
      error = refusal(status, text, :authentication)
      assert error.hint == hint
      refute Exception.message(error) =~ text
    end
  end
end
