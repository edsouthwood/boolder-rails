class Admin::ContributionsController < Admin::BaseController
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

    ActiveRecord::Base.transaction do
      @contribution.update!(contribution_params)
      import_if_newly_accepted(previous_state)
    end

    send_transition_emails(previous_state)
    flash[:notice] = "Contribution updated"
    redirect_to edit_admin_contribution_path(@contribution)
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:error] = @contribution.errors.full_messages.join("; ").presence || e.message
    render "edit", status: :unprocessable_entity
  rescue => e
    flash.now[:error] = "Import failed, no changes were applied: #{e.message}"
    render "edit", status: :unprocessable_entity
  end

  private

  def import_if_newly_accepted(previous_state)
    return unless @contribution.state == "accepted" && previous_state == "pending"

    ContributionImporter.new(
      @contribution,
      apply_photo: param_flag(:apply_photo),
      apply_gps: param_flag(:apply_gps)
    ).import!
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
