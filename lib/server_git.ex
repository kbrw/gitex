defmodule Gitex.Server do
  use GenServer

  @moduledoc """
    Implementation of `Gitex.Repo` protocol for PID (GenServer)

    The server will proxy Gitex.Repo calls to a Gitex.Repo implementation
    given at initialization.
  """

  def start_link(repo, opts \\ []) do
    GenServer.start_link(__MODULE__, repo, opts)
  end

  def init(repo), do: {:ok, repo}

  # Server impl
  def handle_call({:decode, hash, bintype}, _from, repo), do: {:reply, Gitex.Repo.decode(repo, hash, bintype), repo}
  def handle_call({:encode, obj}, _from, repo), do: {:reply, Gitex.Repo.encode(repo, obj), repo}
  def handle_call({:resolve_ref, ref}, _from, repo), do: {:reply, Gitex.Repo.resolve_ref(repo, ref), repo}
  def handle_call({:set_ref, ref, hash}, _from, repo), do: {:reply, Gitex.Repo.set_ref(repo, ref, hash), repo}
  def handle_call({:get_obj, hash}, _from, repo), do: {:reply, Gitex.Repo.get_obj(repo, hash), repo}
  def handle_call({:put_obj, bintype}, _from, repo), do: {:reply, Gitex.Repo.put_obj(repo, bintype), repo}
  def handle_call({:user}, _from, repo), do: {:reply, Gitex.Repo.user(repo), repo}

  def handle_call(request, from, state) do
    # Call the default implementation from GenServer
    super(request, from, state)
  end

  # Implementation of Gitex.Repo for PID: simply send the request to the server
  defimpl Gitex.Repo, for: PID do
    # Client API
    def decode(repo_pid, hash, bintype), do:  GenServer.call(repo_pid, {:decode, hash, bintype})
    def encode(repo_pid, obj), do:  GenServer.call(repo_pid, {:encode, obj})
    def resolve_ref(repo_pid, ref), do:  GenServer.call(repo_pid, {:resolve_ref, ref})
    def set_ref(repo_pid, ref, hash), do:  GenServer.call(repo_pid, {:set_ref, ref, hash})
    def get_obj(repo_pid, hash), do:  GenServer.call(repo_pid, {:get_obj, hash})
    def put_obj(repo_pid, bintype), do:  GenServer.call(repo_pid, {:put_obj, bintype})
    def user(repo_pid), do:  GenServer.call(repo_pid, {:user})
  end
end


