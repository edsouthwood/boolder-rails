# Applies an accepted contribution to the real data: sets the problem's GPS, draws the
# contributed line (with any start holds and not-in areas) on a new or existing topo, and closes any open contribution requests.
#
# Callers are expected to wrap #import! in a transaction (the admin controller does) so the
# whole import is atomic — a partial failure must not leave GPS applied without its line.
class ContributionImporter
  # What the import actually did, so callers can report it (e.g. in a flash message).
  # already_imported: the photo/line was found on the site from an earlier acceptance of
  # this contribution, so nothing was added.
  attr_reader :created_topo, :created_line, :applied_gps, :already_imported

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
    return unless existing_topo && (contribution.line_coordinates.present? || contribution.start_holds.present? || contribution.excluded_areas.present?)
    return @already_imported = true if imported_line_on?(existing_topo, problem)

    @created_line = Line.create!(problem: problem, topo: existing_topo, coordinates: line_coordinates, **line_extras)
  end

  def create_topo_with_line(problem)
    photo = contribution.photos.first
    return @already_imported = true if imported_topo_for?(photo, problem)

    topo = Topo.new(published: true)
    topo.photo.attach(
      io: StringIO.new(photo.download),
      filename: photo.filename.to_s,
      content_type: photo.content_type
    )
    topo.save!
    @created_line = Line.create!(problem: problem, topo: topo, coordinates: line_coordinates, **line_extras)
    @created_topo = topo
  end

  # A contribution put back to pending and accepted again must not be imported twice.
  # Checked against what is on the site (not a flag), so a photo or line an admin has
  # since deleted is imported afresh.
  def imported_topo_for?(photo, problem)
    Topo.joins(:lines, photo_attachment: :blob).
      where(lines: { problem_id: problem.id }, active_storage_blobs: { checksum: photo.blob.checksum }).exists?
  end

  def imported_line_on?(topo, problem)
    topo.lines.where(problem: problem).any? do |line|
      line.coordinates == line_coordinates && line.start_holds.presence == contribution.start_holds.presence &&
        line.excluded_areas.presence == contribution.excluded_areas.presence
    end
  end

  def line_extras
    { start_holds: contribution.start_holds, excluded_areas: contribution.excluded_areas }
  end

  # The contribute form accepts a two-click straight line, but a Line needs at least 3
  # points, so a midpoint is added (the curve through three collinear points is straight).
  # A single point isn't a line at all and is dropped; any start holds still import.
  def line_coordinates
    coords = contribution.line_coordinates
    coords = JSON.parse(coords) if coords.is_a?(String)
    coords = Array(coords)
    return nil if coords.size < 2
    return coords unless coords.size == 2

    a, b = coords
    mid = { "x" => ((a["x"] + b["x"]) / 2.0).round(4), "y" => ((a["y"] + b["y"]) / 2.0).round(4) }
    [ a, mid, b ]
  end
end
