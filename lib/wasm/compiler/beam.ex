defmodule WASM.Compiler.Beam do
  @moduledoc """
  A copy of `ElixirScript.Beam`.  Used for getting expanded AST info.

  This was taken from ElixirScript and editted very slightly for this project.
  All credit goes to them. Thanks to the author of the of code.  Please see:

    - [The ElixirScript project](https://github.com/elixirscript/elixirscript)
    - [The original `ElixirScript.Beam` code](https://github.com/elixirscript/elixirscript/blob/master/lib/elixir_script/beam.ex)
    - [The (MIT) license of the code](https://github.com/elixirscript/elixirscript/blob/master/LICENSE)
  """

  @doc """
  Takes a module and finds the expanded AST
  from the debug info inside the beam file.
  For protocols, this will return a list of
  all the protocol implementations
  """
  @spec debug_info(atom | bitstring) :: {:ok | :error, map | binary}
  def debug_info(module)

  # We get debug info from String and then replace
  # functions in it with equivalents in `WASM.Override`.
  # This is so that we don't include the unicode database
  # in our output
  def debug_info(String) do
    {:ok, info} = do_debug_info(String)
    {:ok, ex_string_info} = do_debug_info(WASM.Override.String)

    definitions = replace_definitions(info.definitions, ex_string_info.definitions)

    info = %{info | definitions: definitions}

    {:ok, info}
  end

  # Replace some modules with `WASM.Override` versions
  def debug_info(module) when module in [Agent, :erlang] do
    case do_debug_info(Module.concat(WASM.Override, module)) do
      {:ok, info} ->
        {:ok, Map.put(info, :module, module)}
      e ->
        e
    end
  end

  def debug_info(module) when is_atom(module) do
    do_debug_info(module)
  end

  def debug_info(beam) when is_bitstring(beam) do
    do_debug_info(beam)
  end

  defp do_debug_info(module, path \\ nil)

  defp do_debug_info(module, _) when is_atom(module) do
    case :code.get_object_code(module) do
      {_, beam, beam_path} ->
        do_debug_info(beam, beam_path)
      :error ->
        {:error, "Unknown module"}
    end
  end

  defp do_debug_info(beam, beam_path) do
    with  {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} <- :beam_lib.chunks(beam, [:debug_info]),
          {:ok, {^module, attribute_info}} = :beam_lib.chunks(beam, [:attributes]) do

          if Keyword.get(attribute_info[:attributes], :protocol) do
            get_protocol_implementations(module)
          else
            backend.debug_info(:elixir_v1, module, data, [])
            |> process_debug_info(beam_path)
          end
    else
      :error ->
        {:error, "Unknown module"}
      {:error, :beam_lib, {:unknown_chunk, "non_existing.beam", :debug_info}} ->
        {:error, "Unsupported version of Erlang"}
      {:error, :beam_lib, {:missing_chunk, _ , _}} ->
        {:error, "Debug info not available"}
      {:error, :beam_lib, {:file_error, "non_existing.beam", :enoent}} ->
        {:error, "Debug info not available"}
    end
  end

  defp process_debug_info({:ok, info}, nil) do
    info = Map.put(info, :last_modified, nil)
    {:ok, info}
  end

  defp process_debug_info({:ok, info}, beam_path) do
    info = case File.stat(beam_path, time: :posix) do
      {:ok, file_info} ->
        Map.put(info, :last_modified, file_info.mtime)
      _ ->
        Map.put(info, :last_modified, nil)
    end

    {:ok, info}
  end

  defp process_debug_info(error, _) do
    error
  end

  defp get_protocol_implementations(module) do
    implementations = module
    |> Protocol.extract_impls(:code.get_path())
    |> Enum.map(fn(x) -> Module.concat([module, x]) end)
    |> Enum.map(fn(x) ->
      case debug_info(x) do
        {:ok, info} ->
          {x, info}
        _ ->
          raise "Unable to compile protocol implementation #{inspect x}"
      end
    end)

    {:ok, module, implementations}
  end

  defp replace_definitions(original_definitions, replacement_definitions) do
    Enum.map(original_definitions, fn
      {{function, arity}, type, _, _} = ast ->
        ex_ast = Enum.find(replacement_definitions, fn
          {{ex_function, ex_arity}, ex_type, _, _}  ->
            ex_function == function and ex_arity == arity and ex_type == type
        end)

        case ex_ast do
          nil ->
            ast
          _ ->
            ex_ast
        end
    end)
  end

end
