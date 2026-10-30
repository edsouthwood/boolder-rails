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

  test "offline_version changes when anything saved for offline changes" do
    area = Area.create!(name: "Versioned", slug: "offline-version-test")
    point = RGeo::Geographic.spherical_factory(srid: 4326).point(-4.0, 50.5)
    versions = [ area.offline_version ]
    assert_equal versions.last, area.reload.offline_version, "stable when nothing changes"

    problem = area.problems.create!(steepness: "slab", location: point)
    versions << area.reload.offline_version

    travel 1.second
    problem.update!(name: "Renamed")
    versions << area.reload.offline_version

    topo = Topo.new(published: true)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: problem, topo: topo)
    versions << area.reload.offline_version

    travel 1.second
    topo.photo.attach(io: StringIO.new("new image"), filename: "topo2.jpg", content_type: "image/jpeg")
    versions << area.reload.offline_version

    area.cover.attach(io: StringIO.new("cover"), filename: "cover.jpg", content_type: "image/jpeg")
    versions << area.reload.offline_version

    assert_equal versions.uniq, versions, "every change produces a new version"
  end

  test "offline_versions batches several areas and matches offline_version" do
    one = Area.create!(name: "One", slug: "offline-versions-one")
    two = Area.create!(name: "Two", slug: "offline-versions-two")
    one.problems.create!(steepness: "slab", location: RGeo::Geographic.spherical_factory(srid: 4326).point(-4.0, 50.5))

    versions = Area.offline_versions([ one.reload, two.reload ])
    assert_equal({ one.id => one.offline_version, two.id => two.offline_version }, versions)
    assert_not_equal versions[one.id], versions[two.id]
  end
end
