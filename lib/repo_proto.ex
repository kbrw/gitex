defprotocol Gitex.Repo do
  @type hash    :: String.t
  @type refpath :: String.t
  @type blob   :: binary
  @type tag    :: %{tag: String.t, object: hash}
  @type commit :: %{tree: hash,parent: hash | [hash]}
  @type tree   :: [%{name: String.t, ref: hash}]
  @type gitobj :: blob | tag | commit | tree
  @type type   :: :blob | :tag | :commit | :tree

  @spec decode(t,hash::hash,{type,binary}) :: gitobj
  def decode(repo,hash,bintype)

  @spec encode(t,gitobj) :: binary
  def encode(repo,obj)

  @spec resolve_ref(t,refpath) :: hash
  def resolve_ref(repo,ref)

  @spec get_obj(t,hash) :: binary
  def get_obj(repo,hash)
end
