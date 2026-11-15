require "test_helper"

class Admin::CragSuggestionsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  SUPER_ADMIN = AdminUser.new(username: "boss", role: "super_admin")
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    login_as SUPER_ADMIN
    @crag = CragSuggestion.create!(name: "Hidden Tor", location: FACTORY.point(-3.85, 50.55), contributor_email: "ann@example.com")
    @photo = PhotoContribution.new(crag_suggestion: @crag).tap do |pc|
      pc.photo.attach(io: StringIO.new("fake image"), filename: "boulder.jpg", content_type: "image/jpeg")
      pc.save!
    end
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :current_admin_user, :_real_current_admin_user
      alias_method :authenticate, :_real_authenticate
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def login_as(user)
    Admin::BaseController.define_method(:current_admin_user) { user }
  end

  test "lists and shows pending suggestions with their photos" do
    get admin_crag_suggestions_url
    assert_response :success
    assert_select "a[href=?]", admin_crag_suggestion_path(@crag)

    get admin_crag_suggestion_url(@crag)
    assert_response :success
    assert_select "img[alt=?]", "Photo ##{@photo.id}"
  end

  test "its photos stay out of the photo queue until it's accepted" do
    get admin_photo_contributions_url
    assert_select "img[alt=?]", "Photo ##{@photo.id}", count: 0
  end

  test "accepting makes the area and emails the contributor" do
    assert_enqueued_emails 1 do
      assert_difference -> { Area.count } do
        post accept_admin_crag_suggestion_url(@crag), params: { area_name: "Hidden Tor" }
      end
    end
    assert_redirected_to admin_crag_suggestion_path(@crag)
    assert @crag.reload.accepted?
    assert_not @crag.area.published
    assert @photo.reload.accepted?
  end

  test "declining keeps it, with the note" do
    assert_no_difference -> { Area.count } do
      post close_admin_crag_suggestion_url(@crag), params: { moderator_note: "Already listed" }
    end
    assert_equal "closed", @crag.reload.state
    assert_equal "Already listed", @crag.moderator_note
  end

  test "area admins can't review suggested crags" do
    login_as AREA_ADMIN

    get admin_crag_suggestions_url
    assert_redirected_to admin_root_path

    assert_no_difference -> { Area.count } do
      post accept_admin_crag_suggestion_url(@crag)
    end
    assert @crag.reload.pending?
  end
end
