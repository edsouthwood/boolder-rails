require "test_helper"

class ProblemTest < ActiveSupport::TestCase
  test "grade_rank orders simplified and detailed grades together" do
    grades = %w[6a 4+ 4c 3 4 5 4a 7a+ 4b 6a+ 5c+]
    assert_equal %w[3 4a 4 4b 4+ 4c 5 5c+ 6a 6a+ 7a+], grades.sort_by { |g| Problem.grade_rank(g) }
  end

  test "grade_rank is nil for a blank or unknown grade" do
    assert_nil Problem.grade_rank(nil)
    assert_nil Problem.grade_rank("")
    assert_nil Problem.grade_rank("V4")
  end
end
