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

  @spec set_ref(t,refpath,hash) :: :ok
  def set_ref(repo,ref,hash)

  @spec get_obj(t,hash) :: {type,binary}
  def get_obj(repo,hash)

  @spec put_obj(t,{type,binary}) :: hash
  def put_obj(repo,bintype)

  @spec user(t):: nil | %{name: binary,email: binary}
  def user(repo)
end
