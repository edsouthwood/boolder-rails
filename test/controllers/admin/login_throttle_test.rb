require "test_helper"

class Admin::LoginThrottleTest < ActionDispatch::IntegrationTest
  # Fixed account so the test doesn't depend on credentials or ENV (works in CI too).
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

  def get_admin(password)
    get admin_docs_url(locale: :en),
      headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", password) }
  end

  test "refuses logins from an IP after too many wrong passwords" do
    Admin::BaseController::MAX_LOGIN_FAILURES.times do
      get_admin("wrong")
      assert_response :unauthorized
    end

    get_admin("correct-password")
    assert_response :too_many_requests
  end

  test "the right password still works below the limit" do
    (Admin::BaseController::MAX_LOGIN_FAILURES - 1).times { get_admin("wrong") }

    get_admin("correct-password")
    assert_response :success
  end
end
