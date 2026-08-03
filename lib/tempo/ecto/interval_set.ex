if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.IntervalSet do
    @moduledoc """
    Ecto.ParameterizedType for persisting a
    `t:Tempo.IntervalSet.t/0` as a PostgreSQL `tstzmultirange`
    value (PostgreSQL 14+).

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

      * Every member must be bounded on both ends (Tempo's
        `IntervalSet.new/2` already enforces this).

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
    def cast(%Tempo.IntervalSet{} = set, _params), do: {:ok, set}

    def cast(%Postgrex.Multirange{} = multirange, params) do
      case multirange_to_set(multirange, params.resolution) do
        {:ok, set} -> {:ok, set}
        {:error, _} -> :error
      end
    end

    def cast(intervals, _params) when is_list(intervals) do
      case IntervalSet.new(intervals) do
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
    def dump(%Tempo.IntervalSet{intervals: []}, _, _), do: :error

    def dump(%Tempo.IntervalSet{intervals: intervals}, _, _) do
      case dump_members(intervals, []) do
        {:ok, ranges} -> {:ok, %Postgrex.Multirange{ranges: ranges}}
        :error -> :error
      end
    end

    def dump(_, _, _), do: :error

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params), do: a == b

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params), do: :self

    defp dump_members([], acc), do: {:ok, Enum.reverse(acc)}

    defp dump_members([interval | rest], acc) do
      case Conversion.interval_to_range(interval) do
        {:ok, range} -> dump_members(rest, [range | acc])
        {:error, _} -> :error
      end
    end

    defp multirange_to_set(%Postgrex.Multirange{ranges: ranges}, resolution) do
      with {:ok, intervals} <- load_members(ranges, resolution, []) do
        IntervalSet.new(intervals)
      end
    end

    defp load_members([], _resolution, acc), do: {:ok, Enum.reverse(acc)}

    defp load_members([range | rest], resolution, acc) do
      case Conversion.range_to_interval(range, resolution: resolution) do
        {:ok, interval} -> load_members(rest, resolution, [interval | acc])
        {:error, _} = err -> err
      end
    end
  end
end
