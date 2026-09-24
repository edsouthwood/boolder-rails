class Admin::ContributionsController < Admin::BaseController
  before_action :require_super_admin, only: [ :bulk_close ]
  before_action :require_contribution_area_access, only: [ :edit, :update, :create_problem ]
  before_action :require_new_problem_area_access, only: [ :create_problem ]

  def index
    # Default to the pending queue on first visit; an explicit blank state means "all".
    @state = params.key?(:state) ? params[:state] : "pending"

    arel = Contribution.includes(problem: :area).order(id: :desc)
    if @state.in?(Contribution::STATES)
      session[:contributions_filter] = @state
      arel = arel.where(state: @state)
    else
      session[:contributions_filter] = nil
    end

    @pending_count = Contribution.pending.count
    @contributions = arel.page(params[:page]).per(50)
  end

  def edit
    set_contribution
    @existing_topo = Topo.find_by(id: @contribution.existing_topo_id)
    @nearby_topos = []
    if (loc = @contribution.location)
      @nearby_topos = Topo.near_location(loc, 10)
                          .where.not(id: @contribution.existing_topo_id.to_i)
                          .includes(lines: :problem)
    end
  end

  def update
    set_contribution
    previous_state = @contribution.state
    importer = nil

    ActiveRecord::Base.transaction do
      @contribution.assign_attributes(contribution_params)
      stamp_review_metadata(previous_state)
      @contribution.save!
      importer = import_if_newly_accepted(previous_state)
    end

    send_transition_emails(previous_state)

    # Accept/close are queue actions: go back to the list so the reviewer can
    # carry on triaging. Plain edits (e.g. moderator note) stay on the page.
    if @contribution.state != previous_state && @contribution.state.in?(%w[accepted closed])
      flash[:notice] = state_change_notice(importer)
      redirect_to admin_contributions_path(state: session[:contributions_filter].presence)
    else
      flash[:notice] = "Contribution updated"
      redirect_to edit_admin_contribution_path(@contribution)
    end
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:error] = @contribution.errors.full_messages.join("; ").presence || e.message
    render "edit", status: :unprocessable_entity
  rescue => e
    flash.now[:error] = "Import failed, no changes were applied: #{e.message}"
    render "edit", status: :unprocessable_entity
  end

  # Creates a real Problem from an "unlisted problem" contribution and links it, so the
  # contribution can then be accepted to import the photo/line/GPS as usual.
  def create_problem
    set_contribution

    if @contribution.problem.present?
      flash[:error] = "This contribution is already linked to a problem."
      return redirect_to edit_admin_contribution_path(@contribution)
    end

    problem = Problem.new(new_problem_params)
    problem.location = @contribution.location if @contribution.location.present?

    if problem.save
      @contribution.update!(problem: problem)
      flash[:notice] = "Problem ##{problem.id} created and linked. Accept the contribution to import the photo and line."
    else
      flash[:error] = "Could not create problem: #{problem.errors.full_messages.join(', ')}"
    end
    redirect_to edit_admin_contribution_path(@contribution)
  end

  # Closes (declines) several contributions at once, with an optional shared note. Accept is
  # deliberately not bulk: each acceptance needs per-contribution photo/line/GPS decisions.
  def bulk_close
    ids = Array(params[:contribution_ids]).reject(&:blank?)
    note = params[:moderator_note].presence
    closed = 0

    Contribution.where(id: ids).where.not(state: "closed").find_each do |contribution|
      attrs = { state: "closed", closed_at: Time.current, reviewed_by: current_admin_user&.username }
      attrs[:moderator_note] = note if note
      begin
        contribution.update!(attrs)
        ContributeMailer.with(contribution: contribution).declined_email.deliver_later
        closed += 1
      rescue ActiveRecord::RecordInvalid
        next
      end
    end

    flash[:notice] = "Closed #{closed} #{'contribution'.pluralize(closed)}."
    redirect_to admin_contributions_path(state: session[:contributions_filter].presence)
  end

  private

  # Unlisted-problem contributions have no area yet, so only super admins may review them.
  def require_contribution_area_access
    area = Contribution.find(params[:id]).problem&.area
    area ? require_area_access(area.slug) : require_super_admin
  end

  def require_new_problem_area_access
    area = Area.find_by(id: params.dig(:problem, :area_id))
    require_area_access(area.slug) if area
  end

  def new_problem_params
    params.require(:problem).permit(:area_id, :name, :grade, :steepness)
  end

  def import_if_newly_accepted(previous_state)
    return unless @contribution.state == "accepted" && previous_state == "pending"

    importer = ContributionImporter.new(
      @contribution,
      apply_photo: param_flag(:apply_photo),
      apply_gps: param_flag(:apply_gps)
    )
    importer.import!
    importer
  end

  # "Contribution #123 accepted · line added to Topo #74 · 2 pending remaining",
  # with the topo linked so the import is one click away to verify.
  def state_change_notice(importer)
    parts = [ "Contribution ##{@contribution.id} #{@contribution.state}" ]

    if importer&.created_topo
      parts << helpers.link_to("new Topo ##{importer.created_topo.id} created",
        edit_admin_topo_path(importer.created_topo), class: "underline")
    elsif importer&.created_line
      parts << helpers.link_to("line added to Topo ##{importer.created_line.topo_id}",
        edit_admin_topo_path(importer.created_line.topo), class: "underline")
    end
    parts << "GPS applied" if importer&.applied_gps
    parts << "#{Contribution.pending.count} pending remaining"

    helpers.safe_join(parts, " · ")
  end

  # Records who reviewed the contribution and when it changed state.
  def stamp_review_metadata(previous_state)
    return if @contribution.state == previous_state

    case @contribution.state
    when "accepted"
      @contribution.accepted_at = Time.current
      @contribution.reviewed_by = current_admin_user&.username
    when "closed"
      @contribution.closed_at = Time.current
      @contribution.reviewed_by = current_admin_user&.username
    end
  end

  def send_transition_emails(previous_state)
    return if @contribution.state == previous_state

    case @contribution.state
    when "accepted"
      ContributeMailer.with(contribution: @contribution).accepted_email.deliver_later
    when "closed"
      ContributeMailer.with(contribution: @contribution).declined_email.deliver_later
    end
  end

  def param_flag(name)
    params.dig(:contribution, name) == "1"
  end

  def contribution_params
    params.require(:contribution).
      permit(:state, :existing_topo_id, :moderator_note)
  end

  def set_contribution
    @contribution = Contribution.find(params[:id])
  end
end
