require "test_helper"

class Admin::ProblemListsControllerTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])
  LIST = "  North Block\n  South Block\n\t\tName\tGrade\nNorth Block\nMorning sun\n\t\tOld Crack\tf4\n\t\tNew Arête\tf6B+\n" \
         "South Block\n\t\tSlab\tf3\n\t\tSummit\tSummit\n"

  # Bypass HTTP-basic admin auth without depending on credentials (so it works in CI too).
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      define_method(:current_admin_user) { AREA_ADMIN }
    end

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
    @old = @mine.problems.create!(name: "Old Crack", grade: "4+", steepness: "wall")
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  test "the paste form loads" do
    get admin_area_problem_list_path(area_slug: "mine")

    assert_response :success
    assert_select "textarea[name=text]"
  end

  test "preview shows what would change and saves nothing" do
    assert_no_difference -> { Boulder.count + Problem.count } do
      post admin_area_problem_list_preview_path(area_slug: "mine"), params: { text: LIST }
    end

    assert_response :success
    assert_select "h2", text: /North Block/
    assert_select "span", text: "matches"
    assert_select "input[type=checkbox][name='update_grades[]'][value='#{@old.id}']"
    assert_select "input[type=checkbox][value=new][checked]", 2
    assert_select "li", text: /Morning sun/
    assert_select "li", text: /Summit.*isn't a bouldering grade/
  end

  test "a list can be uploaded as a file" do
    file = Rack::Test::UploadedFile.new(StringIO.new(LIST.dup), "text/plain", original_filename: "list.txt")
    post admin_area_problem_list_preview_path(area_slug: "mine"), params: { file: file }

    assert_response :success
    assert_select "h2", text: /South Block/
  end

  test "importing creates the boulders and problems and assigns the matches" do
    post admin_area_problem_list_path(area_slug: "mine"), params: { text: LIST }

    assert_redirected_to admin_area_boulders_path(area_slug: "mine")
    assert_match "Imported: 2 boulders, 2 new problems, and 1 problem put on a boulder.", flash[:notice]
    north = @mine.boulders.find_by!(name: "North Block")
    assert_equal north, @old.reload.boulder
    assert_equal "4+", @old.grade, "grades only change when ticked"
    assert_equal [ "New Arête", "Old Crack" ], north.problems.order(:name).pluck(:name)
    assert_equal "6b+", @mine.problems.find_by!(name: "New Arête").grade
  end

  test "ticked grades are updated and unticked new problems are left out" do
    import = CragListImport.new(@mine, LIST)
    key = import.preview.first.rows.find { _1.row.name == "New Arête" }.row.key

    post admin_area_problem_list_path(area_slug: "mine"),
      params: { text: LIST, update_grades: [ @old.id ], choices: { key => "skip" } }

    assert_equal "4", @old.reload.grade
    assert_not @mine.problems.exists?(name: "New Arête")
  end

  test "the preview has a hide box per row, ticked for problems already hidden, and import applies it" do
    @old.update!(hidden: true)
    post admin_area_problem_list_preview_path(area_slug: "mine"), params: { text: LIST }
    assert_select "input[type=checkbox][name='hide[]']", 3
    assert_select "input[type=checkbox][name='hide[]'][checked]", 1

    key = CragListImport.new(@mine, LIST).preview.flat_map(&:rows).find { _1.row.name == "Slab" }.row.key
    post admin_area_problem_list_path(area_slug: "mine"), params: { text: LIST, hide: [ key ] }

    assert_match "1 problem hidden, and 1 problem shown again", flash[:notice]
    assert @mine.problems.find_by!(name: "Slab").hidden
    assert_not @old.reload.hidden
  end

  test "an empty paste is sent back with a message" do
    post admin_area_problem_list_preview_path(area_slug: "mine"), params: { text: "  " }

    assert_redirected_to admin_area_problem_list_path(area_slug: "mine")
    assert_equal "Paste a list or choose a file first.", flash[:error]
  end

  test "text with no boulder names is sent back with a message" do
    post admin_area_problem_list_preview_path(area_slug: "mine"), params: { text: "\t\tOnly\tf4\n" }

    assert_redirected_to admin_area_problem_list_path(area_slug: "mine")
    assert_match "No boulder names found", flash[:error]
  end

  test "area admins can't import into someone else's area" do
    post admin_area_problem_list_path(area_slug: "theirs"), params: { text: LIST }

    assert_response :redirect
    assert_not_equal admin_area_boulders_path(area_slug: "theirs"), URI(response.location).path
    assert_equal 0, @theirs.boulders.count
  end
end
