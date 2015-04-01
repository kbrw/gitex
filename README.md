Gitex
=======

- Reference implementation in pure Elixir of the Git object model and storage,
  including optimized pack-refs and pack-objects/deltas).
- Protocol over Git codec and backend to customize them and reuse the same
  versioning logic in a completely different environment and use case: JSON
  into Riak for instance.

TODO:

- test it (only for regression, currently it works on many open source git repo, so it can be considered as tested)
- add impl `Gitex.Repo` for Pid as a GenServer RPC
- implementation example of previous GenServer maintaining ETS LRU cache of standard git fs objects and deltas
- add some useful alternative implementations, currently only standard object encoding and storage

## Usage

- `Gitex.get_hash` allows you to look for an object and return its hash
- `Gitex.object` to retrieve a git object from its hash
- `Gitex.get` is `Gitex.get_hash |> Gitex.object`

- `Gitex.history` gives you a lazy stream to go through the commit history graph from a reference by date

- `Gitex.save_object` to save a git object
- `Gitex.put` to put a blob/tree at a given path: save the new trees and return the root tree hash
- `Gitex.commit`, given a tree hash and parent branches : save a new commit and update corresponding branches refs.
- `Gitex.tag`, given an object hash, and a name, create a tag referencing this hash

```elixir
repo = Gitex.Git.open #Gitex.Git is the .git fs object storage
Gitex.get("master",repo) #get commit
Gitex.get("myannotatedtag",repo) #get tag object
Gitex.get("master",repo,"/path/to/dir")  #get tree object
Gitex.get("master",repo,"/path/to/file") #get blob

# get all commits from master to 1st January 2015
Gitex.history(repo,"master") 
|> Enum.take_while(& &1.committer.utc_time > {{2015,1,1},{0,0,0}})

# get the stream of version history of a given file
Gitex.history(repo,"master") 
|> Stream.map(&Gitex.get_hash(&1,repo,"/path/to/file")) 
|> Stream.uniq 
|> Stream.map(&Gitex.object(&1,repo))

# commit history stream is powerful, play with it

Gitex.get("master",repo) # return commit
|> Gitex.put(r,"/some/path/file1","file1 content") #return new tree hash
|> Gitex.put(r,"/some/other/path/file2","file2 content") #return new tree hash
|> Gitex.commit(r,"master","some commit message") #return commit hash
```

A nice function `Gitex.align_history` allows you to lazily add an index number to your
history stream in order to construct a pretty visualizer very easily (d3.js for instance)

```elixir
Gitex.history(repo,:head) |> Gitex.align_history
```

## The Gitex.Repo protocol

Any repo implementing the `Gitex.Repo` protocol : (basically object codec, ref
setter/resolver, binary get/put) can be managed with the `Gitex` API.
