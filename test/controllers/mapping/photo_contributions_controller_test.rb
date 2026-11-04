require "test_helper"

class Mapping::PhotoContributionsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @area = Area.create!(name: "Photo Tor", slug: "photo-tor", published: true)
    @neighbour = Area.create!(name: "Next Tor", slug: "next-tor", published: true)
    d = 0.0001
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.9 + x, 50.6 + y) }
    @neighbour_boulder = @neighbour.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)), name: "Neighbour Block")
  end

  def photo(type = "image/jpeg")
    Rack::Test::UploadedFile.new(StringIO.new("fake image"), type, original_filename: "boulder.jpg")
  end

  # The fields a freshly loaded page carries (authenticity token, invisible_captcha's spinner)
  def page_fields(area = @area)
    get new_mapping_photo_contribution_url(area_id: area.id)
    css_select("form[action$='/mapping/photos'] input[type=hidden][name]").to_h { |input| [ input["name"], input["value"].to_s ] }
  end

  def upload(fields, **params)
    travel 10.seconds do
      post mapping_photo_contributions_url, params: fields.merge(photo: photo, **params), as: nil,
           headers: { "Accept" => "application/json" }
    end
  end

  test "the page asks for an area first" do
    get new_mapping_photo_contribution_url

    assert_response :success
    assert_select "select[name=area_id] option", text: "Photo Tor"
    assert_select "form[data-controller=photo-contribution]", count: 0
  end

  test "with an area, offers the boulders with no photo yet" do
    egg = @area.boulders.create!(name: "The Egg")
    @area.problems.create!(name: "Eggy", steepness: "slab", boulder: egg)
    @area.problems.create!(name: "Secret", steepness: "slab", boulder: egg, hidden: true)

    # The Wave has a photo (a line on one of its problems), even though most of its problems aren't drawn
    wave = @area.boulders.create!(name: "The Wave")
    drawn = @area.problems.create!(name: "Wave Arete", steepness: "slab", boulder: wave)
    @area.problems.create!(name: "Undrawn", steepness: "slab", boulder: wave)
    topo = Topo.new.tap { |t| t.photo.attach(io: StringIO.new("x"), filename: "t.jpg", content_type: "image/jpeg"); t.save! }
    Line.create!(problem: drawn, topo: topo, coordinates: [ { x: 0.1, y: 0.1 }, { x: 0.2, y: 0.2 }, { x: 0.3, y: 0.3 } ])

    # A named boulder with no problems still counts; an unnamed outline with none doesn't
    @area.boulders.create!(name: "Lonely Block")
    @area.boulders.create!(polygon: @neighbour_boulder.polygon)

    get new_mapping_photo_contribution_url(area_id: @area.id, boulder_id: egg.id)

    assert_response :success
    assert_select "form[data-controller=photo-contribution]"
    assert_select "input[type=hidden][name='photo_contribution[area_id]'][value=?]", @area.id.to_s
    labels = css_select("label[data-boulder]").map { |l| l.text.squish }
    assert_equal 2, labels.size
    assert_match(/\AThe Egg Not on the map yet 1 problem: Eggy\z/, labels.first)
    assert_match(/Lonely Block/, labels.last)
    assert_select "input[name='photo_contribution[boulder_id]'][value=?][checked]", egg.id.to_s
    assert_select "input[name='photo_contribution[boulder_id]'][value='']"
  end

  test "a boulder with a photo waiting for review is marked" do
    egg = @area.boulders.create!(name: "The Egg")
    pc = PhotoContribution.new(area: @area, boulder: egg, boulder_chosen: true)
    pc.photo.attach(io: StringIO.new("x"), filename: "a.jpg", content_type: "image/jpeg")
    pc.save!

    get new_mapping_photo_contribution_url(area_id: @area.id)
    assert_select "label[data-boulder=?]", egg.id.to_s, text: /Photo waiting for review/
  end

  test "the chosen boulder wins over GPS, which is kept for the reviewer" do
    egg = @area.boulders.create!(name: "The Egg")
    upload(page_fields, "photo_contribution[boulder_id]" => egg.id.to_s, lat: "50.6002", lon: "-3.9")

    assert_response :created
    pc = PhotoContribution.last
    assert_equal egg, pc.boulder
    assert pc.boulder_chosen
    assert_equal @area, pc.area
    assert_equal @neighbour_boulder, pc.gps_boulder
    assert pc.gps_disagrees?
    assert_equal "The Egg", response.parsed_body["boulder"]
  end

  test "a boulder in an unpublished area can't be chosen" do
    hidden = Area.create!(name: "Hidden Tor", slug: "hidden-tor", published: false)
    secret = hidden.boulders.create!(name: "Secret Block")
    upload(page_fields, "photo_contribution[boulder_id]" => secret.id.to_s)

    assert_response :created
    assert_nil PhotoContribution.last.boulder
    assert_equal @area, PhotoContribution.last.area
  end

  test "an unpublished area isn't offered" do
    hidden = Area.create!(name: "Hidden Tor", slug: "hidden-tor", published: false)
    get new_mapping_photo_contribution_url(area_id: hidden.id)

    assert_select "select option", text: "Hidden Tor", count: 0
    assert_select "form[data-controller=photo-contribution]", count: 0
  end

  test "saves a photo, emails once per batch and remembers the contributor" do
    fields = page_fields
    batch = SecureRandom.uuid
    fields = fields.merge("photo_contribution[contributor_name]" => "Ann", "photo_contribution[contributor_email]" => "ann@example.com",
                          "photo_contribution[batch]" => batch)

    assert_enqueued_emails 2 do
      assert_difference -> { PhotoContribution.count } do
        upload(fields)
      end
    end
    assert_response :created

    pc = PhotoContribution.last
    assert pc.pending?
    assert_equal @area, pc.area
    assert_equal "Ann", pc.contributor_name
    assert_nil pc.location
    assert_equal false, response.parsed_body["located"]

    assert_enqueued_emails 0 do
      upload(fields)
    end
    assert_response :created

    get new_mapping_photo_contribution_url(area_id: @area.id)
    assert_select "input[name='photo_contribution[contributor_name]'][value=Ann]"
  end

  test "a photo's GPS matches it to a boulder, which decides the area" do
    upload(page_fields, lat: "50.6002", lon: "-3.9", heading: "200", location_source: "photo")

    assert_response :created
    pc = PhotoContribution.last
    assert_equal @neighbour_boulder, pc.boulder
    assert_not pc.boulder_chosen
    assert_equal @neighbour_boulder, pc.gps_boulder
    assert_not pc.gps_disagrees?
    assert_equal @neighbour, pc.area
    assert_equal 200.0, pc.heading
    assert_equal "photo", pc.location_source
    assert_equal "Neighbour Block", response.parsed_body["boulder"]
  end

  test "a phone position is recorded as such; nonsense positions are ignored" do
    upload(page_fields, lat: "50.7", lon: "-3.8", location_source: "device")
    assert_equal "device", PhotoContribution.last.location_source
    assert_nil PhotoContribution.last.boulder

    upload(page_fields, lat: "500", lon: "-3.8")
    assert_nil PhotoContribution.last.location
  end

  test "rejects non-images and unpublished areas" do
    hidden = Area.create!(name: "Hidden Tor", slug: "hidden-tor", published: false)
    fields = page_fields

    assert_no_difference -> { PhotoContribution.count } do
      travel 10.seconds do
        post mapping_photo_contributions_url, params: fields.merge(photo: photo("image/svg+xml")),
             headers: { "Accept" => "application/json" }
      end
      assert_response :unprocessable_entity

      upload(fields.merge("photo_contribution[area_id]" => hidden.id.to_s))
      assert_response :unprocessable_entity
    end
  end

  test "only the first photo of a batch needs the captcha; another batch needs a fresh page" do
    fields = page_fields.merge("photo_contribution[batch]" => SecureRandom.uuid)
    upload(fields)
    assert_response :created

    # No spinner or timestamp left, but the same batch
    post mapping_photo_contributions_url, params: { photo: photo, "photo_contribution[area_id]" => @area.id,
         "photo_contribution[batch]" => fields["photo_contribution[batch]"] }, headers: { "Accept" => "application/json" }
    assert_response :created

    post mapping_photo_contributions_url, params: { photo: photo, "photo_contribution[area_id]" => @area.id,
         "photo_contribution[batch]" => SecureRandom.uuid }, headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
  end

  test "an upload straight after the page loads is told to wait" do
    fields = page_fields
    post mapping_photo_contributions_url, params: fields.merge(photo: photo), headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    assert_equal "too_fast", response.parsed_body["error"]
  end
end
