require "test_helper"

class CragListImportTest < ActiveSupport::TestCase
  BELL_TOR = File.read(Rails.root.join("test/fixtures/files/crag_lists/bell_tor.txt"))

  setup do
    @area = Area.create!(name: "Import Test", slug: "import-test", published: true)
  end

  def problem(name, grade, **attrs)
    @area.problems.create!(name: name, grade: grade, steepness: "other", **attrs)
  end

  test "parses boulder names, problems and grades, ignoring notes and non-bouldering grades" do
    parsed = CragListImport.parse(BELL_TOR)

    assert_equal [ "Photo Arête", "Little Roof", "Main Roof", "Beau Wall Area", "Platform", "Slab Block",
                   "Isolated Block", "Summit Gully", "Undercuts Wall" ], parsed.sections.map(&:name)
    assert_equal 57, parsed.sections.sum { |section| section.rows.size }
    assert_equal [ "Traverse into Photo Arête", "6b" ], parsed.sections.first.rows.first.then { [ _1.name, _1.grade ] }

    skipped = parsed.skipped.map { |s| [ s.text, s.reason ] }
    assert_includes skipped, [ "Afternoon", "note under Main Roof, ignored" ]
    assert_includes skipped, [ "5 mins, Uphill", "note under Main Roof, ignored" ]
    assert_includes skipped, [ "Bell Tor Summit", "grade \"Summit\" isn't a bouldering grade" ]
    assert_equal 15, parsed.sections.find { _1.name == "Main Roof" }.rows.size
  end

  test "converts grades" do
    { "f6B" => "6b", "f6C+ " => "6c+", "f4+" => "4+", "f5" => "5", "7A" => "7a", "6b+" => "6b+",
      "Summit" => nil, "f6" => nil, "" => nil, nil => nil }.each do |raw, expected|
      assert_equal expected, CragListImport.convert_grade(raw), raw.inspect
    end
  end

  test "without a list at the top, a line straight after a boulder name is a note" do
    parsed = CragListImport.parse("North Face\nMorning sun\n\t\tCrack\tf4\nSouth Face\n\t\tSlab\tf3\n")

    assert_equal [ "North Face", "South Face" ], parsed.sections.map(&:name)
    assert_equal [ "Morning sun" ], parsed.skipped.map(&:text)
  end

  test "rows before any boulder name are skipped" do
    parsed = CragListImport.parse("\t\tLoose\tf4\nBlock\n\t\tTight\tf5\n")

    assert_equal [ "Tight" ], parsed.sections.flat_map(&:rows).map(&:name)
    assert_equal "problem before any boulder name", parsed.skipped.first.reason
  end

  test "names match ignoring accents, case and apostrophes" do
    assert_equal CragListImport.normalize("Craig's Sneaky Arête"), CragListImport.normalize("craigs sneaky arete")
  end

  test "preview matches existing problems, spots new ones and similar names" do
    photo = problem("Photo Arête", "5")
    sitter = problem("Arete Sitter", "6b") # accent-free spelling, different grade
    problem("Photo Wal", "4")              # one letter short of "Photo Wall"

    rows = CragListImport.new(@area, BELL_TOR).preview.flat_map(&:rows).index_by { _1.row.name }

    assert_equal [ :match, photo ], [ rows["Photo Arête"].action, rows["Photo Arête"].problem ]
    assert_equal sitter, rows["Arête Sitter"].problem
    assert rows["Arête Sitter"].grade_differs?
    assert_not rows["Photo Arête"].grade_differs?
    assert_equal :possible_match, rows["Photo Wall"].action
    assert_equal [ "Photo Wal" ], rows["Photo Wall"].similar.map(&:name)
    assert_equal :new, rows["Crack Fox"].action
  end

  test "apply creates boulders and new problems, assigns matches, and only changes ticked grades" do
    photo = problem("Photo Arête", "5")
    sitter = problem("Arête Sitter", "6b")
    wal = problem("Photo Wal", "4")
    import = CragListImport.new(@area, BELL_TOR)
    wall_key = import.preview.flat_map(&:rows).find { _1.row.name == "Photo Wall" }.row.key

    summary = import.apply!(choices: { wall_key => "problem:#{wal.id}" }, update_grades: [ sitter.id ])

    assert_equal 9, summary[:boulders_created]
    assert_equal 9, @area.boulders.unplaced.count
    arete = @area.boulders.find_by!(name: "Photo Arête")
    assert_equal arete, photo.reload.boulder
    assert_equal arete, wal.reload.boulder
    assert_equal "5", photo.grade
    assert_equal "6c", sitter.reload.grade
    assert_equal 54, summary[:problems_created] # 57 rows, minus the 3 that matched
    assert_equal 57, @area.problems.where.not(boulder_id: nil).count
  end

  test "applying the same list twice changes nothing the second time" do
    CragListImport.new(@area, BELL_TOR).apply!

    assert_no_difference -> { Boulder.count } do
      assert_no_difference -> { Problem.count } do
        summary = CragListImport.new(@area, BELL_TOR).apply!
        assert_equal 0, summary.values.sum
      end
    end
  end

  test "reuses an existing boulder of the same name and moves problems onto it" do
    drawn = @area.boulders.create!(name: "photo arete")
    elsewhere = @area.boulders.create!(name: "Somewhere Else")
    photo = problem("Photo Arête", "5", boulder: elsewhere)

    import = CragListImport.new(@area, BELL_TOR)
    plan = import.preview.first
    assert_equal drawn, plan.boulder
    assert_equal elsewhere, plan.moved_from(plan.rows.find { _1.problem == photo })

    summary = import.apply!
    assert_equal drawn, photo.reload.boulder
    assert_equal 1, summary[:moved]
    assert_equal 8, summary[:boulders_created]
  end

  test "new rows can be left out, and unticked possible matches are skipped" do
    problem("Photo Wal", "4")
    import = CragListImport.new(@area, "Block\n\t\tPhoto Wall\tf4\n\t\tFresh\tf5\n")
    keys = import.preview.first.rows.to_h { [ _1.row.name, _1.row.key ] }

    summary = import.apply!(choices: { keys["Fresh"] => "skip" })

    assert_equal 2, summary[:skipped]
    assert_equal 0, summary[:problems_created]
    assert_equal 1, @area.boulders.count # the boulder is still created
  end
  test "a new name whose problems sit on an unnamed outline names that outline instead of making another" do
    d = 0.0001
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.9 + x, 50.6 + y) }
    outline = @area.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)))
    photo = problem("Photo Arête", "5", lat: 50.6, lon: -3.9)
    assert_equal outline, photo.boulder

    import = CragListImport.new(@area, BELL_TOR)
    plan = import.preview.first
    assert plan.adopt
    assert_equal outline, plan.boulder
    assert_nil plan.moved_from(plan.rows.find { _1.problem == photo })

    summary = import.apply!
    assert_equal "Photo Arête", outline.reload.name
    assert_equal outline, photo.reload.boulder
    assert_equal [ 1, 8, 0 ], summary.values_at(:outlines_named, :boulders_created, :moved)
  end
  test "ticked rows are hidden, unticked ones shown, and no hide list leaves them alone" do
    already = problem("Photo Wall", "4", hidden: true)
    keep = problem("Photo Arête", "5")
    list = "Block\n\t\tPhoto Wall\tf4\n\t\tPhoto Arête\tf5\n\t\tFresh\tf6A\n"
    import = CragListImport.new(@area, list)
    keys = import.preview.first.rows.to_h { [ _1.row.name, _1.row.key ] }

    summary = import.apply!(hide: [ keys["Photo Arête"], keys["Fresh"] ])

    assert_not already.reload.hidden, "unticked: shown again"
    assert keep.reload.hidden
    assert @area.problems.find_by!(name: "Fresh").hidden
    assert_equal [ 2, 1 ], summary.values_at(:hidden, :unhidden)

    CragListImport.new(@area, list).apply!
    assert keep.reload.hidden, "without a hide list nothing changes"
  end
end
