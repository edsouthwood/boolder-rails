class Mapping::ProblemsController < ApplicationController
  def show
    @problem = Problem.find(params[:id])
    @contributions = @problem.contributions.pending
  end

  def index
    @area = Area.find(params[:area_id])
    @problems = @area.problems.incomplete.order("ascents DESC NULLS LAST")
  end
end
