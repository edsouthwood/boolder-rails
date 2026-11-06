require "test_helper"
require "minitest/mock"

class SupportPageTest < ActionDispatch::IntegrationTest
  test "the support page explains the running costs and adds up to £75" do
    get "/support"
    assert_response :success
    assert_select "h1", /home of its own/
    assert_select "dd", text: "£75"
    assert_select "img[src*='support-potato']"
  end

  test "without a donation address the page says donations open soon" do
    with_support_url(nil) do
      get "/support"
      assert_select "a", text: /Buy Bowda a coffee/, count: 0
      assert_match "Donations open soon", response.body
    end
  end

  test "with a donation address the button links to it" do
    with_support_url("https://ko-fi.com/example") do
      get "/support"
      assert_select "a[href='https://ko-fi.com/example'][rel='noopener']", text: /Buy Bowda a coffee/
    end
  end

  test "a donation address that isn't a web link is ignored" do
    with_support_url("javascript:alert(1)") do
      get "/support"
      assert_select "a", text: /Buy Bowda a coffee/, count: 0
    end
  end

  test "public pages give hello@bowda.rocks as the contact address" do
    get "/about"
    assert_select "a[href='mailto:hello@bowda.rocks']"
    get "/privacy"
    assert_match "hello@bowda.rocks", response.body
    assert_no_match "bowda@edsouthwood.com", response.body
  end

  test "the footer and about page link to the support page" do
    get "/about"
    assert_select "footer a[href='/support']"
    assert_select "main ~ div a[href='/support']"
  end

  private

  def with_support_url(value)
    previous = ENV["SUPPORT_URL"]
    value.nil? ? ENV.delete("SUPPORT_URL") : ENV["SUPPORT_URL"] = value
    Rails.application.credentials.stub(:support_url, nil) { yield }
  ensure
    previous.nil? ? ENV.delete("SUPPORT_URL") : ENV["SUPPORT_URL"] = previous
  end
end
