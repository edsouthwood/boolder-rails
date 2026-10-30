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

  # The hidden fields a freshly loaded form carries (spinner etc.), as offline_reports.js sends them.
  def fresh_form_fields(**query)
    get new_report_url(locale: :en, **query)
    css_select("form[data-report-form-target=form] input[type=hidden][name]").to_h { |input| [ input["name"], input["value"].to_s ] }
  end

  setup do
    @area = Area.create!(name: "Report Tor", slug: "report-tor", published: true)
    @problem = @area.problems.create!(name: "Flagpole", grade: "5", steepness: "wall")
  end

  test "the form names the problem a report is about" do
    fields = fresh_form_fields(problem_id: @problem.id)
    assert_equal @problem.id.to_s, fields["contribution[problem_id]"]
    assert_select "[data-report-form-target=aboutName]", text: "Flagpole 5"
  end

  test "problem pages link to a report about that problem" do
    get area_problem_path(@area, @problem, locale: :en)
    assert_select "a[href=?]", new_report_path(locale: :en, problem_id: @problem.id)
  end

  test "a JSON submission saves the report against its problem" do
    fields = fresh_form_fields
    travel 10.seconds do
      assert_difference "Contribution.count", 1 do
        post reports_url(locale: :en), headers: { "Accept" => "application/json" },
          params: fields.merge("contribution[comment]" => "Grade is wrong", "contribution[problem_id]" => @problem.id.to_s)
      end
    end
    assert_response :created
    assert_equal @problem, Contribution.last.problem
    assert_equal "Grade is wrong", Contribution.last.comment
  end

  test "an unknown problem id is ignored rather than failing" do
    fields = fresh_form_fields
    travel 10.seconds do
      post reports_url(locale: :en), headers: { "Accept" => "application/json" },
        params: fields.merge("contribution[comment]" => "Hmm", "contribution[problem_id]" => "999999999")
    end
    assert_response :created
    assert_nil Contribution.last.problem
  end

  test "JSON says so when the spam checks reject a report" do
    fields = fresh_form_fields
    assert_no_difference "Contribution.count" do
      post reports_url(locale: :en), headers: { "Accept" => "application/json" },
        params: fields.merge("contribution[comment]" => "Too quick")
    end
    assert_response :unprocessable_entity
    assert_equal [ "too_fast" ], response.parsed_body["errors"]
  end
end
