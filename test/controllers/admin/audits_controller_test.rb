require "test_helper"

class Admin::AuditsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    user = AdminUser.new(username: "someone", role: "super_admin", areas: [])
    Admin::BaseController.define_method(:current_admin_user) { user }
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  test "records without an admin page show as plain text instead of breaking the log" do
    area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    boulder = area.boulders.create!(name: "Big One")
    account = AdminAccount.create!(username: "helper", password: "a-long-enough-password", role: "super_admin")
    photo = PhotoContribution.new(area: area, state: "pending")
    photo.photo.attach(io: StringIO.new("fake image"), filename: "boulder.jpg", content_type: "image/jpeg")
    photo.save!(validate: false)

    get admin_audits_path

    assert_response :success
    assert_select "a[href=?]", admin_area_path(area), text: "Area ##{area.id}"
    [ "Boulder ##{boulder.id}", "AdminAccount ##{account.id}", "PhotoContribution ##{photo.id}" ].each do |label|
      assert_select "td div", text: label
      assert_select "a", text: label, count: 0
    end
  end

  test "filters by who and what, and pages back through older changes" do
    area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    Audited.audit_class.as_user("stamper") { area.problems.create!(name: "Stamped", grade: "4", steepness: "wall") }
    Audited.audit_class.as_user("dale") { area.update!(name: "Bell Tor East") }

    get admin_audits_path(user: "stamper")
    assert_response :success
    assert_select "option[selected][value=?]", "stamper"
    assert_select "td", text: "stamper"
    assert_select "td", text: "dale", count: 0

    get admin_audits_path(type: "Area")
    assert_select "td", text: "dale"
    assert_select "td", text: "stamper", count: 0

    get admin_audits_path(user: Admin::AuditsController::NO_NAME, type: "Area")
    assert_select "td", text: "dale", count: 0
    assert_select "td div", text: "Area ##{area.id}" # its create, with no one signed in

    get admin_audits_path(user: "nobody")
    assert_select "p", text: "No changes match."

    Audited.audit_class.as_user("stamper") do
      Admin::AuditsController::PER_PAGE.times { |i| area.update!(name: "Bell Tor #{i}") }
    end
    get admin_audits_path(user: "stamper")
    assert_select "td", text: "stamper", count: Admin::AuditsController::PER_PAGE
    assert_select "a[href=?]", admin_audits_path(user: "stamper", page: 2)
    get admin_audits_path(user: "stamper", page: 2)
    assert_select "td", text: "stamper", count: 1
  end
end
