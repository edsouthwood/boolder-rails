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

  test "a two-point straight line gets a midpoint so it imports" do
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x",
      line_coordinates: '[{"x":0.2,"y":0.8},{"x":0.4,"y":0.2}]')
    contribution.photos.attach(io: StringIO.new("fake-bytes"), filename: "boulder.jpg", content_type: "image/jpeg")

    importer = ContributionImporter.new(contribution)
    importer.import!

    assert_equal [ { "x" => 0.2, "y" => 0.8 }, { "x" => 0.3, "y" => 0.5 }, { "x" => 0.4, "y" => 0.2 } ],
                 importer.created_line.reload.coordinates
  end

  test "a single point is dropped rather than failing the import" do
    topo = existing_topo
    contribution = Contribution.create!(state: "accepted", problem: @problem, existing_topo: topo,
      line_coordinates: '[{"x":0.2,"y":0.8}]', start_holds: '[{"x":0.2,"y":0.8}]')

    ContributionImporter.new(contribution).import!

    line = @problem.lines.find_by(topo: topo)
    assert_nil line.coordinates
    assert_equal [ { "x" => 0.2, "y" => 0.8 } ], line.start_holds
  end

  private

  def existing_topo
    topo = Topo.new(published: true)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: @area.problems.create!(steepness: "wall"), topo: topo)
    topo
  end

  test "importing twice doesn't add the photo and line again" do
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x",
      line_coordinates: '[{"x":0.2,"y":0.8},{"x":0.4,"y":0.2}]', start_holds: '[{"x":0.2,"y":0.8}]')
    contribution.photos.attach(io: StringIO.new("fake-bytes"), filename: "boulder.jpg", content_type: "image/jpeg")
    ContributionImporter.new(contribution).import!

    again = ContributionImporter.new(contribution)
    assert_no_difference [ "Topo.count", "Line.count" ] do
      again.import!
    end

    assert again.already_imported
    assert_nil again.created_topo
  end

  test "importing twice doesn't draw the line on an existing topo again" do
    topo = existing_topo
    contribution = Contribution.create!(state: "accepted", problem: @problem, existing_topo: topo,
      line_coordinates: '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]', start_holds: '[{"x":0.2,"y":0.8}]')
    ContributionImporter.new(contribution).import!

    again = ContributionImporter.new(contribution)
    assert_no_difference "Line.count" do
      again.import!
    end

    assert again.already_imported
  end

  test "a new line for a problem that already has a different one on the topo still imports" do
    topo = existing_topo
    Line.create!(problem: @problem, topo: topo)
    contribution = Contribution.create!(state: "accepted", problem: @problem, existing_topo: topo,
      line_coordinates: '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]')

    importer = ContributionImporter.new(contribution)
    assert_difference "Line.count", 1 do
      importer.import!
    end

    assert_not importer.already_imported
  end

  test "a photo an admin has deleted since is imported afresh" do
    contribution = Contribution.create!(state: "accepted", problem: @problem, comment: "x",
      line_coordinates: '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]')
    contribution.photos.attach(io: StringIO.new("fake-bytes"), filename: "boulder.jpg", content_type: "image/jpeg")
    first = ContributionImporter.new(contribution)
    first.import!
    first.created_topo.destroy!

    again = ContributionImporter.new(contribution)
    assert_difference [ "Topo.count", "Line.count" ], 1 do
      again.import!
    end

    assert_not again.already_imported
  end

  # --- putting the problem on a photo already on the site ---

  LINE = '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]'

  def contribution_with_photo(bytes: "fake-bytes", **attrs)
    contribution = Contribution.new(state: "accepted", problem: @problem, line_coordinates: LINE, **attrs)
    contribution.photos.attach(io: StringIO.new(bytes), filename: "boulder.jpg", content_type: "image/jpeg")
    contribution.save!
    contribution
  end

  test "merging onto an admin's chosen photo adds an undrawn line there and no topo" do
    topo = existing_topo
    contribution = contribution_with_photo(merge_topo: topo, start_holds: '[{"x":0.2,"y":0.8}]')

    importer = ContributionImporter.new(contribution)
    assert_no_difference "Topo.count" do
      assert_difference "Line.count", 1 do
        importer.import!
      end
    end

    line = importer.merged_line
    assert_equal topo, line.topo
    assert_nil line.coordinates, "the line was drawn on another photo, so it must not be copied"
    assert_nil line.start_holds
    assert_equal contribution, line.reference_contribution
    assert_nil importer.created_line
    assert_includes Topo.undrawn, topo
  end

  test "merging twice doesn't add a second undrawn line" do
    topo = existing_topo
    contribution = contribution_with_photo(merge_topo: topo)
    ContributionImporter.new(contribution).import!

    again = ContributionImporter.new(contribution)
    assert_no_difference "Line.count" do
      again.import!
    end
    assert again.already_imported
  end

  test "merging onto the photo the contributor drew on keeps their line" do
    topo = existing_topo
    contribution = Contribution.create!(state: "accepted", problem: @problem, existing_topo: topo, merge_topo: topo, line_coordinates: LINE)

    importer = ContributionImporter.new(contribution)
    importer.import!

    assert_nil importer.merged_line
    assert_equal JSON.parse(LINE), importer.created_line.coordinates
  end

  test "a photo that's already a topo gets the line as drawn instead of a second topo" do
    first = contribution_with_photo
    ContributionImporter.new(first).import!
    other_problem = @area.problems.create!(steepness: "wall")
    second = contribution_with_photo(problem: other_problem)

    importer = ContributionImporter.new(second)
    assert_no_difference "Topo.count" do
      importer.import!
    end

    assert_equal first.problem.topos.first, importer.created_line.topo
    assert_equal JSON.parse(LINE), importer.created_line.coordinates
  end

  test "merging onto the topo made from this very photo keeps the line as drawn" do
    ContributionImporter.new(contribution_with_photo).import!
    topo = Topo.last
    second = contribution_with_photo(problem: @area.problems.create!(steepness: "wall"), merge_topo: topo)

    importer = ContributionImporter.new(second)
    importer.import!

    assert_nil importer.merged_line
    assert_equal JSON.parse(LINE), importer.created_line.coordinates
  end
end
