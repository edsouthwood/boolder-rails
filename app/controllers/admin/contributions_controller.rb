class Admin::ContributionsController < Admin::BaseController
  def index
    arel = Contribution.includes(problem: :area).order(id: :desc)

    if params[:state].in?(Contribution::STATES)
      session[:contributions_filter] = params[:state]
      arel = arel.where(state: params[:state])
    end

    @contributions = arel
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
    was_pending = @contribution.state == "pending"

    if @contribution.update(contribution_params)
      if @contribution.state == "accepted" && was_pending
        options = {
          apply_photo: params.dig(:contribution, :apply_photo) == "1",
          apply_gps:   params.dig(:contribution, :apply_gps)   == "1",
        }
        process_accepted_contribution(@contribution, options)
      end
      flash[:notice] = "Contribution updated"
      redirect_to edit_admin_contribution_path(@contribution)
    else
      flash[:error] = @contribution.errors.full_messages.join("; ")
      render "edit", status: :unprocessable_entity
    end
  end

  private

  def process_accepted_contribution(contribution, options = {})
    apply_photo = options.fetch(:apply_photo, true)
    apply_gps   = options.fetch(:apply_gps,   true)

    problem = contribution.problem
    return unless problem

    # Apply GPS location to the problem if not already located
    if apply_gps && contribution.location.present? && problem.location.nil?
      problem.update(location: contribution.location)
    end

    # Draw line on an existing topo (contributor selected an existing photo)
    if apply_photo && contribution.existing_topo_id.present?
      existing_topo = Topo.find_by(id: contribution.existing_topo_id)
      if existing_topo && contribution.line_coordinates.present?
        coords = contribution.line_coordinates
        coords = JSON.parse(coords) if coords.is_a?(String)
        Line.create!(problem: problem, topo: existing_topo, coordinates: coords.presence)
      end
    # Attach the first uploaded photo as a new topo with a line
    elsif apply_photo && contribution.photos.any?
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
      permit(:state, :existing_topo_id)
  end

  def set_contribution
    @contribution = Contribution.find(params[:id])
  end
end
