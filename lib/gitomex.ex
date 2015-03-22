
defprotocol Git.Backend do
  @type hash    :: String.t
  @type refpath :: String.t

  @spec resolve_ref(Git.Backend.t,refpath) :: hash
  def resolve_ref(repo,ref)

  @spec get_obj(Git.Backend.t,hash) :: binary
  def get_obj(repo,hash)
end

defprotocol Git.Codec do
  @type blob   :: binary
  @type tag    :: %{tag: String.t, object: Git.Backend.hash}
  @type commit :: %{tree: Git.Backend.hash,parent: Git.Backend.hash | [Git.Backend.hash]}
  @type tree   :: [%{name: String.t, ref: Git.Backend.hash}]
  @type gitobj :: blob | tag | commit | tree
  @type type   :: :blob | :tag | :commit | :tree

  @spec decode(Git.Backend.t,hash::Git.Backend.hash,{type,binary}) :: gitobj
  def decode(repo,hash,bintype)

  @spec encode(Git.Backend.t,gitobj) :: binary
  def encode(repo,obj)
end

defmodule Git do
  @moduledoc """
    Git API to a repo which is a struct implementing Git.Codec and Git.Backend
  """

  @doc "get the decoded GIT object associated with a given hash"
  def object(repo,hash), do:
    Git.Codec.decode(repo,hash,Git.Backend.get_obj(repo,hash))
     
  @type hash   :: {:hash,String.t}
  @type refpath:: {:refpath,String.t}
  @type tag    :: {:tag,String.t}
  @type branch :: {:branch,String.t}
  @type remote :: {:remote,remote::String.t,:head | branch::String.t}
  @type ref :: :head | tag | branch | remote
  @doc """
    get the decoded GIT object from a fuzzy reference : can be
    either a `ref` or a binary which will be tested for
    each reference type in this order : branch,tag,remote
  """
  def get(repo,ref), do:
    object(repo,fuzzy_ref(repo,ref))

  def get(repo,%{}=obj,path) , do: 
    get_path(repo,obj,path)
  def get(repo,ref,path), do: 
    get_path(repo,get(repo,ref),path)

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
  def align(history) do
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
    Git.Backend.resolve_ref(repo,refpath(ref))
  defp fuzzy_ref(repo,ref) when is_binary(ref) do
    Git.Backend.resolve_ref(repo,refpath({:branch,ref}))
    || Git.Backend.resolve_ref(repo,refpath({:tag,ref}))
    || case String.split(ref,"/") do
         [remote,ref]->Git.Backend.resolve_ref(repo,refpath({:remote,remote,ref}))
         [remote]->Git.Backend.resolve_ref(repo,refpath({:remote,remote,:head}))
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

