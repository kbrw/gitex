defmodule Gitex.Git do
  defstruct home_dir: ".git", user: nil

  @moduledoc """
    reference implementation of `Gitex.Repo` protocol
    for the standard git object storage on disk
  """

  @doc "Standard GIT repo : recursively find .git directory"
  def open, do: open(System.cwd!)
  def open("/"), do: nil
  def open(path) do
    gitdir = "#{path}/.git"
    if File.exists?(gitdir), 
      do: %Gitex.Git{home_dir: gitdir}, 
      else: open(Path.dirname(path))
  end

  defimpl Gitex.Repo, for: Gitex.Git do
    import Bitwise

    def user(%{user: user}), do: user
  
    def decode(_repo,hash,{type,bin}) when type in [:commit,:tag], do: parse_obj(bin,hash)
    def decode(_repo,_hash,{:tree,bin}), do: parse_tree(bin)
    def decode(_repo,_hash,{:blob,bin}), do: bin

    def encode(_repo,tree) when is_list(tree), do: encode_tree(tree)
    def encode(_repo,blob) when is_binary(blob), do: blob
    def encode(_repo,%{}=obj), do: encode_obj(obj)

    def get_obj(repo,<<first::binary-size(2)>> <> rest=hash) do
      case read(repo,"objects/#{first}/#{rest}") do
        {:ok,v}->[header,content] = v |> :zlib.uncompress |> String.split(<<0>>,parts: 2)
          [type,_] = String.split(header," ",parts: 2)
          {:"#{type}",content}
        {:error,:enoent}-> 
          (delta_offset=packed_offset(repo,hash)) && packed_read(repo,delta_offset)
      end
    end

    def put_obj(repo,{type,bin}) do
      bin_to_hash = "#{type} #{byte_size(bin)}\0#{bin}"
      <<first::binary-size(2)>><>rest=hash = :crypto.hash(:sha,bin_to_hash) |> Base.encode16(case: :lower)
      dir = "#{repo.home_dir}/objects/#{first}"; path= "#{dir}/#{rest}"
      if !File.exists?(dir), do: File.mkdir_p!(dir)
      if !File.exists?(path), do: File.write!(path,:zlib.compress(bin_to_hash))
      hash
    end
  
    def resolve_ref(repo,"HEAD"), do: 
      raw_ref(repo,read!(repo,"HEAD") |> String.rstrip(?\n))
    def resolve_ref(repo,refpath), do:
      (nilify(read(repo,refpath)) || packed_resolve_ref(nilify(read(repo,"packed-refs")),refpath))

    def set_ref(repo,refpath,hash), do:
      File.write!("#{repo.home_dir}/#{refpath}","#{hash}\n")

    defp read(repo,path), do: File.read("#{repo.home_dir}/#{path}")
    defp read!(repo,path), do: File.read!("#{repo.home_dir}/#{path}")

    defp parse_obj(bin,hash) do
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

    @field_order %{tree: 0, parent: 1, author: 2, committer: 3, object: 4, type: 5, tag: 6, tagger: 7}
    defp encode_obj(%{message: message}=obj) do
      metas = Dict.drop(obj,[:message,:hash])
        |> Enum.sort_by(fn {k,_}->@field_order[k] end)
        |> Enum.map(fn {k,v}->encode_meta("#{k}",v) end)
      IO.iodata_to_binary([metas,?\n,message])
    end

    @gregorian1970 :calendar.datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}})
    defp parse_meta(k,v) when k in [:committer,:author,:tagger] do
      todate=&:calendar.gregorian_seconds_to_datetime/1; toi=&String.to_integer/1
      [_,name,email,ts,tz_sign,tz_h,tz_min] = Regex.run(~r"(.*) <([^><]*)> ([0-9]*) ([+-])([0-9]{2})([0-9]{2})$",v)
      utc_time = toi.(ts) + @gregorian1970
      local_time = utc_time + toi.("#{tz_sign}1")*(3600*toi.(tz_h) + 60*toi.(tz_min))
      %{name: name,email: email,local_time: todate.(local_time), utc_time: todate.(utc_time)}
    end
    defp parse_meta(:type,v), do: :"#{v}"
    defp parse_meta(_,v), do: v

    defp encode_meta(_k,[]), do: []
    defp encode_meta(k,[v|rest]), do: [encode_meta(k,v),encode_meta(k,rest)]
    defp encode_meta(k,%{name: name,email: email, local_time: local_time, utc_time: utc_time}) do
      utc = :calendar.datetime_to_gregorian_seconds(utc_time)
      offset = :calendar.datetime_to_gregorian_seconds(local_time)-utc
      {sign,{delta_h,delta_m,_}}={if(offset>0,do: ?+,else: ?-),:calendar.seconds_to_time(abs(offset))}
      [k,?\s,name,?\s,?<,email,?>,?\s,"#{utc-@gregorian1970}",?\s,sign,String.rjust("#{delta_h}",2,?0),String.rjust("#{delta_m}",2,?0),?\n]
    end
    defp encode_meta(k,v) when is_atom(v), do: encode_meta(k,"#{v}")
    defp encode_meta(k,v), do: [k,?\s,v,?\n]
  
    defp parse_tree(""), do: []
    defp parse_tree(bin) do
      [modename,<<ref::binary-size(20)>> <> rest] = String.split(bin,<<0>>,parts: 2)
      [modetype,name] = String.split(modename," ")
      {type,mode} = case modetype do "1"<>r->{:file,r} ; m->{:dir,m} end
      ref = Base.encode16(ref,case: :lower)
      [%{name: name,mode: mode, type: type, ref: ref}|parse_tree(rest)]
    end

    defp encode_tree(tree) do
      Enum.sort_by(tree,fn %{type: :dir,name: n}-> n<>"/"; %{name: n}->n end)
      |> Enum.map(fn %{type: type,ref: ref, mode: mode, name: name}->
        [if(type==:file, do: ?1, else: []),mode,?\s,name,0,Base.decode16!(ref,case: :lower)]
      end)
      |> IO.iodata_to_binary
    end

    defp raw_ref(repo,"ref: "<>ref), do: nilify(read(repo,ref))
    defp raw_ref(_,ref), do: ref

    defp nilify({:ok,v}), do: String.rstrip(v,?\n)
    defp nilify({:error,:enoent}), do: nil

    defp packed_resolve_ref(nil,_), do: nil
    defp packed_resolve_ref(pack,refpath) do # to do: binary search
      String.split(pack,"\n") |> Enum.find_value(fn
        "#"<>_->nil
        line-> case String.split(line," ") do
          [hash,^refpath]->hash
          _-> nil
        end
      end)
    end

    defp packed_offset(repo,hash) do
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
            {"#{String.slice(idx_path,0..-5)}.pack",offset}
        end
      end)
    end
    defp hashtable_get(fanout,idx,size), do:
      (<<elem::unit(8)-size(size)>> = binary_part(fanout,size*idx,size); elem)

    @types {nil,:commit,:tree,:blob,:tag,nil,:ofs_delta,:ref_delta}
    defp packed_read(repo,{pack_file,offset}) when is_binary(pack_file) do
      fd = File.open!(pack_file,[:raw, read_ahead: 500_000])
      <<"PACK",_version::size(32)>> = IO.binread(fd,8)
      res = packed_read(repo,{fd,offset})
      File.close(fd); res
    end
    defp packed_read(repo,{pack,offset}) do
      {:ok,^offset} = :file.position(pack,offset)
      {:halted,{type,_len,_}} = Enumerable.reduce(IO.binstream(pack,1),{:cont,:first},fn 
        <<msb::size(1),type::size(3),size0::size(4)>>,:first->
          {msb==0 && :halt || :cont,{type,size0,4}}
        <<msb::size(1),size::size(7)>>,{type,acc,shift}->
          {msb==0 && :halt || :cont,{type,acc+(size<<<shift),shift+7}}
      end)
      case elem(@types,type) do
        :ofs_delta-> {:halted,delta_offset} = Enumerable.reduce(IO.binstream(pack,1),{:cont,:first},fn 
            <<msb::size(1),size::size(7)>>,:first-> {msb==0 && :halt || :cont,size}
            <<msb::size(1),size::size(7)>>,acc->{msb==0 && :halt || :cont,((acc+1)<<<7)+size}
          end)
          delta = uncompress_stream(pack)
          packed_apply_delta(packed_read(repo,{pack,offset-delta_offset}),delta)
        :ref_delta-> 
          <<hash::binary-size(20)>> = to_string(IO.binread(pack,20))
          delta = uncompress_stream(pack)
          packed_apply_delta(get_obj(repo,Base.encode16(hash,case: :lower)),delta)
        type-> 
          {type,uncompress_stream(pack)}
      end
    end

    defp packed_apply_delta({type,base},delta) do
      {_base_len,delta} = parse_delta_obj_len(delta,0,0)
      {_res_len,delta} = parse_delta_obj_len(delta,0,0)
      {type,apply_delta_hunks([],base,delta)}
    end

    defp parse_delta_obj_len(<<msb::size(1),val::little-size(7)>> <> rest,base_counter,res_acc) do
      res_acc = res_acc + (val <<< (base_counter*7))
      if msb==0, do: {res_acc,rest}, else: parse_delta_obj_len(rest,base_counter+1,res_acc)
    end

    defp apply_delta_hunks(acc,_base,""), do: 
      IO.iodata_to_binary(acc)
    defp apply_delta_hunks(acc,base,<<0::size(1),add_len::size(7),add::binary-size(add_len)>> <> delta), do:
      apply_delta_hunks([acc,add],base,delta)
    defp apply_delta_hunks(acc,base,<<1::size(1),len_shift::bitstring-size(3),off_shift::bitstring-size(4)>> <> delta) do
      off_ops = Enum.zip([0,8,16,24],Enum.reverse(for(<<x::size(1)<-off_shift>>,do: x))) |> Enum.filter_map(& elem(&1,1)==1,& elem(&1,0))
      len_ops = Enum.zip([0,8,16],Enum.reverse(for(<<x::size(1)<-len_shift>>,do: x))) |> Enum.filter_map(& elem(&1,1)==1,& elem(&1,0))
      {off,delta}=Enum.reduce(off_ops,{0,delta},fn shift,{off,<<byte>><>delta}-> {off ||| (byte<<<shift),delta} end)
      {len,delta}=Enum.reduce(len_ops,{0,delta},fn shift,{off,<<byte>><>delta}-> {off ||| (byte<<<shift),delta} end)
      len = (len==0) && 0x10000 || len
      apply_delta_hunks([acc,binary_part(base,off,len)],base,delta)
    end

    defp uncompress_stream(fd) do
      z = :zlib.open; :zlib.inflateInit(z)
      res = Enum.take_while(Stream.repeatedly(fn->
        case IO.binread(fd,500) do :eof->[]; iodata->:zlib.inflate(z,iodata) end
      end),& &1 !== [])
      :zlib.inflateEnd(z) ; :zlib.close(z)
      IO.iodata_to_binary(res)
    end
  end
end
