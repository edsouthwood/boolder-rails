require "test_helper"

class Admin::PhotoContributionsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    Admin::BaseController.define_method(:current_admin_user) { AREA_ADMIN }

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :current_admin_user, :_real_current_admin_user
      alias_method :authenticate, :_real_authenticate
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def photo_contribution(area = @mine, **attrs)
    PhotoContribution.new(area: area, **attrs).tap do |pc|
      pc.photo.attach(io: StringIO.new("fake image"), filename: "boulder.jpg", content_type: "image/jpeg")
      pc.save!
    end
  end

  test "lists pending photos in the admin's areas only" do
    photo_contribution(contributor_name: "Ann", comment: "North face")
    photo_contribution(@theirs, contributor_name: "Zed")
    photo_contribution(contributor_name: "Old").close!(reviewed_by: "x")

    get admin_photo_contributions_path(locale: :en)

    assert_response :success
    assert_select "li", text: /Ann/
    assert_select "li", text: /North face/
    assert_select "li", text: /Zed/, count: 0
    assert_select "li", text: /Old/, count: 0
    assert_select "button[value=accept]"
  end

  test "accepting selected photos makes topos and emails each contributor once" do
    a = photo_contribution(contributor_email: "ann@example.com", contributor_name: "Ann")
    b = photo_contribution(contributor_email: "ANN@example.com")
    c = photo_contribution

    assert_enqueued_emails 1 do
      assert_difference -> { Topo.count }, 3 do
        post review_admin_photo_contributions_path(locale: :en), params: { decision: "accept", ids: [ a.id, b.id, c.id ] }
      end
    end

    assert_redirected_to admin_photo_contributions_path(locale: :en)
    assert [ a, b, c ].all? { |pc| pc.reload.accepted? && pc.topo.present? }
    assert_equal "local", a.reviewed_by
    assert_match "Photos to draw at Mine", flash[:notice]
  end

  test "a card's own button reviews just that photo" do
    a = photo_contribution
    b = photo_contribution

    post review_admin_photo_contributions_path(locale: :en, only_id: a.id), params: { decision: "close", ids: [ a.id, b.id ] }

    assert a.reload.closed?
    assert b.reload.pending?
  end

  test "declining sends the note" do
    a = photo_contribution(contributor_email: "ann@example.com")

    assert_enqueued_email_with PhotoContributionMailer, :reviewed_email,
        params: { contributor_email: "ann@example.com", contributor_name: nil, accepted: 0, closed: 1, note: "Too dark" } do
      post review_admin_photo_contributions_path(locale: :en), params: { decision: "close", ids: [ a.id ], moderator_note: "Too dark" }
    end
    assert_equal "Too dark", a.reload.moderator_note
  end

  test "no decision, or photos in someone else's area, changes nothing" do
    mine = photo_contribution
    theirs = photo_contribution(@theirs)

    post review_admin_photo_contributions_path(locale: :en), params: { decision: "", ids: [ mine.id ] }
    assert mine.reload.pending?

    assert_no_difference -> { Topo.count } do
      post review_admin_photo_contributions_path(locale: :en), params: { decision: "accept", ids: [ theirs.id ] }
    end
    assert theirs.reload.pending?
  end
end
