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

  test "copies start holds onto the line drawn on an existing topo" do
    topo = existing_topo
    holds = [ { "x" => 0.2, "y" => 0.8 } ]
    contribution = Contribution.create!(state: "accepted", problem: @problem, existing_topo: topo,
      line_coordinates: '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]', start_holds: holds.to_json)

    ContributionImporter.new(contribution).import!

    assert_equal holds, @problem.lines.find_by(topo: topo).start_holds
  end

  test "imports start holds marked on an existing topo without a line" do
    topo = existing_topo
    contribution = Contribution.create!(state: "accepted", problem: @problem, existing_topo: topo,
      start_holds: '[{"x":0.2,"y":0.8},{"x":0.3,"y":0.75}]')

    ContributionImporter.new(contribution).import!

    line = @problem.lines.find_by(topo: topo)
    assert_equal 2, line.start_holds.size
    assert_nil line.coordinates
  end

  test "copies start holds onto the line on a new topo from the contributed photo" do
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x",
      line_coordinates: '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]', start_holds: '[{"x":0.2,"y":0.8}]')
    contribution.photos.attach(io: StringIO.new("fake-bytes"), filename: "boulder.jpg", content_type: "image/jpeg")

    importer = ContributionImporter.new(contribution)
    importer.import!

    assert_equal [ { "x" => 0.2, "y" => 0.8 } ], importer.created_line.reload.start_holds
  end

  test "copies not-in areas onto the line" do
    topo = existing_topo
    areas = [ [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.3, "y" => 0.1 }, { "x" => 0.2, "y" => 0.4 } ] ]
    contribution = Contribution.create!(state: "accepted", problem: @problem, existing_topo: topo, excluded_areas: areas.to_json)

    ContributionImporter.new(contribution).import!

    assert_equal areas, @problem.lines.find_by(topo: topo).excluded_areas
  end

  private

  def existing_topo
    topo = Topo.new(published: true)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: @area.problems.create!(steepness: "wall"), topo: topo)
    topo
  end
end
