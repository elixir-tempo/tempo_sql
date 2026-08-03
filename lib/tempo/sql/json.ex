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
  def decode!(binary) when is_binary(binary) do
    {decoded, :ok, _rest} = :json.decode(binary, :ok, Meta.decode_options())
    decoded
  end
end
