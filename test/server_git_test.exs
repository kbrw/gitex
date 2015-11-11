defmodule ServerGitTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  setup do
    repo = create_standard_git_repo
    on_exit(fn->clean_standard_git_repo(repo) end)
    {:ok, repo_pid} = Gitex.Server.start_link(repo)
    {:ok, repo: repo_pid}
  end

  test "create a branch", %{repo: repo} do
    hash = Gitex.commit([], repo, "branch1", "first commit")
    assert %{hash: ^hash} = Gitex.get("branch1", repo)
  end

  test "create a tag", %{repo: repo} do
    hash = Gitex.commit([], repo,"master", "first commit") |> Gitex.tag(repo, "tag1")
    assert %{hash: ^hash} = Gitex.get("tag1", repo)
  end

  test "branch history", %{repo: repo} do
    tree1 = Gitex.put([], repo, "/path1/file1", "file1 content") 
    |> Gitex.put(repo, "/path1/subpath1/file2", "file2 content")
    hash1 = Gitex.commit(tree1, repo, "master", "first commit")

    _some_other_hash = Gitex.put(hash1, repo, "/path1/file1", "file1 content2") 
    |> Gitex.put(repo, "/path2/subpath1/file2", "file3 content")
    |> Gitex.commit(repo, "branch1", "other commit")

    tree2 = Gitex.put(hash1, repo, "/path1/file1", "file1 content3") 
    |> Gitex.put(repo, "/path2/subpath1/file2", "file3 content")
    hash2 = Gitex.commit(tree2, repo, "master", "second commit")
    history = Gitex.history("master", repo)

    assert [
      %{hash: ^hash2, tree: ^tree2, parent: ^hash1},
      %{hash: ^hash1, tree: ^tree1}
    ] = Enum.to_list(history)
  end

  test "stream of version history for a given file", %{repo: repo} do
    tree1 = Gitex.put([], repo, "/path1/file1", "file1 content") 
    |> Gitex.put(repo, "/path1/subpath1/file2", "file2 content")
    hash1 = Gitex.commit(tree1, repo, "master", "first commit")

    _some_other_hash = Gitex.put(hash1, repo, "/path1/file1", "file1 content2") 
    |> Gitex.put(repo, "/path2/subpath1/file2", "file3 content")
    |> Gitex.commit(repo, "branch1", "other commit")

    tree2 = Gitex.put(hash1, repo, "/path1/file1", "file1 content3") 
    |> Gitex.put(repo, "/path2/subpath1/file2", "file3 content")
    Gitex.commit(tree2, repo,"master", "second commit")

    file1_version_history = Gitex.history("master", repo)
    |> Stream.map(&Gitex.get_hash(&1, repo, "/path1/file1")) 
    |> Stream.dedup
    |> Stream.map(&Gitex.object(&1, repo))

    assert ["file1 content3", "file1 content"] = Enum.to_list(file1_version_history)
  end

  test "simple get tree object", %{repo: repo} do
    Gitex.put([], repo,"/path1/file1","file1 content") 
    |> Gitex.put(repo,"/path1/subpath1/file2","file2 content")
    |> Gitex.commit(repo,"master","first commit")

    assert [
        %{name: "file1", type: :file, mode: "00777"},
        %{name: "subpath1", type: :dir, mode: "40000"}
      ] = Gitex.get("master", repo, "/path1")
  end

  test "get tree with several commits", %{repo: repo} do
    tree_hash1 = Gitex.put([], repo, "/file1", "file1 content") 
    |> Gitex.put(repo, "/file2", "file2 content") 
    |> Gitex.put(repo, "/path1/file3", "file3 content")
    |> Gitex.put(repo, "/path2/file4", "file4 content")
    |> Gitex.commit(repo, "master", "first commit")

    Gitex.put(tree_hash1, repo,"/file1","file1 content2") 
    |> Gitex.put(repo,"/path1/file5","file5 content")
    |> Gitex.put(repo,"/file6","file6 content") 
    |> Gitex.put(repo,"/path3/file7","file5 content")
    |> Gitex.commit(repo,"master","second commit")

    assert [
        %{name: "file1", type: :file, mode: "00777"},
        %{name: "file2", type: :file, mode: "00777"},
        %{name: "file6", type: :file, mode: "00777"},
        %{name: "path1", type: :dir,  mode: "40000"},
        %{name: "path2", type: :dir,  mode: "40000"},
        %{name: "path3", type: :dir,  mode: "40000"}
      ] = Gitex.get("master", repo, "/")
  end

  test "remove a file from tree", %{repo: repo} do
    tree_hash1 = Gitex.put([], repo, "/file1", "file1 content") 
    |> Gitex.put(repo, "/path1/file2", "file2 content")
    |> Gitex.put(repo, "/path1/file3", "file2 content")
    |> Gitex.commit(repo, "master", "first commit")

    # prepare a tree for path1 containing a single file
    subtree_hash2 = Gitex.put([], repo, "/file2", "file2 content2") 

    # commit modified subtree
    Gitex.put(tree_hash1, repo,"path1", Gitex.object(subtree_hash2, repo)) 
    |> Gitex.commit(repo, "master", "second commit")

    # check the root tree
    assert [
        %{name: "file1", type: :file, mode: "00777"},
        %{name: "path1", type: :dir,  mode: "40000"},
      ] = Gitex.get("master", repo, "/")

    # path1 should contain a single file
    assert [
        %{name: "file2", type: :file, mode: "00777"},
      ] = Gitex.get("master", repo, "/path1")
  end

  test "print history", %{repo: repo} do
    tree_hash1 = Gitex.put([], repo, "/file1", "file1 content") 
    |> Gitex.put(repo, "/path1/file2", "file2 content")
    |> Gitex.put(repo, "/path1/file3", "file2 content")
    |> Gitex.commit(repo, "master", "first commit")

    # prepare a tree for path1 containing a single file
    subtree_hash2 = Gitex.put([], repo, "/file2", "file2 content2") 

    # commit modified subtree
    tree_hash2 = Gitex.put(tree_hash1, repo,"path1", Gitex.object(subtree_hash2, repo)) 
    |> Gitex.commit(repo, "master", "second commit")

    fun = fn ->
      # print history of the master branch
      Gitex.history("master", repo)
      |> Stream.each(&IO.puts "* #{String.slice(&1.hash, 0, 7)}: #{&1.message}")
      |> Stream.run
    end

    assert capture_io(fun) == """
    * #{String.slice(tree_hash2, 0, 7)}: second commit
    * #{String.slice(tree_hash1, 0, 7)}: first commit
    """ 
  end

  defp gen_tmp_repo_name, do: "repo_#{:os.system_time(:nano_seconds)}" 

  defp create_standard_git_repo do
    repo_path = Path.join(System.tmp_dir!, gen_tmp_repo_name)
    :ok = File.mkdir(repo_path)
    Gitex.Git.init(repo_path)
  end

  defp clean_standard_git_repo(%{home_dir: repo_dir}), do: File.rm_rf!(Path.dirname(repo_dir))

end
