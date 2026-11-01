defmodule Tempo.SQL.SQLite.Document do
  @moduledoc """
  The JSON document a SQLite column holds for a Tempo expression.

  SQLite has no range type, so `Tempo.Ecto.SQLite.TempoRange` stores an
  expression as one `TEXT` value holding a JSON object: the expression
  whole, as the PostgreSQL composite types keep it, beside the integer
  bounds of the time it covers.

      {"v": 1, "frame": "utc", "lo": 1781514000, "hi": 1781517600,
       "spans": [[1781514000, 1781517600]],
       "meta": {"expression": "2026Y6M15DT9H0MZ/T10H0MZ", ...}}

  * `lo` and `hi` are the half-open bounds of the stretch the expression
    covers, from the start of its first span to the end of its last, in
    whole seconds: since the Unix epoch at UTC for a column on the UTC
    frame, and since 1970-01-01T00:00 on the wall clock for a floating
    one. A bound with a fraction of a second is rounded outward, so the
    bounds always cover the expression. An open end is the least or the
    greatest 64-bit integer.

  * `spans` are the bounds of each span the expression has, in order. A
    recurrence with no end has its stretch alone.

  * `meta` is the document `Tempo.SQL.Meta` writes, from which the
    expression is read back as it was written.

  `encode/2` writes the document, `decode/1` reads the expression back,
  and `bounds/2` gives the bounds alone, for a query's probe.

  """

  alias Tempo.SQL.Conversion
  alias Tempo.SQL.JSON, as: StorageJSON
  alias Tempo.SQL.Meta
  alias Tempo.SQL.UnsupportedValueError

  @version 1
  @least -9_223_372_036_854_775_808
  @greatest 9_223_372_036_854_775_807
  @epoch ~N[1970-01-01 00:00:00]
  @microseconds_in_a_second 1_000_000

  @typedoc "A bound in whole seconds on a column's frame."
  @type bound() :: integer()

  @doc """
  Writes the document a SQLite column holds for an expression.

  ### Arguments

  * `expression` is a `t:Tempo.t/0` with ISO 8601 text and a place on
    the time line.

  * `frame` is `:utc` (the default) or `:floating`, the column's frame.

  ### Returns

  * `{:ok, json}`, the document as a binary.

  * `{:error, exception}` where `exception` is a
    `t:Tempo.SQL.UnsupportedValueError.t/0` for an expression with no
    place on the time line or of the other frame (the reason `:frame`),
    or the error `Tempo.to_iso8601/1` returns.

  ### Examples

      iex> {:ok, json} = Tempo.SQL.SQLite.Document.encode(~o"2026-06-15T09:00Z/2026-06-15T10:00Z")
      iex> document = Tempo.SQL.JSON.decode!(json)
      iex> {document["lo"], document["hi"]}
      {1781514000, 1781517600}

      iex> {:error, error} = Tempo.SQL.SQLite.Document.encode(~o"2026-06-15T09:00/2026-06-15T10:00")
      iex> error.reason
      :frame

  """
  @spec encode(Tempo.t(), Conversion.frame()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(expression, frame \\ :utc)

  def encode(%Tempo{} = expression, frame) do
    with {:ok, {lower, upper}} <- bounds(expression, frame),
         {:ok, spans} <- spans(expression, frame, [lower, upper]),
         {:ok, meta} <- meta_document(expression) do
      document = %{
        "v" => @version,
        "frame" => Atom.to_string(frame),
        "lo" => lower,
        "hi" => upper,
        "spans" => spans,
        "meta" => meta
      }

      {:ok, Meta.encode_json(document)}
    end
  end

  def encode(other, _frame) do
    {:error, UnsupportedValueError.exception(reason: :unsupported_endpoint, value: other)}
  end

  @doc """
  Reads back the expression a SQLite column's document holds.

  ### Arguments

  * `json` is the document, as `encode/2` writes it.

  ### Returns

  * `{:ok, expression}`, a `t:Tempo.t/0`, as it was written.

  * `{:error, reason}` for a document that is not JSON, not of this
    shape, or whose expression cannot be read.

  ### Examples

      iex> {:ok, json} = Tempo.SQL.SQLite.Document.encode(~o"2026-06", :floating)
      iex> Tempo.SQL.SQLite.Document.decode(json)
      {:ok, ~o"2026-06"}

      iex> {:error, {:invalid_document, _}} = Tempo.SQL.SQLite.Document.decode(~s({"v": 9}))

  """
  @spec decode(binary()) :: {:ok, Tempo.t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case StorageJSON.decode(json) do
      {:ok, %{"v" => @version, "meta" => %{} = meta}} -> Meta.decode_interval(meta)
      {:ok, other} -> {:error, {:invalid_document, other}}
      {:error, _exception} = error -> error
    end
  end

  def decode(other) do
    {:error, {:invalid_document, other}}
  end

  @doc """
  The half-open bounds of the stretch an expression covers, in whole
  seconds on a frame.

  ### Arguments

  * `expression` is a `t:Tempo.t/0` with a place on the time line.

  * `frame` is `:utc` (the default) or `:floating`.

  ### Returns

  * `{:ok, {lower, upper}}`, each an integer, an open end the least or
    the greatest 64-bit integer.

  * `{:error, exception}` as `Tempo.SQL.Conversion.interval_to_queryable_range/2`
    returns it.

  ### Examples

      iex> Tempo.SQL.SQLite.Document.bounds(~o"2026-06-15/2026-06-16", :floating)
      {:ok, {1781481600, 1781654400}}

      iex> Tempo.SQL.SQLite.Document.bounds(~o"2026-06-15T09:00Z/..")
      {:ok, {1781514000, 9223372036854775807}}

  """
  @spec bounds(Tempo.t(), Conversion.frame()) ::
          {:ok, {bound(), bound()}} | {:error, Exception.t()}
  def bounds(expression, frame \\ :utc)

  def bounds(%Tempo{} = expression, frame) do
    with {:ok, range} <- Conversion.interval_to_queryable_range(expression, frame) do
      {:ok, {lower(range.lower), upper(range.upper)}}
    end
  end

  def bounds(other, _frame) do
    {:error, UnsupportedValueError.exception(reason: :unsupported_endpoint, value: other)}
  end

  # The document `Tempo.SQL.Meta` writes, as a term to embed.
  defp meta_document(expression) do
    with {:ok, meta} <- Meta.encode_interval(expression) do
      meta
      |> IO.iodata_to_binary()
      |> StorageJSON.decode()
    end
  end

  # The bounds of each span, or the stretch alone for an expression whose
  # spans have no end (a recurrence with no end).
  defp spans(expression, frame, stretch) do
    case Conversion.intervals(expression) do
      {:ok, intervals} -> each_span(intervals, frame, [])
      {:error, _no_last_span} -> {:ok, [stretch]}
    end
  end

  defp each_span([], _frame, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp each_span([interval | rest], frame, acc) do
    case bounds(interval, frame) do
      {:ok, {lower, upper}} -> each_span(rest, frame, [[lower, upper] | acc])
      {:error, _} = error -> error
    end
  end

  defp lower(:unbound) do
    @least
  end

  defp lower(instant) do
    instant
    |> microseconds()
    |> Integer.floor_div(@microseconds_in_a_second)
  end

  defp upper(:unbound) do
    @greatest
  end

  defp upper(instant) do
    microseconds = microseconds(instant)
    -Integer.floor_div(-microseconds, @microseconds_in_a_second)
  end

  defp microseconds(%DateTime{} = instant) do
    DateTime.to_unix(instant, :microsecond)
  end

  defp microseconds(%NaiveDateTime{} = instant) do
    NaiveDateTime.diff(instant, @epoch, :microsecond)
  end
end
