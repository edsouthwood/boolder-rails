require "test_helper"

# Unpublished areas, their problems and unpublished photos stay hidden from the
# public (a 404, as if they didn't exist) but remain visible to signed-in admins.
class UnpublishedVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_accounts, :accounts
      def accounts = { "admin" => "correct-password" }
    end
    Rails.cache.clear

    @hidden = Area.create!(name: "Combestone", slug: "combestone", published: false)
    @hidden_problem = @hidden.problems.create!(name: "Secret Arete", grade: "6a", steepness: "wall", lat: 50.5, lon: -3.9)
    @hidden_topo = topo_for(@hidden_problem)

    @open = Area.create!(name: "Bonehill", slug: "bonehill", published: true)
    @open_problem = @open.problems.create!(name: "Flagpole", grade: "5", steepness: "wall", lat: 50.6, lon: -3.8)
    @open_topo = topo_for(@open_problem)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :accounts, :_real_accounts
      remove_method :_real_accounts
    end
    Rails.cache.clear
  end

  def topo_for(problem, published: true)
    topo = Topo.new(published: published)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: problem, topo: topo,
                 coordinates: [ { "x" => 0.2, "y" => 0.9 }, { "x" => 0.3, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ])
    topo
  end

  def sign_in_admin
    get admin_docs_url(locale: :en),
        headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "correct-password") }
    assert_response :success
  end

  def hidden_pages
    [
      area_url(@hidden.slug, locale: :en),
      area_problems_url(@hidden.slug, locale: :en),
      area_problem_url(@hidden.slug, @hidden_problem, locale: :en),
      problem_permalink_url(id: @hidden_problem.id, locale: :en),
      mapping_problem_url(@hidden_problem, locale: :en),
      mapping_problems_url(area_id: @hidden.id, locale: :en)
    ]
  end

  test "the public gets a 404 for an unpublished area and its problems" do
    hidden_pages.each do |url|
      get url
      assert_response :not_found, url
    end
    get area_offline_data_url(@hidden.slug, locale: :en)
    assert_response :not_found
  end

  test "published areas and problems are unaffected" do
    get area_url(@open.slug, locale: :en)
    assert_response :success
    get area_problem_url(@open.slug, @open_problem, locale: :en)
    assert_response :success
    assert_select "img[src^=?]", "/proxy/topos/#{@open_topo.id}"
  end

  test "signed-in admins can still see unpublished areas and their photos" do
    sign_in_admin
    hidden_pages.each do |url|
      get url
      assert_response :success, url unless url.include?("/p/")
    end
    get area_problem_url(@hidden.slug, @hidden_problem, locale: :en)
    # Admins load the photo through a signed URL, as the public proxy won't serve it
    assert_select "img[src*='/rails/active_storage/']"
  end

  test "the photo proxy only serves published photos in published areas" do
    assert @open_topo.publicly_visible?
    assert_not @hidden_topo.publicly_visible?
    unpublished = topo_for(@open_problem, published: false)
    assert_not unpublished.publicly_visible?

    get topo_proxy_url(@hidden_topo)
    assert_response :not_found
    get topo_proxy_url(unpublished)
    assert_response :not_found
  end

  test "the contribution form offers only published photos from published areas" do
    unpublished = topo_for(@open_problem, published: false)

    get new_mapping_contribution_url(problem_id: @open_problem.id, locale: :en)
    assert_response :success
    assert_match "Topo #{@open_topo.id}", response.body
    assert_no_match "Topo #{unpublished.id}\"", response.body
  end
end
