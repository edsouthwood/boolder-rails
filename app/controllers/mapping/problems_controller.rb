class Mapping::ProblemsController < ApplicationController
  def show
    @problem = Problem.find(params[:id])
    return if hide_unpublished_area(@problem.area)

    @contributions = @problem.contributions.pending
  end

  def index
    @area = Area.find(params[:area_id])
    return if hide_unpublished_area(@area)

    @problems = @area.problems.incomplete.order("ascents DESC NULLS LAST")
  end
end
