require "test_helper"

class AreaTest < ActiveSupport::TestCase
  test "bounds returns nil corners when the area has no boulders or located problems" do
    area = Area.create!(name: "Empty", slug: "empty-bounds-test")

    assert_nil area.bounds[:south_west]
    assert_nil area.bounds[:north_east]
  end

  test "serialized_bounds falls back to the default viewport when there is no geometry" do
    area = Area.create!(name: "Empty", slug: "empty-serialized-bounds-test")

    assert_equal(
      {
        south_west: { lat: Area::DEFAULT_BOUNDS[:south_west][:lat], lng: Area::DEFAULT_BOUNDS[:south_west][:lon] },
        north_east: { lat: Area::DEFAULT_BOUNDS[:north_east][:lat], lng: Area::DEFAULT_BOUNDS[:north_east][:lon] }
      },
      area.serialized_bounds
    )
  end

  test "bounds derives a box from located problems when the area has no boulders" do
    area = Area.create!(name: "Problems only", slug: "problems-only-bounds-test")
    point = ->(lon, lat) { RGeo::Geographic.spherical_factory(srid: 4326).point(lon, lat) }

    area.problems.create!(steepness: "slab", location: point.call(-4.0, 50.5))
    area.problems.create!(steepness: "slab", location: point.call(-3.8, 50.6))

    sw = area.bounds[:south_west]
    ne = area.bounds[:north_east]

    assert_in_delta(-4.0, sw.lon, 1e-6)
    assert_in_delta 50.5, sw.lat, 1e-6
    assert_in_delta(-3.8, ne.lon, 1e-6)
    assert_in_delta 50.6, ne.lat, 1e-6
  end
end
