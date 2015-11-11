Gitex [![Build Status](https://travis-ci.org/awetzel/gitex.svg)](https://travis-ci.org/awetzel/gitex)
=======

See API documentation at [http://hexdocs.pm/gitex](http://hexdocs.pm/gitex).

- Reference implementation in pure Elixir of the Git object model and storage,
  including optimized pack-refs and pack-objects/deltas).
- Protocol over Git codec and backend to customize them and reuse the same
  versioning logic in a completely different environment and use case: JSON
  into Riak for instance.

TODO:

- [x] test it (only for regression, currently it works on many open source git repo, so it can be considered as tested)
- [ ] add a `Gitex.merge` helper to help you construct a commit tree from multiple trees
- [x] add impl `Gitex.Repo` for Pid as a GenServer RPC
- [ ] implementation example of previous GenServer maintaining ETS LRU cache of standard git fs objects and deltas
- [ ] add some useful alternative implementations, currently only standard object encoding and storage

## Usage example


```elixir
r = Gitex.Git.open #Gitex.Git is the .git fs object storage
Gitex.get("master",r) #get commit
Gitex.get("myannotatedtag",r) #get tag object
Gitex.get("master",r,"/path/to/dir")  #get tree object
Gitex.get("master",r,"/path/to/file") #get blob

# get all commits from master to 1st January 2015
Gitex.history("master",r) 
|> Enum.take_while(& &1.committer.utc_time > {{2015,1,1},{0,0,0}})

# get the stream of version history of a given file
Gitex.history("master",r) 
|> Stream.map(&Gitex.get_hash(&1,r,"/path/to/file")) 
|> Stream.dedup
|> Stream.map(&Gitex.object(&1,r))

# commit history stream is powerful, play with it

Gitex.get("master",r) # return commit
|> Gitex.put(r,"/some/path/file1","file1 content") #put new trees and return new root tree hash
|> Gitex.put(r,"/some/other/path/file2","file2 content") ##put new trees and return new root tree hash
|> Gitex.commit(r,"master","some commit message") #save tree in a commit with "master" parent then update "master" and return commit hash 
|> Gitex.tag(r,"mytag") # save this commit to a soft tag return commit_tag
|> Gitex.tag(r,"myannotatedtag","my message") # save this commit to a tag object with comment, return tag hash

# Currently "put" is the only helper to construct a new "tree", for merging you have to construct the tree yourself
```

A nice function `Gitex.align_history` allows you to lazily add an index number to your
history stream in order to construct a pretty visualizer very easily (d3.js for instance)

```elixir
Gitex.history(:head,repo) |> Gitex.align_history
```

`Gitex.Server` provides a GenServer implementation (implementing `Gitex.Repo`for PIDs).
This implementation relies on an underlying `Gitex.Repo` that is provided at initialization:

```elixir
r = Gitex.Git.open                           # Create a standard (reference impl) Gitex.Repo
{:ok, repo_pid} = Gitex.Server.start_link(r) # Create a GenServer Gitex.Repo
Gitex.history("master", repo_pid)            # print history stream
|> Stream.each(&IO.puts "* #{String.slice(&1.hash, 0 ,7)} #{&1.message}")
|> Stream.run
```


## The Gitex.Repo protocol

Any repo implementing the `Gitex.Repo` protocol : (basically object codec, ref
setter/resolver, binary get/put) can be managed with the `Gitex` API.
