defmodule Tempo.SQL.UnsupportedValueError do
  @moduledoc """
  Returned when a Tempo expression cannot be stored in a PostgreSQL
  range type, its `:reason` saying why.

  See the storage contract guide for the full list of cases. The
  reasons are `:qualification` (an uncertain or approximate value),
  `:non_gregorian_calendar`, `:multi_valued_slot` (several spans where
  a range holds one), `:partial_resolution` (a value with no year),
  `:fully_unbounded` (`../..`), `:open_ended_member` (a recurrence
  with no end, where a multirange needs a last span) and
  `:unsupported_endpoint` (a range bound, or a stretch, with no place
  on the time line).

  """

  defexception [:reason, :value, :message]

  @type t :: %__MODULE__{
          reason: atom(),
          value: term(),
          message: String.t()
        }

  @impl true
  def exception(fields) do
    reason = Keyword.fetch!(fields, :reason)
    value = Keyword.get(fields, :value)
    message = Keyword.get(fields, :message) || default_message(reason, value)

    %__MODULE__{reason: reason, value: value, message: message}
  end

  defp default_message(:qualification, _) do
    "qualified Tempo values (uncertain/approximate) cannot be stored in a PostgreSQL range"
  end

  defp default_message(:non_gregorian_calendar, _) do
    "non-Gregorian calendars are not supported for PostgreSQL range storage"
  end

  defp default_message(:multi_valued_slot, _) do
    "a Tempo expression of several spans cannot be stored in one PostgreSQL range"
  end

  defp default_message(:partial_resolution, _) do
    "a Tempo value with no year has no instant to store"
  end

  defp default_message(:open_ended_member, _) do
    "a Tempo expression with no end has no last span to store in a tstzmultirange"
  end

  defp default_message(reason, value) do
    "Tempo value cannot be stored in a PostgreSQL range (#{reason}): #{inspect(value)}"
  end
end
