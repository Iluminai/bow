defmodule Bow do
  @moduledoc """
  Bow - the file uploader


  ## Global Configuration

      config :bow,
        storage: Bow.Storage.Local,             # storage adapter; Bow.Storage.Local or Bow.Storage.S3
        storage_prefix: "priv/static/uploads",  # storage directory prefix

        store_timeout:  30_000,                 # single version upload timeout
        exec_timeout:   15_000,                 # single command execution timeout
  """

  def storage,          do: Application.get_env(:bow, :storage, Bow.Storage.Local)
  def store_timeout,    do: Application.get_env(:bow, :store_timeout, 30_000)
  def version_timeout,  do: Application.get_env(:bow, :version_timeout, 60_000)

  @type t :: %__MODULE__{
            name:     String.t, # "cat.jpg",  "README"
            rootname: String.t, # "cat",      "README"
            ext:      String.t, # ".jpg",     ""
            path:     String.t | nil,
            scope:    any,
            uploader: atom
  }

  defstruct name:     "",
            rootname: "",
            ext:      nil,
            path:     nil,
            scope:    nil,
            uploader: nil

  @enforce_keys [:name, :rootname, :ext]

  defmodule Error do
    defexception message: ""
  end

  @doc """
  Process & store given file with its uploader
  """
  @spec store(t) :: {:ok, t} | {:error, any}
  def store(file) do
    uploader = file.uploader
    versions = uploader.versions(file)

    make(uploader, file, file, versions) |> combine_results
  end

  # def load({file, scope}) do
  #   file |> set_scope(scope) |> load
  # end

  @doc """
  Load given file
  """
  @spec load(t) :: {:ok, t} | {:error, any}
  def load(file) do
    with {:ok, path} <- load_file(file.uploader, file) do
      {:ok, %{file | path: path}}
    end
  end

  def regenerate(file) do
    file |> load |> store
  end

  defp make(up, f0, fx, versions) when is_list(versions) do
    versions
    |> Enum.map(&Task.async(fn -> make(up, f0, fx, &1) end))
    |> Enum.map(&Task.await(&1, version_timeout()))
    |> List.flatten
  end

  defp make(up, f0, fx, version) do
    fy = fx
      |> set_name(up.filename(f0, version))
      |> set_path(nil)

    case up.transform(fx, fy, version) do
      {:ok, fy, next_versions} ->
        res0 = Task.async(fn -> store_file(up, fy) end)
        res1 = make(up, f0, fy, next_versions)
        [{version, Task.await(res0, store_timeout())} | res1]

      {:ok, fy} ->
        [{version, store_file(up, fy)}]

      :ok ->
        [{version, {:ok, :no_store}}]

      {:error, reason} ->
        [{version, {:error, reason}}]
    end
  end

  defp store_file(uploader, file) do
    storage().store(
      file.path,
      uploader.store_dir(file),
      file.name,
      uploader.store_options(file)
    )
  end

  defp load_file(uploader, file) do
    storage().load(
      uploader.store_dir(file),
      file.name
    )
  end

  # defp get_file_path(uploader, file) do
  #   storage().load(
  #     uploader.store_dir(file),
  #     file.name
  #   )
  # end

  def url(_, nil, _, _), do: nil
  def url(_, {nil, _}, _, _), do: nil

  def url(uploader, {file, scope}, version, opts) do
    url(uploader, %{file | scope: scope}, version, opts)
  end

  def url(uploader, file, version, opts) do
    storage().url(
      uploader.store_dir(file),
      uploader.filename(file, version),
      opts
    )
  end

  # def new([{:path, path} | args]) do
  #   %__MODULE__{
  #
  #   }
  # end


  def new(args) do
    {name, path} = case {args[:name], args[:path]} do
      {nil, nil}    -> raise Error, message: "Missing :name or :path attributes when creating new Bow file"
      {nil, path}   -> {basename(path), path}
      {name, path}  -> {name, path}
    end

    args = Keyword.merge(args, [
      path:     path,
      name:     name,
      rootname: rootname(name),
      ext:      extname(name)
    ])

    struct!(__MODULE__, args)
  end

  defp basename(name), do: name |> Path.basename()
  defp rootname(name), do: name |> Path.rootname()
  defp extname(name), do: name |> Path.extname() |> String.downcase()

  def set_path(file, path), do: %{file | path: path}
  def set_name(file, name), do: %{file | name: name, rootname: Path.rootname(name), ext: extname(name)}
  def set_rootname(file, rootname), do: %{file | rootname: rootname, name: "#{rootname}#{file.ext}"}
  def set_ext(file, ext) when ext in ["", nil], do: %{file | ext: "", name: file.rootname}
  def set_ext(file, "." <> ext),                do: %{file | ext: ext, name: "#{file.rootname}#{ext}"}
  def set_ext(file, ext),                       do: %{file | ext: "." <> ext, name: "#{file.rootname}.#{ext}"}
  def set_scope(file, scope), do:  %{file | scope: scope}

  def combine_results(results) do
    error? = Enum.any? results, fn
      {_, {:error, _}} -> true
      _                -> false
    end

    status = if error?, do: :error, else: :ok

    {status, results}
  end

  defp extname(name), do: name |> Path.extname |> String.downcase

  ## REMOTE FILE URL
  #
  # defmodule Download do
  #   use Tesla
  #   plug Tesla.Middleware.FollowRedirects
  #   adapter :hackney
  # end
  #
  # def download_remote_file(url) do
  #   case Bow.Download.get(URI.encode(url)) do
  #     %{status: 200, body: body, headers: headers} ->
  #       content_type = headers["Content-Type"]
  #       base = url |> URI.parse |> Map.get(:path) |> Path.basename
  #       name = case MIME.extensions(content_type) do
  #         [ext | _] -> Path.rootname(base) <> "." <> ext
  #         _         -> base
  #       end
  #       path = Plug.Upload.random_file!("bow_download")
  #       File.write!(path, body)
  #       {:ok, %Plug.Upload{filename: name, path: path, content_type: content_type}}
  #
  #     env ->
  #       ex = %Tesla.Error{message: "Bow.Download error"}
  #       stacktrace = System.stacktrace()
  #       Sentry.capture_exception(ex, stacktrace: stacktrace, extra: %{
  #         env: inspect(env)
  #       })
  #       {:error, env}
  #   end
  # end

  def to_plug_upload(%{name: name, path: path, ext: ext}) do
    %Plug.Upload{filename: name, path: path, content_type: content_type(ext)}
  end

  defp content_type("." <> ext), do: MIME.type(ext)
  defp content_type(ext), do: MIME.type(ext)
end
