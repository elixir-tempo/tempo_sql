if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.SQLite.TempoRange do
    @moduledoc """
    Ecto.ParameterizedType that stores a Tempo expression whole in a
    SQLite `TEXT` column.

    SQLite has no range type. The column holds the JSON document
    `Tempo.SQL.SQLite.Document` writes: the expression's ISO 8601 text,
    read back as it was written, beside the integer bounds of the time it
    covers and of each of its spans, which `Tempo.Ecto.SQLite.QueryAPI`
    queries. It takes any expression with ISO 8601 text and a place on
    the time line: a value, an interval, a set, a recurrence.

    ## Usage

        schema "meetings" do
          field :window, Tempo.Ecto.SQLite.TempoRange
          field :opening_hours, Tempo.Ecto.SQLite.TempoRange, frame: :floating
        end

    and in the migration:

        import Tempo.SQL.SQLite.Migration

        create table(:meetings) do
          add_tempo_range :window
        end

        create_tempo_range_index :meetings, :window

    ## Options

      * `:frame` — `:utc` (the default) for values in a zone or at a
        time shift, stored as seconds since the Unix epoch at UTC, or
        `:floating` for values with neither, stored as seconds on the
        wall clock. A value of the other frame is refused by `cast/2`,
        as a changeset error that names the frame to declare, and by
        `dump/3`.

    ## Precision

    The bounds are whole seconds, rounded outward, so a query of a span
    shorter than a second may find its neighbours. The expression itself
    is kept as written and loads back exactly.

    """

    use Ecto.ParameterizedType

    alias Ecto.ParameterizedType
    alias Tempo.IntervalSet
    alias Tempo.SQL.Conversion
    alias Tempo.SQL.SQLite.Document

    @doc """
    Builds the parameterized-type tuple for use outside a schema.

    ### Arguments

    * `options` is a keyword list of options.

    ### Options

    * `:frame` is `:utc` (the default) or `:floating`.

    ### Returns

    * A `t:Ecto.ParameterizedType.opts/0` tuple.

    ### Examples

        iex> Tempo.Ecto.SQLite.TempoRange.cast_type()
        {:parameterized, {Tempo.Ecto.SQLite.TempoRange, %{frame: :utc}}}

        iex> Tempo.Ecto.SQLite.TempoRange.cast_type(frame: :floating)
        {:parameterized, {Tempo.Ecto.SQLite.TempoRange, %{frame: :floating}}}

    """
    @spec cast_type(keyword()) :: Ecto.Type.t()
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(_params) do
      :string
    end

    @impl Ecto.ParameterizedType
    def init(options) do
      frame =
        options
        |> Keyword.get(:frame, :utc)
        |> Conversion.validate_frame!()

      %{frame: frame}
    end

    @impl Ecto.ParameterizedType
    def cast(nil, _params) do
      {:ok, nil}
    end

    def cast(%Tempo{} = expression, params) do
      expression
      |> written_on_frame(frame(params))
      |> Conversion.cast_result()
    end

    def cast(members, params) when is_list(members) do
      case IntervalSet.new(members) do
        {:ok, set} -> cast(set, params)
        {:error, _} -> :error
      end
    end

    def cast(_, _params) do
      :error
    end

    @impl Ecto.ParameterizedType
    def load(value, loader \\ nil, params \\ %{frame: :utc})

    def load(nil, _loader, _params) do
      {:ok, nil}
    end

    def load(json, _loader, _params) when is_binary(json) do
      case Document.decode(json) do
        {:ok, expression} -> {:ok, expression}
        {:error, _reason} -> :error
      end
    end

    def load(_, _, _) do
      :error
    end

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{frame: :utc})

    def dump(nil, _dumper, _params) do
      {:ok, nil}
    end

    def dump(%Tempo{} = expression, _dumper, params) do
      case Document.encode(expression, frame(params)) do
        {:ok, json} -> {:ok, json}
        {:error, _exception} -> :error
      end
    end

    def dump(_, _, _) do
      :error
    end

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params) do
      a == b
    end

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params) do
      :self
    end

    defp frame(params) do
      Map.get(params, :frame, :utc)
    end

    # An expression the column can write, on its frame.
    defp written_on_frame(expression, frame) do
      with {:ok, _text} <- Tempo.to_iso8601(expression),
           :ok <- Conversion.on_frame(expression, frame) do
        {:ok, expression}
      end
    end
  end
end
