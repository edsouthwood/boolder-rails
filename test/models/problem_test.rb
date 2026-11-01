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

  test "grades_matching folds legacy detailed grades into the simplified sub-6a ones" do
    assert_equal %w[4 4a 4a+ 4b], Problem.grades_matching("4")
    assert_equal %w[4+ 4b+ 4c 4c+], Problem.grades_matching("4+")
    assert_equal %w[6a+], Problem.grades_matching("6a+")
    assert_equal [], Problem.grades_matching("4a")
    assert_equal [], Problem.grades_matching("nonsense")
  end

  test "bleau mismatch scopes find problems that differ from bleau.info" do
    bleau_area = BleauArea.create!(slug: "bas-cuvier", name: "Bas Cuvier")
    area = Area.create!(name: "Cuvier", slug: "cuvier", bleau_area: bleau_area)
    bleau = BleauProblem.create!(id: 1, bleau_area: bleau_area, name: "La Marie-Rose", grade: "6a", steepness: "wall", sit_start: false)
    unpromoted = BleauProblem.create!(id: 2, bleau_area: bleau_area, name: "Big Boss", grade: "7a", steepness: "wall")
    same = area.problems.create!(name: "La Marie-Rose", grade: "6a", steepness: "wall", bleau_info_id: bleau.id)

    assert_equal [ unpromoted ], BleauProblem.unpromoted.to_a
    assert_empty Problem.bleau_name_mismatch
    same.update!(name: "Marie Rose", grade: "6a+", sit_start: true)
    assert_equal [ same ], Problem.bleau_name_mismatch.to_a
    assert_equal [ same ], Problem.bleau_grade_mismatch.to_a
    assert_equal [ same ], Problem.bleau_sit_start_mismatches
    same.update!(name: "Marie Rose (assis)")
    assert_empty Problem.bleau_sit_start_mismatches, "an (assis) name is a sit start whatever bleau.info says"
  end
end
