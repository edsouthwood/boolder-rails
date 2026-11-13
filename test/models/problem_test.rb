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

  test "typed coordinates place the problem, as numbers or text" do
    area = Area.create!(name: "Coordinate Tor", slug: "coordinate-tor")
    problem = area.problems.create!(name: "Typed", grade: "5", steepness: "wall", lat: " 50.5712 ", lon: "-3.9341")
    assert_equal [ 50.5712, -3.9341 ], [ problem.lat, problem.lon ]

    problem.update!(lat: 50.6, lon: -3.9)
    assert_equal [ 50.6, -3.9 ], [ problem.reload.lat, problem.lon ]
  end

  test "coordinates that aren't coordinates are refused and the location is left alone" do
    area = Area.create!(name: "Coordinate Tor", slug: "coordinate-tor")
    problem = area.problems.create!(name: "Typed", grade: "5", steepness: "wall", lat: 50.5712, lon: -3.9341)

    { [ "50,5712", "-3.9341" ] => /Latitude must be a number.*50,5712/,
      [ "50.5712", "abc" ] => /Longitude must be a number.*abc/,
      [ "NaN", "-3.9341" ] => /Latitude must be a number/,
      [ "95", "-3.9341" ] => /Latitude must be a number between -90 and 90/,
      [ "50.5712", "-393.41" ] => /Longitude must be a number between -180 and 180/,
      [ "50.5712", "" ] => /go together/,
      [ nil, "-3.9341" ] => /go together/ }.each do |(lat, lon), message|
      assert_not problem.update(lat: lat, lon: lon), "#{lat.inspect}, #{lon.inspect} should be refused"
      assert_match message, problem.errors.full_messages.to_sentence
      assert_equal [ 50.5712, -3.9341 ], [ problem.reload.lat, problem.lon ]
    end

    assert problem.update(lat: "50.58", lon: "-3.93"), "a corrected pair goes through"
    assert_equal [ 50.58, -3.93 ], [ problem.reload.lat, problem.lon ]
  end

  test "clearing both coordinates removes the location, clearing neither keeps it" do
    area = Area.create!(name: "Coordinate Tor", slug: "coordinate-tor")
    problem = area.problems.create!(name: "Typed", grade: "5", steepness: "wall", lat: 50.5712, lon: -3.9341)

    problem.update!(name: "Renamed")
    assert problem.reload.location

    problem.update!(lat: "", lon: "")
    assert_nil problem.reload.location
  end
end
