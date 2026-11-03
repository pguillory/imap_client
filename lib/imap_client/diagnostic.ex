defmodule IMAPClient.Diagnostic do
  # Internal to IMAPClient.
  @moduledoc false

  require Logger

  @doc """
  Runs the config's `:on_diagnostic` callback, if any, with `event` in the caller. A
  failing callback logs only a fixed warning and never changes the operation's result.
  """
  def emit(%{on_diagnostic: callback}, event) when is_function(callback, 1) do
    try do
      callback.(event)
    catch
      # The callback is application code; its failure must not change the result.
      _kind, _reason -> Logger.warning("IMAP diagnostic callback failed")
    end

    :ok
  end

  def emit(_config, _event) do
    :ok
  end
end
