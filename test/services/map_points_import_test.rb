require "test_helper"

class MapPointsImportTest < ActiveSupport::TestCase
  SAMPLE = File.read(Rails.root.join("test/fixtures/files/map_points/sample.kml"))

  setup do
    @area = Area.create!(name: "Known Crag", slug: "known-crag", published: true)
    @owl = @area.boulders.create!(name: "Owl Boulder")
    @tower = @area.boulders.create!(name: "Big Tower")
    @fox = @area.boulders.create!(name: "Fox Block")
    @badger = @area.boulders.create!(name: "Badger Boulder")
    @long = @area.boulders.create!(name: "The Long Wall")
    @goal = @area.boulders.create!(name: "Goalpost Top Prow")
    @tiny = @area.boulders.create!(name: "Tiny Boulder")
    @drawn = @area.boulders.create!(name: "Drawn Slab", polygon: square(-3.70500, 50.60000))
    # An unnamed outline right by the "Big Twr" pin
    @unnamed = @area.boulders.create!(polygon: square(-3.70010, 50.60011))
    @old_parking = Poi.create!(poi_type: "parking", name: "Old", location: FACTORY.point(-3.68101, 50.60101))
  end

  # A square about 3 m across centred on lon/lat
  def square(lon, lat, size: 0.00002)
    ring = [ [ -1, -1 ], [ 1, -1 ], [ 1, 1 ], [ -1, 1 ], [ -1, -1 ] ].map { |x, y| FACTORY.point(lon + x * size, lat + y * size) }
    FACTORY.polygon(FACTORY.linear_ring(ring))
  end

  def plans(import = MapPointsImport.new(SAMPLE))
    import.preview.flat_map(&:points).index_by { |plan| plan.point.name }
  end

  test "parses folders and points, skipping lines and shapes" do
    parsed = MapPointsImport.parse(SAMPLE)

    assert_equal [ "Known Crag", "Fresh Crag", "Parking" ], parsed.folders.map(&:name)
    assert_equal 8, parsed.folders.first.points.size
    assert_equal [ "A Track" ], parsed.skipped.map(&:text)
    owl = parsed.folders.first.points.first
    assert_equal [ 50.6, -3.7 ], [ owl.lat, owl.lon ]
    assert_equal "3 Cars", parsed.folders.last.points.first.description
  end

  test "rejects KMZ and files that aren't KML" do
    assert_raises(MapPointsImport::ParseError) { MapPointsImport.parse("PK\x03\x04zipped") }
    assert_raises(MapPointsImport::ParseError) { MapPointsImport.parse("<html><body>no</body></html>") }
    assert_raises(MapPointsImport::ParseError) { MapPointsImport.parse("not xml at all <") }
  end

  test "expands short forms and compares names without The or a generic ending" do
    assert_equal "Waller Tower", MapPointsImport.expand("Waller Twr")
    assert_equal "Mini Boulder", MapPointsImport.expand("Mini B?")
    assert_equal "Slabs and Aretes", MapPointsImport.expand("Slabs & Aretes")
    assert_equal "BBB", MapPointsImport.expand("BBB")
    assert_equal "yak", MapPointsImport.core("The Yak")
    assert_equal "yak", MapPointsImport.core("Yak B")
    assert_equal "bezs", MapPointsImport.core("Bez's Block")
  end

  test "folders go to the area with the same name, a new area, or parking" do
    targets = MapPointsImport.new(SAMPLE).preview.map(&:target)

    assert_equal [ "area:#{@area.id}", "new", "parking" ], targets
  end

  test "matches pins to listed boulders by name" do
    plans = plans()

    assert_equal [ :match, [ @owl ] ], [ plans["Owl B"].action, plans["Owl B"].boulders ]
    assert_equal [ @fox, @badger ], plans["Fox / Badger B"].boulders
    assert_equal [ @long ], plans["Long Wl - Sunny Side"].boulders
    assert_equal :possible_match, plans["Goalpost"].action
    assert_equal [ @goal ], plans["Goalpost"].similar
    assert_equal "skip", plans["Goalpost"].default_choice
    assert_equal :new, plans["Brand New B"].action
    assert_equal "Brand New Boulder", plans["Brand New B"].new_name
    assert_equal :on_map, plans["Drawn Slab"].action
  end

  test "a pin ending in ? is skipped unless chosen" do
    plan = plans()["Tiny B?"]

    assert plan.point.uncertain?
    assert_equal :match, plan.action
    assert_equal "skip", plan.default_choice
  end

  test "offers a nearby unnamed outline, ticked when it's within a few metres" do
    plan = plans()["Big Twr"]

    assert_equal @unnamed, plan.outline
    assert plan.adopt_by_default?
  end

  test "warns when a drawn boulder's outline is far from its pin" do
    @drawn.update!(polygon: square(-3.70560, 50.60000))

    assert_operator plans()["Drawn Slab"].far_metres, :>, MapPointsImport::FAR_METRES
  end

  test "applying locates boulders, names outlines, adds areas, names and parking" do
    summary = MapPointsImport.new(SAMPLE).apply!

    assert_equal 1, summary[:areas_created]
    assert_equal 1, summary[:parking_created]
    assert_equal 1, summary[:outlines_named]
    assert_in_delta(-3.7, @owl.reload.location.lon, 1e-6)
    assert @fox.reload.location && @badger.reload.location
    assert_nil @goal.reload.location, "a possible match is skipped by default"
    assert_nil @tiny.reload.location, "an unsure pin is skipped by default"
    assert_nil @drawn.reload.location
    assert_equal "Big Tower", @unnamed.reload.name
    assert_not Boulder.exists?(@tower.id), "the listed name merged into the outline"
    assert @area.boulders.unplaced.find_by(name: "Brand New Boulder").location

    fresh = Area.find_by!(name: "Fresh Crag")
    assert_not fresh.published
    assert_equal [ "Acorn", "Acorn 2" ], fresh.boulders.order(:id).pluck(:name)
    assert_equal [ "Lay-by (3 cars)" ], Poi.where.not(id: @old_parking.id).pluck(:name)
  end

  test "an area with nothing drawn yet takes its bounds from the pins" do
    MapPointsImport.new(SAMPLE).apply!

    bounds = Area.find_by!(name: "Fresh Crag").bounds
    assert_in_delta 50.61, bounds[:south_west].lat, 1e-6
    assert_in_delta(-3.69, bounds[:north_east].lon, 1e-6)
  end

  test "applying again changes nothing" do
    MapPointsImport.new(SAMPLE).apply!

    assert_no_difference -> { Area.count + Boulder.count + Poi.count } do
      summary = MapPointsImport.new(SAMPLE).apply!
      assert_equal 0, summary[:located] + summary[:boulders_created] + summary[:areas_created] + summary[:parking_created]
    end
  end

  test "choices pick a similar boulder, rename a new one, keep a saved location, and skip folders" do
    @owl.update!(location: FACTORY.point(-3.6, 50.6))
    import = MapPointsImport.new(SAMPLE, targets: { "f1" => "skip", "f2" => "skip" })
    plans = plans(import)
    assert plans["Owl B"].moves_location?

    summary = import.apply!(
      choices: { plans["Goalpost"].point.key => "boulder:#{@goal.id}" },
      names: { plans["Brand New B"].point.key => "Shiny Block" }, adopt: [])

    assert_in_delta(-3.6, @owl.reload.location.lon, 1e-6)
    assert_equal 1, summary[:location_kept]
    assert @goal.reload.location
    assert @area.boulders.exists?(name: "Shiny Block")
    assert_nil @unnamed.reload.name
    assert_not Area.exists?(name: "Fresh Crag")
  end

  test "a choice can't point at a boulder that wasn't offered" do
    other = Area.create!(name: "Elsewhere", slug: "elsewhere").boulders.create!(name: "Stranger")
    key = plans()["Goalpost"].point.key

    MapPointsImport.new(SAMPLE).apply!(choices: { key => "boulder:#{other.id}" })

    assert_nil other.reload.location
  end
end
