# Optional start holds: [{ "x" => 0..1, "y" => 0..1 }, ...] in the same normalised
# image space as Line#coordinates. Shared by Line and the (anonymous) Contribution form.
class StartHoldsValidator < ActiveModel::EachValidator
  MAX_HOLDS = 4

  def self.valid_point?(point)
    point.is_a?(Hash) && %w[x y].all? { |k| point[k].is_a?(Numeric) && point[k].between?(0, 1) }
  end

  def validate_each(record, attribute, holds)
    return if holds.nil?

    unless holds.is_a?(Array) && holds.all? { |hold| self.class.valid_point?(hold) }
      return record.errors.add(attribute, "must be a list of points with x and y between 0 and 1")
    end

    if holds.length > MAX_HOLDS
      record.errors.add(attribute, "can have at most #{MAX_HOLDS} points")
    end
  end
end
