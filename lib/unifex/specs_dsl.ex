defmodule Unifex.Specs.DSL do
  @moduledoc """
  Module exporting macros that can be used to define Unifex specs.

  Example of such specs is provided below:

      module Membrane.Element.Mad.Decoder.Native

      spec create() :: {:ok :: label, state}

      spec decode_frame(payload, offset :: int, state) ::
             {:ok :: label, {payload, bytes_used :: long, sample_rate :: long, channels :: int}}
             | {:error :: label, :buflen :: label}
             | {:error :: label, :malformed :: label}
             | {:error :: label, {:recoverable :: label, bytes_to_skip :: int}}

      dirty :cpu, decode_frame: 3

      sends {:example_msg :: label, number :: int}

  According to this specification, module `Membrane.Element.Mad.Decoder.Native` should contain 2 functions: `create/0`
  and `decode_frame/3` (which is a cpu-bound dirty NIF). The module should use `Unifex.Loader` to provide access to
  these functions. What is more, messages of the form `{:example_msg, integer}` can be sent from the native code to
  erlang processes.

  The generated boilerplate would require implementation of the following functions:

      UNIFEX_TERM create(UnifexEnv* env);
      UNIFEX_TERM decode_frame(UnifexEnv* env, UnifexPayload * payload, int offset, State* state);

  Also the following functions that should be called to return results will be generated:

      UNIFEX_TERM create_result_ok(UnifexEnv* env, State* state);
      UNIFEX_TERM decode_frame_result_ok(UnifexEnv* env, UnifexPayload * payload,
                                         long bytes_used, long sample_rate, int channels);
      UNIFEX_TERM decode_frame_result_error_buflen(UnifexEnv* env);
      UNIFEX_TERM decode_frame_result_error_malformed(UnifexEnv* env);
      UNIFEX_TERM decode_frame_result_error_recoverable(UnifexEnv* env, int bytes_to_skip);

  See docs for appropriate macros for more details.
  """

  @doc """
  Defines module that exports native functions to Elixir world.

  The module needs to be defined manually, but it can `use` `Unifex.Loader` to
  have functions declared with `spec/1` automatically defined.
  """
  defmacro module(module) do
    store_config(:module, module)
  end

  @doc """
  Defines native function specification.

  The specification should be in the form of

      spec function_name(parameter1 :: parameter1_type, some_type, parameter3 :: parameter3_type, ...) ::
          {:label1 :: label, {result_value1 :: result_value1_type, some_type2, ...}}
          | {:label2 :: label, other_result_value2 :: other_result_value2_type}

  ## Parameters

  Specs for parameters can either take the form of `parameter1 :: parameter1_type`
  which will generate parameter with name `parameter1` of type `parameter1_type`
  The other form - just a name, like `some_type` - will generate parameter `some_type`
  of type `some_type`.

  Custom types can be added by creating modules `Unifex.CodeGenerator.BaseTypes.Type` that implement
  `Unifex.CodeGenerator.BaseType` behaviour. Then, they can by used in specs as `type`.

  Each generated function gets additional `UnifexEnv* env` as the first parameter implicitly.

  ## Returned values

  Specs for returned values contain a special type - `label`. An atom of type `label`
  will be put literally in returned values by the special function generated for each
  spec. Names of the generated functions start with Elixir function name
  (e.g. `create`) followed by `_result_` part and then all the labels joined with `_`.

  ## Example

  The example is provided in the moduledoc of this module.
  """
  defmacro spec(spec) do
    store_config(:function, spec |> parse_function() |> enquote())
  end

  @doc """
  Specifies interface, for example NIF or CNode.

  It should be a module name (or list of module names) that will be prepended
  with `Unifex.CodeGenerators`. If no interface is specified, it is automatically
  detected basing on `Bundlex.Project` specification.
  """
  defmacro interface(interface) do
    store_config(:interface, interface)
  end

  @doc """
  Defines the state type, required for using `Unifex.CodeGenerator.BaseTypes.State`.
  """
  defmacro state_type(state_type) do
    store_config(:state_type, state_type)
  end

  defmacro enum(enum) do
    store_config(:enum, enum |> parse_enum() |> enquote())
  end

  @doc """
  Macro used for marking functions as dirty, i.e. performing long cpu-bound or
  io-bound operations.

  The macro should be used the following way:

      dirty type, function1: function1_arity, ...

  when type is one of:
  - `:cpu` - marks function as CPU-bound (maps to the `ERL_NIF_DIRTY_JOB_CPU_BOUND` erlang flag)
  - `:io` - marks function as IO-bound (maps to the `ERL_NIF_DIRTY_JOB_IO_BOUND` erlang flag)
  """
  defmacro dirty(type, funs) when type in [:cpu, :io] and is_list(funs) do
    store_config(:dirty_functions, funs |> Enum.map(&{&1, type}))
  end

  @doc """
  Defines terms that can be sent from the native code to elixir processes.

  Creates native function that can be invoked to send specified data. Name of the
  function starts with `send_` and is constructed from `label`s.
  """
  defmacro sends(spec) do
    store_config(:sends, spec |> enquote())
  end

  @doc """
  Defines names of callbacks invoked on specified hook.

  The available hooks are:

  * `:load` - invoked when the library is loaded. Callback must have the following typing:

    `int on_load(UnifexEnv *env, void ** priv_data)`

    The callback receives an `env` and a pointer to private data that is initialized
    with NULL and can be set to whatever should be passed to other callbacks.
    If callback returns anything else than 0, the library fails to load.

  * `:upgrade` - called when the library is loaded while there is old code for this module
    with a native library loaded. Compared to `:load`, it also receives `old_priv_data`:

    `int on_upgrade(UnifexEnv* env, void** priv_data, void** old_priv_data)`

    Both old and new private data can be modified
    If this callback is not defined, the module code cannot be hot-swapped. Non-zero return
    value also prevents code upgrade.

  * `:unload` - called when the code for module is unloaded. It has the following declaration:

    `void on_unload(UnifexEnv *env, void * priv_data)`

  """
  defmacro callback(hook, fun \\ nil)
           when hook in [:load, :upgrade, :unload, :main] and is_atom(fun) do
    fun = fun || "handle_#{hook}" |> String.to_atom()

    store_config(:callback, {hook, fun})
  end

  @doc """
  Defines struct type specification

  The specification should be in the form of

      struct_def my_struct :: %My.Struct{
        field1: type1,
        field2: type2,
        ...
      }

  Struct specified in such way can be used in like any other supported type, E.g.

      spec my_function(in_struct :: my_struct) :: {:ok :: label, out_struct :: my_struct}

  Elixir definition of %My.Struct{} should contain every field listed in specification and is not generated by Unifex
  """
  defmacro struct_def(struct) do
    store_config(:struct_def, struct |> parse_struct() |> Macro.escape())
  end

  defp store_config(key, value) when is_atom(key) do
    config_store = Macro.var(:unifex_config__, nil)

    quote generated: true do
      unquote(config_store) = [{unquote(key), unquote(value)} | unquote(config_store)]
    end
  end

  defp parse_enum({:"::", _, [{enum_name, _, _}, enum_types]}) do
    {enum_name, parse_enum_types(enum_types)}
  end

  defp parse_enum_types(type_name) when is_atom(type_name) do
    [type_name]
  end

  defp parse_enum_types({:|, _, [first_arg, second_arg]}) do
    parse_enum_types(first_arg) ++ parse_enum_types(second_arg)
  end

  defp parse_struct({:"::", _, [{struct_alias, _, _}, struct]}) do
    {:%, _,
     [
       {:__aliases__, _, struct_module_name},
       {:%{}, _, struct_fields}
     ]} = struct

    struct_module_name =
      struct_module_name
      |> Enum.join(".")
      |> String.to_atom()

    struct_fields =
      struct_fields
      |> Enum.map(fn
        {name, {type, _, _}} -> {name, type}
        {name, [{type, _, _}]} -> {name, {:list, type}}
      end)

    {struct_alias, struct_module_name, struct_fields}
  end

  defp parse_function({:"::", _, [{fun_name, _, args}, results]}) do
    args =
      args
      |> Enum.map(fn
        {:"::", _, [{name, _, _}, [{type, _, _}]]} -> {name, {:list, type}}
        [{name, _, _}] -> {name, {:list, name}}
        {:"::", _, [{name, _, _}, {type, _, _}]} -> {name, type}
        {name, _, _} -> {name, name}
      end)

    results = parse_function_results_traverse_helper(results)
    {fun_name, args, results}
  end

  defp parse_function_results_traverse_helper({:|, _, [left, right]}) do
    parse_function_results_traverse_helper(left) ++ parse_function_results_traverse_helper(right)
  end

  defp parse_function_results_traverse_helper(value) do
    [value]
  end

  # Embeds code in a `quote` block. Useful when willing to store the code and parse
  # it in runtime instead of compile time.
  defp enquote(value) do
    {:quote, [], [[do: value]]}
  end
end
