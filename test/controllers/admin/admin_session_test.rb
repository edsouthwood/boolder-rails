require "test_helper"

class Admin::AdminSessionTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_accounts, :accounts
      def accounts = { "admin" => "correct-password" }
    end
    Rails.cache.clear
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :accounts, :_real_accounts
      remove_method :_real_accounts
    end
    Rails.cache.clear
  end

  def auth_header
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "correct-password") }
  end

  def sign_in
    get admin_docs_url, headers: auth_header
    assert_response :success
  end

  test "a login is remembered without resending the password" do
    sign_in
    get admin_docs_url
    assert_response :success
  end

  test "a login expires after the session lifetime" do
    sign_in
    travel ApplicationController::ADMIN_SESSION_LIFETIME + 1.minute do
      get admin_docs_url
      assert_response :unauthorized
    end
  end

  test "signing out asks for the password again, even if the browser resends it" do
    sign_in
    delete admin_session_url
    assert_redirected_to root_path

    # The browser still has the password saved and sends it: ask afresh once
    get admin_docs_url, headers: auth_header
    assert_response :unauthorized

    get admin_docs_url, headers: auth_header
    assert_response :success
  end

  test "public pages show admin extras only while signed in" do
    area = Area.create!(name: "Bonehill", slug: "bonehill", published: true)
    problem = area.problems.create!(name: "Flagpole", grade: "5", steepness: "wall", lat: 50.6, lon: -3.9)

    get area_problem_url(area.slug, problem)
    assert_select "a[href=?]", admin_problem_path(problem), 0

    sign_in
    get area_problem_url(area.slug, problem)
    assert_select "a[href=?]", admin_problem_path(problem), 1

    travel ApplicationController::ADMIN_SESSION_LIFETIME + 1.minute do
      get area_problem_url(area.slug, problem)
      assert_select "a[href=?]", admin_problem_path(problem), 0
    end
  end
end
