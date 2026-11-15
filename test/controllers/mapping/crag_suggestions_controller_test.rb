require "test_helper"

class Mapping::CragSuggestionsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  # The fields a freshly loaded form carries (authenticity token, invisible_captcha's spinner)
  def form_fields(url, action)
    get url
    css_select("form[action$='#{action}'] input[type=hidden][name]").to_h { |input| [ input["name"], input["value"].to_s ] }
  end

  def suggest(**extra)
    fields = form_fields(new_mapping_crag_suggestion_url, "/mapping/crags")
    travel 10.seconds do
      post mapping_crag_suggestions_url, params: fields.merge(
        "crag_suggestion[name]" => "Hidden Tor", "crag_suggestion[location_lat]" => "50.55",
        "crag_suggestion[location_lon]" => "-3.85", "crag_suggestion[access_notes]" => "Park at the bridge",
        "crag_suggestion[contributor_email]" => "ann@example.com", **extra
      )
    end
  end

  def photo
    Rack::Test::UploadedFile.new(StringIO.new("fake image"), "image/jpeg", original_filename: "boulder.jpg")
  end

  test "the mapping page links to it" do
    get mapping_url
    assert_select "a[href=?]", new_mapping_crag_suggestion_path
  end

  test "saves the crag, emails staff and the contributor, then offers photos and problems" do
    assert_enqueued_emails 2 do
      assert_difference -> { CragSuggestion.count } do
        suggest
      end
    end

    crag = CragSuggestion.last
    assert_redirected_to mapping_crag_suggestion_path(crag)
    assert_equal "Hidden Tor", crag.name
    assert_in_delta 50.55, crag.location.lat, 1e-6

    follow_redirect!
    assert_select "a[href=?]", new_mapping_photo_contribution_path(crag_suggestion_id: crag.id)
    assert_select "a[href=?]", new_mapping_contribution_path(crag_suggestion_id: crag.id)
  end

  test "a pin outside the south-west is refused" do
    assert_no_difference -> { CragSuggestion.count } do
      suggest("crag_suggestion[location_lat]" => "0", "crag_suggestion[location_lon]" => "0")
    end
    assert_response :unprocessable_entity
  end

  test "the honeypot drops it" do
    assert_no_difference -> { CragSuggestion.count } do
      suggest(InvisibleCaptcha.honeypots.first => "spam")
    end
  end

  test "photos sent for it wait with it, without their own emails or a listed boulder" do
    area = Area.create!(name: "Listed Tor", slug: "listed-tor", published: true)
    d = 0.0001
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.85 + x, 50.55 + y) }
    area.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)), name: "Close Block")
    suggest
    crag = CragSuggestion.last

    fields = form_fields(new_mapping_photo_contribution_url(crag_suggestion_id: crag.id), "/mapping/photos")
    assert_equal crag.id.to_s, fields["photo_contribution[crag_suggestion_id]"]
    assert_select "select[name=area_id]", count: 0

    assert_enqueued_emails 0 do
      travel 10.seconds do
        post mapping_photo_contributions_url, params: fields.merge(photo: photo, lat: "50.55", lon: "-3.85", location_source: "photo"),
             headers: { "Accept" => "application/json" }
      end
    end
    assert_response :created

    pc = PhotoContribution.last
    assert_equal crag, pc.crag_suggestion
    assert_nil pc.area
    assert_nil pc.boulder, "a listed boulder nearby doesn't claim it"
  end

  test "problems sent for it are filed with it" do
    suggest
    crag = CragSuggestion.last

    fields = form_fields(new_mapping_contribution_url(crag_suggestion_id: crag.id), "/mapping/contributions")
    assert_select "input[name='contribution[area_name]']", count: 0
    travel 10.seconds do
      assert_enqueued_emails 0 do
        post mapping_contributions_url, params: fields.merge("contribution[problem_name]" => "Hidden Arete")
      end
    end

    contribution = Contribution.last
    assert_equal crag, contribution.crag_suggestion
    assert_equal "Hidden Tor", contribution.area_name
    assert_redirected_to mapping_crag_suggestion_path(crag)
  end

  test "another visitor can't send things for someone else's crag" do
    crag = CragSuggestion.create!(name: "Their Tor", location: FACTORY.point(-3.85, 50.55))

    get mapping_crag_suggestion_url(crag)
    assert_redirected_to new_mapping_crag_suggestion_path

    get new_mapping_photo_contribution_url(crag_suggestion_id: crag.id)
    assert_select "input[name='photo_contribution[crag_suggestion_id]']", count: 0

    fields = form_fields(new_mapping_contribution_url, "/mapping/contributions")
    travel 10.seconds do
      post mapping_contributions_url, params: fields.merge(
        "contribution[problem_name]" => "Sneaky", "contribution[crag_suggestion_id]" => crag.id.to_s
      )
    end
    assert_nil Contribution.last.crag_suggestion
  end
end
