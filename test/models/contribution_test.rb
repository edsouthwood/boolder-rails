require "test_helper"

class ContributionTest < ActiveSupport::TestCase
  test "top_contributors counts only accepted contributions" do
    Contribution.create!(contributor_name: "Alice", state: "accepted")
    Contribution.create!(contributor_name: "Alice", state: "accepted")
    Contribution.create!(contributor_name: "Bob",   state: "pending")
    Contribution.create!(contributor_name: "Carol", state: "closed")

    result = Contribution.top_contributors
    names = result.map(&:display_name)

    assert_includes names, "Alice"
    assert_not_includes names, "Bob"
    assert_not_includes names, "Carol"
    assert_equal 2, result.find { |c| c.display_name == "Alice" }.contributions_count
  end

  test "top_contributors groups case-insensitively and ignores surrounding whitespace" do
    Contribution.create!(contributor_name: "Sam",   state: "accepted")
    Contribution.create!(contributor_name: "sam",   state: "accepted")
    Contribution.create!(contributor_name: " SAM ", state: "accepted")

    rows = Contribution.top_contributors.to_a

    assert_equal 1, rows.size
    assert_equal 3, rows.first.contributions_count
  end

  test "top_contributors ignores blank contributor names" do
    Contribution.create!(contributor_name: nil, state: "accepted")
    Contribution.create!(contributor_name: "",  state: "accepted")

    assert_empty Contribution.top_contributors.to_a
  end

  test "top_contributors ranks by count desc then name for a stable order" do
    3.times { Contribution.create!(contributor_name: "Top", state: "accepted") }
    Contribution.create!(contributor_name: "Beta",  state: "accepted")
    Contribution.create!(contributor_name: "Alpha", state: "accepted")

    assert_equal %w[Top Alpha Beta], Contribution.top_contributors.map(&:display_name)
  end

  test "top_contributors honours the limit" do
    5.times { |i| Contribution.create!(contributor_name: "Person #{i}", state: "accepted") }

    assert_equal 2, Contribution.top_contributors(limit: 2).to_a.size
  end
end
