class Admin::BleauProblemsController < Admin::BaseController
  before_action :require_super_admin

  def index
    by_popularity = "ascents DESC NULLS LAST, id ASC"
    @bleau_problems = BleauProblem.unpromoted.order(by_popularity)
    @problems_with_name_mismatch = Problem.bleau_name_mismatch.order(by_popularity)
    @problems_with_grade_mismatch = Problem.bleau_grade_mismatch.order(by_popularity)
    @problems_with_sit_start_mismatch = Problem.order(by_popularity).bleau_sit_start_mismatches
  end

  def toggle_ignore
    @bleau_problem = BleauProblem.find(params[:id])
    @bleau_problem.update!(ignore: params[:ignore])
    action = params[:ignore] ? "ignored" : "unignored"
    redirect_to admin_bleau_problems_path, notice: "Bleau problem ##{@bleau_problem.id} has been #{action}"
  end
end
