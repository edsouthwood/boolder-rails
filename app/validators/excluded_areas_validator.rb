# Optional "not in" areas: parts of the boulder that are off-limits for a problem.
# A list of polygons, each [{ "x" => 0..1, "y" => 0..1 }, ...] in the same normalised
# image space as Line#coordinates. Shared by Line and the (anonymous) Contribution form.
class ExcludedAreasValidator < ActiveModel::EachValidator
  MAX_AREAS = 4
  MAX_POINTS_PER_AREA = 30

  def validate_each(record, attribute, areas)
    return if areas.nil?

    unless areas.is_a?(Array) && areas.all? { |area| valid_area?(area) }
      return record.errors.add(attribute, "must be a list of shapes, each with 3 to #{MAX_POINTS_PER_AREA} points with x and y between 0 and 1")
    end

    if areas.length > MAX_AREAS
      record.errors.add(attribute, "can have at most #{MAX_AREAS} areas")
    end
  end

  private

  def valid_area?(area)
    area.is_a?(Array) && area.length.between?(3, MAX_POINTS_PER_AREA) && area.all? { |point| StartHoldsValidator.valid_point?(point) }
  end
end
