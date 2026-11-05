defmodule IMAPClient.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/pguillory/imap_client"

  def project do
    [
      app: :imap_client,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: [],
      description:
        "A hardened IMAP client with IDLE, XOAUTH2 and a wire-level fake IMAP server for tests.",
      package: [licenses: ["MIT"], links: %{"GitHub" => @source_url}],
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :ssl, :public_key, :crypto]]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end
end
