# Shows a portrait photo whole that was stored before uncropped topos came in: its topo shows
# only the middle of the photo (the 4:3 crop), with lines drawn on that crop.
#
# The cropped topo is kept and a new, uncropped topo of the same photo (same file, nothing
# re-uploaded) replaces it, the way an admin replaces a photo with a better one: a new topo
# rather than a new picture on the old one, because /proxy/topos/:id is cached forever by id.
# Its lines are the old ones moved to where they sit on the whole photo, then it's swapped in,
# so undo on the old topo's page puts things back.
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
        area_id: @old[:area_id], published: false, uncropped: true, photo: @old.photo.blob,
        metadata: (@old.metadata || {}).except("replaces_topo_id", "replaced_by_topo_id")
      )
      new_topo.replace!(@old)
      @old.lines.each { |line| copy_line(line, new_topo) }
    end

    new_topo.reload
    unless new_topo.all_drawn?
      return result(:needs_drawing, "some lines weren't drawn on the old photo: finish them in the workbench, then swap", new_topo)
    end

    new_topo.swap_in! if @old.published
    result(:converted, "#{new_topo.lines.count} line(s) moved to the whole photo", new_topo)
  end

  private

  def skip_reason
    return "already uncropped" if @old.uncropped?
    return "it has been replaced by another photo" if @old.replaced_by_topo
    return "it is itself replacing another photo" if @old.replaces_topo
    return "another photo is replacing it" if Topo.where("metadata->>'replaces_topo_id' = ?", @old.id.to_s).exists?
    "its photo isn't portrait" unless ratio && ratio < 1
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
      coordinates: self.class.remap_points(line.coordinates, ratio),
      start_holds: self.class.remap_points(line.start_holds, ratio),
      excluded_areas: line.excluded_areas&.map { |area| self.class.remap_points(area, ratio) },
      reference_contribution: line.reference_contribution,
      reference_line: line.reference_line
    )
  end

  def result(status, message, new_topo = nil)
    Result.new(old: @old, new_topo: new_topo, status: status, message: message)
  end
end
