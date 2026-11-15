require "test_helper"

class TopoTest < ActiveSupport::TestCase
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

  test "only a published photo in the same area can be replaced" do
    elsewhere = photo(area: Area.create!(name: "Elsewhere", slug: "elsewhere"))

    assert_raises(Topo::ReplacementError) { @better.replace!(elsewhere) }
    assert_raises(Topo::ReplacementError) { @better.replace!(@better) }
    assert_raises(Topo::ReplacementError) { @better.replace!(photo(published: false)) }
  end

  test "stopping a replacement forgets the old photo" do
    @better.replace!(@old)
    @better.replace!(nil)

    assert_nil @better.reload.replaces_topo
  end
end
