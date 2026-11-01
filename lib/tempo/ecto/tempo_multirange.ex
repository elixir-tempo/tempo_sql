if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.TempoMultirange do
    @moduledoc """
    Ecto.ParameterizedType for the PostgreSQL composite type
    `tempo_multirange` — a `tstzmultirange` paired with a
    resolution string and `jsonb` metadata that together round-
    trip a set, or any expression of several spans with ISO 8601 text,
    without information loss.

        CREATE TYPE tempo_multirange AS (
          ranges     tstzmultirange,
          resolution text,
          meta       jsonb
        );

    A floating expression, with no zone and no time shift, is kept in
    `tempo_floating_multirange`, the same with a `tsmultirange` for its
    ranges: a field declared with `frame: :floating`.

    The meta column stores the set as a JSON document keyed by
    member index, so qualifications, recurrence state, and other
    per-member facts survive the round-trip.

    See `Tempo.Ecto.TempoRange` for the setup and query
    conventions.

    """

    use Ecto.ParameterizedType

    alias Ecto.ParameterizedType
    alias Tempo.IntervalSet
    alias Tempo.SQL.Conversion
    alias Tempo.SQL.Meta

    @doc """
    Builds the parameterized-type tuple for use outside a schema.

    See `Tempo.Ecto.Interval.cast_type/1` for the schema-side
    equivalent and the full discussion.

    ### Arguments

    * `options` is a keyword list of options.

    ### Options

    * `:resolution` truncates the endpoints recorded in the composite to the given component. One of
      `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second`.
      Defaults to `:second`.

    * `:frame` is `:utc` (the default) for a `tempo_multirange` column,
      or `:floating` for a `tempo_floating_multirange` column.

    ### Returns

    * A `t:Ecto.ParameterizedType.opts/0` tuple.

    ### Examples

        iex> Tempo.Ecto.TempoMultirange.cast_type()
        {:parameterized, {Tempo.Ecto.TempoMultirange, %{frame: :utc, resolution: :second}}}

        iex> Tempo.Ecto.TempoMultirange.cast_type(resolution: :day, frame: :floating)
        {:parameterized, {Tempo.Ecto.TempoMultirange, %{frame: :floating, resolution: :day}}}

    """
    @spec cast_type(keyword()) :: Ecto.Type.t()
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(%{frame: :floating}) do
      :tempo_floating_multirange
    end

    def type(_params) do
      :tempo_multirange
    end

    @impl Ecto.ParameterizedType
    def init(options) do
      resolution =
        options
        |> Keyword.get(:resolution, :second)
        |> Conversion.validate_resolution!()

      frame =
        options
        |> Keyword.get(:frame, :utc)
        |> Conversion.validate_frame!()

      %{resolution: resolution, frame: frame}
    end

    @impl Ecto.ParameterizedType
    def cast(nil, _params) do
      {:ok, nil}
    end

    def cast(%Tempo{} = expression, params) do
      expression
      |> written_on_frame(Map.get(params, :frame, :utc))
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
    def load(value, loader \\ nil, params \\ %{resolution: :second, frame: :utc})

    def load(nil, _loader, _params) do
      {:ok, nil}
    end

    def load({%Postgrex.Multirange{} = _multirange, _resolution, meta}, _loader, _params)
        when not is_nil(meta) do
      loaded(Meta.decode_interval(meta))
    end

    # A composite row with no meta, written by hand, is read from its ranges.
    def load({%Postgrex.Multirange{ranges: ranges}, _resolution, nil}, _loader, params) do
      loaded(from_ranges(ranges, params.resolution))
    end

    def load(_, _, _) do
      :error
    end

    # Ecto takes a value that does not load as `:error`, whatever the reason.
    defp loaded({:ok, expression}) do
      {:ok, expression}
    end

    defp loaded({:error, _reason}) do
      :error
    end

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{resolution: :second, frame: :utc})

    def dump(nil, _, _) do
      {:ok, nil}
    end

    def dump(%Tempo{} = expression, _, params) do
      case composite(expression, Map.get(params, :frame, :utc)) do
        {:ok, {multirange, meta}} -> {:ok, {multirange, Atom.to_string(params.resolution), meta}}
        {:error, _} -> :error
      end
    end

    def dump(_, _, _) do
      :error
    end

    # An expression a composite can write, on the column's frame.
    defp written_on_frame(expression, frame) do
      with {:ok, _text} <- Tempo.to_iso8601(expression),
           :ok <- Conversion.on_frame(expression, frame) do
        {:ok, expression}
      end
    end

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params) do
      a == b
    end

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params) do
      :self
    end

    # The ranges of the intervals an expression covers, none empty, and its meta.
    defp composite(expression, frame) do
      with {:ok, [_ | _] = intervals} <- Conversion.intervals(expression),
           {:ok, ranges} <- each(intervals, &Conversion.interval_to_queryable_range(&1, frame)),
           {:ok, meta} <- Meta.encode_interval(expression) do
        {:ok, {%Postgrex.Multirange{ranges: ranges}, IO.iodata_to_binary(meta)}}
      end
      |> non_empty()
    end

    defp non_empty({:ok, []}) do
      {:error, :empty_set}
    end

    defp non_empty({:ok, _} = composite) do
      composite
    end

    defp non_empty({:error, _} = error) do
      error
    end

    defp non_empty(_no_intervals) do
      {:error, :empty_set}
    end

    defp from_ranges(ranges, resolution) do
      with {:ok, intervals} <-
             each(ranges, &Conversion.range_to_interval(&1, resolution: resolution)),
           do: IntervalSet.new(intervals)
    end

    defp each(items, fun) do
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case fun.(item) do
          {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end
end
