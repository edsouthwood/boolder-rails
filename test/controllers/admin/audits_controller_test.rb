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
end
