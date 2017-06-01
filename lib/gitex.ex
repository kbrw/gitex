defmodule Gitex do
  @type tag    :: {:tag,String.t}
  @type branch :: {:branch,String.t}
  @type remote :: {:remote,remote::String.t,:head | branch::String.t}
  @type ref :: :head | tag | branch | remote

  @moduledoc """
    Git API to a repo which is a struct implementing `Gitex.Repo`
  """

  @doc "get the decoded GIT object associated with a given hash"
  @spec object(nil | Gitex.Repo.hash,Gitex.Repo.t) :: Gitex.Repo.gitobj
  def object(nil,_repo), do: nil
  def object(hash,repo), do:
    Gitex.Repo.decode(repo,hash,Gitex.Repo.get_obj(repo,hash))

  @doc "save the GIT object and return the created hash"
  @spec save_object(Gitex.Repo.gitobj,Gitex.Repo.t) :: Gitex.Repo.hash
  def save_object(elem,repo), do:
    Gitex.Repo.put_obj(repo,{typeof(elem),Gitex.Repo.encode(repo,elem)})
     
  @doc "basically `get_hash |> object`"
  def get(ref,repo), do: object(get_hash(ref,repo),repo)
  def get(ref,repo,path), do: object(get_hash(ref,repo,path),repo)

  @doc """
    Get the decoded GIT object hash from a fuzzy
    reference : can be either a `ref` or a binary which
    will be tested for each reference type in this order : branch,tag,remote
  """
  @spec get_hash((someref::binary) | Gitex.Repo.commit | Gitex.Repo.tag,Gitex.Repo.t) :: Gitex.Repo.hash
  def get_hash(%{hash: hash},_repo), do: hash
  def get_hash(ref,repo), do: fuzzy_ref(ref,repo)

  @doc "from a reference, use a path to get the wanted object : tree or blob"
  @spec get_hash((someref::binary) | Gitex.Repo.commit | Gitex.Repo.tag | Gitex.Repo.tree,Gitex.Repo.t) :: Gitex.Repo.hash
  def get_hash(%{tree: tree},repo,path), do: get_hash(tree,object(tree,repo),repo,path)
  def get_hash(%{object: ref},repo,path), do: get_hash(object(ref,repo),repo,path)
  def get_hash(tree,repo,path) when is_list(tree), do: get_hash(nil,tree,repo,path)
  def get_hash(ref,repo,path), do: get_hash(get(ref,repo),repo,path)

  def get_hash(hash,tree,repo,path), do: 
    get_hash_path(hash,tree,repo,path |> String.strip(?/) |>  String.split("/"))
   
  @doc """
  - from some reference or object, get a root tree to alter
  - save the missing or changed trees and blob from the root
  - return the new root tree hash
  """
  @spec put((someref::binary) | Gitex.Repo.commit | Gitex.Repo.tag | Gitex.Repo.tree,Gitex.Repo.t,path::binary,elem::Gitex.Repo.blob | Gitex.Repo.tree) :: Gitex.Repo.hash
  def put(%{tree: tree},repo,path,elem), do: put(object(tree,repo),repo,path,elem)
  def put(%{object: ref},repo,path,elem), do: put(object(ref,repo),repo,path,elem)
  def put(tree,repo,path,elem) when is_list(tree), do:
    ({:tree,ref}=put_path(tree,repo,path |> String.strip(?/) |>  String.split("/"),elem); ref)
  def put(ref,repo,path,elem), do: 
    put(get(ref,repo),repo,path,elem)

  @doc """
  save a new commit :

  - `tree_hash` is the tree which must be referenced by this commit, use "put" to construct it
  - `branches` hashes will be commit parents, and these branches specs will be updated after commit
  - committer and author are taken from `Gitex.Repo.user` or `Application.get_env(:gitex,:anonymous_user)` if `nil`
  """
  @spec commit(Gitex.Repo.hash,Gitex.Repo.t,[branch::binary]|branch::binary,binary) :: Gitex.Repo.hash
  def commit(tree_hash,repo,branches,message) when is_list(branches) do
    committer = author = user_now(repo)
    parents = Enum.map(branches,&Gitex.Repo.resolve_ref(repo,refpath({:branch,&1}))) |> Enum.filter(&!is_nil(&1))
    commit_hash = save_object(%{tree: tree_hash, message: message,parent: parents,committer: committer, author: author},repo)
    Enum.each(branches,&Gitex.Repo.set_ref(repo,refpath({:branch,&1}),commit_hash))
    commit_hash
  end
  def commit(tree_hash,repo,branch,message), do: commit(tree_hash,repo,[branch],message)

  @doc "create a new soft tag to reference an object"
  def tag(hash,repo,tag), do: (Gitex.Repo.set_ref(repo,refpath({:tag,tag}),hash); hash)
  @doc "create an annottated tag to reference an object"
  def tag(hash,repo,tag,message) do
    {type,_} = Gitex.Repo.get_obj(repo,hash)
    tag(save_object(%{tag: tag,type: type,object: hash,message: message,tagger: user_now(repo)},repo),repo,tag)
  end

  @doc "lazily stream parents of a reference commit, sorted by date"
  @spec history(someref::binary,Gitex.Repo.t) :: Stream.t
  def history(ref,repo) do
    Stream.resource(fn-> {object(fuzzy_ref(ref,repo),repo),[]} end,fn
      :nomore->{:halt,nil}
      {current,others}->
        to_compare = Enum.concat(Enum.map(parent_list(current),&object(&1,repo)) ,others)
        nexts = to_compare |> Enum.uniq_by(& &1.hash) |> Enum.sort_by(& &1.committer.utc_time) |> Enum.reverse
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
  @spec align_history(Stream.t(Gitex.Repo.commit)) :: Stream.t({integer,Gitex.Repo.commit})
  def align_history(history) do
    Stream.transform(history,{1,Map.new}, fn commit, {nextlevel,levels}=acc->
      level = Map.get(levels,commit.hash,0)
      acc = case parent_list(commit) do
        [head|tail]->
          levels = Map.update(levels,head,level,&min(&1,level))
          Enum.reduce(tail,{nextlevel,levels},fn h,{nextlevel,levels}->
            levels[h] && {nextlevel,levels} || {nextlevel+1,Map.put(levels,h,nextlevel)}
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

  defp put_path(_,repo,[],elem), do: {typeof(elem),save_object(elem,repo)}
  defp put_path(tree,repo,[name|path],elem) do
    childtree = if (e=Enum.find(tree,& &1.name==name and &1.type==:dir)), do: object(e.ref,repo), else: []
    {type,ref} = put_path(childtree,repo,path,elem)
    {type,mode} = if type==:tree do {:dir,"40000"} else {:file,"00777"} end
    {:tree,save_object([%{name: name, mode: mode, type: type, ref: ref}|Enum.reject(tree, & &1.name==name)],repo)}
  end

  defp user_now(repo) do
    now = :erlang.timestamp
    base = %{name: "anonymous", email: "anonymous@localhost",
             local_time: :calendar.now_to_local_time(now), utc_time: :calendar.now_to_universal_time(now)}
    Enum.into(Gitex.Repo.user(repo) || Application.get_env(:gitex,:anonymous_user,[]),base)
  end

  defp typeof(tree) when is_list(tree), do: :tree
  defp typeof(blob) when is_binary(blob), do: :blob
  defp typeof(%{tag: _}), do: :tag
  defp typeof(%{committer: _}), do: :commit
end
