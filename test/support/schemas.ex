defmodule Tempo.SQL.Test.Meeting do
  @moduledoc false
  use Ecto.Schema

  schema "meetings" do
    field(:name, :string)
    field(:window, Tempo.Ecto.Interval)
  end
end

defmodule Tempo.SQL.Test.Calendar do
  @moduledoc false
  use Ecto.Schema

  schema "calendars" do
    field(:owner, :string)
    field(:busy_times, Tempo.Ecto.IntervalSet)
  end
end

defmodule Tempo.SQL.Test.FidelityMeeting do
  @moduledoc false
  use Ecto.Schema

  schema "fidelity_meetings" do
    field(:name, :string)
    field(:window, Tempo.Ecto.TempoRange)
  end
end

defmodule Tempo.SQL.Test.FidelityCalendar do
  @moduledoc false
  use Ecto.Schema

  schema "fidelity_calendars" do
    field(:owner, :string)
    field(:busy_times, Tempo.Ecto.TempoMultirange)
  end
end

defmodule Tempo.SQL.Test.OpeningHours do
  @moduledoc false
  use Ecto.Schema

  schema "opening_hours" do
    field(:shop, :string)
    field(:hours, Tempo.Ecto.Interval, frame: :floating)
    field(:weekly, Tempo.Ecto.IntervalSet, frame: :floating)
  end
end

defmodule Tempo.SQL.Test.FidelityOpeningHours do
  @moduledoc false
  use Ecto.Schema

  schema "fidelity_opening_hours" do
    field(:shop, :string)
    field(:hours, Tempo.Ecto.TempoRange, frame: :floating)
    field(:weekly, Tempo.Ecto.TempoMultirange, frame: :floating)
  end
end

defmodule Tempo.SQL.Test.SQLiteMeeting do
  @moduledoc false
  use Ecto.Schema

  schema "meetings" do
    field(:name, :string)
    field(:window, Tempo.Ecto.SQLite.TempoRange)
  end
end

defmodule Tempo.SQL.Test.SQLiteShop do
  @moduledoc false
  use Ecto.Schema

  schema "shops" do
    field(:name, :string)
    field(:hours, Tempo.Ecto.SQLite.TempoRange, frame: :floating)
  end
end
