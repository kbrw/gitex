defmodule Gitex.Mixfile do
  use Mix.Project

  def project do
    [app: :gitex,
     version: "0.0.1",
     elixir: "~> 1.0",
     package: package,
     description: description,
     deps: []]
  end

  def application do
    [applications: [:logger]]
  end

  defp package do
    [ contributors: ["Arnaud Wetzel"],
      licenses: ["The MIT License (MIT)"],
      links: %{ "GitHub"=>"https://github.com/awetzel/gitex"} ]
  end

  defp description do
    """
    Elixir implementation of the Git object storage, but with the goal to implement the same semantic with other storage and topics
    """
  end
end
