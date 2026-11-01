require "test_helper"

class BoulderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # ~11 m square boulder centred on (LON, LAT)
  LON = -3.9
  LAT = 50.6
  D = 0.0001

  setup do
    @area = Area.create!(name: "Bonehill", slug: "bonehill-boulders", published: true)
  end

  def square(lon = LON, lat = LAT, d = D)
    FACTORY.polygon(FACTORY.linear_ring([
      [ lon - d, lat - d ], [ lon + d, lat - d ], [ lon + d, lat + d ], [ lon - d, lat + d ], [ lon - d, lat - d ]
    ].map { |x, y| FACTORY.point(x, y) }))
  end

  def topo(published: true)
    t = Topo.new(published: published)
    t.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    t.save!
    t
  end

  # Problem on the boulder edge at the given compass bearing, drawn on the given topo
  def problem_at(bearing, topo)
    rad = bearing * Math::PI / 180
    lon = LON + D * Math.sin(rad) / [ Math.sin(rad).abs, Math.cos(rad).abs ].max
    lat = LAT + D * Math.cos(rad) / [ Math.sin(rad).abs, Math.cos(rad).abs ].max
    problem = @area.problems.create!(steepness: "wall", lat: lat, lon: lon)
    Line.create!(problem: problem, topo: topo)
    problem
  end

  test "recompute_topos! links topos and orders them anti-clockwise from the biggest gap" do
    boulder = perform_enqueued_jobs { @area.boulders.create!(polygon: square) }
    north, east, west = topo, topo, topo
    problem_at(0, north)
    problem_at(90, east)
    problem_at(270, west)
    # The biggest gap is south (90° → 270°), so the walk starts after it and goes
    # anti-clockwise: east (90°), north (0°), west (270°)

    boulder.recompute_topos!

    assert_equal [ boulder.id ] * 3, [ east, north, west ].map { |t| t.reload.boulder_id }
    assert_equal [ 0, 1, 2 ], [ east, north, west ].map { |t| t.reload.position }
  end

  test "recompute_topos! ignores unpublished topos and unlinks ones no longer on the boulder" do
    boulder = @area.boulders.create!(polygon: square)
    hidden = topo(published: false)
    problem_at(0, hidden)
    stale = topo
    stale.update_columns(boulder_id: boulder.id, position: 5)

    boulder.recompute_topos!

    assert_nil hidden.reload.boulder_id
    assert_nil stale.reload.boulder_id
  end

  test "saving a problem location links its topo automatically" do
    boulder = @area.boulders.create!(polygon: square)
    t = topo
    problem = @area.problems.create!(steepness: "wall")
    Line.create!(problem: problem, topo: t)

    perform_enqueued_jobs { problem.update!(lat: LAT + D, lon: LON) }
    assert_equal boulder.id, t.reload.boulder_id

    # Moving it well away unlinks it again (the job runs for the old spot too)
    perform_enqueued_jobs { problem.update!(lat: LAT + 1, lon: LON) }
    assert_nil t.reload.boulder_id
  end

  test "changing a boulder outline or deleting it updates its topos" do
    t = topo
    problem_at(0, t)
    boulder = perform_enqueued_jobs { @area.boulders.create!(polygon: square) }
    assert_equal boulder.id, t.reload.boulder_id

    perform_enqueued_jobs { boulder.update!(polygon: square(LON + 1)) }
    assert_nil t.reload.boulder_id

    perform_enqueued_jobs { boulder.update!(polygon: square) }
    assert_equal boulder.id, t.reload.boulder_id

    boulder.destroy!
    assert_nil t.reload.boulder_id
  end

  test "nothing is enqueued for a problem without a boulder" do
    assert_no_enqueued_jobs(only: RecomputeBoulderToposJob) do
      @area.problems.create!(steepness: "wall", lat: LAT + 1, lon: LON)
    end
  end
end
