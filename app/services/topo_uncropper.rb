# Shows a portrait photo whole that was stored before uncropped topos came in: its topo shows
# only the middle of the photo (the 4:3 crop), with lines drawn on that crop.
#
# The cropped topo is kept and a new, uncropped topo of the same photo (same file, nothing
# re-uploaded) replaces it, the way an admin replaces a photo with a better one: a new topo
# rather than a new picture on the old one, because /proxy/topos/:id is cached forever by id.
# Its lines are the old ones moved to where they sit on the whole photo, then it's swapped in,
# so undo on the old topo's page puts things back.
#
# Lines drawn in the line editor or workbench were drawn on the crop and are moved. A line
# imported from a contribution as it was sent was drawn by the contributor on their whole
# photo (it was out of place on the crop), so it's copied as it is. Start holds and not-in
# areas are judged the same way, each on its own.
class TopoUncropper
  Result = Struct.new(:old, :new_topo, :status, :message, keyword_init: true)

  # The stored crop: :medium is resize_to_fill [1200, 900], which keeps the middle
  CROP_RATIO = Topo::CROPPED_ASPECT_RATIO

  # Cropped topos whose photo is portrait (taller than it is wide)
  def self.candidates
    Topo.where(uncropped: false).includes(photo_attachment: :blob).order(:id).select do |topo|
      next false unless topo.photo.attached?

      topo.photo.analyze unless topo.photo.analyzed?
      width, height = topo.photo.metadata.values_at("width", "height").map(&:to_f)
      width.positive? && height > width
    rescue ActiveStorage::FileNotFoundError
      false
    end
  end

  # The part of the photo's height the crop kept, for a photo width / height = ratio
  def self.kept_height(ratio)
    ratio / CROP_RATIO
  end

  # A point on the crop (fractions of the crop) as fractions of the whole photo. The crop
  # kept the photo's full width and the middle of its height.
  def self.remap_point(point, ratio)
    kept = kept_height(ratio)
    point.merge("x" => point["x"].to_f, "y" => (0.5 - kept / 2 + point["y"].to_f * kept).round(4))
  end

  def self.remap_points(points, ratio)
    points&.map { |p| remap_point(p, ratio) }
  end

  def initialize(old, dry_run: false)
    @old = old
    @dry_run = dry_run
  end

  def call
    reason = skip_reason
    return result(:skipped, reason) if reason
    return result(:would_convert, "#{@old.lines.count} line(s) would move to the whole photo") if @dry_run

    new_topo = nil
    Topo.transaction do
      new_topo = Topo.create!(
        area_id: @old.area_id, published: false, uncropped: true, photo: @old.photo.blob,
        metadata: (@old.metadata || {}).except("replaces_topo_id", "replaced_by_topo_id")
      )
      new_topo.replace!(@old)
      @old.lines.each { |line| copy_line(line, new_topo) }
    end

    new_topo.reload
    return swap_photo_without_lines(new_topo) if new_topo.lines.none?

    unless new_topo.all_drawn?
      return result(:needs_drawing, "some lines weren't drawn on the old photo: finish them in the workbench, then swap", new_topo)
    end

    new_topo.swap_in! if @old.published
    result(:converted, "#{new_topo.lines.count} line(s) moved to the whole photo", new_topo)
  end

  private

  def skip_reason
    return "already uncropped" if @old.uncropped?
    return "it has no area (no lines and no area set when uploaded)" unless @old.area_id
    return "it has been replaced by another photo" if @old.replaced_by_topo
    return "it is itself replacing another photo" if @old.replaces_topo
    return "another photo is replacing it" if Topo.where("metadata->>'replaces_topo_id' = ?", @old.id.to_s).exists?
    "its photo isn't portrait" unless ratio && ratio < 1
  end

  # Nothing drawn on it yet, so nothing to wait for: the whole photo takes its place now, the
  # way swap_in! would (which needs a drawn line), so lines are drawn on the whole photo
  def swap_photo_without_lines(new_topo)
    was_published = @old.published
    Topo.transaction do
      @old.update!(published: false, metadata: (@old.metadata || {}).merge("replaced_by_topo_id" => new_topo.id))
      new_topo.update!(published: was_published)
    end
    result(:converted, "no lines yet: the whole photo is in its place", new_topo)
  end

  def ratio
    @ratio ||= begin
      @old.photo.analyze unless @old.photo.analyzed?
      width, height = @old.photo.metadata.values_at("width", "height").map(&:to_f)
      width / height if width.positive? && height.positive?
    end
  end

  def copy_line(line, new_topo)
    Line.create!(
      problem: line.problem, topo: new_topo,
      coordinates: on_whole_photo?(line.coordinates, :line_coordinates) ? line.coordinates : self.class.remap_points(line.coordinates, ratio),
      start_holds: on_whole_photo?(line.start_holds, :start_holds) ? line.start_holds : self.class.remap_points(line.start_holds, ratio),
      excluded_areas: on_whole_photo?(line.excluded_areas, :excluded_areas) ? line.excluded_areas : line.excluded_areas&.map { |area| self.class.remap_points(area, ratio) },
      reference_contribution: line.reference_contribution,
      reference_line: line.reference_line
    )
  end

  # Contributions sent with this very photo (the importer finds a photo's topo the same way)
  def contributions
    @contributions ||= Contribution.where(id: Contribution.joins(photos_attachments: :blob).
      where(active_storage_blobs: { checksum: @old.photo.blob.checksum }).select(:id)).to_a
  end

  # Whether points are exactly as a contributor sent them with this photo. A line's ends are
  # compared, as a two-click line gets a midpoint added when it's imported.
  def on_whole_photo?(points, field)
    return false if points.blank?

    contributions.any? do |contribution|
      sent = contribution.public_send(field)
      sent = JSON.parse(sent) if sent.is_a?(String)
      next false if sent.blank?

      field == :line_coordinates ? same_ends?(points, sent) : sent == points
    end
  end

  def same_ends?(a, b)
    a.size >= 2 && b.size >= 2 && a.first == b.first && a.last == b.last && (b.size == 2 || a.size == b.size)
  end

  def result(status, message, new_topo = nil)
    Result.new(old: @old, new_topo: new_topo, status: status, message: message)
  end
end
