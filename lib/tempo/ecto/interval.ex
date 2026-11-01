if Code.ensure_loaded?(Ecto.Type) do
  defmodule Tempo.Ecto.Interval do
    @moduledoc """
    Ecto.ParameterizedType for persisting an interval as a
    PostgreSQL `tstzrange` value, or as a `tsrange` value when it is
    floating.

    It takes any expression that is one span — an interval, or a value
    (`~o"2026-06"`) as the interval it names — and loads an interval.

    ## Usage

        schema "meetings" do
          field :window, Tempo.Ecto.Interval
        end

    and in the migration:

        add :window, :tstzrange

    (or use `Tempo.SQL.Migration.add_interval/2`).

    A field of floating values (with no zone and no time shift, such as
    a shop's opening hours wherever it is) is declared on the floating
    frame, and stored in a `tsrange`:

        field :opening_hours, Tempo.Ecto.Interval, frame: :floating

        add :opening_hours, :tsrange

    ## Options

      * `:resolution` — on load, truncate both endpoints to the
        given component and drop all sub-components. One of
        `:year`, `:month`, `:day`, `:hour`, `:minute`, or
        `:second`. Defaults to `:second` (no truncation). See
        the storage contract guide for the semantics and
        caveats.

            field :reporting_period, Tempo.Ecto.Interval, resolution: :year

      * `:frame` — the line the column's instants lie on. `:utc`
        (the default) stores a value in a zone or at a time shift as
        the UTC instants it is, in a `tstzrange`; `:floating` stores a
        value with neither, in a `tsrange`. A value of the other frame
        is refused by `cast/2`, as a changeset error that names the
        frame to declare, and by `dump/3`.

    ## Storage contract

    This type refuses to store values it cannot round-trip
    semantically. The `dump` callback returns `:error` for:

      * A value of the other frame: a floating value for a column on
        the UTC line, or a value in a zone or at a time shift for a
        floating column.

      * An expression of several spans: a recurrence, a set, or a
        value naming several (`~o"2026Y{6,8}M"`). Store those as
        `Tempo.Ecto.IntervalSet` instead.

      * A qualification (`:uncertain`, `:approximate`) or a calendar
        other than the Gregorian, which a range of instants cannot
        keep. `Tempo.Ecto.TempoRange` keeps both.

      * An interval unbounded on both sides. One open end is stored
        as a `(,b)` or `[a,)` range in Postgres.

    ## Bracket normalisation on load

    PostgreSQL does not canonicalise `tstzrange` values on
    output — a column populated by another writer might hold
    `[a, b]`, `(a, b)`, or `(a, b]`. The loader normalises any
    non-half-open range to `[lower, upper)`
    by shifting the offending endpoint one second (Tempo is
    second-resolution so this is exact).

    """

    use Ecto.ParameterizedType

    alias Ecto.ParameterizedType
    alias Tempo.SQL.Conversion

    @doc """
    Builds the parameterized-type tuple for use outside a schema.

    Inside a schema, `field :window, Tempo.Ecto.Interval, resolution: :day`
    does this for you. Reach for this when calling `Ecto.Type.cast/2`
    and friends directly.

    ### Arguments

    * `options` is a keyword list of options.

    ### Options

    * `:resolution` truncates both endpoints on load to the given
      component. One of `:year`, `:month`, `:day`, `:hour`, `:minute`,
      or `:second`. Defaults to `:second`.

    * `:frame` is `:utc` (the default) for a `tstzrange` column or
      `:floating` for a `tsrange` column.

    ### Returns

    * A `t:Ecto.ParameterizedType.opts/0` tuple.

    ### Examples

        iex> Tempo.Ecto.Interval.cast_type()
        {:parameterized, {Tempo.Ecto.Interval, %{frame: :utc, resolution: :second}}}

        iex> Tempo.Ecto.Interval.cast_type(resolution: :year, frame: :floating)
        {:parameterized, {Tempo.Ecto.Interval, %{frame: :floating, resolution: :year}}}

    """
    @spec cast_type(keyword()) :: Ecto.Type.t()
    def cast_type(options \\ []) do
      ParameterizedType.init(__MODULE__, options)
    end

    @impl Ecto.ParameterizedType
    def type(%{frame: :floating}) do
      :tsrange
    end

    def type(_params) do
      :tstzrange
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
      |> Conversion.as_interval()
      |> on_frame(params)
      |> Conversion.cast_result()
    end

    def cast(%Postgrex.Range{} = range, params) do
      range
      |> Conversion.range_to_interval(resolution: params.resolution)
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

    def load(%Postgrex.Range{} = range, _loader, params) do
      case Conversion.range_to_interval(range, resolution: params.resolution) do
        {:ok, interval} -> {:ok, interval}
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
      case Conversion.interval_to_range(expression, Map.get(params, :frame, :utc)) do
        {:ok, range} -> {:ok, range}
        {:error, _} -> :error
      end
    end

    def dump(_, _, _) do
      :error
    end

    defp on_frame({:ok, interval}, params) do
      with :ok <- Conversion.on_frame(interval, Map.get(params, :frame, :utc)) do
        {:ok, interval}
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
  end
end
