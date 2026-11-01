defmodule Tempo.SQL.QueryAPITest do
  @moduledoc """
  The five range operators the query API exposes. Only `contains` and
  `overlaps` were previously exercised; `meets`, `strictly_before` and
  `strictly_after` are the ones a scheduling application reaches for to
  answer *"what butts up against this?"* and *"what comes after it?"*,
  and they were untested in both the plain and composite APIs.
  """

  use Tempo.SQL.Test.RepoCase

  import Tempo.Ecto.QueryAPI
  import Tempo.Sigils

  alias Tempo.Ecto.Interval, as: IntervalType

  defp range(interval) do
    {:ok, range} = IntervalType.dump(interval)
    range
  end

  defp floating_range(interval) do
    {:ok, range} = IntervalType.dump(interval, nil, IntervalType.init(frame: :floating))
    range
  end

  # Three back-to-back-ish meetings: morning and midday *meet* exactly,
  # afternoon sits clear of both.
  defp seed do
    Repo.insert!(%Meeting{
      name: "Morning",
      window: ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"
    })

    Repo.insert!(%Meeting{
      name: "Midday",
      window: ~o"2026-06-15T10:00:00Z/2026-06-15T11:00:00Z"
    })

    Repo.insert!(%Meeting{
      name: "Afternoon",
      window: ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
    })
  end

  defp names(query) do
    query
    |> Repo.all()
    |> Enum.sort()
  end

  describe "meets/2" do
    setup do
      seed()
      :ok
    end

    test "finds the window that abuts another with no gap" do
      # Under the half-open convention, 09:00–10:00 and 10:00–11:00 meet
      # exactly: no overlap, no gap.
      probe = range(~o"2026-06-15T10:00:00Z/2026-06-15T11:00:00Z")

      assert names(from(m in Meeting, where: meets(m.window, ^probe), select: m.name)) ==
               ["Morning"]
    end

    test "a window with a gap does not meet" do
      probe = range(~o"2026-06-15T12:00:00Z/2026-06-15T13:00:00Z")

      assert names(from(m in Meeting, where: meets(m.window, ^probe), select: m.name)) == []
    end

    test "an overlapping window does not meet either" do
      probe = range(~o"2026-06-15T09:30:00Z/2026-06-15T10:30:00Z")

      assert names(from(m in Meeting, where: meets(m.window, ^probe), select: m.name)) == []
    end
  end

  describe "strictly_before/2 and strictly_after/2" do
    setup do
      seed()
      :ok
    end

    test "strictly_before finds windows entirely earlier" do
      probe = range(~o"2026-06-15T13:00:00Z/2026-06-15T14:00:00Z")

      assert names(from(m in Meeting, where: strictly_before(m.window, ^probe), select: m.name)) ==
               ["Midday", "Morning"]
    end

    test "strictly_after finds windows entirely later" do
      probe = range(~o"2026-06-15T09:00:00Z/2026-06-15T09:30:00Z")

      assert names(from(m in Meeting, where: strictly_after(m.window, ^probe), select: m.name)) ==
               ["Afternoon", "Midday"]
    end

    test "a touching window is neither strictly before nor strictly after" do
      probe = range(~o"2026-06-15T10:00:00Z/2026-06-15T11:00:00Z")

      before = names(from(m in Meeting, where: strictly_before(m.window, ^probe), select: m.name))
      later = names(from(m in Meeting, where: strictly_after(m.window, ^probe), select: m.name))

      refute "Midday" in before
      refute "Midday" in later
    end

    test "the two operators are inverses across a disjoint pair" do
      probe = range(~o"2026-06-15T12:00:00Z/2026-06-15T13:00:00Z")

      before = names(from(m in Meeting, where: strictly_before(m.window, ^probe), select: m.name))
      later = names(from(m in Meeting, where: strictly_after(m.window, ^probe), select: m.name))

      assert before == ["Midday", "Morning"]
      assert later == ["Afternoon"]
      assert Enum.sort(before ++ later) == ["Afternoon", "Midday", "Morning"]
    end
  end

  describe "the operators over a floating column" do
    setup do
      Repo.insert!(%OpeningHours{
        shop: "bakery",
        hours: ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"
      })

      Repo.insert!(%OpeningHours{
        shop: "cafe",
        hours: ~o"2026-06-15T13:00:00/2026-06-15T18:00:00"
      })

      Repo.insert!(%OpeningHours{
        shop: "bar",
        hours: ~o"2026-06-15T19:00:00/2026-06-15T23:00:00"
      })

      :ok
    end

    test "overlaps finds the shops open during a floating range" do
      probe = floating_range(~o"2026-06-15T12:00:00/2026-06-15T14:00:00")

      assert names(from(o in OpeningHours, where: overlaps(o.hours, ^probe), select: o.shop)) ==
               ["bakery", "cafe"]
    end

    test "contains finds the shop open throughout a floating range" do
      probe = floating_range(~o"2026-06-15T08:00:00/2026-06-15T09:00:00")

      assert names(from(o in OpeningHours, where: contains(o.hours, ^probe), select: o.shop)) ==
               ["bakery"]
    end

    test "meets finds the hours that end as another's begin" do
      probe = floating_range(~o"2026-06-15T13:00:00/2026-06-15T18:00:00")

      assert names(from(o in OpeningHours, where: meets(o.hours, ^probe), select: o.shop)) ==
               ["bakery"]
    end

    test "strictly_before and strictly_after divide the shops about a floating range" do
      probe = floating_range(~o"2026-06-15T18:00:00/2026-06-15T19:00:00")

      before =
        names(from(o in OpeningHours, where: strictly_before(o.hours, ^probe), select: o.shop))

      later =
        names(from(o in OpeningHours, where: strictly_after(o.hours, ^probe), select: o.shop))

      assert before == ["bakery", "cafe"]
      assert later == ["bar"]
    end
  end
