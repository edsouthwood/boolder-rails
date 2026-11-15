require "test_helper"

class Mapping::ContributionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # The per-IP submission throttle counts across tests
    Rack::Attack.reset!
    @area = Area.create!(name: "Form Area", slug: "form-area")
    @problem = @area.problems.create!(steepness: "slab")
  end

  test "renders the contribution form (with the location picker) for a problem" do
    get new_mapping_contribution_url(problem_id: @problem.id)

    assert_response :success
    assert_select "div[data-controller*=location-picker]"
    assert_select "div[data-location-picker-target=map]"
    # The picker is wired to the area's boulder geojson so outlines are drawn.
    assert_select "div[data-location-picker-map-data-url-value*=?]", "area_id=#{@area.id}"
  end

  test "renders the contribution detail page" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "Looks great")
    get mapping_contribution_url(id: contribution.id)

    assert_response :success
    assert_select "body", text: /Looks great/
  end

  test "the form carries the start holds mode and field" do
    get new_mapping_contribution_url(problem_id: @problem.id)

    assert_select "button[data-mode=holds]"
    assert_select "input[type=hidden][name='contribution[start_holds]']"
    assert_select "button[data-mode=excluded]"
    assert_select "input[type=hidden][name='contribution[excluded_areas]']"
    assert_select "button[data-action='click->contribution-photo#zoomIn']"
    assert_select "button[data-action='click->contribution-photo#zoomOut']"
  end

  test "saves start holds submitted with a contribution" do
    # Submit the fields a freshly loaded form carries (invisible_captcha's spinner etc.), not too fast.
    get new_mapping_contribution_url(problem_id: @problem.id)
    fields = css_select("form input[type=hidden][name]").to_h { |input| [ input["name"], input["value"].to_s ] }

    travel 10.seconds do
      assert_difference "Contribution.count", 1 do
        post mapping_contributions_url, params: fields.merge(
          "contribution[comment]" => "Start matched on the jug", "contribution[start_holds]" => '[{"x":0.2,"y":0.8}]'
        )
      end
    end

    assert_equal [ { "x" => 0.2, "y" => 0.8 } ], Contribution.last.start_holds
  end

  test "starting from an area's list carries the published area into the unlisted form" do
    @area.update!(published: true)
    get new_mapping_contribution_url(area_id: @area.id)

    assert_select "input[type=hidden][name='contribution[area_id]'][value=?]", @area.id.to_s
    assert_select "input[name='contribution[area_name]']", count: 0
  end

  test "an unpublished or unknown area id is ignored and the crag name field shows instead" do
    get new_mapping_contribution_url(area_id: @area.id)

    assert_select "input[name='contribution[area_id]']", count: 0
    assert_select "input[name='contribution[area_name]']"
  end

  test "saves the crag name of an unlisted problem and drops an unpublished area id" do
    get new_mapping_contribution_url
    fields = css_select("form input[type=hidden][name]").to_h { |input| [ input["name"], input["value"].to_s ] }

    travel 10.seconds do
      assert_difference "Contribution.count", 1 do
        post mapping_contributions_url, params: fields.merge(
          "contribution[problem_name]" => "Hidden Arete", "contribution[area_name]" => "Secret Tor",
          "contribution[area_id]" => @area.id.to_s
        )
      end
    end

    contribution = Contribution.last
    assert_equal "Secret Tor", contribution.area_name
    assert_nil contribution.area_id
  end

  # --- drawing the next problem on a photo just sent ---

  LINE = '[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4},{"x":0.5,"y":0.6}]'

  # Posts the form for a problem as a browser would, with the captcha fields it carries
  def send_contribution(problem, extra = {})
    get new_mapping_contribution_url(problem_id: problem.id)
    fields = css_select("form input[type=hidden][name]").to_h { |input| [ input["name"], input["value"].to_s ] }
    travel 10.seconds do
      post mapping_contributions_url, params: fields.merge(
        "contribution[problem_id]" => problem.id, "contribution[line_coordinates]" => LINE
      ).merge(extra)
    end
  end

  def photo_upload
    Rack::Test::UploadedFile.new(StringIO.new("face photo"), "image/jpeg", original_filename: "face.jpg")
  end

  test "the next problem's form offers the photo just sent, and sending it shares the file" do
    send_contribution(@problem, "contribution[photos][]" => photo_upload)
    first = Contribution.last
    second_problem = @area.problems.create!(steepness: "wall")

    get new_mapping_contribution_url(problem_id: second_problem.id)
    assert_select "button[data-action='click->contribution-photo#selectRecentPhoto'][data-contribution-id=?]", first.id.to_s

    assert_difference "Contribution.count", 1 do
      send_contribution(second_problem, "contribution[source_contribution_id]" => first.id)
    end
    second = Contribution.last
    assert_equal second_problem, second.problem
    assert_equal first.photos.first.blob, second.photos.first.blob
  end

  test "lines drawn on one shared photo end up on one topo, as drawn" do
    send_contribution(@problem, "contribution[photos][]" => photo_upload)
    first = Contribution.last
    second_problem = @area.problems.create!(steepness: "wall")
    send_contribution(second_problem, "contribution[source_contribution_id]" => first.id)
    second = Contribution.last

    ContributionImporter.new(first).import!
    importer = ContributionImporter.new(second)
    assert_no_difference "Topo.count" do
      importer.import!
    end

    assert_equal first.problem.topos.first, importer.created_line.topo
    assert_equal JSON.parse(LINE), importer.created_line.coordinates
  end

  test "someone else's photo can't be reused" do
    stranger = Contribution.new(state: "pending", problem: @problem, comment: "theirs")
    stranger.photos.attach(io: StringIO.new("their photo"), filename: "theirs.jpg", content_type: "image/jpeg")
    stranger.save!

    get new_mapping_contribution_url(problem_id: @problem.id)
    assert_select "button[data-contribution-id=?]", stranger.id.to_s, count: 0

    send_contribution(@problem, "contribution[source_contribution_id]" => stranger.id, "contribution[comment]" => "mine")
    assert_not Contribution.last.photos.attached?
  end

  test "photos from another crag aren't offered" do
    send_contribution(@problem, "contribution[photos][]" => photo_upload)
    elsewhere = Area.create!(name: "Elsewhere", slug: "elsewhere").problems.create!(steepness: "wall")

    get new_mapping_contribution_url(problem_id: elsewhere.id)

    assert_select "button[data-action='click->contribution-photo#selectRecentPhoto']", count: 0
  end

  test "deleting one contribution's photo keeps the other's" do
    send_contribution(@problem, "contribution[photos][]" => photo_upload)
    first = Contribution.last
    send_contribution(@area.problems.create!(steepness: "wall"), "contribution[source_contribution_id]" => first.id)
    second = Contribution.last

    perform_enqueued_jobs { first.photos.purge_later }

    assert second.reload.photos.first.blob.service.exist?(second.photos.first.blob.key)
  end
end
