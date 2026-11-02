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
  test "placed boulders have an outline; unplaced ones are just a name" do
    drawn = @area.boulders.create!(polygon: square)
    named = @area.boulders.create!(name: "Photo Arête")

    assert_equal [ drawn ], @area.boulders.placed.to_a
    assert_equal [ named ], @area.boulders.unplaced.to_a
    assert_equal "Photo Arête", named.display_name
    assert_equal "Boulder ##{drawn.id}", drawn.display_name
  end

  test "names are unique within an area, ignoring case, and blanks are no name" do
    @area.boulders.create!(name: "Photo Arête")

    assert_not @area.boulders.new(name: "photo arête").valid?
    assert Area.create!(name: "Other", slug: "other-names").boulders.new(name: "Photo Arête").valid?
    assert_nil @area.boulders.create!(name: "  ").name
  end

  test "saving an outline claims the located problems on it that have no boulder" do
    listed = @area.boulders.create!(name: "Listed")
    free = @area.problems.create!(steepness: "wall", lat: LAT, lon: LON)
    assigned = @area.problems.create!(steepness: "wall", lat: LAT, lon: LON, boulder: listed)

    drawn = @area.boulders.create!(polygon: square)

    assert_equal drawn, free.reload.boulder
    assert_equal listed, assigned.reload.boulder
  end

  test "a newly located problem with no boulder takes the outline it sits on" do
    drawn = @area.boulders.create!(polygon: square)
    problem = @area.problems.create!(steepness: "wall")
    assert_nil problem.boulder

    problem.update!(lat: LAT, lon: LON)
    assert_equal drawn, problem.reload.boulder

    elsewhere = @area.boulders.create!(name: "Elsewhere")
    moved = @area.problems.create!(steepness: "wall", boulder: elsewhere)
    moved.update!(lat: LAT, lon: LON)
    assert_equal elsewhere, moved.reload.boulder, "an explicit boulder is kept"
  end

  test "a problem's boulder must be in its area" do
    other = Area.create!(name: "Other", slug: "other-area").boulders.create!(name: "There")
    problem = @area.problems.new(steepness: "wall", boulder: other)

    assert_not problem.valid?
    assert_includes problem.errors[:boulder], "must be in the same area"
  end

  test "absorb takes over another boulder's name and problems" do
    drawn = @area.boulders.create!(polygon: square)
    listed = @area.boulders.create!(name: "Photo Arête")
    problem = @area.problems.create!(steepness: "wall", boulder: listed)

    drawn.absorb!(listed)

    assert_equal "Photo Arête", drawn.reload.name
    assert_equal drawn, problem.reload.boulder
    assert_not Boulder.exists?(listed.id)
    assert_raises(ArgumentError) { drawn.absorb!(drawn) }
  end

  test "deleting a boulder leaves its problems without one" do
    listed = @area.boulders.create!(name: "Gone")
    problem = @area.problems.create!(steepness: "wall", boulder: listed)

    listed.destroy!
    assert_nil problem.reload.boulder_id
  end
end