end

defmodule Tempo.SQL.QueryAPICompositeTest do
  @moduledoc """
  The composite API mirrors the plain one, reaching inside the
  `tempo_range` composite to its range component. Ecto query macros must
  be imported rather than module-qualified, and both APIs export the
  same five names, so the composite tests live in their own module.
  """

  use Tempo.SQL.Test.RepoCase

  import Tempo.Ecto.QueryAPI.Composite
  import Tempo.Sigils

  alias Tempo.Ecto.Interval, as: IntervalType

  defp range(interval) do
    {:ok, range} = IntervalType.dump(interval)
    range
  end

  defp floating_range(interval) do
    {:ok, range} = IntervalType.dump(interval, nil, IntervalType.init(frame: :floating))
    range
  end

  describe "the same five operators over a composite column" do
    setup do
      Repo.insert!(%FidelityMeeting{
        name: "Morning",
        window: ~o"2026-06-15T09:00:00Z/2026-06-15T10:00:00Z"
      })

      Repo.insert!(%FidelityMeeting{
        name: "Afternoon",
        window: ~o"2026-06-15T14:00:00Z/2026-06-15T15:00:00Z"
      })

      :ok
    end

    test "overlaps reaches inside the composite's range component" do
      probe = range(~o"2026-06-15T09:30:00Z/2026-06-15T09:45:00Z")

      found =
        from(m in FidelityMeeting, where: overlaps(m.window, ^probe), select: m.name)
        |> Repo.all()

      assert found == ["Morning"]
    end

    test "contains reaches inside the composite's range component" do
      probe = range(~o"2026-06-15T09:15:00Z/2026-06-15T09:30:00Z")

      found =
        from(m in FidelityMeeting, where: contains(m.window, ^probe), select: m.name)
        |> Repo.all()

      assert found == ["Morning"]
    end

    test "meets works on a composite column" do
      probe = range(~o"2026-06-15T10:00:00Z/2026-06-15T11:00:00Z")

      found =
        from(m in FidelityMeeting, where: meets(m.window, ^probe), select: m.name)
        |> Repo.all()

      assert found == ["Morning"]
    end

    test "strictly_before and strictly_after work on a composite column" do
      probe = range(~o"2026-06-15T12:00:00Z/2026-06-15T13:00:00Z")

      before =
        from(m in FidelityMeeting,
          where: strictly_before(m.window, ^probe),
          select: m.name
        )
        |> Repo.all()

      later =
        from(m in FidelityMeeting,
          where: strictly_after(m.window, ^probe),
          select: m.name
        )
        |> Repo.all()

      assert before == ["Morning"]
      assert later == ["Afternoon"]
    end
  end

  describe "the operators over a floating composite column" do
    setup do
      Repo.insert!(%FidelityOpeningHours{
        shop: "bakery",
        hours: ~o"2026-06-15T07:00:00/2026-06-15T13:00:00"
      })

      Repo.insert!(%FidelityOpeningHours{
        shop: "bar",
        hours: ~o"2026-06-15T19:00:00/2026-06-15T23:00:00"
      })

      :ok
    end

    test "overlaps reaches inside the floating composite's range component" do
      probe = floating_range(~o"2026-06-15T12:00:00/2026-06-15T14:00:00")

      found =
        from(o in FidelityOpeningHours, where: overlaps(o.hours, ^probe), select: o.shop)
        |> Repo.all()

      assert found == ["bakery"]
    end

    test "contains reaches inside the floating composite's range component" do
      probe = floating_range(~o"2026-06-15T20:00:00/2026-06-15T21:00:00")

      found =
        from(o in FidelityOpeningHours, where: contains(o.hours, ^probe), select: o.shop)
        |> Repo.all()

      assert found == ["bar"]
    end

    test "strictly_before works on a floating composite column" do
      probe = floating_range(~o"2026-06-15T14:00:00/2026-06-15T15:00:00")

      found =
        from(o in FidelityOpeningHours, where: strictly_before(o.hours, ^probe), select: o.shop)
        |> Repo.all()

      assert found == ["bakery"]
    end
  end
end
