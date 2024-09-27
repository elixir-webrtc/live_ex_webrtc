defmodule LiveExWebrtc.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_ex_webrtc,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, "~> 0.20.17"},
      {:jason, "~> 1.0"},
      {:ex_webrtc, "~> 0.5.0"}
    ]
  end
end
