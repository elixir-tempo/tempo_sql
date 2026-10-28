defmodule Tempo.SQL.Conversion do
  @moduledoc """
  Internal helpers that translate between Tempo intervals and the
  `DateTime` / `:unbound` values that `Postgrex.Range` understands.

  The storage contract this module enforces — see the README for
  the full rationale:

    * An interval is stored as the instants it runs between
      (`Tempo.Interval.instants/1`): from the instant it begins to
      the instant it ends, half-open. An end written to a date is read
      through it, so `2026-06-15/2026-06-20` is stored up to the 21st.

    * A value with no zone is stored as though at UTC.

    * Qualifications (`:uncertain`, `:approximate`) and calendars other
      than the Gregorian are rejected by the plain types, which cannot
      keep them; the composite types keep them in their `meta` column.

    * A recurrence, or anything else of several spans, is stored by
      `Tempo.Ecto.IntervalSet` as a `tstzmultirange`, not by the plain
      interval types.

  """

  alias Tempo.Interval
  alias Tempo.IntervalSet
  alias Tempo.SQL.UnsupportedValueError

  @gregorian_calendars [Calendar.ISO, Calendrical.Gregorian]
  @resolutions [:year, :month, :day, :hour, :minute, :second]
  @clock_resolutions [:hour, :minute, :second]

  @doc """
  Returns the valid values for the `:resolution` option on the Ecto
  types.

  ### Returns

  * A list of resolution atoms, coarsest first.

  ### Examples

      iex> Tempo.SQL.Conversion.valid_resolutions()
      [:year, :month, :day, :hour, :minute, :second]

  """
  def valid_resolutions do
    @resolutions
  end

  @doc """
  Converts an interval into a `%Postgrex.Range{}` with `DateTime`
  bounds in UTC.

  The range is half-open — lower inclusive, upper exclusive — from the
  instant the interval begins to the instant it ends, so no boundary is
  gained or lost in storage.

  ### Arguments

  * `interval` is a `t:Tempo.t/0` interval.

  ### Returns

  * `{:ok, range}` where `range` is a `t:Postgrex.Range.t/0`.

  * `{:error, exception}` where `exception` is a
    `t:Tempo.SQL.UnsupportedValueError.t/0`, when the interval holds
    something a `tstzrange` cannot — see the storage-contract guide.

  ### Examples

      iex> workday = Tempo.Interval.new!(
      ...>   from: ~o"2027-06-15T09:00:00",
      ...>   to: ~o"2027-06-15T17:00:00"
      ...> )
      iex> {:ok, range} = Tempo.SQL.Conversion.interval_to_range(workday)
      iex> {range.lower, range.upper}
      {~U[2027-06-15 09:00:00Z], ~U[2027-06-15 17:00:00Z]}
      iex> {range.lower_inclusive, range.upper_inclusive}
      {true, false}

      iex> {:ok, range} = Tempo.SQL.Conversion.interval_to_range(~o"2027-06-15/2027-06-20")
      iex> {range.lower, range.upper}
      {~U[2027-06-15 00:00:00Z], ~U[2027-06-21 00:00:00Z]}

      iex> {:error, error} = Tempo.SQL.Conversion.interval_to_range(~o"1984?/2004")
      iex> error.reason
      :qualification

  """
  @spec interval_to_range(Tempo.t()) ::
          {:ok, Postgrex.Range.t()} | {:error, UnsupportedValueError.t()}
  def interval_to_range(%Tempo{} = interval) do
    with {:ok, span} <- one_span(interval),
         :ok <- plain(span),
         {:ok, {from, to}} <- span_instants(span, interval),
         :ok <- bounded_somewhere(interval, from, to),
         {:ok, lower} <- utc(from),
         {:ok, upper} <- utc(to) do
      {:ok, half_open(lower, upper)}
    end
  end

  @doc """
  Converts any expression into a `%Postgrex.Range{}` tolerant enough
  for the composite `tempo_range` type.

  Unlike `interval_to_range/1`, this accepts what the plain `tstzrange`
  encoder rejects — qualifications, calendars other than the Gregorian,
  values that name several, recurrences — because the composite's
  `meta` column carries the expression losslessly. The range is the
  stretch the expression covers, from its first instant to its last, so
  Postgres range operators still find it.

  ### Arguments

  * `expression` is a `t:Tempo.t/0`.

  ### Returns

  * `{:ok, range}` where `range` is a `t:Postgrex.Range.t/0`. An open
    end, or a recurrence with no end, becomes `:unbound`, so it is still
    queryable.

  * `{:error, exception}` when the expression has no place on the time
    line at all — a bare duration, a value with no year, a span open at
    both ends, or a recurrence counted back with no start.

  ### Examples

      iex> workday = Tempo.Interval.new!(
      ...>   from: ~o"2027-06-15T09:00:00",
      ...>   to: ~o"2027-06-15T17:00:00"
      ...> )
      iex> {:ok, range} = Tempo.SQL.Conversion.interval_to_queryable_range(workday)
      iex> range.upper
      ~U[2027-06-15 17:00:00Z]

  An open-ended interval keeps a usable lower bound:

      iex> {:ok, range} = Tempo.SQL.Conversion.interval_to_queryable_range(~o"2027-06-15T09:00:00/..")
      iex> {range.lower, range.upper}
      {~U[2027-06-15 09:00:00Z], :unbound}

  """
  @spec interval_to_queryable_range(Tempo.t() | Tempo.Duration.t()) ::
          {:ok, Postgrex.Range.t()} | {:error, UnsupportedValueError.t()}
  def interval_to_queryable_range(%Tempo.Duration{} = duration) do
    {:error,
     UnsupportedValueError.exception(
       reason: :unsupported_endpoint,
       value: duration,
       message: "cannot derive a queryable range from a Tempo.Duration alone"
     )}
  end

  def interval_to_queryable_range(%Tempo{} = expression) do
    with {:ok, {from, to}} <- stretch(expression),
         :ok <- bounded_somewhere(expression, from, to),
         {:ok, lower} <- utc(from),
         {:ok, upper} <- utc(to) do
      {:ok, half_open(lower, upper)}
    end
  end

  @doc """
  Convert a `%Postgrex.Range{}` back into an interval.

  Unlike discrete range types (`int4range`, `daterange`), PostgreSQL
  does **not** canonicalise `tstzrange` to `[lower, upper)` on
  output — a range written as `[a, b]` round-trips as `[a, b]`.
  This loader therefore normalises any non-half-open range to
  `[lower, upper)` by shifting the offending endpoint one second:

    * `[a, b]`  → `[a,         b + 1s)`
    * `(a, b)`  → `[a + 1s,    b)`
    * `(a, b]`  → `[a + 1s,    b + 1s)`

  ### Arguments

  * `range` is the `t:Postgrex.Range.t/0` to convert.

  * `options` is a keyword list of options.

  ### Options

  * `:resolution` truncates both endpoints to the given component,
    dropping all sub-components. Must be one of `:year`, `:month`,
    `:day`, `:hour`, `:minute`, or `:second`. Defaults to `:second`
    (no truncation). An end at a date resolution is read through it,
    so the range's upper bound becomes the last day, month or year it
    holds. See the storage contract guide for semantics.

  ### Returns

  * `{:ok, interval}` where `interval` is a `t:Tempo.t/0` interval.

  * `{:error, exception}` when an endpoint is not a time, or when
    truncating to the requested resolution leaves the interval ending
    before it begins.

  ### Examples

      iex> range = %Postgrex.Range{
      ...>   lower: ~U[2027-06-15 09:00:00Z],
      ...>   upper: ~U[2027-06-15 17:00:00Z],
      ...>   lower_inclusive: true,
      ...>   upper_inclusive: false
      ...> }
      iex> {:ok, interval} = Tempo.SQL.Conversion.range_to_interval(range)
      iex> {Tempo.hour(Tempo.Interval.from(interval)), Tempo.hour(Tempo.Interval.to(interval))}
      {9, 17}

  A range of whole days loaded at the day is the days it holds:

      iex> days = %Postgrex.Range{
      ...>   lower: ~U[2027-06-15 00:00:00Z],
      ...>   upper: ~U[2027-06-21 00:00:00Z],
      ...>   lower_inclusive: true,
      ...>   upper_inclusive: false
      ...> }
      iex> Tempo.SQL.Conversion.range_to_interval(days, resolution: :day)
      {:ok, ~o"2027Y6M15DZ/2027Y6M20DZ"}

  """
  @spec range_to_interval(Postgrex.Range.t(), keyword()) ::
          {:ok, Tempo.t()} | {:error, Exception.t()}
  def range_to_interval(range, options \\ [])

  def range_to_interval(%Postgrex.Range{} = range, options) do
    resolution = Keyword.get(options, :resolution, :second)
    lower = shift_lower_to_inclusive(range.lower, range.lower_inclusive)
    upper = shift_upper_to_exclusive(range.upper, range.upper_inclusive)

    with {:ok, from} <- lower_end(lower, resolution),
         {:ok, to} <- upper_end(upper, resolution) do
      Interval.new(from: from, to: to)
    end
  end

  @doc """
  Validates a `:resolution` option value.

  ### Arguments

  * `resolution` is the value to validate.

  ### Returns

  * The resolution atom unchanged, when it is one of those returned by
    `valid_resolutions/0`.

  * Raises `ArgumentError` otherwise, naming the value it was given.

  ### Examples

      iex> Tempo.SQL.Conversion.validate_resolution!(:day)
      :day

      iex> Tempo.SQL.Conversion.validate_resolution!(:fortnight)
      ** (ArgumentError) expected :resolution to be one of [:year, :month, :day, :hour, :minute, :second], got: :fortnight

  """
  def validate_resolution!(resolution) when resolution in @resolutions do
    resolution
  end

  def validate_resolution!(other) do
    raise ArgumentError,
          "expected :resolution to be one of #{inspect(@resolutions)}, got: #{inspect(other)}"
  end

  @doc """
  Truncates a value to the given resolution, dropping all finer
  components.

  ### Arguments

  * `tempo` is the `t:Tempo.t/0` value to truncate.

  * `resolution` is the coarsest component to keep — one of those
    returned by `valid_resolutions/0`.

  ### Returns

  * A `t:Tempo.t/0`. A value already coarser than the requested
    resolution is returned unchanged.

  ### Examples

      iex> Tempo.SQL.Conversion.truncate_tempo(~o"2027-06-15T09:30:45", :day)
      ~o"2027Y6M15D"

      iex> Tempo.SQL.Conversion.truncate_tempo(~o"2027Y", :second)
      ~o"2027Y"

  """
  @spec truncate_tempo(Tempo.t(), atom()) :: Tempo.t()
  def truncate_tempo(%Tempo{} = tempo, resolution) do
    case Tempo.trunc(tempo, resolution) do
      {:ok, truncated} -> truncated
      {:error, _} -> tempo
    end
  end

  @doc """
  The one interval an expression is: an interval itself, or a value as
  the interval it names.

  ### Arguments

  * `expression` is a `t:Tempo.t/0`.

  ### Returns

  * `{:ok, interval}`, a `t:Tempo.t/0` interval.

  * `{:error, exception}` for an expression of several spans (a value
    naming several, a recurrence, a set) or with none.

  ### Examples

      iex> Tempo.SQL.Conversion.as_interval(~o"2027-06")
      {:ok, ~o"2027-06/2027-06"}

      iex> {:error, error} = Tempo.SQL.Conversion.as_interval(~o"R3/2027-06-01/P1D")
      iex> error.reason
      :multi_valued_slot

  """
  @spec as_interval(Tempo.t()) :: {:ok, Tempo.t()} | {:error, UnsupportedValueError.t()}
  def as_interval(%Tempo{} = expression) do
    one_span(expression)
  end

  @doc """
  The intervals an expression covers, each a span, in order.

  ### Arguments

  * `expression` is a `t:Tempo.t/0` with a last span.

  ### Returns

  * `{:ok, intervals}`, a list of `t:Tempo.t/0` intervals.

  * `{:error, exception}` for an expression with no end or no spans.

  ### Examples

      iex> Tempo.SQL.Conversion.intervals(~o"R2/2027-06-01/P1D")
      {:ok, [~o"2027-06-01/2027-06-01", ~o"2027-06-02/2027-06-02"]}

  """
  @spec intervals(Tempo.t()) :: {:ok, [Tempo.t()]} | {:error, UnsupportedValueError.t()}
  def intervals(%Tempo{} = expression) do
    case Tempo.to_interval(expression) do
      {:ok, interval} -> {:ok, IntervalSet.members(interval)}
      {:error, exception} -> {:error, unsupported(:open_ended_member, expression, exception)}
    end
  end

  # ------------------------------------------------------------------
  # Interval → instants
  # ------------------------------------------------------------------

  # The one span an expression is: a value is its span, and one naming
  # several (`2026Y{6,8}M`), or a recurrence, is none.
  defp one_span(%Tempo{} = expression) do
    case Tempo.to_interval(expression) do
      {:ok, interval} -> only_span(IntervalSet.members(interval), expression)
      {:error, exception} -> {:error, unsupported(:partial_resolution, expression, exception)}
    end
  end

  defp only_span([span], _expression) do
    {:ok, span}
  end

  defp only_span(_several, expression) do
    {:error, unsupported(:multi_valued_slot, expression)}
  end

  defp span_instants(span, original) do
    case Interval.instants(span) do
      {:ok, instants} ->
        {:ok, instants}

      {:error, %Tempo.ConversionError{reason: :several}} ->
        {:error, unsupported(:multi_valued_slot, original)}

      {:error, exception} ->
        {:error, unsupported(:partial_resolution, original, exception)}
    end
  end

  # The stretch an expression covers: its spans' first start to their last
  # end, an open end unbound; one with no end from its first occurrence.
  defp stretch(%Tempo{} = expression) do
    case Tempo.to_interval(expression) do
      {:ok, interval} -> spans_stretch(IntervalSet.members(interval), expression)
      {:error, %Tempo.ConversionError{reason: :unbounded}} -> first_onward(expression)
      {:error, exception} -> {:error, unsupported(:unsupported_endpoint, expression, exception)}
    end
  end

  defp spans_stretch(spans, expression) do
    case all_instants(spans) do
      {:ok, pairs} ->
        {:ok, {earliest(Enum.map(pairs, &elem(&1, 0))), latest(Enum.map(pairs, &elem(&1, 1)))}}

      {:error, exception} ->
        {:error, unsupported(:unsupported_endpoint, expression, exception)}
    end
  end

  # An expression with no end has a first occurrence only where it has a
  # start, which `Tempo.walk/2` asks: it refuses one with an open start, a
  # recurrence counted back from no end.
  defp first_onward(expression) do
    with {:ok, _walk} <- started(expression),
         {:ok, interval} <- Tempo.to_interval(IntervalSet.first(expression)),
         {:ok, {from, _to}} <- spans_stretch(IntervalSet.members(interval), expression) do
      {:ok, {from, nil}}
    end
  end

  defp started(expression) do
    case Tempo.walk(expression, :day) do
      {:ok, walk} -> {:ok, walk}
      {:error, exception} -> {:error, unsupported(:unsupported_endpoint, expression, exception)}
    end
  end

  defp all_instants(spans) do
    Enum.reduce_while(spans, {:ok, []}, fn span, {:ok, acc} ->
      case Interval.instants(span) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The first of instants, or none where one of them is open.
  defp earliest(instants) do
    if nil in instants do
      nil
    else
      Enum.min_by(instants, &utc_ticks/1, fn -> nil end)
    end
  end

  defp latest(instants) do
    if nil in instants do
      nil
    else
      Enum.max_by(instants, &utc_ticks/1, fn -> nil end)
    end
  end

  defp utc_ticks(instant) do
    {:ok, utc} = utc(instant)
    DateTime.to_unix(utc, :microsecond)
  end

  # An instant with no zone is stored as though at UTC; one of another
  # calendar is stored as the Gregorian instant it is.
  defp utc(nil) do
    {:ok, :unbound}
  end

  defp utc(%NaiveDateTime{} = naive) do
    with {:ok, iso} <- NaiveDateTime.convert(naive, Calendar.ISO),
         do: DateTime.from_naive(iso, "Etc/UTC")
  end

  defp utc(%DateTime{} = datetime) do
    with {:ok, iso} <- DateTime.convert(datetime, Calendar.ISO),
         do: DateTime.shift_zone(iso, "Etc/UTC")
  end

  defp half_open(lower, upper) do
    %Postgrex.Range{lower: lower, upper: upper, lower_inclusive: true, upper_inclusive: false}
  end

  # ------------------------------------------------------------------
  # Shape validation
  # ------------------------------------------------------------------

  # A plain range holds instants and nothing else: a qualification or a
  # calendar of its own would be lost.
  defp plain(%Tempo{calendar: calendar} = interval) do
    cond do
      qualified?(interval) ->
        {:error, UnsupportedValueError.exception(reason: :qualification, value: interval)}

      calendar not in @gregorian_calendars ->
        {:error,
         UnsupportedValueError.exception(reason: :non_gregorian_calendar, value: calendar)}

      true ->
        :ok
    end
  end

  defp qualified?(%Tempo{} = span) do
    {from, to} = Interval.endpoints(span)

    not is_nil(Tempo.qualification(span)) or
      Enum.any?([from, to], &(match?(%Tempo{}, &1) and not is_nil(Tempo.qualification(&1))))
  end

  defp bounded_somewhere(interval, nil, nil) do
    {:error,
     UnsupportedValueError.exception(
       reason: :fully_unbounded,
       value: interval,
       message: "interval is unbounded on both sides; refusing to store a `(,)` range"
     )}
  end

  defp bounded_somewhere(_interval, _from, _to) do
    :ok
  end

  defp unsupported(reason, value, cause \\ nil) do
    message =
      if cause do
        Exception.message(cause)
      end

    UnsupportedValueError.exception(reason: reason, value: value, message: message)
  end

  # ------------------------------------------------------------------
  # Range bounds → interval ends
  # ------------------------------------------------------------------

  defp shift_lower_to_inclusive(bound, _inclusive) when bound in [:unbound, nil] do
    :unbound
  end

  defp shift_lower_to_inclusive(value, true) do
    value
  end

  defp shift_lower_to_inclusive(%DateTime{} = dt, false) do
    DateTime.add(dt, 1, :second)
  end

  defp shift_lower_to_inclusive(%NaiveDateTime{} = ndt, false) do
    NaiveDateTime.add(ndt, 1, :second)
  end

  defp shift_upper_to_exclusive(bound, _inclusive) when bound in [:unbound, nil] do
    :unbound
  end

  defp shift_upper_to_exclusive(value, false) do
    value
  end

  defp shift_upper_to_exclusive(%DateTime{} = dt, true) do
    DateTime.add(dt, 1, :second)
  end

  defp shift_upper_to_exclusive(%NaiveDateTime{} = ndt, true) do
    NaiveDateTime.add(ndt, 1, :second)
  end

  # The value a lower bound begins, truncated to the resolution.
  defp lower_end(:unbound, _resolution) do
    {:ok, :open}
  end

  defp lower_end(bound, resolution) do
    with {:ok, value} <- bound_value(bound), do: Tempo.trunc(value, resolution)
  end

  # The end an upper bound makes: at a clock resolution the bound itself,
  # where the interval ends; at a date resolution the last date before it,
  # which the interval runs through.
  defp upper_end(:unbound, _resolution) do
    {:ok, :open}
  end

  defp upper_end(bound, resolution) when resolution in @clock_resolutions do
    with {:ok, value} <- bound_value(bound), do: Tempo.trunc(value, resolution)
  end

  defp upper_end(bound, resolution) do
    with {:ok, value} <- bound_value(bound),
         {:ok, truncated} <- Tempo.trunc(value, resolution),
         do: Tempo.shift(truncated, [{resolution, -1}])
  end

  # A bound of whole seconds is read as a second, one with a fraction keeps it.
  defp bound_value(%{microsecond: {0, _precision}} = instant)
       when is_struct(instant, DateTime) or is_struct(instant, NaiveDateTime) do
    Tempo.from_elixir(%{instant | microsecond: {0, 0}})
  end

  defp bound_value(%DateTime{} = datetime) do
    Tempo.from_elixir(datetime)
  end

  defp bound_value(%NaiveDateTime{} = naive) do
    Tempo.from_elixir(naive)
  end

  defp bound_value(other) do
    {:error,
     UnsupportedValueError.exception(
       reason: :unsupported_endpoint,
       value: other,
       message: "cannot interpret range bound #{inspect(other)} as a Tempo endpoint"
     )}
  end
end
