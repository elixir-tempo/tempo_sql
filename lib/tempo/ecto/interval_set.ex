if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.IntervalSet do
    @moduledoc """
    Ecto.ParameterizedType for persisting the intervals an expression
    covers as a PostgreSQL `tstzmultirange` value (PostgreSQL 14+).

    It takes any expression with a last span — a set, a bounded
    recurrence, a value naming several — and loads a set of intervals.

    ## Usage

        schema "alice_calendar" do
          field :busy_times, Tempo.Ecto.IntervalSet
        end

    and in the migration:

        add :busy_times, :tstzmultirange

    (or use `Tempo.SQL.Migration.add_interval_set/2`).

    ## Options

      * `:resolution` — on load, truncate every member
        interval's endpoints to the given component. Same values
        and semantics as `Tempo.Ecto.Interval`.

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

    ### Returns

    * A `t:Ecto.ParameterizedType.opts/0` tuple.

    ### Examples

        iex> Tempo.Ecto.IntervalSet.cast_type()
        {:parameterized, {Tempo.Ecto.IntervalSet, %{resolution: :second}}}

        iex> Tempo.Ecto.IntervalSet.cast_type(resolution: :day)
        {:parameterized, {Tempo.Ecto.IntervalSet, %{resolution: :day}}}

    """
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(_params), do: :tstzmultirange

    @impl Ecto.ParameterizedType
    def init(options) do
      resolution =
        options
        |> Keyword.get(:resolution, :second)
        |> Conversion.validate_resolution!()

      %{resolution: resolution}
    end

    @impl Ecto.ParameterizedType
    def cast(nil, _params), do: {:ok, nil}

    def cast(%Tempo{} = expression, _params) do
      case Conversion.intervals(expression) do
        {:ok, _intervals} -> {:ok, expression}
        {:error, _} -> :error
      end
    end

    def cast(%Postgrex.Multirange{} = multirange, params) do
      case multirange_to_set(multirange, params.resolution) do
        {:ok, set} -> {:ok, set}
        {:error, _} -> :error
      end
    end

    def cast(members, _params) when is_list(members) do
      case IntervalSet.new(members) do
        {:ok, set} -> {:ok, set}
        {:error, _} -> :error
      end
    end

    def cast(_, _params), do: :error

    @impl Ecto.ParameterizedType
    def load(value, loader \\ nil, params \\ %{resolution: :second})
    def load(nil, _loader, _params), do: {:ok, nil}

    def load(%Postgrex.Multirange{} = multirange, _loader, params) do
      case multirange_to_set(multirange, params.resolution) do
        {:ok, set} -> {:ok, set}
        {:error, _} -> :error
      end
    end

    def load(_, _, _), do: :error

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{resolution: :second})
    def dump(nil, _, _), do: {:ok, nil}

    def dump(%Tempo{} = expression, _, _) do
      case Conversion.intervals(expression) do
        {:ok, [_ | _] = intervals} -> dump_members(intervals, [])
        _empty_or_error -> :error
      end
    end

    def dump(_, _, _), do: :error

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params), do: a == b

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params), do: :self

    defp dump_members([], acc), do: {:ok, %Postgrex.Multirange{ranges: Enum.reverse(acc)}}

    defp dump_members([interval | rest], acc) do
      case Conversion.interval_to_range(interval) do
        {:ok, range} -> dump_members(rest, [range | acc])
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

    defp in_order({:ok, intervals}), do: IntervalSet.new(Enum.reverse(intervals))
    defp in_order(error), do: error
  end
end
