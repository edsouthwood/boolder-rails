class Line < ApplicationRecord
  belongs_to :problem, touch: true
  belongs_to :topo
  accepts_nested_attributes_for :topo

  audited

  after_save -> { problem.update_has_line }
  after_destroy -> { problem.update_has_line }

  MAX_START_HOLDS = 4

  validate :validate_line_length
  validate :validate_start_holds

  before_validation -> { self.start_holds = nil if start_holds.blank? }

  scope :published, -> { joins(:topo).where(topos: { published: true }) }
  scope :unpublished, -> { joins(:topo).where(topos: { published: false }) }
  scope :with_coordinates, -> { where.not(coordinates: nil) }
  default_scope { order(created_at: :asc) } # TODO: use a dedicated order column for multi-topos problems (e.g. traverses)

  def secondary_lines
    (topo.lines.reject { |l| l.problem.parent_id.present? } - [ self ]).
      select { |l| l.problem.lines.published.first&.topo_id == self.topo_id } # TODO: simplify once we handle ordering of multiple lines
  end

  private

  def validate_line_length
    if coordinates && coordinates.length < 3
      errors.add(:coordinates, "must have at least 3 points")
    end
  end

  # start_holds: optional [{ "x" => 0..1, "y" => 0..1 }, ...] in the same normalised space as coordinates
  def validate_start_holds
    return if start_holds.nil?

    unless start_holds.is_a?(Array) && start_holds.all? { |h| valid_hold?(h) }
      return errors.add(:start_holds, "must be a list of points with x and y between 0 and 1")
    end

    if start_holds.length > MAX_START_HOLDS
      errors.add(:start_holds, "can have at most #{MAX_START_HOLDS} points")
    end
  end

  def valid_hold?(hold)
    hold.is_a?(Hash) && %w[x y].all? { |k| hold[k].is_a?(Numeric) && hold[k].between?(0, 1) }
  end
end
