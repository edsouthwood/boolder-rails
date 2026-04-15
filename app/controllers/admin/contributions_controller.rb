class Admin::ContributionsController < Admin::BaseController
  def index
    arel = Contribution.all.order(id: :desc)

    if params[:state].in?(Contribution::STATES)
      session[:contributions_filter] = params[:state]
      arel = arel.where(state: params[:state])
    end

    @contributions = arel
  end

  def edit
    set_contribution
  end

  def update
    set_contribution
    was_pending = @contribution.state == "pending"

    if @contribution.update(contribution_params)
      if @contribution.state == "accepted" && was_pending
        process_accepted_contribution(@contribution)
      end
      flash[:notice] = "Contribution updated"
      redirect_to edit_admin_contribution_path(@contribution)
    else
      flash[:error] = @contribution.errors.full_messages.join("; ")
      render "edit", status: :unprocessable_entity
    end
  end

  private

  def process_accepted_contribution(contribution)
    problem = contribution.problem
    return unless problem

    # Apply GPS location to the problem if not already located
    if contribution.location.present? && problem.location.nil?
      problem.update(location: contribution.location)
    end

    # Attach the first photo as a topo with a line
    if contribution.photos.any?
      photo = contribution.photos.first
      topo = Topo.new(published: true)
      topo.photo.attach(
        io: photo.download.then { |data| StringIO.new(data) },
        filename: photo.filename.to_s,
        content_type: photo.content_type
      )
      if topo.save
        coords = contribution.line_coordinates
        coords = JSON.parse(coords) if coords.is_a?(String)
        coords = coords.presence
        Line.create!(
          problem: problem,
          topo: topo,
          coordinates: coords
        )
      end
    end

    # Close any open contribution requests for this problem
    problem.contribution_requests.open.update_all(state: "closed")
  end

  def contribution_params
    params.require(:contribution).
      permit(:state)
  end

  def set_contribution
    @contribution = Contribution.find(params[:id])
  end
end
