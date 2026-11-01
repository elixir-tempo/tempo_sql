defmodule Tempo.SQL.Test.RepoCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Tempo.SQL.Repo

      alias Tempo.SQL.Test.{
        Calendar,
        FidelityCalendar,
        FidelityMeeting,
        FidelityOpeningHours,
        Meeting,
        OpeningHours
      }

      import Ecto
      import Ecto.Query
      import Tempo.SQL.Test.RepoCase
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Tempo.SQL.Repo)

    unless tags[:async] do
      Sandbox.mode(Tempo.SQL.Repo, {:shared, self()})
    end

    :ok
  end
end