defmodule Git.RefImpl do
  defstruct home_dir: ".git"

  @moduledoc """
    reference implementation of `Git.Codec` and `Git.Backend`
    for the standard git object storage on disk
  """

  @doc "Standard GIT repo : recursively find .git directory"
  def new, do: new(System.cwd!)
  def new("/"), do: nil
  def new(path) do
    gitdir = "#{path}/.git"
    if File.exists?(gitdir), 
      do: %Git.RefImpl{home_dir: gitdir}, 
      else: new(Path.dirname(path))
  end

  defimpl Git.Codec, for: Git.RefImpl do
    def parse_obj(bin,hash) do
      [metadatas,message] = String.split(bin,"\n\n",parts: 2)
      String.split(metadatas,"\n") |> Enum.map(fn metadata->
        [k,v] = String.split(metadata," ", parts: 2)
        {:"#{k}",parse_meta(:"#{k}",v)}
      end) 
      |> Enum.reduce(%{},fn {k,v},map->
        Dict.update(map,k,v,& is_list(&1) && [v|&1] || [v,&1])
      end)
      |> Dict.put(:message,message)
      |> Dict.put(:hash,hash)
    end

    @gregorian1970 :calendar.datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}})
    def parse_meta(k,v) when k in [:committer,:author,:tagger] do
      todate=&:calendar.gregorian_seconds_to_datetime/1; toi=&String.to_integer/1
      [_,name,email,ts,tz_sign,tz_h,tz_min] = Regex.run(~r"(.*) <([^><]*)> ([0-9]*) ([+-])([0-9]{2})([0-9]{2})$",v)
      utc_time = toi.(ts) + @gregorian1970
      local_time = utc_time + toi.("#{tz_sign}1")*(3600*toi.(tz_h) + 60*toi.(tz_min))
      %{name: name,email: email,local_time: todate.(local_time), utc_time: todate.(utc_time)}
    end
    def parse_meta(_,v), do: v
  
    def parse_tree(""), do: []
    def parse_tree(bin) do
      [modename,<<ref::binary-size(20)>> <> rest] = String.split(bin,<<0>>,parts: 2)
      [modetype,name] = String.split(modename," ")
      {type,mode} = case modetype do "1"<>r->{:file,r} ; m->{:dir,m} end
      ref = Base.encode16(ref,case: :lower)
      [%{name: name,mode: mode, type: type, ref: ref}|parse_tree(rest)]
    end
  
    def decode(_repo,hash,{type,bin}) when type in [:commit,:tag], do: parse_obj(bin,hash)
    def decode(_repo,_hash,{:tree,bin}), do: parse_tree(bin)
    def decode(_repo,_hash,{:blob,bin}), do: bin
  end
  
  defimpl Git.Backend, for: Git.RefImpl do
    import Bitwise
    def read(repo,path), do: File.read("#{repo.home_dir}/#{path}")
    def read!(repo,path), do: File.read!("#{repo.home_dir}/#{path}")

    def get_obj(repo,<<first::binary-size(2)>> <> rest=hash) do
      IO.puts("get obj #{hash}")
      case read(repo,"objects/#{first}/#{rest}") do
        {:ok,v}->[header,content] = v |> :zlib.uncompress |> String.split(<<0>>,parts: 2)
          [type,_] = String.split(header," ",parts: 2)
          {:"#{type}",content}
        {:error,:enoent}-> 
          (delta_offset=packed_offset(repo,hash)) && packed_read(repo,delta_offset)
      end
    end
  
    def resolve_ref(repo,"HEAD"), do: 
      raw_ref(repo,read!(repo,"HEAD") |> String.rstrip(?\n))
    def resolve_ref(repo,refpath), do:
      (nilify(read(repo,refpath)) || packed_resolve_ref(nilify(read(repo,"packed-refs")),refpath))

    defp raw_ref(repo,"ref: "<>ref), do: nilify(read(repo,ref))
    defp raw_ref(_,ref), do: ref

    defp nilify({:ok,v}), do: String.rstrip(v,?\n)
    defp nilify({:error,:enoent}), do: nil

    def packed_resolve_ref(nil,_), do: nil
    def packed_resolve_ref(pack,refpath) do # to do: binary search
      String.split(pack,"\n") |> Enum.find_value(fn
        "#"<>_->nil
        line-> case String.split(line," ") do
          [hash,^refpath]->hash
          _-> nil
        end
      end)
    end

    def packed_offset(repo,hash) do
      Enum.find_value(Path.wildcard("#{repo.home_dir}/objects/pack/pack-*.idx"), fn idx_path->
        idx = File.read!(idx_path)
        <<first,_::binary>> = hash = hash |> String.upcase |> Base.decode16!
        <<255,"tOc",2::size(32),fanout::binary-size(1024)>> <> rest = idx
        lo = (first==0) && 0 || hashtable_get(fanout,first-1,4)
        hi = hashtable_get(fanout,first,4)
        case :binary.match(rest,hash,[scope: {lo*20,(hi+1-lo)*20}]) do
          :nomatch->nil
          {hash_byte_pos,_}-> hash_pos=div(hash_byte_pos,20)
            nb_hash = hashtable_get(fanout,255,4)
            offsets_offset= nb_hash*(20+4); offsets_size= nb_hash*4
            <<_::binary-size(offsets_offset),offsets::binary-size(offsets_size)>> <> large_offsets =  rest
            offset = case <<hashtable_get(offsets,hash_pos,4)::size(32)>> do
              <<0::size(1),offset::size(31)>>-> offset
              <<1::size(1),offset_index::size(31)>>->
                hashtable_get(large_offsets,offset_index,8)
            end
            IO.puts("offset for #{Base.encode16 hash}: #{offset}")
            {"#{String.slice(idx_path,0..-5)}.pack",offset}
        end
      end)
    end
    defp hashtable_get(fanout,idx,size), do:
      (<<elem::unit(8)-size(size)>> = binary_part(fanout,size*idx,size); elem)

    @types {nil,:commit,:tree,:blob,:tag,nil,:ofs_delta,:ref_delta}
    def packed_read(repo,{pack_file,offset}) when is_binary(pack_file) do
      fd = File.open!(pack_file,[:raw])
      res = packed_read(repo,{fd,offset})
      File.close(fd); res
    end
    def packed_read(repo,{pack,offset}) do
      {:ok,^offset} = :file.position(pack,offset)
      {:halted,{type,len,_}} = Enumerable.reduce(IO.binstream(pack,1),{:cont,:first},fn 
        <<msb::size(1),type::size(3),size0::size(4)>>,:first->
          {msb==0 && :halt || :cont,{type,size0,4}}
        <<msb::size(1),size::size(7)>>,{type,acc,shift}->
          {msb==0 && :halt || :cont,{type,acc+(size<<<shift),shift+7}}
      end)
      IO.puts("len : #{len}")
      case elem(@types,type) do
        :ofs_delta-> {:halted,{delta_offset,offlen}} = Enumerable.reduce(IO.binstream(pack,1),{:cont,:first},fn 
            <<msb::size(1),size::size(7)>>,:first-> {msb==0 && :halt || :cont,{size,7}}
            <<msb::size(1),size::size(7)>>,{acc,offlen}->{msb==0 && :halt || :cont,{(acc<<<7)+size,offlen+7}}
          end)
          IO.puts("ofs_delta")
          #<<delta_offset::size(offlen)>> = off_bs
          delta_offset=delta_offset + Enum.reduce(0..div(offlen,7)-1,-1,& &2 + (1<<<(&1*7)))
          delta = :zlib.uncompress(IO.binread(pack,:all))#len))
          packed_apply_delta(packed_read(repo,{pack,offset-delta_offset}),delta)
        :ref_delta-> 
          IO.puts("ref_delta")
          <<hash::binary-size(20)>> <> content = to_string(IO.binread(pack,:all))#len+20))
          delta = content
          packed_apply_delta(get_obj(repo,Base.encode16(hash,case: :lower)),delta)
        type-> 
          {type,:zlib.uncompress(IO.binread(pack,len))}
      end
    end

    def packed_apply_delta({type,base},delta) do
      {_base_len,delta} = parse_delta_obj_len(delta,0,0)
      {res_len,delta} = parse_delta_obj_len(delta,0,0)
      {type,apply_delta_hunks([],base,delta,res_len,0)}
    end

    defp parse_delta_obj_len(<<msb::size(1),val::little-size(7)>> <> rest,base_counter,res_acc) do
      res_acc = res_acc + (val <<< (base_counter*7))
      if msb==0, do: {res_acc,rest}, else: parse_delta_obj_len(rest,base_counter+1,res_acc)
    end

    defp apply_delta_hunks(acc,_,_,res_size,acc_size) when acc_size >= res_size, do: IO.iodata_to_binary(acc)
    defp apply_delta_hunks(acc,base,<<0::size(1),add_len::size(7),add::binary-size(add_len)>> <> delta,res_size,acc_size), do:
      apply_delta_hunks([acc,add],base,delta,res_size,acc_size+add_len)
    defp apply_delta_hunks(acc,base,<<1::size(1),len_shift::bitstring-size(3),off_shift::bitstring-size(4)>> <> delta,res_size,acc_size) do
      off_ops = 3..0 |> Enum.map(& &1*8) |> Enum.zip(for(<<x::size(1)<-off_shift>>,do: x)) |> Enum.filter_map(& elem(&1,1)==1,& elem(&1,0))
      len_ops = 2..0 |> Enum.map(& &1*8) |> Enum.zip(for(<<x::size(1)<-len_shift>>,do: x)) |> Enum.filter_map(& elem(&1,1)==1,& elem(&1,0))
      {off,delta}=Enum.reduce(off_ops,{0,delta},fn shift,{off,<<byte>><>delta}-> {off ||| (byte<<<shift),delta} end)
      {len,delta}=Enum.reduce(len_ops,{0,delta},fn shift,{off,<<byte>><>delta}-> {off ||| (byte<<<shift),delta} end)
      len = (len==0) && 0x10000 || len
      IO.puts(inspect(acc))
      apply_delta_hunks([acc,binary_part(base,off,len)],base,delta,res_size,acc_size+len)
    end
  end
end

Git.history(Git.RefImpl.new,"master") 
|> Enum.at(2)
#|> Enum.map(&"#{&1.hash}: #{&1.message}")
#Git.history(Git.RefImpl.new,"master") |> Git.align
#|> Enum.map(fn {level,c}->"#{level}: #{c.hash}: #{c.message}" end)
#Git.history(repo,"master") 
