if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.TempoRange do
    @moduledoc """
    Ecto.ParameterizedType for the PostgreSQL composite type
    `tempo_range` — a `tstzrange` paired with a Tempo-resolution
    string and a `jsonb` metadata column that together preserve
    the full Tempo shape on round-trip.

        CREATE TYPE tempo_range AS (
          range      tstzrange,
          resolution text,
          meta       jsonb
        );

    Use this type when you care about round-trip fidelity: any
    expression with ISO 8601 text — a value, an interval, a
    recurrence, a set — round-trips as the same expression, including
    qualifications, calendars other than the Gregorian, recurrence
    rules, zone identifiers and the value-versus-interval distinction.
    The range column holds the stretch it covers, for queries.

    ## Setup

    Run the DDL helpers once, early in the migration history:

        import Tempo.SQL.Migration
        create_tempo_types()

    Then declare columns with `add_tempo_range/2` (or the raw
    `add :window, :tempo_range`).

    ## Usage

        schema "meetings" do
          field :window, Tempo.Ecto.TempoRange
        end

    ## Query API

    The standard Postgres range operators (`@>`, `&&`) do not
    apply directly to a composite column — they must reach into
    `(column).range`. Use `Tempo.Ecto.QueryAPI.Composite` for
    fragments that auto-unwrap the composite; the plain
    `Tempo.Ecto.QueryAPI` does not work on these columns.

    ## Fidelity

    Round-trip preserves:

      * The resolution a value is written to (`~o"2026Y"`
        round-trips as `~o"2026Y"`, not as an interval between two
        instants).

      * Qualifications (`:uncertain`, `:approximate`).

      * Non-Gregorian calendars.

      * Recurrence rules and repeat rules.

      * Zone identifiers (IANA names preserved via the meta
        column, not just the UTC offset).

      * The expression's metadata, and a set's members', provided
        each is JSON-serialisable.

    """

    use Ecto.ParameterizedType

    alias Ecto.ParameterizedType
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

        iex> Tempo.Ecto.TempoRange.cast_type()
        {:parameterized, {Tempo.Ecto.TempoRange, %{resolution: :second}}}

        iex> Tempo.Ecto.TempoRange.cast_type(resolution: :day)
        {:parameterized, {Tempo.Ecto.TempoRange, %{resolution: :day}}}

    """
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(_params), do: :tempo_range

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
      case Tempo.to_iso8601(expression) do
        {:ok, _text} -> {:ok, expression}
        {:error, _} -> :error
      end
    end

    def cast(_, _params), do: :error

    @impl Ecto.ParameterizedType
    def load(value, loader \\ nil, params \\ %{resolution: :second})
    def load(nil, _loader, _params), do: {:ok, nil}

    def load({%Postgrex.Range{} = _range, _resolution, meta}, _loader, _params)
        when not is_nil(meta),
        do: loaded(Meta.decode_interval(meta))

    # A composite row with no meta, written by hand, is read from its range.
    def load({%Postgrex.Range{} = range, _resolution, nil}, _loader, params),
      do: loaded(Conversion.range_to_interval(range, resolution: params.resolution))

    def load(_, _, _), do: :error

    # Ecto takes a value that does not load as `:error`, whatever the reason.
    defp loaded({:ok, expression}), do: {:ok, expression}
    defp loaded({:error, _reason}), do: :error

    @impl Ecto.ParameterizedType
    def dump(value, dumper \\ nil, params \\ %{resolution: :second})
    def dump(nil, _, _), do: {:ok, nil}

    def dump(%Tempo{} = expression, _, params) do
      case composite(expression) do
        {:ok, {range, meta}} -> {:ok, {range, Atom.to_string(params.resolution), meta}}
        {:error, _} -> :error
      end
    end

    def dump(_, _, _), do: :error

    defp composite(expression) do
      with {:ok, range} <- Conversion.interval_to_queryable_range(expression),
           {:ok, meta} <- Meta.encode_interval(expression),
           do: {:ok, {range, IO.iodata_to_binary(meta)}}
    end

    @impl Ecto.ParameterizedType
    def equal?(a, b, _params), do: a == b

    @impl Ecto.ParameterizedType
    def embed_as(_format, _params), do: :self
  end
end
