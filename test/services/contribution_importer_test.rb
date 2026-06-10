require "test_helper"
require "minitest/mock"

class ContributionImporterTest < ActiveSupport::TestCase
  setup do
    @area = Area.create!(name: "Importer Area", slug: "importer-area")
    @problem = @area.problems.create!(steepness: "slab")
    @point = RGeo::Geographic.spherical_factory(srid: 4326).point(-3.9, 50.58)
  end

  test "applies GPS to an unlocated problem" do
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x", location: @point)

    ContributionImporter.new(contribution, apply_photo: false, apply_gps: true).import!

    assert_not_nil @problem.reload.location
  end

  test "does not overwrite an already-located problem" do
    other = RGeo::Geographic.spherical_factory(srid: 4326).point(-4.0, 50.6)
    @problem.update!(location: other)
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x", location: @point)

    ContributionImporter.new(contribution, apply_photo: false, apply_gps: true).import!

    assert_in_delta(-4.0, @problem.reload.location.lon, 1e-6)
  end

  test "closes open contribution requests for the problem" do
    request = @problem.contribution_requests.create!(state: "open", what: "line", location_estimated: @point)
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x", location: @point)

    ContributionImporter.new(contribution, apply_photo: false).import!

    assert_equal "closed", request.reload.state
  end

  test "GPS and line are applied atomically when wrapped in a transaction" do
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x", location: @point)
    contribution.photos.attach(io: StringIO.new("fake-bytes"), filename: "boulder.jpg", content_type: "image/jpeg")
    contribution.update!(line_coordinates: [ [ 1, 2 ], [ 3, 4 ], [ 5, 6 ] ])

    # Force the line creation (the last step) to fail mid-import.
    Line.stub :create!, proc { raise "boom" } do
      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          ContributionImporter.new(contribution).import!
        end
      end
    end

    # The earlier GPS write must have rolled back with the failed line.
    assert_nil @problem.reload.location
  end
end
