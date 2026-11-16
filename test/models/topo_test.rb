require "test_helper"

class TopoTest < ActiveSupport::TestCase
  # --- uncropped photos ---

  def sized(topo, width, height)
    topo.photo.blob.update!(metadata: { "analyzed" => true, "identified" => true, "width" => width, "height" => height })
    topo
  end

  test "new topos keep the photo's shape; older, cropped ones are 4:3" do
    portrait = sized(photo(bytes: "portrait"), 900, 1200)
    assert portrait.uncropped?
    assert_equal :full, portrait.display_variant
    assert_in_delta 0.75, portrait.aspect_ratio, 1e-9
    assert portrait.portrait?

    portrait.update!(uncropped: false)
    assert_equal :medium, portrait.display_variant
    assert_in_delta 4.0 / 3, portrait.aspect_ratio, 1e-9
  end

  test "an uncropped photo with no size yet is taken as 4:3" do
    topo = sized(photo(bytes: "no size"), nil, nil)
    assert_in_delta 4.0 / 3, topo.aspect_ratio, 1e-9
  end

  # --- replacing a photo with a better one ---

  LINE = [ { "x" => 0.5, "y" => 0.9 }, { "x" => 0.5, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ].freeze

  setup do
    @area = Area.create!(name: "Swap Area", slug: "swap-area", published: true)
    @crack = @area.problems.create!(name: "Crack", steepness: "wall")
    @arete = @area.problems.create!(name: "Arete", steepness: "wall")
    @old = photo(published: true)
    Line.create!(problem: @crack, topo: @old, coordinates: LINE, start_holds: [ { "x" => 0.5, "y" => 0.9 } ])
    Line.create!(problem: @arete, topo: @old, coordinates: LINE)
    @better = photo(bytes: "better photo")
  end

  def photo(bytes: "old photo", published: true, area: @area)
    topo = Topo.new(area: area, published: published)
    topo.photo.attach(io: StringIO.new(bytes), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    topo
  end

  def draw_all(topo)
    topo.lines.each { |line| line.update!(coordinates: LINE) }
  end

  test "a replacement is kept off the site and brings the old photo's problems across, undrawn" do
    @better.replace!(@old)

    assert_not @better.reload.published
    assert_equal @old, @better.replaces_topo
    assert_equal 2, @better.bring_problems_across!
    assert_equal 0, @better.bring_problems_across!, "bringing them twice adds nothing"

    line = @better.lines.find_by(problem: @crack)
    assert_nil line.coordinates
    assert_equal @old.lines.find_by(problem: @crack), line.reference_line
  end

  test "can't swap until every problem is drawn" do
    @better.replace!(@old)
    @better.bring_problems_across!

    assert_raises(Topo::ReplacementError) { @better.swap_in! }
    assert @old.reload.published
  end

  test "swapping publishes the better photo, keeps the old one unpublished, and undo puts it back" do
    @better.replace!(@old)
    @better.bring_problems_across!
    draw_all(@better)

    @better.swap_in!

    assert @better.reload.published
    assert_not @old.reload.published
    assert_equal @better, @old.replaced_by_topo
    assert_equal @better, @crack.lines.published.first.topo
    assert @crack.reload.has_line

    @old.undo_swap!

    assert @old.reload.published
    assert_not @better.reload.published
    assert_nil @old.replaced_by_topo
    assert_equal @old, @crack.lines.published.first.topo
  end

  test "a problem left off the better photo loses its line on the swap" do
    @better.replace!(@old)
    Line.create!(problem: @crack, topo: @better, coordinates: LINE)

    assert_equal [ @arete ], @better.problems_left_behind.to_a
    @better.swap_in!

    assert_not @arete.reload.has_line
  end

  test "only another photo in the same area can be replaced, and not round in a circle" do
    elsewhere = photo(area: Area.create!(name: "Elsewhere", slug: "elsewhere"))

    assert_raises(Topo::ReplacementError) { @better.replace!(elsewhere) }
    assert_raises(Topo::ReplacementError) { @better.replace!(@better) }
    @better.replace!(@old)
    assert_raises(Topo::ReplacementError) { @old.replace!(@better) }
  end

  test "an unpublished photo can be replaced too, and the published one stays on the site" do
    unfinished = photo(bytes: "unfinished", published: false)
    Line.create!(problem: @crack, topo: unfinished, coordinates: LINE)
    published = photo(bytes: "published one")
    Line.create!(problem: @arete, topo: published, coordinates: LINE)
    # Both tied by hand to the same boulder, with no problem in common
    [ unfinished, published ].each { |topo| topo.update!(metadata: { "chosen_boulder_id" => 4242 }) }

    assert_includes published.replacement_candidates, unfinished
    assert_includes unfinished.replacement_candidates, published

    published.replace!(unfinished)
    assert published.reload.published
    assert_equal 1, published.bring_problems_across!
    published.lines.each { |line| line.update!(coordinates: LINE) }

    published.swap_in!
    assert published.reload.published
    assert_not unfinished.reload.published
  end

  test "a photo already swapped out isn't offered again" do
    @better.replace!(@old)
    @better.bring_problems_across!
    draw_all(@better)
    @better.swap_in!
    another = photo(bytes: "another")
    Line.create!(problem: @crack, topo: another, coordinates: LINE)

    assert_not_includes another.replacement_candidates, @old
    assert_includes another.replacement_candidates, @better
  end

  test "stopping a replacement forgets the old photo" do
    @better.replace!(@old)
    @better.replace!(nil)

    assert_nil @better.reload.replaces_topo
  end
end
