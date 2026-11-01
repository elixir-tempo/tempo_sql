if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.IntervalSet do
    @moduledoc """
    Ecto.ParameterizedType for persisting the intervals an expression
    covers as a PostgreSQL `tstzmultirange` value (PostgreSQL 14+), or
    as a `tsmultirange` value when they are floating.

    It takes any expression with a last span — a set, a bounded
    recurrence, a value naming several — and loads a set of intervals.

    ## Usage

        schema "alice_calendar" do
          field :busy_times, Tempo.Ecto.IntervalSet
        end

    and in the migration:

        add :busy_times, :tstzmultirange

    (or use `Tempo.SQL.Migration.add_interval_set/2`). Floating values
    go in a `tsmultirange`, on the floating frame:

        field :opening_hours, Tempo.Ecto.IntervalSet, frame: :floating

        add :opening_hours, :tsmultirange

    ## Options

      * `:resolution` — on load, truncate every member
        interval's endpoints to the given component. Same values
        and semantics as `Tempo.Ecto.Interval`.

      * `:frame` — `:utc` (the default) for a `tstzmultirange` column,
        `:floating` for a `tsmultirange` column, as for
        `Tempo.Ecto.Interval`.

    ## Storage contract

    Every member interval must satisfy the same contract as
    `Tempo.Ecto.Interval`. In addition:

      * The set must be non-empty. An empty multirange
        round-trips as `'{}'::tstzmultirange`; use a NULL column
        to represent "no set".

      * The expression must have a last span: a recurrence with no
        end has no multirange.

    """

    use Ecto.ParameterizedType

    alias Ecto.ParameterizedType
    alias Tempo.IntervalSet
    alias Tempo.SQL.Conversion

    @doc """
    Builds the parameterized-type tuple for use outside a schema.

    See `Tempo.Ecto.Interval.cast_type/1` for the schema-side
    equivalent and the full discussion.

    ### Arguments

    * `options` is a keyword list of options.

    ### Options

    * `:resolution` truncates member interval's endpoints on load to the given component. One of
      `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second`.
      Defaults to `:second`.

    * `:frame` is `:utc` (the default) for a `tstzmultirange` column or
      `:floating` for a `tsmultirange` column.

    ### Returns

    * A `t:Ecto.ParameterizedType.opts/0` tuple.

    ### Examples

        iex> Tempo.Ecto.IntervalSet.cast_type()
        {:parameterized, {Tempo.Ecto.IntervalSet, %{frame: :utc, resolution: :second}}}

        iex> Tempo.Ecto.IntervalSet.cast_type(resolution: :day, frame: :floating)
        {:parameterized, {Tempo.Ecto.IntervalSet, %{frame: :floating, resolution: :day}}}

    """
    @spec cast_type(keyword()) :: Ecto.Type.t()
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(%{frame: :floating}) do
      :tsmultirange
    end

    def type(_params) do
      :tstzmultirange
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
      |> Conversion.intervals()
      |> with_expression(expression)
      |> on_frame(params)
      |> Conversion.cast_result()
    end

    def cast(%Postgrex.Multirange{} = multirange, params) do
      multirange
      |> multirange_to_set(params.resolution)
      |> on_frame(params)
      |> Conversion.cast_result()
    end

    def cast(members, params) when is_list(members) do
      members
      |> IntervalSet.new()
      |> on_frame(params)
      |> Conversion.cast_result()
    end

    def cast(_, _params) do
      :error
    end

    @impl Ecto.ParameterizedType
    def load(value, loader \\ nil, params \\ %{resolution: :second, frame: :utc})

    def load(nil, _loader, _params) do
      {:ok, nil}
    end

    def load(%Postgrex.Multirange{} = multirange, _loader, params) do
      case multirange_to_set(multirange, params.resolution) do
        {:ok, set} -> {:ok, set}
        {:error, _} -> :error
      end
    end

    def load(_, _, _) do
      :error
    end

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{resolution: :second, frame: :utc})

    def dump(nil, _, _) do
      {:ok, nil}
    end

    def dump(%Tempo{} = expression, _, params) do
      case Conversion.intervals(expression) do
        {:ok, [_ | _] = intervals} -> dump_members(intervals, Map.get(params, :frame, :utc), [])
        _empty_or_error -> :error
      end
    end

    def dump(_, _, _) do
      :error
    end

    defp with_expression({:ok, _intervals}, expression) do
      {:ok, expression}
    end

    defp with_expression(error, _expression) do
      error
    end

    defp on_frame({:ok, set}, params) do
      with :ok <- Conversion.on_frame(set, Map.get(params, :frame, :utc)) do
        {:ok, set}
      end
    end

    defp on_frame(error, _params) do
      error
    end

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params) do
      a == b
    end

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params) do
      :self
    end

    defp dump_members([], _frame, acc) do
      {:ok, %Postgrex.Multirange{ranges: Enum.reverse(acc)}}
    end

    defp dump_members([interval | rest], frame, acc) do
      case Conversion.interval_to_range(interval, frame) do
        {:ok, range} -> dump_members(rest, frame, [range | acc])
        {:error, _} -> :error
      end
    end

    defp multirange_to_set(%Postgrex.Multirange{ranges: ranges}, resolution) do
      ranges
      |> Enum.reduce_while({:ok, []}, fn range, {:ok, acc} ->
        case Conversion.range_to_interval(range, resolution: resolution) do
          {:ok, interval} -> {:cont, {:ok, [interval | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> in_order()
    end

    defp in_order({:ok, intervals}) do
      IntervalSet.new(Enum.reverse(intervals))
    end

    defp in_order(error) do
      error
    end
  end
end
