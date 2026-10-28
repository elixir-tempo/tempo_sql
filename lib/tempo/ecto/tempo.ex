if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.Tempo do
    @moduledoc """
    Ecto.ParameterizedType for persisting a value as a PostgreSQL
    `tstzrange`: `Tempo.Ecto.Interval` under the name `tempo_sql` 0.2.0
    gave a column of bare values, kept so that schemas written for it
    still compile.

    A value is the span it names — `~o"2026Y"` the whole of 2026,
    `~o"2026Y-06M"` June 2026 — and is stored as that interval, as
    `Tempo.Ecto.Interval` stores it.

    ## Usage

        schema "years" do
          field :reporting_year, Tempo.Ecto.Tempo, resolution: :year
        end

    ## Options

      * `:resolution` — as for `Tempo.Ecto.Interval`. With `:year`, a
        year loads as the interval from that year through itself.

    ## Round-trip caveat

    A stored `~o"2026Y"` loads back as the interval it names, not the
    value: a `tstzrange` keeps no more. `Tempo.Ecto.TempoRange` keeps
    the value as it was written.

    """

    use Ecto.ParameterizedType

    alias Ecto.ParameterizedType
    alias Tempo.Ecto.Interval, as: IntervalType
    alias Tempo.SQL.Conversion

    @doc """
    Builds the parameterized-type tuple for use outside a schema.

    See `Tempo.Ecto.Interval.cast_type/1` for the schema-side
    equivalent and the full discussion.

    ### Arguments

    * `options` is a keyword list of options.

    ### Options

    * `:resolution` writes the ends to the given unit on load. One of
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
    @spec cast_type(keyword()) :: Ecto.Type.t()
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(_params) do
      :tstzrange
    end

    @impl Ecto.ParameterizedType
    def init(options) do
      resolution =
        options
        |> Keyword.get(:resolution, :second)
        |> Conversion.validate_resolution!()

      %{resolution: resolution}
    end

    @impl Ecto.ParameterizedType
    def cast(value, params) do
      IntervalType.cast(value, params)
    end

    @impl Ecto.ParameterizedType
    def load(value, loader \\ nil, params \\ %{resolution: :second}) do
      IntervalType.load(value, loader, params)
    end

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{resolution: :second}) do
      IntervalType.dump(value, dumper, params)
    end

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params) do
      a == b
    end

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params) do
      :self
    end
  end
end
