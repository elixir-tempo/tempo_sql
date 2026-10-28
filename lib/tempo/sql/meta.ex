defmodule Tempo.SQL.Meta do
  @moduledoc """
  JSON encoding and decoding for the `meta` column of the
  `tempo_range` and `tempo_multirange` composite types.

  The range column of a composite carries the queryable span.
  The `meta` column carries everything else Tempo knows that
  `tstzrange` cannot express — qualifications, non-Gregorian
  calendars, zone identifiers, recurrence rules, metadata, the
  resolution a value is written to, and whether it was written as a
  value or as an interval.

  On store, the meta is a JSON document with this shape:

      %{
        "v"          => 3,
        "expression" => iso8601_string,
        "metadata"   => map,             # must be JSON-serialisable
        "members"    => [map] | null     # each member's, for a set
      }

  The expression is its whole ISO 8601 text, which Tempo reads back
  as it was: every feature ISO 8601, ISO 8601-2 and IXDTF can
  express. An expression with no text (a conditional member, a rule
  read in another calendar, a set read as it is walked) is not
  stored.

  ## Format versions

  Versions 1 and 2 were written by `tempo_sql` 0.2.0 and earlier,
  from Tempo 1.x, and held an interval end by end: `"from"`, `"to"`,
  `"recurrence"`, `"direction"`, `"duration"`, `"repeat_rule"` and
  `"metadata"`, and a set as `"intervals"`, a list of them. Tempo 1.x
  read an interval's `to` as the end it stops before; Tempo 2.0 reads
  an end written to a date through it. So a version 1 or 2 row is read
  as it was written to mean: an end written to a calendar unit is the
  unit before it (`"to": "2022Y1M5D"` is through the 4th), and a
  recurrence is built from its start, its cadence and its count.
  No row needs migrating, and each is written as version 3 when it is
  next stored.

  Version 2 writes `".."` for an explicitly open-ended endpoint and
  `null` for an absent one; version 1 wrote `null` for both and is
  read as open-ended.

  Encoding uses Erlang's built-in `:json` module (OTP 27+);
  the `jsonb` column type handles storage and indexing on the
  Postgres side.

  """

  alias Tempo.Interval
  alias Tempo.IntervalSet
  alias Tempo.RecurrenceSet

  @current_version 3

  # Erlang's :json module uses the `:null` atom for JSON null by
  # default. We configure both encode and decode to use Elixir's
  # `nil` instead, so the rest of the codebase never has to
  # distinguish `:null` from `nil`.
  @decode_options %{null: nil}

  @doc """
  Encoder callback for `:json.encode/2` that treats `nil` as JSON
  null.

  ### Arguments

  * `value` is the term being encoded.

  * `encode` is the encoder function `:json` passes for recursion.

  ### Returns

  * The encoded value as iodata.

  ### Examples

      iex> :json.encode(%{"ends" => nil}, &Tempo.SQL.Meta.nil_aware_encoder/2)
      ...> |> IO.iodata_to_binary()
      ~s({"ends":null})

  """
  @spec nil_aware_encoder(term(), :json.encoder()) :: iodata()
  def nil_aware_encoder(nil, _encode) do
    "null"
  end

  def nil_aware_encoder(value, encode) do
    :json.encode_value(value, encode)
  end

  @doc """
  Returns the decoder options for `:json.decode/3` that map JSON null
  to `nil`.

  ### Returns

  * A map of `:json` decoder options.

  ### Examples

      iex> Tempo.SQL.Meta.decode_options()
      %{null: nil}

  """
  @spec decode_options() :: map()
  def decode_options do
    @decode_options
  end

  @doc """
  Encodes an arbitrary term as a nil-aware JSON binary.

  ### Arguments

  * `term` is any JSON-serialisable term.

  ### Returns

  * The encoded JSON as a binary.

  ### Examples

      iex> Tempo.SQL.Meta.encode_json(%{"hours" => 8})
      ~s({"hours":8})

  """
  @spec encode_json(term()) :: binary()
  def encode_json(term) do
    term
    |> :json.encode(&nil_aware_encoder/2)
    |> IO.iodata_to_binary()
  end

  @doc """
  Decodes a nil-aware JSON binary.

  ### Arguments

  * `binary` is the JSON document to decode.

  ### Returns

  * The decoded term directly — not wrapped in a tuple — with JSON
    null becoming `nil`.

  ### Examples

      iex> Tempo.SQL.Meta.decode_json(~s({"hours":8}))
      %{"hours" => 8}

  """
  @spec decode_json(binary()) :: term()
  def decode_json(binary) when is_binary(binary) do
    {decoded, :ok, _rest} = :json.decode(binary, :ok, @decode_options)
    decoded
  end

  @doc """
  Encodes an expression to a JSON string for storage in a `jsonb`
  column.

  This is what makes the composite types lossless: everything a
  `tstzrange` cannot express — qualifications, calendars, recurrence,
  metadata — is carried here instead.

  ### Arguments

  * `expression` is a `t:Tempo.t/0`.

  ### Returns

  * `{:ok, iodata}`, the encoded document, suitable for handing to
    Postgrex.

  * `{:error, exception}` for an expression with no ISO 8601 text.

  ### Examples

      iex> {:ok, json} = Tempo.SQL.Meta.encode_interval(~o"2027-06-15/2027-06-16")
      iex> json
      ...> |> IO.iodata_to_binary()
      ...> |> Tempo.SQL.Meta.decode_json()
      ...> |> Map.get("expression")
      "2027Y6M15D/16D"

  """
  @spec encode_interval(Tempo.t()) :: {:ok, iodata()} | {:error, Exception.t()}
  def encode_interval(%Tempo{} = expression) do
    with {:ok, text} <- Tempo.to_iso8601(expression) do
      document = %{
        "v" => @current_version,
        "expression" => text,
        "metadata" => Tempo.metadata(expression),
        "members" => members_metadata(expression)
      }

      {:ok, :json.encode(document, &nil_aware_encoder/2)}
    end
  end

  # A set's members each carry their own metadata, which its text does not
  # hold; an expression that is no set is its own one member, and has none.
  defp members_metadata(expression) do
    case RecurrenceSet.members(expression) do
      [^expression] -> nil
      members -> Enum.map(members, &Tempo.metadata/1)
    end
  end

  @doc """
  Decodes a JSON string, or an already-decoded map, back into an
  expression, whichever version wrote it.

  ### Arguments

  * `json` is the encoded document, either as a binary or as the map
    Postgrex hands back from a `jsonb` column.

  ### Returns

  * `{:ok, expression}` where `expression` is a `t:Tempo.t/0`.

  * `{:error, reason}` when the document is none `tempo_sql` wrote
    (`{:invalid_meta_shape, document}`), or holds a field that does not
    decode.

  ### Examples

      iex> {:ok, json} = Tempo.SQL.Meta.encode_interval(~o"1984?/2004~")
      iex> Tempo.SQL.Meta.decode_interval(IO.iodata_to_binary(json))
      {:ok, ~o"1984?/2004~"}

  A row `tempo_sql` 0.2.0 wrote is read as it was written to mean, its
  end the day before the one written:

      iex> Tempo.SQL.Meta.decode_interval(~s({"v":2,"from":"2022Y1M1D","to":"2022Y1M5D","recurrence":1}))
      {:ok, ~o"2022-01-01/2022-01-04"}

      iex> Tempo.SQL.Meta.decode_interval(~s({"from":"2026","to":"2027","direction":7}))
      {:error, {:invalid_direction, 7}}

  """
  @spec decode_interval(String.t() | map()) :: {:ok, Tempo.t()} | {:error, term()}
  def decode_interval(json) when is_binary(json) do
    case :json.decode(json, :ok, @decode_options) do
      {map, :ok, _rest} when is_map(map) -> decode_interval(map)
      {other, :ok, _rest} -> {:error, {:invalid_meta_shape, other}}
    end
  end

  def decode_interval(%{"v" => 3, "expression" => text} = map) when is_binary(text) do
    with {:ok, expression} <- read(text),
         {:ok, expression} <- with_members_metadata(expression, Map.get(map, "members")) do
      {:ok, Tempo.put_metadata(expression, Map.get(map, "metadata") || %{})}
    end
  end

  def decode_interval(%{"intervals" => members} = map) when is_list(members) do
    with {:ok, intervals} <- each(members, &decode_interval/1) do
      IntervalSet.new(intervals, metadata: Map.get(map, "metadata") || %{})
    end
  end

  # Versions 1 and 2 wrote both ends of every interval, `null` where it had none.
  def decode_interval(%{"from" => _from, "to" => _to} = map) do
    decode_written_by_1x(map, Map.get(map, "v", 1))
  end

  def decode_interval(%{} = map) do
    {:error, {:invalid_meta_shape, map}}
  end

  defp read(text) do
    case Tempo.from_iso8601(text) do
      {:ok, %Tempo{} = expression} -> {:ok, expression}
      {:ok, other} -> {:error, {:unexpected_expression, other}}
      {:error, _} = error -> error
    end
  end

  defp with_members_metadata(expression, nil) do
    {:ok, expression}
  end

  defp with_members_metadata(expression, metadata) when is_list(metadata) do
    members = IntervalSet.members(expression)

    if length(members) == length(metadata) do
      members
      |> Enum.zip_with(metadata, &Tempo.put_metadata(&1, &2 || %{}))
      |> IntervalSet.new()
    else
      {:error, {:invalid_members_metadata, metadata}}
    end
  end

  # ------------------------------------------------------------------
  # Versions 1 and 2, written from Tempo 1.x
  # ------------------------------------------------------------------

  defp decode_written_by_1x(map, version) do
    with {:ok, from} <- decode_endpoint(Map.get(map, "from"), version),
         {:ok, to} <- decode_endpoint(Map.get(map, "to"), version),
         {:ok, recurrence} <- decode_recurrence(Map.get(map, "recurrence", 1)),
         {:ok, _direction} <- decode_direction(Map.get(map, "direction", 1)),
         {:ok, duration} <- decode_duration(Map.get(map, "duration")),
         {:ok, rule} <- decode_repeat_rule(Map.get(map, "repeat_rule")),
         {:ok, expression} <- built(from, to, recurrence, duration, rule) do
      {:ok, Tempo.put_metadata(expression, Map.get(map, "metadata") || %{})}
    end
  end

  # An interval, its end read as Tempo 1.x read it: the one it stops before.
  defp built(from, to, 1, duration, nil) do
    with {:ok, to} <- through(to, duration), do: Interval.new(from: from, to: to)
  end

  # A recurrence counted back from its end (`R5/P1M/2022-06-01`).
  defp built(:open, %Tempo{} = to, recurrence, %Tempo.Duration{} = duration, rule) do
    with {:ok, to} <- through(to, nil),
         do: Tempo.every(duration, every_options([to: to], recurrence, rule))
  end

  # A recurrence from its start, of its duration, or of the span from its
  # start to its end (`R3/2022-01-01/2022-01-03` is every two days).
  defp built(%Tempo{} = from, to, recurrence, duration, rule) do
    with {:ok, cadence} <- cadence(from, to, duration),
         do: Tempo.every(cadence, every_options([from: from], recurrence, rule))
  end

  defp built(from, to, recurrence, _duration, _rule) do
    {:error, {:unsupported_recurrence, %{from: from, to: to, recurrence: recurrence}}}
  end

  defp every_options(options, recurrence, rule) do
    options
    |> then(
      &if is_integer(recurrence) do
        Keyword.put(&1, :count, recurrence)
      else
        &1
      end
    )
    |> then(
      &if rule do
        Keyword.put(&1, :select, rule)
      else
        &1
      end
    )
  end

  defp cadence(_from, _to, %Tempo.Duration{} = duration) do
    {:ok, duration}
  end

  defp cadence(from, %Tempo{} = to, nil) do
    Tempo.duration(from, to)
  end

  defp cadence(from, to, nil) do
    {:error, {:unsupported_recurrence, %{from: from, to: to}}}
  end

  # Tempo 1.x read an end as the instant it stops before: an end written
  # to a calendar unit is, in 2.0's reading, the unit before it; an end on
  # the clock is a boundary either way.
  defp through(:open, _duration) do
    {:ok, :open}
  end

  defp through(nil, %Tempo.Duration{} = duration) do
    {:ok, duration}
  end

  defp through(nil, nil) do
    {:ok, :open}
  end

  defp through(%Tempo.Duration{} = duration, _duration) do
    {:ok, duration}
  end

  defp through(%Tempo{} = to, _duration) do
    step = unit_before(Tempo.resolution(to))

    if is_nil(step) do
      {:ok, to}
    else
      Tempo.shift(to, step)
    end
  end

  defp unit_before(unit) when unit in [:year, :month, :week] do
    [{unit, -1}]
  end

  defp unit_before(unit) when unit in [:day, :day_of_week, :day_of_year] do
    [day: -1]
  end

  defp unit_before(_clock_or_other) do
    nil
  end

  defp decode_endpoint("..", _version) do
    {:ok, :open}
  end

  # Version 1 could not distinguish "open-ended" from "absent", and
  # read back as open-ended. Version 2 rows say `..` when they mean
  # open-ended, so a null there is an absent endpoint.
  defp decode_endpoint(nil, 1) do
    {:ok, :open}
  end

  defp decode_endpoint(nil, _version) do
    {:ok, nil}
  end

  defp decode_endpoint(string, _version) when is_binary(string) do
    case Tempo.from_iso8601(string) do
      {:ok, %Tempo{} = tempo} -> {:ok, tempo}
      {:ok, %Tempo.Duration{} = duration} -> {:ok, duration}
      {:error, _} = error -> error
    end
  end

  defp decode_recurrence(n) when is_integer(n) and n > 0 do
    {:ok, n}
  end

  defp decode_recurrence("infinity") do
    {:ok, :infinity}
  end

  defp decode_recurrence(other) do
    {:error, {:invalid_recurrence, other}}
  end

  # Tempo 1.x wrote a direction on every interval. A recurrence counted
  # back was written with an open start and its end, which `built/5`
  # reads; the direction itself changes no span.
  defp decode_direction(direction) when direction in [1, -1] do
    {:ok, direction}
  end

  defp decode_direction(other) do
    {:error, {:invalid_direction, other}}
  end

  defp decode_duration(nil) do
    {:ok, nil}
  end

  defp decode_duration(string) when is_binary(string) do
    case Tempo.from_iso8601(string) do
      {:ok, %Tempo.Duration{} = duration} -> {:ok, duration}
      {:ok, other} -> {:error, {:unexpected_duration_type, other}}
      {:error, _} = error -> error
    end
  end

  defp decode_repeat_rule(nil) do
    {:ok, nil}
  end

  defp decode_repeat_rule(string) when is_binary(string) do
    case Tempo.from_iso8601(string) do
      {:ok, %Tempo{} = selection} -> {:ok, selection}
      {:ok, other} -> {:error, {:unexpected_repeat_rule_type, other}}
      {:error, _} = error -> error
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
