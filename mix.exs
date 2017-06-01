defmodule Gitex.Mixfile do
  use Mix.Project

  def project do
    [app: :gitex,
     version: "0.2.0",
     elixir: "~> 1.0",
     docs: [
       readme: "README.md", main: "README",
       source_url: "https://github.com/awetzel/gitex",
       source_ref: "master"
     ],
     package: package(),
     description: description(),
     deps: [{:ex_doc, ">= 0.0.0", only: :dev}]]
  end

  def application do
    [applications: [:logger],
     env: [anonymous_user: %{name: "anonymous", email: "anonymous@localhost"}]]
  end

  defp package do
    [ maintainers: ["Arnaud Wetzel"],
      licenses: ["The MIT License (MIT)"],
      links: %{ "GitHub"=>"https://github.com/awetzel/gitex"} ]
  end

  defp description do
    """
    Elixir implementation of the Git object storage, but with the goal to implement the same semantic with other storage and topics
    """
  end
end
