if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.Tempo do
    @moduledoc """
    Ecto.ParameterizedType for persisting a bare `t:Tempo.t/0` as
    a PostgreSQL `tstzrange`.

    A bare Tempo value is an *implicit* span — `~o"2026Y"` spans
    the whole of 2026, `~o"2026Y-06M"` spans June 2026. This type
    materialises the implicit span via `Tempo.to_interval/1` and
    then delegates to `Tempo.Ecto.Interval`.

    ## Usage

        schema "years" do
          field :reporting_year, Tempo.Ecto.Tempo, resolution: :year
        end

    ## Options

      * `:resolution` — same as `Tempo.Ecto.Interval`. With
        `:year`, loaded values come back as year-resolution
        Tempos (the closest shape-preserving round-trip
        available for implicit spans).

    ## Round-trip caveat

    *Implicit spans do not round-trip as implicit spans without
    help.* A stored `~o"2026Y"` loads back as a
    `%Tempo.Interval{}` — there is no way to recover "it was
    just a year token" from a `tstzrange` alone. Setting
    `resolution: :year` gives the closest approximation by
    returning an interval whose endpoints are year-resolution
    Tempos. See the storage contract guide.

    Tempo values that materialise to an `IntervalSet` (any value
    with a recurrence rule) are rejected — use a
    `Tempo.Ecto.IntervalSet` column instead.

    """

    use Ecto.ParameterizedType

    alias Ecto.ParameterizedType
    alias Tempo.SQL.Conversion

    @doc """
    Builds the parameterized-type tuple for use outside a schema.

    See `Tempo.Ecto.Interval.cast_type/1` for the schema-side
    equivalent and the full discussion.

    ### Arguments

    * `options` is a keyword list of options.

    ### Options

    * `:resolution` truncates the materialised endpoints on load to the given component. One of
      `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second`.
      Defaults to `:second`.

    ### Returns

    * A `t:Ecto.ParameterizedType.opts/0` tuple.

    ### Examples

        iex> Tempo.Ecto.Tempo.cast_type()
        {:parameterized, {Tempo.Ecto.Tempo, %{resolution: :second}}}

        iex> Tempo.Ecto.Tempo.cast_type(resolution: :day)
        {:parameterized, {Tempo.Ecto.Tempo, %{resolution: :day}}}

    """
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(_params), do: :tstzrange

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
    def cast(%Tempo{} = tempo, _params), do: materialise(tempo)
    def cast(%Tempo.Interval{} = interval, _params), do: {:ok, interval}

    def cast(%Postgrex.Range{} = range, params) do
      Tempo.Ecto.Interval.cast(range, params)
    end

    def cast(_, _params), do: :error

    @impl Ecto.ParameterizedType
    def load(value, loader \\ nil, params \\ %{resolution: :second})

    def load(value, loader, params) do
      Tempo.Ecto.Interval.load(value, loader, params)
    end

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{resolution: :second})

    def dump(nil, _, _), do: {:ok, nil}

    def dump(%Tempo{} = tempo, dumper, params) do
      case materialise(tempo) do
        {:ok, interval} -> Tempo.Ecto.Interval.dump(interval, dumper, params)
        :error -> :error
      end
    end

    def dump(%Tempo.Interval{} = interval, dumper, params) do
      Tempo.Ecto.Interval.dump(interval, dumper, params)
    end

    def dump(_, _, _), do: :error

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params), do: a == b

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params), do: :self

    defp materialise(%Tempo{} = tempo) do
      case Tempo.to_interval(tempo) do
        {:ok, %Tempo.Interval{} = interval} -> {:ok, interval}
        {:ok, %Tempo.IntervalSet{}} -> :error
        _ -> :error
      end
    end
  end
end
