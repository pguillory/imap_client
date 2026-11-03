defmodule IMAPClient.CallbackFailureTest do
  # Sync: these tests capture the log, which is global, to check the fixed warning a
  # failing application callback leaves.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import IMAPClient

  alias IMAPClient.FakeServer
  alias IMAPClient.SampleDecoder

  defp fake(message) do
    server = start_supervised!({FakeServer, mailboxes: %{"INBOX" => %{messages: [message]}}})
    {server, FakeServer.endpoint(server)}
  end

  test "a failing diagnostic callback cannot alter the fetch or leak its exception text" do
    {server, config} = fake(%{uid: 7})
    config = Map.put(config, :on_diagnostic, fn _ -> raise "private callback data" end)
    :ok = FakeServer.script_next(server, :fetch, {:omit, :metadata})

    log =
      capture_log(fn ->
        assert search(config, %{}) == {:ok, %{results: [], unreturned: 1}}
      end)

    assert log =~ "IMAP diagnostic callback failed"
    refute log =~ "private callback data"
  end

  test "a failing charset decoder leaves the text raw and logs no message bytes" do
    {_server, config} =
      fake(%{
        uid: 7,
        bodystructure: ~s|"TEXT" "PLAIN" ("CHARSET" "x-crash") NIL NIL "7BIT" 6 1|,
        sections: %{"1" => "secret"}
      })

    config = Map.put(config, :charset_decoder, SampleDecoder)

    log =
      capture_log(fn ->
        assert {:ok, %{email: %{text_body: %{charset: "x-crash", bytes: "secret"}}}} =
                 read(config, 7)
      end)

    assert log =~ "IMAP charset decoder failed"
    refute log =~ "secret"
  end
end
