Gitex
=======

- Reference implementation in pure Elixir of the Git object model and storage,
  including optimized pack-refs and pack-objects (the storage is optimal, not this implementation :-) ).
- Protocols over Git codec and backend to customize them and reuse the same
  versioning logic in a completely different environment and use case: JSON
  into Riak for instance.

TODO (DO NOT USE IT SERIOUSLY YET):

- test it
- add a cache logic with an ETS LRU cache 
- write commit implementation, currently read-only
- add some useful alternative implementations, currently only standard object
  encoding and storage

## Usage

The main API consists in 2 functions:

- `Gitex.get` allows you to get "something" on git with a high level logic :
  fuzzy reference and path to select dir or file.
- `Gitex.history` gives you a lazy stream to go through the commit history graph from
  a reference by date

```elixir
repo = Gitex.RefImpl.new
Gitex.get(repo,"master") #get commit
Gitex.get(repo,"myannotatedtag") #get tag object
Gitex.get(repo,"master","/path/to/dir")  #get tree object
Gitex.get(repo,"master","/path/to/file") #get blob

# get all commits from master to 1st January 2015
Gitex.history(repo,"master") |> Enum.take_while(& &1.committer.utc_time > {{2015,1,1},{0,0,0}})
```

The low level API is a function to get an object from a hash : `Gitex.object`

```elixir
Gitex.object("abbabef2512234112311923874")
```

A nice function `Gitex.align_history` allows you to lazily add an index number to your
history stream in order to construct a pretty visualizer very easily (d3.js for instance)

```elixir
Gitex.history(repo,:head) |> Gitex.align_history
```
