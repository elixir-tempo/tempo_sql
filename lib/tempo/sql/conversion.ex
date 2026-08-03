defmodule Tempo.SQL.Conversion do
  @moduledoc """
  Internal helpers that translate between `t:Tempo.Interval.t/0`
  endpoints and the `DateTime` / `:unbound` values that
  `Postgrex.Range` understands.

  The storage contract this module enforces — see the README for
  the full rationale:

    * `%Tempo{}` endpoints must carry a fully anchored
      year/month/day/hour/minute/second time slot (Tempo's highest
      resolution). Partial values must be materialised via
      `Tempo.to_interval/1` first.

    * `:qualification`, `:qualifications`, and `:extended` metadata
      are *dropped on storage* — round-tripping is lossy by design
      for round 1.

    * Non-Gregorian calendars are rejected.

    * Multi-valued token slots (lists like `day_of_week: [1, 3, 5]`
      or ranges like `day: 1..15`) are rejected.

    * `Tempo.Interval` recurrence (`:recurrence`, `:repeat_rule`)
      is rejected — callers must materialise recurring intervals to
      a `Tempo.IntervalSet` via `Tempo.to_interval/1` and store
      that as `tstzmultirange` instead.

  """

  alias Tempo.Interval
  alias Tempo.SQL.UnsupportedValueError

  @gregorian_calendars [nil, Calendar.ISO, Calendrical.Gregorian]

  @resolutions [:year, :month, :day, :hour, :minute, :second]
  @time_components [:year, :month, :day, :hour, :minute, :second]

  @doc """
  The valid values for the `:resolution` option on the Ecto types.
  """
  def valid_resolutions, do: @resolutions

  @doc """
  Convert a `t:Tempo.Interval.t/0` into a `%Postgrex.Range{}` with
  `DateTime` bounds in UTC.

  Returns `{:ok, range}` on success, `{:error, exception}` when the
  interval violates the storage contract.
  """
  @spec interval_to_range(Tempo.Interval.t()) ::
          {:ok, Postgrex.Range.t()} | {:error, UnsupportedValueError.t()}
  def interval_to_range(%Tempo.Interval{} = interval) do
    with :ok <- validate_interval_shape(interval),
         {:ok, lower} <- endpoint_to_datetime(interval.from),
         {:ok, upper} <- endpoint_to_datetime(interval.to) do
      {:ok,
       %Postgrex.Range{
         lower: lower,
         upper: upper,
         lower_inclusive: true,
         upper_inclusive: false
       }}
    end
  end

  @doc """
  Convert a `t:Tempo.Interval.t/0` into a `%Postgrex.Range{}`
  tolerant enough for the composite `tempo_range` type.

  Unlike `interval_to_range/1`, this variant accepts Tempo
  endpoints the plain `tstzrange` encoder rejects — qualifications,
  non-Gregorian calendars, multi-valued slots, and endpoints still
  carrying week or day-of-year tokens — because the composite's
  `meta` column carries the original
  shape losslessly. The range is still populated from the
  materialised endpoints so Postgres range-operator queries work.

  Endpoints are materialised via `Tempo.to_interval/1` where
  needed to produce usable DateTime bounds.
  """
  @spec interval_to_queryable_range(Tempo.Interval.t()) ::
          {:ok, Postgrex.Range.t()} | {:error, UnsupportedValueError.t()}
  def interval_to_queryable_range(%Tempo.Interval{} = interval) do
    with {:ok, lower} <- queryable_endpoint(interval.from),
         {:ok, upper} <- queryable_endpoint(interval.to) do
      {:ok,
       %Postgrex.Range{
         lower: lower,
         upper: upper,
         lower_inclusive: true,
         upper_inclusive: false
       }}
    end
  end

  defp queryable_endpoint(:undefined), do: {:ok, :unbound}
  defp queryable_endpoint(nil), do: {:ok, :unbound}

  defp queryable_endpoint(%Tempo{} = tempo) do
    case Tempo.to_interval(tempo) do
      {:ok, %Tempo.Interval{from: %Tempo{} = materialised}} ->
        tempo_to_datetime(materialised)

      _ ->
        tempo_to_datetime(tempo)
    end
  end

  defp queryable_endpoint(%Tempo.Duration{}) do
    {:error,
     UnsupportedValueError.exception(
       reason: :unsupported_endpoint,
       message: "cannot derive a queryable range bound from a Tempo.Duration alone"
     )}
  end

  @doc """
  Convert a `%Postgrex.Range{}` back into a `t:Tempo.Interval.t/0`.

  Unlike discrete range types (`int4range`, `daterange`), PostgreSQL
  does **not** canonicalise `tstzrange` to `[lower, upper)` on
  output — a range written as `[a, b]` round-trips as `[a, b]`.
  This loader therefore normalises any non-half-open range to
  Tempo's `[first, last)` convention by shifting the offending
  endpoint one second:

    * `[a, b]`  → `[a,         b + 1s)`
    * `(a, b)`  → `[a + 1s,    b)`
    * `(a, b]`  → `[a + 1s,    b + 1s)`

  Tempo is second-resolution so the shift is exact — the loaded
  interval covers the same instants as the stored range.

  ### Options

    * `:resolution` truncates both endpoints to the given
      component, dropping all sub-components. Must be one of
      `:year`, `:month`, `:day`, `:hour`, `:minute`, or `:second`.
      Defaults to `:second` (no truncation). See the storage
      contract guide for semantics.

  """
  @spec range_to_interval(Postgrex.Range.t(), keyword()) ::
          {:ok, Tempo.Interval.t()} | {:error, UnsupportedValueError.t()}
  def range_to_interval(range, options \\ [])

  def range_to_interval(%Postgrex.Range{} = range, options) do
    resolution = Keyword.get(options, :resolution, :second)

    with {:ok, normalised} <- normalise_brackets(range),
         {:ok, from} <- datetime_to_endpoint(normalised.lower, resolution),
         {:ok, to} <- datetime_to_endpoint(normalised.upper, resolution) do
      Interval.new(from: from, to: to)
    end
  end

  defp normalise_brackets(%Postgrex.Range{} = range) do
    lower = shift_lower_to_inclusive(range.lower, range.lower_inclusive)
    upper = shift_upper_to_exclusive(range.upper, range.upper_inclusive)

    {:ok,
     %{
       lower: lower,
       upper: upper,
       lower_inclusive: true,
       upper_inclusive: false
     }}
  end

  defp shift_lower_to_inclusive(:unbound, _), do: :unbound
  defp shift_lower_to_inclusive(nil, _), do: :unbound
  defp shift_lower_to_inclusive(value, true), do: value
  defp shift_lower_to_inclusive(%DateTime{} = dt, false), do: DateTime.add(dt, 1, :second)

  defp shift_lower_to_inclusive(%NaiveDateTime{} = ndt, false),
    do: NaiveDateTime.add(ndt, 1, :second)

  defp shift_upper_to_exclusive(:unbound, _), do: :unbound
  defp shift_upper_to_exclusive(nil, _), do: :unbound
  defp shift_upper_to_exclusive(value, false), do: value
  defp shift_upper_to_exclusive(%DateTime{} = dt, true), do: DateTime.add(dt, 1, :second)

  defp shift_upper_to_exclusive(%NaiveDateTime{} = ndt, true),
    do: NaiveDateTime.add(ndt, 1, :second)

  @doc """
  Validate a `:resolution` option value. Returns the atom
  unchanged or raises `ArgumentError`.
  """
  def validate_resolution!(resolution) when resolution in @resolutions, do: resolution

  def validate_resolution!(other) do
    raise ArgumentError,
          "expected :resolution to be one of #{inspect(@resolutions)}, got: #{inspect(other)}"
  end

  @doc """
  Truncate a `t:Tempo.t/0` token list to the given resolution,
  dropping all sub-resolution components.
  """
  @spec truncate_tempo(Tempo.t(), atom()) :: Tempo.t()
  def truncate_tempo(%Tempo{time: time} = tempo, resolution) do
    %{tempo | time: truncate_time(time, resolution)}
  end

  defp truncate_time(time, resolution) do
    keep =
      @time_components
      |> Enum.take_while(&(&1 != resolution))
      |> Kernel.++([resolution])

    Enum.filter(time, fn {key, _value} -> key in keep end)
  end

  # ------------------------------------------------------------------
  # Endpoint ↔ DateTime
  # ------------------------------------------------------------------

  defp endpoint_to_datetime(:undefined), do: {:ok, :unbound}
  defp endpoint_to_datetime(nil), do: {:ok, :unbound}

  defp endpoint_to_datetime(%Tempo{} = tempo) do
    with :ok <- validate_tempo_shape(tempo) do
      tempo_to_datetime(tempo)
    end
  end

  defp endpoint_to_datetime(other) do
    {:error,
     UnsupportedValueError.exception(
       reason: :unsupported_endpoint,
       value: other,
       message: "interval endpoint must be a %Tempo{}, :undefined, or nil; got #{inspect(other)}"
     )}
  end

  # `normalise_brackets/1` maps a `nil` bound to `:unbound`, so an
  # endpoint reaching here is only ever `:unbound`, a `DateTime`, or a
  # `NaiveDateTime` — a `nil` clause would be unreachable.
  defp datetime_to_endpoint(:unbound, _resolution), do: {:ok, :undefined}

  defp datetime_to_endpoint(%DateTime{} = dt, resolution) do
    {:ok, truncate_tempo(Tempo.from_date_time(dt), resolution)}
  end

  defp datetime_to_endpoint(%NaiveDateTime{} = ndt, resolution) do
    {:ok, truncate_tempo(Tempo.from_naive_date_time(ndt), resolution)}
  end

  defp datetime_to_endpoint(other, _resolution) do
    {:error,
     UnsupportedValueError.exception(
       reason: :unsupported_endpoint,
       value: other,
       message: "cannot interpret range bound #{inspect(other)} as a Tempo endpoint"
     )}
  end

  # Tempo values with no `:shift` are assumed to be UTC — the only
  # safe default when storing a zone-aware range. When `:shift` is
  # set, Tempo does not currently expose a direct `to_date_time/1`
  # helper, so we build the NaiveDateTime from the token list and
  # subtract the shift offset to land on UTC before handing it to
  # Postgrex (which expects UTC DateTimes for tstzrange). Partial
  # Tempo endpoints (year-only, year-month) are filled in with
  # calendar-default zero values — this is correct because Tempo's
  # implicit-span convention means a partial endpoint is always the
  # *start* of its resolution's span.
  defp tempo_to_datetime(%Tempo{shift: nil, time: time}) do
    with {:ok, ndt} <- naive_from_tempo(time) do
      DateTime.from_naive(ndt, "Etc/UTC")
    end
  end

  defp tempo_to_datetime(%Tempo{shift: shift, time: time}) do
    with {:ok, ndt} <- naive_from_tempo(time) do
      offset_seconds = shift_to_seconds(shift)
      utc_ndt = NaiveDateTime.add(ndt, -offset_seconds, :second)
      DateTime.from_naive(utc_ndt, "Etc/UTC")
    end
  end

  defp shift_to_seconds(shift) do
    hours = Keyword.get(shift, :hour, 0)
    minutes = Keyword.get(shift, :minute, 0)
    hours * 3600 + minutes * 60
  end

  # ------------------------------------------------------------------
  # Shape validation
  # ------------------------------------------------------------------

  defp validate_interval_shape(%Tempo.Interval{recurrence: n}) when n != 1 do
    {:error, UnsupportedValueError.exception(reason: :recurrence, value: n)}
  end

  defp validate_interval_shape(%Tempo.Interval{repeat_rule: rule}) when not is_nil(rule) do
    {:error, UnsupportedValueError.exception(reason: :repeat_rule, value: rule)}
  end

  defp validate_interval_shape(%Tempo.Interval{from: :undefined, to: :undefined} = iv) do
    {:error,
     UnsupportedValueError.exception(
       reason: :fully_unbounded,
       value: iv,
       message: "interval is unbounded on both sides; refusing to store a `(,)` range"
     )}
  end

  defp validate_interval_shape(%Tempo.Interval{}), do: :ok

  defp validate_tempo_shape(%Tempo{qualification: q}) when not is_nil(q) do
    {:error, UnsupportedValueError.exception(reason: :qualification, value: q)}
  end

  defp validate_tempo_shape(%Tempo{qualifications: qs}) when not is_nil(qs) and qs != [] do
    {:error, UnsupportedValueError.exception(reason: :qualification, value: qs)}
  end

  defp validate_tempo_shape(%Tempo{calendar: calendar})
       when calendar not in @gregorian_calendars do
    {:error, UnsupportedValueError.exception(reason: :non_gregorian_calendar, value: calendar)}
  end

  defp validate_tempo_shape(%Tempo{time: time} = tempo) do
    cond do
      not has_year_month_day?(time) ->
        {:error, UnsupportedValueError.exception(reason: :partial_resolution, value: tempo)}

      has_multi_valued_slot?(time) ->
        {:error, UnsupportedValueError.exception(reason: :multi_valued_slot, value: tempo)}

      true ->
        :ok
    end
  end

  # Tempo endpoints from `to_interval/1` may carry a span-resolution
  # token list — e.g. a year-only `%Tempo{time: [year: 2026]}`
  # materialises to an Interval whose endpoints are
  # `[year: 2026]` and `[year: 2027]`. Both represent the start of
  # their respective spans (half-open `[from, to)`), so we require
  # at minimum year/month (accepting year-only by filling calendar
  # defaults) and fill hour/minute/second with zeros.
  defp has_year_month_day?(time) do
    Keyword.has_key?(time, :year)
  end

  defp has_multi_valued_slot?(time) do
    Enum.any?(time, fn
      {_, value} when is_integer(value) -> false
      {_, _} -> true
    end)
  end

  defp naive_from_tempo(time) do
    year = Keyword.fetch!(time, :year)
    month = Keyword.get(time, :month, 1)
    day = Keyword.get(time, :day, 1)
    hour = Keyword.get(time, :hour, 0)
    minute = Keyword.get(time, :minute, 0)
    second = Keyword.get(time, :second, 0)

    # Ordinal date (`year + day`) and week date (`year + week + day_of_week`)
    # require calendar conversion — reject them here; callers must
    # materialise them via `Tempo.to_date/1` first.
    if Keyword.has_key?(time, :week) or
         (Keyword.has_key?(time, :day) and not Keyword.has_key?(time, :month)) do
      {:error,
       UnsupportedValueError.exception(
         reason: :partial_resolution,
         value: time,
         message:
           "ordinal or week-date Tempo endpoints must be materialised to a calendar date before storage"
       )}
    else
      NaiveDateTime.new(year, month, day, hour, minute, second, {0, 0})
    end
  end
end
