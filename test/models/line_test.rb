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
end
