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
  def object(nil,_repo), do: nil
  def object(hash,repo), do:
    Gitex.Repo.decode(repo,hash,Gitex.Repo.get_obj(repo,hash))

  @doc "save the GIT object and return the created hash"
  def save_object(elem,repo) do
    bin = Gitex.Repo.encode(elem)
    hash = :crypto.hash(:sha,bin) |> Base.encode16(case: :lower)
    Gitex.Repo.put_obj(repo,hash,bin)
    hash
  end
     
  @doc """
    get the decoded GIT object from a fuzzy reference : can be
    either a `ref` or a binary which will be tested for
    each reference type in this order : branch,tag,remote
  """
  def get(ref,repo), do: object(get_hash(ref,repo),repo)
  def get(ref,repo,path), do: object(get_hash(ref,repo,path),repo)

  def get_hash(ref,repo), do: fuzzy_ref(ref,repo)

  @doc "from a reference, use a path to get the wanted object"
  def get_hash(%{tree: tree},repo,path), do: get_hash(tree,object(tree,repo),repo,path)
  def get_hash(%{object: ref},repo,path), do: get_hash(object(ref,repo),repo,path)
  def get_hash(tree,repo,path) when is_list(tree), do: get_hash(nil,tree,repo,path)
  def get_hash(ref,repo,path), do: get_hash(get(ref,repo),repo,path)

  def get_hash(hash,tree,repo,path), do: 
    get_hash_path(hash,tree,repo,path |> String.strip(?/) |>  String.split("/"))
   
  @doc "from a reference, use a path to put the wanted element"
  def put(%{tree: tree},repo,path,elem), do: put(repo,object(tree,repo),path,elem)
  def put(%{object: ref},repo,path,elem), do: put(repo,object(ref,repo),path,elem)
  def put(tree,repo,path,elem) when is_list(tree), do: 
    put_path(tree,repo,path |> String.strip(?/) |>  String.split("/"),elem)
  def put(ref,repo,path,elem), do: 
    put(get(ref,repo),repo,path,elem)

  def commit(tree_hash,repo,message,params), do:
    save_object(params |> Enum.into(%{tree: tree_hash, message: message}),repo)

  def tag(commit_hash,repo,tag) when is_binary(tag), do:
    (Gitex.Repo.put_ref(repo,refpath({:tag,tag}),commit_hash); commit_hash)
  def tag(commit_hash,repo,tag,message,params \\ []), do:
    tag(save_object(params |> Enum.into(%{object: commit_hash,message: message}),repo),repo,tag)

  def branch(commit_hash,repo,branch), do:
    (Gitex.Repo.put_ref(repo,refpath({:branch,branch}),commit_hash); commit_hash)

  @doc "lazily stream parents of a reference, sorted by date"
  def history(repo,ref) do
    Stream.resource(fn-> {object(fuzzy_ref(ref,repo),repo),[]} end,fn
      :nomore->{:halt,nil}
      {current,others}->
        to_compare = Enum.concat(Enum.map(parent_list(current),&object(&1,repo)) ,others)
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

  defp fuzzy_ref(ref,repo) when is_atom(ref) or is_tuple(ref), do:
    Gitex.Repo.resolve_ref(repo,refpath(ref))
  defp fuzzy_ref(ref,repo) when is_binary(ref) do
    Gitex.Repo.resolve_ref(repo,refpath({:branch,ref}))
    || Gitex.Repo.resolve_ref(repo,refpath({:tag,ref}))
    || case String.split(ref,"/") do
         [remote,ref]->Gitex.Repo.resolve_ref(repo,refpath({:remote,remote,ref}))
         [remote]->Gitex.Repo.resolve_ref(repo,refpath({:remote,remote,:head}))
       end
    || ref
  end

  defp get_hash_path(hash,_tree,_repo,[]), do: hash
  defp get_hash_path(hash,_tree,_repo,[""]), do: hash
  defp get_hash_path(nil,_tree,_repo,[]), do: nil 
  defp get_hash_path(_hash,tree,repo,[name|subpath]) when is_list(tree) do
    if (elem=Enum.find(tree,& &1.name == name)), do:
      get_hash_path(elem.ref,object(elem.ref,repo),repo,subpath)
  end
  defp get_hash_path(_,_,_,_), do: nil 

  defp put_path(elem,repo,_,[]), do: save_object(elem,repo)
  defp put_path(elem,repo,tree,[name|path]) do
    childtree = if (e=Enum.find(tree,& &1.name==name and &1.type==:dir)), do: object(e.ref,repo), else: []
    ref = put_path(repo,childtree,path,elem)
    {type,mode} = case elem do o when is_list(o)->{:dir,"40000"}; _->{:file,"00777"} end
    save_object([%{name: name, mode: mode, type: type, ref: ref}|Enum.reject(tree, & &1.name == name)],repo)
  end
end
