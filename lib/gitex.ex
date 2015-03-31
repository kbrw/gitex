defmodule Gitex do
  @type hash   :: {:hash,String.t}
  @type refpath:: {:refpath,String.t}
  @type tag    :: {:tag,String.t}
  @type branch :: {:branch,String.t}
  @type remote :: {:remote,remote::String.t,:head | branch::String.t}
  @type ref :: :head | tag | branch | remote

  @moduledoc """
    Git API to a repo which is a struct implementing Gitex.Repo
  """

  @doc "get the decoded GIT object associated with a given hash"
  def object(repo,hash), do:
    Gitex.Repo.decode(repo,hash,Gitex.Repo.get_obj(repo,hash))
     
  @doc """
    get the decoded GIT object from a fuzzy reference : can be
    either a `ref` or a binary which will be tested for
    each reference type in this order : branch,tag,remote
  """
  def get(repo,ref), do:
    object(repo,fuzzy_ref(repo,ref))

  @doc "from a reference, use a path to get the wanted object"
  def get(repo,%{}=obj,path) , do: 
    get_path(repo,obj,path)
  def get(repo,ref,path), do: 
    get_path(repo,get(repo,ref),path)

  @doc "lazily stream parents of a reference, sorted by date"
  def history(repo,ref) do
    Stream.resource(fn-> {object(repo,fuzzy_ref(repo,ref)),[]} end,fn
      :nomore->{:halt,nil}
      {current,others}->
        to_compare = Enum.concat(Enum.map(parent_list(current),&object(repo,&1)) ,others)
        nexts = to_compare |> Enum.uniq(& &1.hash) |> Enum.sort_by(& &1.committer.utc_time) |> Enum.reverse
        case nexts do
          [next|others]-> {[current],{next,others}}
          []-> {[current],:nomore}
        end
    end,fn _->:done end)
  end

  @doc """
  take a commit stream (from `history/2`) and lazily 
  add an index of the current branch to ease visualization and tree drawing
  """
  def align_history(history) do
    Stream.transform(history,{1,HashDict.new}, fn commit, {nextlevel,levels}=acc->
      level = Dict.get(levels,commit.hash,0)
      acc = case parent_list(commit) do
        [head|tail]->
          levels = Dict.update(levels,head,level,&min(&1,level))
          Enum.reduce(tail,{nextlevel,levels},fn h,{nextlevel,levels}->
            levels[h] && {nextlevel,levels} || {nextlevel+1,Dict.put(levels,h,nextlevel)}
          end)
        []->acc 
      end
      {[{level,commit}],acc}
    end)
  end

  defp parent_list(%{parent: parents}) when is_list(parents), do: Enum.reverse(parents)
  defp parent_list(%{parent: parent}), do: [parent]
  defp parent_list(_), do: []

  defp refpath(:head), do: "HEAD"
  defp refpath({:branch,ref}), do: "refs/heads/#{ref}"
  defp refpath({:tag,ref}), do: "refs/tags/#{ref}"
  defp refpath({:remote,remote,:head}), do: "refs/remotes/#{remote}/HEAD"
  defp refpath({:remote,remote,ref}), do: "refs/remotes/#{remote}/#{ref}"

  defp fuzzy_ref(repo,ref) when is_atom(ref) or is_tuple(ref), do:
    Gitex.Repo.resolve_ref(repo,refpath(ref))
  defp fuzzy_ref(repo,ref) when is_binary(ref) do
    Gitex.Repo.resolve_ref(repo,refpath({:branch,ref}))
    || Gitex.Repo.resolve_ref(repo,refpath({:tag,ref}))
    || case String.split(ref,"/") do
         [remote,ref]->Gitex.Repo.resolve_ref(repo,refpath({:remote,remote,ref}))
         [remote]->Gitex.Repo.resolve_ref(repo,refpath({:remote,remote,:head}))
       end
    || ref
  end

  defp get_path(repo,%{tree: tree},path), do: get_path(repo,object(repo,tree),path)
  defp get_path(repo,%{object: ref},path), do: get_path(repo,object(repo,ref),path)
  defp get_path(_repo,obj,"/"), do: obj
  defp get_path(repo,tree,path) when is_list(tree) do
    {name,subpath} = case String.split(String.strip(path,?/),"/", parts: 2) do
        [head,tail] -> {head,tail}
        [head] -> {head,nil}
    end
    if (elem=Enum.find(tree,& &1.name == name)) do
      obj = object(repo,elem.ref)
      if subpath, do: get_path(repo,obj,subpath), else: obj
    end
  end
  defp get_path(_,_,_), do: nil
end
