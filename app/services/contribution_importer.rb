# Applies an accepted contribution to the real data: sets the problem's GPS, draws the
# contributed line on a new or existing topo, and closes any open contribution requests.
#
# Callers are expected to wrap #import! in a transaction (the admin controller does) so the
# whole import is atomic — a partial failure must not leave GPS applied without its line.
class ContributionImporter
  # What the import actually did, so callers can report it (e.g. in a flash message).
  attr_reader :created_topo, :created_line, :applied_gps

  def initialize(contribution, apply_photo: true, apply_gps: true)
    @contribution = contribution
    @apply_photo = apply_photo
    @apply_gps = apply_gps
  end

  def import!
    problem = contribution.problem
    return unless problem

    apply_gps!(problem)
    apply_photo_and_line!(problem)
    problem.contribution_requests.open.update_all(state: "closed")
  end

  private

  attr_reader :contribution

  def apply_gps!(problem)
    return unless @apply_gps && contribution.location.present? && problem.location.nil?

    problem.update!(location: contribution.location)
    @applied_gps = true
  end

  def apply_photo_and_line!(problem)
    return unless @apply_photo

    if contribution.existing_topo_id.present?
      draw_on_existing_topo(problem)
    elsif contribution.photos.any?
      create_topo_with_line(problem)
    end
  end

  def draw_on_existing_topo(problem)
    existing_topo = Topo.find_by(id: contribution.existing_topo_id)
    return unless existing_topo && contribution.line_coordinates.present?

    @created_line = Line.create!(problem: problem, topo: existing_topo, coordinates: line_coordinates)
  end

  def create_topo_with_line(problem)
    photo = contribution.photos.first
    topo = Topo.new(published: true)
    topo.photo.attach(
      io: StringIO.new(photo.download),
      filename: photo.filename.to_s,
      content_type: photo.content_type
    )
    topo.save!
    @created_line = Line.create!(problem: problem, topo: topo, coordinates: line_coordinates)
    @created_topo = topo
  end

  def line_coordinates
    coords = contribution.line_coordinates
    coords = JSON.parse(coords) if coords.is_a?(String)
    coords.presence
  end
end
