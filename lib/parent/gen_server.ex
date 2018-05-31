defmodule Parent.GenServer do
  @moduledoc """
  A GenServer extension which simplifies parenting of children.

  This behaviour helps implementing a GenServer which also needs to directly
  start child processes and handle their termination.

  ## Starting the process

  The usage is similar to GenServer. You need to use the module and start the
  process:

  ```
  def MyParentProcess do
    use Parent.GenServer

    def start_link(arg) do
      Parent.GenServer.start_link(__MODULE__, arg, options \\\\ [])
    end
  end
  ```

  The expression `use Parent.GenServer` will also inject `use GenServer` into
  your code. Your parent process is a GenServer, and this behaviour doesn't try
  to hide it. Except when starting the process, you work with the parent exactly
  as you work with any GenServer, using the same functions, and writing the same
  callbacks:

  ```
  def MyParentProcess do
    use Parent.GenServer

    def do_something(pid, arg), do: GenServer.call(pid, {:do_something, arg})

    ...

    @impl GenServer
    def init(arg), do: {:ok, initial_state(arg)}

    @impl GenServer
    def handle_call({:do_something, arg}, _from, state),
      do: {:reply, response(state, arg), next_state(state, arg)}
  end
  ```

  Compared to plain GenServer, there are following differences:

  - A Parent.GenServer traps exits by default.
  - The generated `child_spec/1` has the `:shutdown` configured to `:infinity`.

  ## Starting children

  To start a child, you can invoke `start_child/1` in the parent process:

  ```
  def handle_call(...) do
    Parent.GenServer.start_child(child_spec)
    ...
  end
  ```

  The function takes a child spec map which is similar to Supervisor child
  specs. The map has the following keys:

    - `:id` (required) - a term uniquely identifying the child
    - `:start` (required) - an MFA, or a zero arity lambda invoked to start the child
    - `:meta` (optional) - a term associated with the started child, defaults to `nil`
    - `:shutdown` (optional) - same as with `Supervisor`, defaults to 5000

  The function described with `:start` needs to start a linked process and return
  the result as `{:ok, pid}`. For example:

  ```
  Parent.GenServer.start_child(%{
    id: :hello_world,
    start: {Task, :start_link, [fn -> IO.puts "Hello, World!" end]}
  })
  ```

  You can also pass a zero-arity lambda for `:start`:

  ```
  Parent.GenServer.start_child(%{
    id: :hello_world,
    start: fn -> Task.start_link(fn -> IO.puts "Hello, World!" end) end
  })
  ```

  Finally, a child spec can also be a module, or a `{module, arg}` function.
  This works similarly to supervisor specs, invoking `module.child_spec/1`
  is which must provide the final child specification.

  ## Handling child termination

  When a child terminates, `handle_child_terminated/5` will be invoked. The
  default implementation is injected into the module, but you can of course
  override it:

  ```
  @impl Parent.GenServer
  def handle_child_terminated(id, child_meta, pid, reason, state) do
    ...
    {:noreply, state}
  end
  ```

  The return value of `handle_child_terminated` is the same as for `handle_info`.

  ## Working with children

  This module provide various functions for managing the children. For example,
  you can enumerate running children with `children/0`, fetch child meta with
  `child_meta/1`, or terminate a child with `shutdown_child/1`.

  ## Termination

  The behaviour takes down the children during termination, to ensure that no
  child is running after the parent has terminated. This happens after the
  `terminate/1` callback returns. Therefore in `terminate/1` the children are
  still running, and you can interact with them.
  """
  use GenServer
  use Parent.PublicTypes

  @type state :: term

  @doc "Invoked when a child has terminated."
  @callback handle_child_terminated(id, child_meta, pid, reason :: term, state) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate}
              | {:stop, reason :: term, new_state}
            when new_state: state

  @doc "Starts the parent process."
  @spec start_link(module, arg :: term, GenServer.options()) :: GenServer.on_start()
  def start_link(module, arg, options \\ []) do
    GenServer.start_link(__MODULE__, {module, arg}, options)
  end

  @doc "Starts the child described by the specification."
  @spec start_child(child_spec | module | {module, term}) :: on_start_child
  defdelegate start_child(child_spec), to: Parent.Procdict

  @doc """
  Terminates the child.

  This function waits for the child to terminate. In the case of explicit
  termination, `handle_child_terminated/5` will not be invoked.
  """
  @spec shutdown_child(id) :: :ok
  defdelegate shutdown_child(child_id), to: Parent.Procdict

  @doc """
  Terminates all running children.

  The order in which children are taken down is not guaranteed.
  The function returns after all of the children have been terminated.
  """
  @spec shutdown_all(reason :: term) :: :ok
  defdelegate shutdown_all(reason \\ :shutdown), to: Parent.Procdict

  @doc "Returns the list of running children."
  @spec children :: [child]
  defdelegate children(), to: Parent.Procdict, as: :entries

  @doc "Returns the count of running children."
  @spec num_children() :: non_neg_integer
  defdelegate num_children(), to: Parent.Procdict, as: :size

  @doc "Returns the id of a child with the given pid."
  @spec child_id(pid) :: {:ok, id} | :error
  defdelegate child_id(pid), to: Parent.Procdict, as: :id

  @doc "Returns the pid of a child with the given id."
  @spec child_pid(id) :: {:ok, pid} | :error
  defdelegate child_pid(id), to: Parent.Procdict, as: :pid

  @doc "Returns the meta associated with the given child id."
  @spec child_meta(id) :: {:ok, child_meta} | :error
  defdelegate child_meta(id), to: Parent.Procdict, as: :meta

  @doc "Updates the meta of the given child."
  @spec update_child_meta(id, (child_meta -> child_meta)) :: :ok | :error
  defdelegate update_child_meta(id, updater), to: Parent.Procdict, as: :update_meta

  @doc """
  Returns true if the child is still running, false otherwise.

  Note that this function might return true even if the child has terminated.
  This can happen if the corresponding `:EXIT` message still hasn't been
  processed.
  """
  @spec child?(id) :: boolean
  def child?(id), do: match?({:ok, _}, child_pid(id))

  @impl GenServer
  def init({callback, arg}) do
    Process.put({__MODULE__, :callback}, callback)
    Parent.Procdict.initialize()
    invoke_callback(:init, [arg])
  end

  @impl GenServer
  def handle_info(message, state) do
    case Parent.Procdict.handle_message(message) do
      {:EXIT, pid, id, meta, reason} ->
        invoke_callback(:handle_child_terminated, [id, meta, pid, reason, state])

      :error ->
        invoke_callback(:handle_info, [message, state])
    end
  end

  @impl GenServer
  def handle_call(message, from, state), do: invoke_callback(:handle_call, [message, from, state])

  @impl GenServer
  def handle_cast(message, state), do: invoke_callback(:handle_cast, [message, state])

  @impl GenServer
  def format_status(reason, pdict_and_state),
    do: invoke_callback(:format_status, [reason, pdict_and_state])

  @impl GenServer
  def code_change(old_vsn, state, extra),
    do: invoke_callback(:code_change, [old_vsn, state, extra])

  @impl GenServer
  def terminate(reason, state) do
    invoke_callback(:terminate, [reason, state])
  after
    Parent.Procdict.shutdown_all(reason)
  end

  defp invoke_callback(fun, arg), do: apply(Process.get({__MODULE__, :callback}), fun, arg)

  @doc false
  def child_spec(_arg) do
    raise("#{__MODULE__} can't be used in a child spec.")
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts, behaviour: __MODULE__] do
      use GenServer, opts
      @behaviour behaviour

      @doc """
      Returns a specification to start this module under a supervisor.
      See `Supervisor`.
      """
      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          shutdown: :infinity
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      @impl behaviour
      def handle_child_terminated(_id, _meta, _pid, _reason, state), do: {:noreply, state}

      defoverridable handle_child_terminated: 5, child_spec: 1
    end
  end
end
