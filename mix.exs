defmodule LiveExWebrtc.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/elixir-webrtc/live_ex_webrtc"

  def project do
    [
      app: :live_ex_webrtc,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Phoenix Live Components for Elixir WebRTC",
      package: package(),
      deps: deps(),

      # docs
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(mix.exs lib assets package.json README.md LICENSE)
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.0"},
      # {:ex_webrtc, "~> 0.8.0"},
      {:ex_webrtc, github: "elixir-webrtc/ex_webrtc", override: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      formatters: ["html"],
      nest_modules_by_prefix: [LiveExWebRTC]
    ]
  end
end
