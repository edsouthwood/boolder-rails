require "test_helper"

class ContributionTest < ActiveSupport::TestCase
  # --- validations ---

  test "is invalid when it carries no useful content" do
    contribution = Contribution.new(state: "pending", contributor_name: "Ed")
    assert_not contribution.valid?
    assert_includes contribution.errors[:base].join, "must include"
  end

  test "is valid with any one piece of content" do
    assert Contribution.new(state: "pending", comment: "found a new boulder").valid?
    assert Contribution.new(state: "pending", problem_name: "Unnamed slab").valid?
  end

  test "rejects a malformed contributor email" do
    contribution = Contribution.new(state: "pending", comment: "hi", contributor_email: "not-an-email")
    assert_not contribution.valid?
    assert_includes contribution.errors.attribute_names, :contributor_email
  end

  test "accepts image uploads" do
    contribution = Contribution.new(state: "pending")
    contribution.photos.attach(io: StringIO.new("fake-bytes"), filename: "boulder.jpg", content_type: "image/jpeg")
    assert contribution.valid?
  end

  test "rejects non-image uploads" do
    contribution = Contribution.new(state: "pending")
    contribution.photos.attach(io: StringIO.new("%PDF-1.4 not a photo"), filename: "doc.pdf", content_type: "application/pdf")
    assert_not contribution.valid?
    assert_includes contribution.errors[:photos].join, "must be images"
  end

  test "rejects oversized uploads" do
    contribution = Contribution.new(state: "pending")
    contribution.line_drawings.attach(io: StringIO.new("fake-bytes"), filename: "line.png", content_type: "image/png")
    contribution.line_drawings.first.blob.byte_size = Contribution::MAX_ATTACHMENT_SIZE + 1
    assert_not contribution.valid?
    assert_includes contribution.errors[:line_drawings].join, "under"
  end

  test "rejects too many uploads" do
    contribution = Contribution.new(state: "pending")
    (Contribution::MAX_ATTACHMENTS_PER_KIND + 1).times do |i|
      contribution.photos.attach(io: StringIO.new("fake-bytes"), filename: "p#{i}.jpg", content_type: "image/jpeg")
    end
    assert_not contribution.valid?
    assert_includes contribution.errors[:photos].join, "more than"
  end

  test "accepts a blank contributor email" do
    assert Contribution.new(state: "pending", comment: "hi", contributor_email: "").valid?
  end

  test "has accepted?/closed?/pending? predicates" do
    assert Contribution.new(state: "accepted").accepted?
    assert Contribution.new(state: "closed").closed?
    assert Contribution.new(state: "pending").pending?
  end

  # Regression: Line's default order scope leaked into topo.problems and broke
  # the SELECT DISTINCT in this validation (PG::InvalidColumnReference).
  test "existing_topo area check runs despite Line default order scope" do
    area = Area.create!(name: "Area A", slug: "area-a", published: true)
    other_area = Area.create!(name: "Area B", slug: "area-b", published: true)
    topo_problem = Problem.create!(area: area, steepness: "wall")
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: topo_problem, topo: topo)

    same_area = Contribution.new(state: "pending", problem: Problem.create!(area: area, steepness: "wall"),
      existing_topo: topo, line_coordinates: '[{"x":0.1,"y":0.1}]')
    assert same_area.valid?

    cross_area = Contribution.new(state: "pending", problem: Problem.create!(area: other_area, steepness: "wall"),
      existing_topo: topo, line_coordinates: '[{"x":0.1,"y":0.1}]')
    assert_not cross_area.valid?
    assert_includes cross_area.errors.attribute_names, :existing_topo_id
  end

  # --- top_contributors ---

  test "top_contributors counts only accepted contributions" do
    accepted_contribution(name: "Alice")
    accepted_contribution(name: "Alice")
    contribution(name: "Bob",   state: "pending")
    contribution(name: "Carol", state: "closed")

    result = Contribution.top_contributors
    names = result.map(&:display_name)

    assert_includes names, "Alice"
    assert_not_includes names, "Bob"
    assert_not_includes names, "Carol"
    assert_equal 2, result.find { |c| c.display_name == "Alice" }.contributions_count
  end

  test "top_contributors groups case-insensitively and ignores surrounding whitespace" do
    accepted_contribution(name: "Sam")
    accepted_contribution(name: "sam")
    accepted_contribution(name: " SAM ")

    rows = Contribution.top_contributors.to_a

    assert_equal 1, rows.size
    assert_equal 3, rows.first.contributions_count
  end

  test "top_contributors ignores blank contributor names" do
    accepted_contribution(name: nil)
    accepted_contribution(name: "")

    assert_empty Contribution.top_contributors.to_a
  end

  test "top_contributors ranks by count desc then name for a stable order" do
    3.times { accepted_contribution(name: "Top") }
    accepted_contribution(name: "Beta")
    accepted_contribution(name: "Alpha")

    assert_equal %w[Top Alpha Beta], Contribution.top_contributors.map(&:display_name)
  end

  test "top_contributors honours the limit" do
    5.times { |i| accepted_contribution(name: "Person #{i}") }

    assert_equal 2, Contribution.top_contributors(limit: 2).to_a.size
  end

  private

  def contribution(name:, state:)
    Contribution.create!(contributor_name: name, state: state, comment: "test content")
  end

  def accepted_contribution(name:)
    contribution(name: name, state: "accepted")
  end
end
