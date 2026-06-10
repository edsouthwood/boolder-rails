require "test_helper"

class Admin::ContributionsControllerTest < ActionDispatch::IntegrationTest
  # Bypass HTTP-basic admin auth without depending on credentials (so it works in CI too).
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      def current_admin_user = AdminUser.new(username: "tester", role: "super_admin")
    end

    @area = Area.create!(name: "Admin Area", slug: "admin-area", published: true)
    @problem = @area.problems.create!(steepness: "slab")
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  # --- views render ---

  test "index renders with the bulk-close form" do
    Contribution.create!(state: "pending", problem: @problem, comment: "a")
    get admin_contributions_url(locale: :en)
    assert_response :success
    assert_select "form[action=?]", bulk_close_admin_contributions_path
    assert_select "input[type=checkbox][name='contribution_ids[]']"
  end

  test "edit of an unlisted contribution renders the create-problem form" do
    contribution = Contribution.create!(state: "pending", comment: "new", problem_name: "Secret Slab")
    get edit_admin_contribution_url(contribution, locale: :en)
    assert_response :success
    assert_select "form[action=?]", create_problem_admin_contribution_path(contribution)
    assert_select "select[name='problem[area_id]']"
  end

  test "edit shows a line-only label for an existing-topo contribution, with no photo checkbox confusion" do
    topo = Topo.new(published: true)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: @problem, topo: topo)
    contribution = Contribution.create!(state: "pending", problem: @problem,
      existing_topo_id: topo.id, line_coordinates: '[{"x":0.1,"y":0.1}]')

    get edit_admin_contribution_url(contribution, locale: :en)

    assert_response :success
    assert_match "Line on Topo ##{topo.id}", response.body
    assert_match "No GPS in this contribution", response.body
  end

  test "edit shows nothing-to-import notes for a comment-only contribution" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "just a note")

    get edit_admin_contribution_url(contribution, locale: :en)

    assert_response :success
    assert_match "No photo or line to import", response.body
    assert_match "No GPS in this contribution", response.body
  end

  # --- B8: lifecycle metadata ---

  test "accepting a contribution stamps accepted_at and reviewer" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "nice")

    patch admin_contribution_url(contribution, locale: :en), params: { contribution: { state: "accepted" } }

    contribution.reload
    assert_equal "accepted", contribution.state
    assert_not_nil contribution.accepted_at
    assert_equal "tester", contribution.reviewed_by
  end

  test "closing a contribution stamps closed_at and reviewer" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "spam")

    patch admin_contribution_url(contribution, locale: :en), params: { contribution: { state: "closed" } }

    contribution.reload
    assert_equal "closed", contribution.state
    assert_not_nil contribution.closed_at
    assert_equal "tester", contribution.reviewed_by
  end

  # --- accept/close return to the queue ---

  test "accepting redirects to the contributions list with a summary linking the topo" do
    topo = Topo.new(published: true)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    contribution = Contribution.create!(state: "pending", problem: @problem,
      existing_topo_id: topo.id, line_coordinates: '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]')

    assert_difference -> { topo.lines.count }, 1 do
      patch admin_contribution_url(contribution, locale: :en),
            params: { contribution: { state: "accepted", apply_photo: "1", apply_gps: "1" } }
    end

    assert_redirected_to admin_contributions_path
    follow_redirect!
    assert_match "Contribution ##{contribution.id} accepted", response.body
    assert_select "a[href=?]", edit_admin_topo_path(topo), text: "line added to Topo ##{topo.id}"
    assert_match "pending remaining", response.body
  end

  test "closing redirects to the contributions list" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "spam")

    patch admin_contribution_url(contribution, locale: :en), params: { contribution: { state: "closed" } }

    assert_redirected_to admin_contributions_path
    follow_redirect!
    assert_match "Contribution ##{contribution.id} closed", response.body
  end

  test "an update without a state change stays on the edit page" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "hi")

    patch admin_contribution_url(contribution, locale: :en),
          params: { contribution: { state: "pending", moderator_note: "checking" } }

    assert_redirected_to edit_admin_contribution_path(contribution)
  end

  # --- B9: create problem from an unlisted contribution ---

  test "create_problem builds and links a problem from an unlisted contribution" do
    point = RGeo::Geographic.spherical_factory(srid: 4326).point(-3.9, 50.58)
    contribution = Contribution.create!(state: "pending", comment: "new line", problem_name: "Secret Slab", location: point)

    assert_difference -> { Problem.count }, 1 do
      post create_problem_admin_contribution_url(contribution, locale: :en),
           params: { problem: { area_id: @area.id, name: "Secret Slab", grade: "5", steepness: "slab" } }
    end

    contribution.reload
    assert_not_nil contribution.problem
    assert_equal "Secret Slab", contribution.problem.name
    assert_equal @area.id, contribution.problem.area_id
    assert_not_nil contribution.problem.location, "the new problem inherits the contribution's GPS"
  end

  test "create_problem refuses when a problem is already linked" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "x")

    assert_no_difference -> { Problem.count } do
      post create_problem_admin_contribution_url(contribution, locale: :en),
           params: { problem: { area_id: @area.id, name: "Dup", steepness: "slab" } }
    end
  end

  # --- A4: bulk close ---

  test "bulk_close closes the selected contributions with a shared note" do
    a = Contribution.create!(state: "pending", problem: @problem, comment: "a")
    b = Contribution.create!(state: "pending", problem: @problem, comment: "b")
    keep = Contribution.create!(state: "pending", problem: @problem, comment: "keep")

    post bulk_close_admin_contributions_url(locale: :en),
         params: { contribution_ids: [ a.id, b.id ], moderator_note: "Out of scope" }

    assert_equal "closed", a.reload.state
    assert_equal "closed", b.reload.state
    assert_equal "Out of scope", a.moderator_note
    assert_not_nil a.closed_at
    assert_equal "pending", keep.reload.state
  end
end
