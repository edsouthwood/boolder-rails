require "test_helper"

class TopoUncropperTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  LINE = [ { "x" => 0.5, "y" => 0.0 }, { "x" => 0.5, "y" => 0.5 }, { "x" => 0.4, "y" => 1.0 } ].freeze

  setup do
    @area = Area.create!(name: "Uncrop Area", slug: "uncrop-area", published: true)
    @crack = @area.problems.create!(name: "Crack", steepness: "wall")
    @old = topo(width: 900, height: 1200, uncropped: false)
    @line = Line.create!(problem: @crack, topo: @old, coordinates: LINE,
                         start_holds: [ { "x" => 0.5, "y" => 0.5 } ],
                         excluded_areas: [ [ { "x" => 0.1, "y" => 0.0 }, { "x" => 0.2, "y" => 1.0 }, { "x" => 0.3, "y" => 0.5 } ] ])
  end

  def topo(width:, height:, uncropped:, published: true)
    topo = Topo.new(area: @area, published: published, uncropped: uncropped)
    topo.photo.attach(io: StringIO.new("photo #{SecureRandom.hex(4)}"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    topo.photo.blob.update!(metadata: { "analyzed" => true, "identified" => true, "width" => width, "height" => height })
    topo
  end

  test "a point on the crop moves to the same spot on the whole photo" do
    # A 3:4 photo: the 4:3 crop kept the middle 9/16 of its height
    ratio = 3.0 / 4
    assert_in_delta 0.5625, TopoUncropper.kept_height(ratio), 1e-9
    assert_in_delta 0.2188, TopoUncropper.remap_point({ "x" => 0.3, "y" => 0.0 }, ratio)["y"], 1e-4
    assert_in_delta 0.5, TopoUncropper.remap_point({ "x" => 0.3, "y" => 0.5 }, ratio)["y"], 1e-4
    assert_in_delta 0.7813, TopoUncropper.remap_point({ "x" => 0.3, "y" => 1.0 }, ratio)["y"], 1e-4
    assert_equal 0.3, TopoUncropper.remap_point({ "x" => 0.3, "y" => 1.0 }, ratio)["x"]
  end

  test "finds cropped portrait topos only" do
    landscape = topo(width: 1600, height: 1200, uncropped: false)
    already = topo(width: 900, height: 1200, uncropped: true)

    candidates = TopoUncropper.candidates
    assert_includes candidates, @old
    assert_not_includes candidates, landscape
    assert_not_includes candidates, already
  end

  test "a dry run changes nothing" do
    topos = Topo.count
    result = TopoUncropper.new(@old, dry_run: true).call

    assert_equal :would_convert, result.status
    assert_equal topos, Topo.count
    assert_equal [ @old ], @crack.lines.map(&:topo)
  end

  test "swaps in a whole-photo topo of the same file, with every line moved, and undo puts it back" do
    result = TopoUncropper.new(@old).call

    assert_equal :converted, result.status
    fresh = result.new_topo
    assert fresh.uncropped?
    assert fresh.published
    assert_not @old.reload.published
    assert_equal fresh, @old.replaced_by_topo
    assert_equal @old.photo.blob, fresh.photo.blob, "the same file, not a copy"
    assert_in_delta 0.75, fresh.aspect_ratio, 1e-9

    line = fresh.lines.find_by!(problem: @crack)
    assert_equal [ 0.2188, 0.5, 0.7813 ], line.coordinates.map { |p| p["y"] }
    assert_equal [ 0.5, 0.5, 0.4 ], line.coordinates.map { |p| p["x"] }
    assert_equal [ 0.5 ], line.start_holds.map { |p| p["y"] }
    assert_equal [ 0.2188, 0.7813, 0.5 ], line.excluded_areas.first.map { |p| p["y"] }
    assert_equal fresh, @crack.lines.published.first.topo
    assert_equal @line.reload.coordinates, LINE, "the old line is kept as it was, for undo"

    @old.undo_swap!
    assert @old.reload.published
    assert_not fresh.reload.published
  end

  test "an unpublished topo's whole-photo topo stays unpublished" do
    @old.update!(published: false)

    result = TopoUncropper.new(@old).call

    assert_equal :converted, result.status
    assert_not result.new_topo.reload.published
  end

  test "leaves the replacement in the workbench when the old photo has an undrawn line" do
    Line.create!(problem: @area.problems.create!(name: "Arete", steepness: "wall"), topo: @old)

    result = TopoUncropper.new(@old).call

    assert_equal :needs_drawing, result.status
    assert_not result.new_topo.published
    assert @old.reload.published
  end

  test "skips landscape photos, converted ones, and ones already being replaced" do
    landscape = topo(width: 1600, height: 1200, uncropped: false)
    assert_equal :skipped, TopoUncropper.new(landscape).call.status

    TopoUncropper.new(@old).call
    assert_equal :skipped, TopoUncropper.new(@old.reload).call.status, "already replaced"

    pending = topo(width: 900, height: 1200, uncropped: false)
    topo(width: 1200, height: 900, uncropped: true, published: false).replace!(pending)
    assert_equal :skipped, TopoUncropper.new(pending).call.status
  end

  test "a line imported from a contribution was drawn on the whole photo, so it isn't moved" do
    sent = [ { "x" => 0.3, "y" => 0.1 }, { "x" => 0.3, "y" => 0.9 } ]
    holds = [ { "x" => 0.3, "y" => 0.9 } ]
    contribution = Contribution.create!(state: "accepted", problem: @crack, comment: "x",
                                        line_coordinates: sent, start_holds: holds)
    contribution.photos.attach(@old.photo.blob)
    arete = @area.problems.create!(name: "Arete", steepness: "wall")
    # As imported (a midpoint added to the two-click line), but its holds since redrawn on the crop
    imported = Line.create!(problem: arete, topo: @old, coordinates: [ sent[0], { "x" => 0.3, "y" => 0.5 }, sent[1] ],
                            start_holds: [ { "x" => 0.3, "y" => 0.5 } ])

    fresh = TopoUncropper.new(@old).call.new_topo

    assert_equal imported.coordinates, fresh.lines.find_by!(problem: arete).coordinates
    assert_equal [ 0.5 ], fresh.lines.find_by!(problem: arete).start_holds.map { |p| p["y"] }
    assert_equal [ 0.2188, 0.5, 0.7813 ], fresh.lines.find_by!(problem: @crack).coordinates.map { |p| p["y"] },
                 "a line drawn by an admin on the crop still moves"

    imported.update!(start_holds: holds)
    other = topo(width: 900, height: 1200, uncropped: false)
    other.photo.attach(@old.photo.blob)
    Line.create!(problem: arete, topo: other, coordinates: imported.coordinates, start_holds: holds)
    assert_equal holds, TopoUncropper.new(other).call.new_topo.lines.find_by!(problem: arete).start_holds
  end

  test "deleting the old topo leaves the photo file the new one shares" do
    fresh = TopoUncropper.new(@old).call.new_topo
    blob = fresh.photo.blob

    perform_enqueued_jobs { @old.reload.destroy! }

    assert ActiveStorage::Blob.exists?(blob.id)
    assert fresh.reload.photo.attached?
    assert blob.service.exist?(blob.key), "the file itself is still stored"
  end

  test "a photo with no lines yet is swapped for the whole photo straight away" do
    empty = topo(width: 900, height: 1200, uncropped: false)

    result = TopoUncropper.new(empty).call

    assert_equal :converted, result.status
    assert result.new_topo.reload.published
    assert_not empty.reload.published
    assert_equal result.new_topo, empty.replaced_by_topo
    empty.undo_swap!
    assert empty.reload.published
  end

  test "skips a photo with no area to put the new one in" do
    orphan = topo(width: 900, height: 1200, uncropped: false)
    orphan.update_column(:area_id, nil)

    assert_equal :skipped, TopoUncropper.new(orphan).call.status
  end

  test "an older photo with its area only through its problems keeps that area" do
    @old.update_column(:area_id, nil)

    result = TopoUncropper.new(@old.reload).call

    assert_equal :converted, result.status
    assert_equal @area.id, result.new_topo[:area_id]
  end
end
