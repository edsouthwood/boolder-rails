# Applies an accepted contribution to the real data: sets the problem's GPS, draws the
# contributed line (with any start holds and not-in areas) on a new or existing topo, and closes any open contribution requests.
#
# Which photo the problem goes on, first match wins:
# 1. merge_topo: a photo an admin picked. The line was drawn on the contributor's own photo,
#    so it can't be copied across: the problem gets an undrawn line there, linked back to this
#    contribution, to redraw in the workbench. (Unless it's the photo the contributor drew on.)
# 2. existing_topo: the photo the contributor drew on. The line goes on as drawn.
# 3. A topo whose photo is the very same file. The line goes on as drawn.
# 4. A new topo made from the contributed photo.
#
# Callers are expected to wrap #import! in a transaction (the admin controller does) so the
# whole import is atomic — a partial failure must not leave GPS applied without its line.
class ContributionImporter
  # What the import actually did, so callers can report it (e.g. in a flash message).
  # already_imported: the photo/line was found on the site from an earlier acceptance of
  # this contribution, so nothing was added.
  # merged_line: an undrawn line put on the admin's chosen photo, to be redrawn there.
  attr_reader :created_topo, :created_line, :merged_line, :applied_gps, :already_imported

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

    merge_topo = contribution.merge_topo
    drawn_on = contribution.existing_topo

    if merge_topo && merge_topo != drawn_on && merge_topo != same_photo_topo
      merge_onto(merge_topo, problem)
    elsif (topo = merge_topo || drawn_on)
      draw_on_existing_topo(topo, problem)
    elsif contribution.photos.any?
      same_photo_topo ? draw_on_same_photo(same_photo_topo, problem) : create_topo_with_line(problem)
    end
  end

  def same_photo_topo
    return @same_photo_topo if defined?(@same_photo_topo)

    @same_photo_topo = contribution.same_photo_topo
  end

  def draw_on_existing_topo(existing_topo, problem)
    return unless contribution.line_coordinates.present? || contribution.start_holds.present? || contribution.excluded_areas.present?
    return @already_imported = true if imported_line_on?(existing_topo, problem)

    @created_line = Line.create!(problem: problem, topo: existing_topo, coordinates: line_coordinates, **line_extras)
  end

  # The contributed photo is already a topo (sent twice, or accepted before): the line fits
  # it as drawn. Any line for this problem there already means it was imported before.
  def draw_on_same_photo(topo, problem)
    return @already_imported = true if topo.lines.where(problem: problem).exists?

    @created_line = Line.create!(problem: problem, topo: topo, coordinates: line_coordinates, **line_extras)
  end

  # Start holds and not-in areas are positions on the contributor's photo too, so they stay
  # behind with the line, on the reference shown in the workbench.
  def merge_onto(topo, problem)
    return @already_imported = true if topo.lines.where(problem: problem).exists?

    @merged_line = Line.create!(problem: problem, topo: topo, coordinates: nil, reference_contribution: contribution)
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
    @created_line = Line.create!(problem: problem, topo: topo, coordinates: line_coordinates, **line_extras)
    @created_topo = topo
  end

  # A contribution put back to pending and accepted again must not be imported twice. That's
  # checked against what is on the site (not a flag), so a photo or line an admin has since
  # deleted is imported afresh: the photo's topo is found by checksum (draw_on_same_photo).
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
