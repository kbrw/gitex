
defprotocol Gitex.Backend do
  @type hash    :: String.t
  @type refpath :: String.t

  @spec resolve_ref(Gitex.Backend.t,refpath) :: hash
  def resolve_ref(repo,ref)

  @spec get_obj(Gitex.Backend.t,hash) :: binary
  def get_obj(repo,hash)
end

defprotocol Gitex.Codec do
  @type blob   :: binary
  @type tag    :: %{tag: String.t, object: Gitex.Backend.hash}
  @type commit :: %{tree: Gitex.Backend.hash,parent: Gitex.Backend.hash | [Gitex.Backend.hash]}
  @type tree   :: [%{name: String.t, ref: Gitex.Backend.hash}]
  @type gitobj :: blob | tag | commit | tree
  @type type   :: :blob | :tag | :commit | :tree

  @spec decode(Gitex.Backend.t,hash::Gitex.Backend.hash,{type,binary}) :: gitobj
  def decode(repo,hash,bintype)

  @spec encode(Gitex.Backend.t,gitobj) :: binary
  def encode(repo,obj)
end
