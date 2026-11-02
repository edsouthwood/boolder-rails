class ProblemsController < ApplicationController
  def show
    @problem = Problem.find(params[:id])
    return if hide_unpublished_area(@problem.area)
    return render_404 if @problem.hidden && !admin_session?

    @line = @problem.lines.published.first
    @topo_neighbours = TopoNeighbours.new(@line.topo) if @line
  end

  # Browse every published problem of one grade, those with a topo photo first
  def index
    published = Problem.shown.joins(:area).where(areas: { published: true }).with_location
    counts = published.group(:grade).count
    @grades = Problem::DISPLAY_GRADE_VALUES.
      map { |grade| [ grade, Problem.grades_matching(grade).sum { |g| counts[g].to_i } ] }.
      select { |_, count| count.positive? }

    available = @grades.map(&:first)
    @grade = params[:grade].presence_in(available) || ("6a" if available.include?("6a")) || available.first

    @problems = published.where(grade: Problem.grades_matching(@grade)).
      preload(:area, :circuit).
      order(has_line: :desc).order("areas.name", "problems.name")
  end
end
