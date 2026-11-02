class Mapping::ContributionsController < ApplicationController
  include RemembersContributor

  invisible_captcha only: [ :create ], on_spam: :handle_spam

  def show
    @contribution = Contribution.find(params[:id])
  end

  def new
    @contribution = Contribution.new(**remembered_contributor, problem_id: params[:problem_id],
                                     area: published_area(params[:area_id]))
    @area_topos = area_topos_for_problem(params[:problem_id])
  end

  def create
    @contribution = Contribution.new(contribution_params)
    # Only a published area can be named by id; an unknown crag goes in area_name.
    @contribution.area = published_area(@contribution.area_id)

    remember_contributor(@contribution)

    if @contribution.save
      flash[:notice] = t("views.mapping.contributions.new.flash_success")

      ContributeMailer.with(contribution: @contribution).new_contribution_email.deliver_later
      ContributeMailer.with(contribution: @contribution).acknowledgement_email.deliver_later

      # Unlisted-problem submissions have no problem to return to; show the contribution instead.
      redirect_to(@contribution.problem ? [ :mapping, @contribution.problem ] : [ :mapping, @contribution ])
    else
      @area_topos = area_topos_for_problem(@contribution.problem_id)
      render "new", status: :unprocessable_entity
    end
  end

  private

  # invisible_captcha honeypot tripped — silently drop and send the bot home.
  def handle_spam
    redirect_to mapping_path
  end

  def published_area(id)
    Area.published.find_by(id: id) if id.present?
  end

  def area_topos_for_problem(problem_id)
    problem = Problem.find_by(id: problem_id)
    return [] unless problem
    return [] unless problem.area.published

    topo_ids = Line.joins(:problem)
                   .where(problems: { area_id: problem.area_id })
                   .pluck(:topo_id)
                   .uniq
    Topo.published.where(id: topo_ids).order(id: :desc)
  end

  def contribution_params
    params.require(:contribution).permit(
      :location_lat, :location_lon, :comment, :problem_id, :contributor_name, :contributor_email,
      :problem_name, :problem_url, :ukc_url, :line_coordinates, :start_holds, :excluded_areas, :existing_topo_id,
      :area_id, :area_name, photos: [], line_drawings: []
    )
  end
end
