class Mapping::ContributionsController < ApplicationController
  invisible_captcha only: [ :create ], on_spam: :handle_spam

  def show
    @contribution = Contribution.find(params[:id])
  end

  def new
    @contribution = Contribution.new(
      problem_id: params[:problem_id],
      contributor_name: session[:contribution_name],
      contributor_email: session[:contribution_email],
    )
    @area_topos = area_topos_for_problem(params[:problem_id])
  end

  def create
    @contribution = Contribution.new(contribution_params)

    session[:contribution_name] = @contribution.contributor_name
    session[:contribution_email] = @contribution.contributor_email

    if @contribution.save
      flash[:notice] = t("views.mapping.contributions.new.flash_success")

      ContributeMailer.with(contribution: @contribution).new_contribution_email.deliver_later
      ContributeMailer.with(contribution: @contribution).acknowledgement_email.deliver_later

      redirect_to [ :mapping, @contribution.problem ]
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

  def area_topos_for_problem(problem_id)
    problem = Problem.find_by(id: problem_id)
    return [] unless problem
    topo_ids = Line.joins(:problem)
                   .where(problems: { area_id: problem.area_id })
                   .pluck(:topo_id)
                   .uniq
    Topo.where(id: topo_ids).order(id: :desc)
  end

  def contribution_params
    params.require(:contribution).permit(
      :location_lat, :location_lon, :comment, :problem_id, :contributor_name, :contributor_email,
      :problem_name, :problem_url, :ukc_url, :line_coordinates, :existing_topo_id,
      photos: [], line_drawings: []
    )
  end
end
