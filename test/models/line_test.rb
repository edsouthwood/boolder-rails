require "test_helper"

class LineTest < ActiveSupport::TestCase
  setup do
    area = Area.create!(name: "Bonehill", slug: "bonehill", published: true)
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    @line = Line.new(problem: area.problems.create!(steepness: "wall"), topo: topo)
  end

  test "start holds are optional" do
    assert @line.valid?
  end

  test "accepts up to four start holds inside the image" do
    @line.start_holds = [ { "x" => 0.1, "y" => 0.9 }, { "x" => 0, "y" => 1 } ]
    assert @line.valid?

    @line.start_holds = Array.new(Line::MAX_START_HOLDS + 1) { { "x" => 0.5, "y" => 0.5 } }
    assert_not @line.valid?
    assert_includes @line.errors[:start_holds].join, "at most"
  end

  test "rejects holds outside the image or without numeric x/y" do
    [ [ { "x" => 1.2, "y" => 0.5 } ], [ { "x" => 0.5 } ], [ { "x" => "0.5", "y" => 0.5 } ], [ 0.5 ], { "x" => 0.5, "y" => 0.5 } ].each do |holds|
      @line.start_holds = holds
      assert_not @line.valid?, "expected #{holds.inspect} to be invalid"
    end
  end

  test "an empty list is stored as nil" do
    @line.update!(start_holds: [])
    assert_nil @line.reload.start_holds
  end

  test "accepts not-in areas of 3+ points" do
    @line.excluded_areas = [ [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.3, "y" => 0.1 }, { "x" => 0.2, "y" => 0.4 } ], [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.3, "y" => 0.1 }, { "x" => 0.2, "y" => 0.4 } ] ]
    assert @line.valid?
  end

  test "rejects not-in areas with too few points, bad points or too many areas" do
    [
      [ [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.2, "y" => 0.2 } ] ],
      [ [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.2, "y" => 0.2 }, { "x" => 1.5, "y" => 0.2 } ] ],
      [ { "x" => 0.1, "y" => 0.1 } ],
      Array.new(Line::MAX_EXCLUDED_AREAS + 1) { [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.3, "y" => 0.1 }, { "x" => 0.2, "y" => 0.4 } ] }
    ].each do |areas|
      @line.excluded_areas = areas
      assert_not @line.valid?, "expected #{areas.inspect} to be invalid"
      assert_includes @line.errors.attribute_names, :excluded_areas
    end
  end

  test "empty not-in areas are stored as nil" do
    @line.update!(excluded_areas: [])
    assert_nil @line.reload.excluded_areas
  end
end
