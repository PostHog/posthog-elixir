defmodule PostHog do
  @moduledoc """
  Main API for working with PostHog
  """

  @typedoc "Name under which an instance of PostHog supervision tree is registered."
  @type supervisor_name() :: atom()

  @typedoc ~S(Event name, such as `"user_signed_up"` or `"$create_alias"`)
  @type event() :: String.t()

  @typedoc "string representing distinct ID"
  @type distinct_id() :: String.t()

  @typedoc """
  Map representing event properties.

  Note that it __must__ be JSON-serializable.
  """

  @type properties() :: %{optional(String.t()) => any(), optional(atom()) => any()}

  @doc """
  Returns the configuration map for a named `PostHog` supervisor.

  ## Examples

  Retrieve the default `PostHog` instance config:

      %{supervisor_name: PostHog} = PostHog.config()

  Retrieve named instance config:

      %{supervisor_name: MyPostHog} = PostHog.config(MyPostHog)
  """
  @spec config(supervisor_name()) :: PostHog.Config.config()
  def config(name \\ __MODULE__), do: PostHog.Registry.config(name)

  @doc false
  def bare_capture(event, distinct_id, %{} = properties),
    do: bare_capture(__MODULE__, event, distinct_id, properties)

  @doc """
  Captures a single event without retrieving properties from context.

  Capture is a relatively lightweight operation. The event is prepared
  synchronously and then sent to PostHog workers to be batched together with
  other events and sent over the wire.

  ## Examples

  Capture a simple event:

      PostHog.bare_capture("event_captured", "user123")

  Capture an event with properties:

      PostHog.bare_capture("event_captured", "user123", %{backend: "Phoenix"})

  Capture through a named PostHog instance:

      PostHog.bare_capture(MyPostHog, "event_captured", "user123")
  """
  @spec bare_capture(supervisor_name(), event(), distinct_id(), properties()) :: :ok
  def bare_capture(name \\ __MODULE__, event, distinct_id, properties \\ %{}) do
    config = PostHog.Registry.config(name)

    properties =
      properties
      |> Map.merge(config.global_properties)
      |> LoggerJSON.Formatter.RedactorEncoder.encode([])

    event = %{
      event: event,
      distinct_id: distinct_id,
      uuid: UUIDv7.generate(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      properties: properties
    }

    PostHog.Sender.send(event, name)
  end

  @doc false
  def capture(event, %{} = properties),
    do: capture(__MODULE__, event, properties)

  @doc """
  Captures a single event.

  Any context previously set will be included in the event properties. Note that
  `distinct_id` is still required.

  ## Examples

  Set context and capture an event:

      PostHog.set_context(%{distinct_id: "user123", "$feature/my-feature-flag": true})
      PostHog.capture("job_started", %{job_name: "JobName"})

  Set context and capture an event through a named PostHog instance:

      PostHog.set_context(MyPostHog, %{distinct_id: "user123", "$feature/my-feature-flag": true})
      PostHog.capture(MyPostHog, "job_started", %{job_name: "JobName"})
  """
  @spec capture(supervisor_name(), event(), properties()) :: :ok | {:error, :missing_distinct_id}
  def capture(name \\ __MODULE__, event, properties \\ %{}) do
    context =
      name
      |> get_event_context(event)
      |> Map.merge(properties)

    case Map.pop(context, :distinct_id) do
      {nil, _} -> {:error, :missing_distinct_id}
      {distinct_id, properties} -> bare_capture(name, event, distinct_id, properties)
    end
  end

  @doc """
  Sets context for the current process.

  ## Examples

  Set and retrieve context for the current process:

      > PostHog.set_context(%{foo: "bar"})
      > PostHog.get_context()
      %{foo: "bar"}

  Set and retrieve context for a named PostHog instance:

      > PostHog.set_context(MyPostHog, %{foo: "bar"})
      > PostHog.get_context(MyPostHog)
      %{foo: "bar"}
  """
  @spec set_context(supervisor_name(), properties()) :: :ok
  defdelegate set_context(name \\ __MODULE__, context), to: PostHog.Context, as: :set

  @doc """
  Sets context for the current process scoped to a specific event.

  ## Examples

  Set and retrieve context scoped to an event:

      > PostHog.set_event_context("$exception", %{foo: "bar"})
      > PostHog.get_event_context("$exception")
      %{foo: "bar"}

  Set and retrieve context for a specific event through a named PostHog instance:

      > PostHog.set_event_context(MyPostHog, "$exception", %{foo: "bar"})
      > PostHog.get_event_context(MyPostHog, "$exception")
      %{foo: "bar"}
  """
  @spec set_event_context(supervisor_name(), event(), properties()) :: :ok
  def set_event_context(name \\ __MODULE__, event, context),
    do: PostHog.Context.set(name, event, context)

  @doc """
  Retrieves context for the current process.

  ## Examples

  Set and retrieve context for current process:

      > PostHog.set_context(%{foo: "bar"})
      > PostHog.get_context()
      %{foo: "bar"}

  Set and retrieve context for a named PostHog instance:

      > PostHog.set_context(MyPostHog, %{foo: "bar"})
      > PostHog.get_context(MyPostHog)
      %{foo: "bar"}
  """
  @spec get_context(supervisor_name()) :: properties()
  defdelegate get_context(name \\ __MODULE__), to: PostHog.Context, as: :get

  @doc """
  Retrieves context for the current process scoped to a specific event.

  ## Examples

  Set and retrieve context scoped to an event:

      > PostHog.set_event_context("$exception", %{foo: "bar"})
      > PostHog.get_event_context("$exception")
      %{foo: "bar"}

  Set and retrieve context for a specific event through a named PostHog instance:

      > PostHog.set_event_context(MyPostHog, "$exception", %{foo: "bar"})
      > PostHog.get_event_context(MyPostHog, "$exception")
      %{foo: "bar"}
  """
  @spec get_event_context(supervisor_name()) :: properties()
  def get_event_context(name \\ __MODULE__, event), do: PostHog.Context.get(name, event)
end
