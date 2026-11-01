defmodule Tempo.SQL.JSON do
  @moduledoc """
  Shim module that adapts Erlang's built-in `:json` (OTP 27+) to
  Postgrex's expected JSON-library interface.

  Postgrex's `jsonb` extension calls
  `library.encode_to_iodata!/1` and `library.decode!/1` (the
  shapes Jason exposes). Erlang's `:json` exposes `encode/2` and
  `decode/3`, so this module bridges the two. It also configures
  `nil` ↔ JSON null translation in both directions, sparing
  application code from the `:null` atom the raw `:json` module
  returns.

  ## Use from Postgrex

      Postgrex.Types.define(MyApp.PostgresTypes, [], json: Tempo.SQL.JSON)

  """

  alias Tempo.SQL.Meta

  @doc """
  Encodes a term as JSON iodata, in the shape Postgrex expects of a
  JSON library.

  ### Arguments

  * `term` is any JSON-serialisable term.

  ### Returns

  * The encoded JSON as iodata. `nil` encodes as JSON `null` rather
    than as the `:null` atom the raw `:json` module uses.

  ### Examples

      iex> Tempo.SQL.JSON.encode_to_iodata!(%{"hours" => 8})
      ...> |> IO.iodata_to_binary()
      ~s({"hours":8})

      iex> Tempo.SQL.JSON.encode_to_iodata!(%{"ends" => nil})
      ...> |> IO.iodata_to_binary()
      ~s({"ends":null})

  """
  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term) do
    :json.encode(term, &Meta.nil_aware_encoder/2)
  end

  @doc """
  Decodes a JSON binary, in the shape Postgrex expects of a JSON
  library.

  ### Arguments

  * `binary` is the JSON document to decode.

  ### Returns

  * The decoded term, with JSON `null` becoming `nil` rather than the
    `:null` atom.

  ### Examples

      iex> Tempo.SQL.JSON.decode!(~s({"hours":8}))
      %{"hours" => 8}

      iex> Tempo.SQL.JSON.decode!(~s({"ends":null}))
      %{"ends" => nil}

  """
  @spec decode!(binary()) :: term()
  def decode!(binary) when is_binary(binary) do
    case decode(binary) do
      {:ok, decoded} -> decoded
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Decodes a JSON binary, returning an error for text that is not one
  JSON document.

  ### Arguments

  * `binary` is the JSON document to decode.

  ### Returns

  * `{:ok, term}`, with JSON `null` becoming `nil`.

  * `{:error, exception}` for text that is not JSON, or that has more
    than whitespace after its document.

  ### Examples

      iex> Tempo.SQL.JSON.decode(~s({"hours":8}))
      {:ok, %{"hours" => 8}}

      iex> {:error, _exception} = Tempo.SQL.JSON.decode(~s({"hours":))

      iex> {:error, %ArgumentError{}} = Tempo.SQL.JSON.decode(~s({"hours":8} and more))

  """
  @spec decode(binary()) :: {:ok, term()} | {:error, Exception.t()}
  def decode(binary) when is_binary(binary) do
    binary
    |> decoded()
    |> whole()
  end

  # `:json` raises on text that is not JSON and has no form that returns an
  # error instead, so this call is where its raise becomes an error.
  defp decoded(binary) do
    {:ok, :json.decode(binary, :ok, Meta.decode_options())}
  rescue
    error in ErlangError -> {:error, error}
  end

  defp whole({:ok, {decoded, :ok, ""}}) do
    {:ok, decoded}
  end

  defp whole({:ok, {_decoded, :ok, rest}}) do
    {:error, ArgumentError.exception("JSON document followed by #{inspect(rest)}")}
  end

  defp whole({:error, _exception} = error) do
    error
  end
end
