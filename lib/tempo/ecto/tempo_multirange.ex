if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.TempoMultirange do
    @moduledoc """
    Ecto.ParameterizedType for the PostgreSQL composite type
    `tempo_multirange` — a `tstzmultirange` paired with a
    resolution string and `jsonb` metadata that together round-
    trip a full `%Tempo.IntervalSet{}` without information loss.

        CREATE TYPE tempo_multirange AS (
          ranges     tstzmultirange,
          resolution text,
          meta       jsonb
        );

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

    ### Returns

    * A `t:Ecto.ParameterizedType.opts/0` tuple.

    ### Examples

        iex> Tempo.Ecto.TempoMultirange.cast_type()
        {:parameterized, {Tempo.Ecto.TempoMultirange, %{resolution: :second}}}

        iex> Tempo.Ecto.TempoMultirange.cast_type(resolution: :day)
        {:parameterized, {Tempo.Ecto.TempoMultirange, %{resolution: :day}}}

    """
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(_params), do: :tempo_multirange

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

    def load({%Postgrex.Multirange{} = _multirange, _resolution, meta}, _loader, _params)
        when not is_nil(meta) do
      decode_set(meta)
    end

    def load({%Postgrex.Multirange{ranges: ranges}, _resolution, nil}, _loader, params) do
      load_ranges_fallback(ranges, params.resolution)
    end

    def load(_, _, _), do: :error

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{resolution: :second})

    def dump(nil, _, _), do: {:ok, nil}
    def dump(%Tempo.IntervalSet{intervals: []}, _, _), do: :error

    def dump(%Tempo.IntervalSet{intervals: intervals} = set, _, params) do
      with {:ok, ranges} <- dump_members(intervals, []),
           meta_json <- encode_set(set) do
        resolution_text = Atom.to_string(params.resolution)
        {:ok, {%Postgrex.Multirange{ranges: ranges}, resolution_text, meta_json}}
      else
        _ -> :error
      end
    end

    def dump(_, _, _), do: :error

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params), do: a == b

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params), do: :self

    # ------------------------------------------------------------------

    defp dump_members([], acc), do: {:ok, Enum.reverse(acc)}

    defp dump_members([interval | rest], acc) do
      case Conversion.interval_to_queryable_range(interval) do
        {:ok, range} -> dump_members(rest, [range | acc])
        {:error, _} -> :error
      end
    end

    defp encode_set(%Tempo.IntervalSet{intervals: intervals, metadata: metadata}) do
      member_jsons =
        Enum.map(intervals, fn interval ->
          interval |> Meta.encode_interval() |> IO.iodata_to_binary() |> Meta.decode_json()
        end)

      %{
        "v" => 1,
        "intervals" => member_jsons,
        "metadata" => metadata || %{}
      }
      |> Meta.encode_json()
    end

    defp decode_set(json) when is_binary(json) do
      case Meta.decode_json(json) do
        %{"intervals" => _} = decoded -> decode_set(decoded)
        other -> {:error, {:invalid_multirange_meta, other}}
      end
    end

    defp decode_set(%{"intervals" => members} = map) when is_list(members) do
      with {:ok, intervals} <- decode_members(members, []) do
        {:ok,
         %Tempo.IntervalSet{
           intervals: intervals,
           metadata: Map.get(map, "metadata", %{}) || %{}
         }}
      end
    end

    defp decode_set(_), do: {:error, :invalid_multirange_meta}

    defp decode_members([], acc), do: {:ok, Enum.reverse(acc)}

    defp decode_members([member | rest], acc) do
      case Meta.decode_interval(member) do
        {:ok, interval} -> decode_members(rest, [interval | acc])
        {:error, _} = err -> err
      end
    end

    defp load_ranges_fallback(ranges, resolution) do
      with {:ok, intervals} <- reduce_ranges(ranges, resolution, []),
           {:ok, set} <- IntervalSet.new(intervals) do
        {:ok, set}
      else
        _ -> :error
      end
    end

    defp reduce_ranges([], _resolution, acc), do: {:ok, Enum.reverse(acc)}

    defp reduce_ranges([range | rest], resolution, acc) do
      case Conversion.range_to_interval(range, resolution: resolution) do
        {:ok, interval} -> reduce_ranges(rest, resolution, [interval | acc])
        {:error, _} = err -> err
      end
    end
  end
end
