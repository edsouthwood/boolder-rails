require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  test "drops submissions that fill the honeypot" do
    get new_report_url(locale: :en)
    honeypot = css_select("input[name][tabindex='-1']").map { |input| input["name"] }.find { |name| !name.include?("[") }
    assert honeypot, "form should carry the invisible_captcha honeypot"

    travel 10.seconds do
      assert_no_difference "Contribution.count" do
        post reports_url(locale: :en), params: { honeypot => "spam", contribution: { comment: "Buy now" } }
      end
    end
  end
end
