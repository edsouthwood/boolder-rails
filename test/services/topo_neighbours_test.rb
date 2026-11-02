require "test_helper"

class TopoNeighboursTest < ActiveSupport::TestCase
  # A square boulder about 44 m north-south by 28 m east-west, centred on (50.6, -3.9)
  D = 0.0002

  setup do
    @area = Area.create!(name: "Nav Area", slug: "nav-area", published: true)
    ring = [ [ -D, -D ], [ D, -D ], [ D, D ], [ -D, D ], [ -D, -D ] ].map { |x, y| FACTORY.point(-3.9 + x, 50.6 + y) }
    @boulder = @area.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)))
    # One photo per face, its problem placed at the middle of that face's edge
    @south = photo_with_problem("South", 50.6 - D, -3.9)
    @east = photo_with_problem("East", 50.6, -3.9 + D)
    @west = photo_with_problem("West", 50.6, -3.9 - D)
    @north = photo_with_problem("North", 50.6 + D, -3.9)
  end

  def photo_with_problem(name, lat, lon, metadata: {}, ascents: 0, published: true)
    topo = Topo.new(area: @area, published: published, metadata: metadata)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    problem = @area.problems.create!(name: name, steepness: "wall", lat: lat, lon: lon, ascents: ascents)
    Line.create!(problem: problem, topo: topo, coordinates: [ { "x" => 0.5, "y" => 0.9 }, { "x" => 0.5, "y" => 0.5 }, { "x" => 0.5, "y" => 0.1 } ])
    topo
  end

  test "facing the boulder from a face, right and left are the neighbouring faces" do
    # On the south face you look north: east is to the right, west to the left
    nav = TopoNeighbours.new(@south)
    assert_equal "East", nav.right.problem.name
    assert_equal "West", nav.left.problem.name

    # On the east face you look west: north is to the right, south to the left
    nav = TopoNeighbours.new(@east)
    assert_equal "North", nav.right.problem.name
    assert_equal "South", nav.left.problem.name
  end

  test "the facing direction is inferred from the boulder" do
    heading = TopoNeighbours.new(@south).placements[@south.id][2]
    assert_in_delta 0, heading, 1
    assert_in_delta 270, TopoNeighbours.new(@east).placements[@east.id][2], 1
  end

  test "a photo's saved compass heading wins, and a photo without a boulder can still use one" do
    loose = photo_with_problem("Loose", 50.601, -3.9, metadata: { "heading" => 90.0 }) # facing east, 100 m north of the boulder
    beside = photo_with_problem("Beside", 50.6007, -3.9)                               # 33 m south of it: to its right

    assert_equal "Beside", TopoNeighbours.new(loose).right.problem.name
    assert_nil TopoNeighbours.new(beside).left, "no heading and no boulder: no arrows"
    assert_nil TopoNeighbours.new(beside).right
  end

  test "photos straight ahead, from the same spot or too far away aren't neighbours" do
    nav = TopoNeighbours.new(@south)
    assert_not_equal "North", nav.right&.problem&.name # straight ahead, behind the boulder
    assert_not_equal "North", nav.left&.problem&.name

    @east.lines.first.problem.update!(lat: 50.6 - D, lon: -3.89999) # moved next to the south photo
    @west.lines.first.problem.update!(lat: 50.6, lon: -3.89) # ~700 m east
    nav = TopoNeighbours.new(@south)
    assert_nil nav.right
    assert_nil nav.left
  end

  test "links go to the most climbed problem that shows that photo, skipping hidden ones" do
    popular = @area.problems.create!(name: "Popular", steepness: "wall", lat: 50.6, lon: -3.9 + D, ascents: 50)
    Line.create!(problem: popular, topo: @east, coordinates: [ { "x" => 0.2, "y" => 0.9 }, { "x" => 0.2, "y" => 0.5 }, { "x" => 0.2, "y" => 0.1 } ])
    assert_equal "Popular", TopoNeighbours.new(@south).right.problem.name

    popular.update!(hidden: true)
    assert_equal "East", TopoNeighbours.new(@south).right.problem.name
  end

  test "unpublished photos and areas give no neighbours" do
    @east.update!(published: false)
    assert_nil TopoNeighbours.new(@south).right, "the only photo to the right is unpublished"
    assert_equal "West", TopoNeighbours.new(@south).left.problem.name

    @area.update!(published: false)
    assert_nil TopoNeighbours.new(@south).left
  end
end
