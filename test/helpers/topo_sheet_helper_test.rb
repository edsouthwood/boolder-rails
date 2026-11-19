require "test_helper"

class TopoSheetHelperTest < ActionView::TestCase
  test "a start area is a smooth closed curve through its corners" do
    square = [ { "x" => 0.0, "y" => 0.0 }, { "x" => 1.0, "y" => 0.0 }, { "x" => 1.0, "y" => 1.0 }, { "x" => 0.0, "y" => 1.0 } ]
    path = start_area_path(square, 6, 6)

    # Starts on the first corner, passes through each in turn and closes, bulging outwards
    # between them (the first edge's controls sit above it), so a square comes out round
    assert path.start_with?("M 0.0,0.0 C 1.0,-1.0 5.0,-1.0 6.0,0.0 C "), path
    assert_equal 4, path.scan(" C ").size
    assert path.end_with?(" 0.0,0.0 Z"), path
  end
end
