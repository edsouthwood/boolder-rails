class AreasController < ApplicationController
  def index
    # see https://guides.rubyonrails.org/caching_with_rails.html#avoid-caching-instances-of-active-record-objects
    @popular_areas_ids = Area.published.any_tags(:popular).pluck(:id).shuffle

    @areas_with_count = Area.published.sort_by { |a| I18n.transliterate(a.name) }
  end

  def levels
    # see https://guides.rubyonrails.org/caching_with_rails.html#avoid-caching-instances-of-active-record-objects
    @beginner_areas_ids = Area.beginner_friendly.pluck(:id)

    @areas_with_count = Area.published.map { |area| [ area, area.problems.shown.with_location.count ] }.sort { |a, b| b.second <=> a.second }
  end

  def show
    @area = Area.find_by!(slug: params[:slug])
    return if hide_unpublished_area(@area)

    @circuits = @area.main_circuits

    @popular_problems = @area.problems.shown.with_location.where(featured: true).order(grade: :desc, popularity: :desc)
    @nearby_areas = @area.nearby_areas
  end

  # Printable topo sheet: every published photo with its lines drawn and numbered,
  # then the area's other problems
  def print
    @area = Area.find_by!(slug: params[:slug])
    return if hide_unpublished_area(@area)

    lines = Line.reorder(nil).joins(:topo, :problem).merge(Topo.published).
      where(problems: { area_id: @area.id, hidden: false }).where.not(coordinates: nil).
      includes(:topo, problem: :circuit).to_a

    # Photos in boulder order (as linked automatically), lines left to right on each
    @topos = lines.group_by(&:topo).
      sort_by { |topo, _| [ topo.boulder_id || Float::INFINITY, topo.position || 0, topo.id ] }.
      map { |topo, topo_lines| [ topo, topo_lines.sort_by { |line| line.coordinates.first["x"].to_f } ] }

    # One number per problem, in reading order, reused if it's on more than one photo
    @numbers = {}
    @topos.each { |_, topo_lines| topo_lines.each { |line| @numbers[line.problem_id] ||= @numbers.size + 1 } }

    @without_topo = @area.problems.shown.with_location.where.not(id: @numbers.keys).includes(:circuit).
      sort_by { |problem| [ Problem.grade_rank(problem.grade) || 99, problem.name_with_fallback.to_s ] }

    render layout: "print"
  end

  def problems
    @area = Area.find_by!(slug: params[:slug])
    return if hide_unpublished_area(@area)

    @problems = @area.problems.shown.with_location.order(popularity: :desc).group_by { |p| p.grade }.sort_by { |grade, _| grade }.reverse
  end
end
