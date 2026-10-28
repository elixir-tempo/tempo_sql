defmodule Tempo.SQL.GuidesTest do
  # The guide's examples that need no database run as doctests, so its
  # claims are checked against the code on every test run.
  use ExUnit.Case, async: true

  doctest_file("guides/storage-contract.md")
end
