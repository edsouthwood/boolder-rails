class Contribution < ApplicationRecord
  include Geolocatable
  geolocatable :location

  has_many_attached :photos
  has_many_attached :line_drawings
  has_many_attached :location_drawings
  belongs_to :problem, optional: true
  # A photo already on the site that the contributor drew on, so their line fits it as drawn
  belongs_to :existing_topo, class_name: "Topo", optional: true
  # A photo already on the site that an admin chose to put this problem on, instead of making
  # a new topo from the contributor's photo. The line was drawn on a different image, so it
  # comes across undrawn, to be redrawn in the workbench (see ContributionImporter).
  belongs_to :merge_topo, class_name: "Topo", optional: true
  # Which crag an unlisted problem is at: an existing area, or `area_name` free text for one
  # that isn't on the site yet. Neither counts as content on its own.
  belongs_to :area, optional: true

  # Other unlisted submissions still waiting, near this one: likely the same new crag.
  def nearby_unlisted(within: 300)
    return Contribution.none if location.blank?

    Contribution.pending.where(problem_id: nil).where.not(id: id)
                .where("ST_DWithin(location, ST_GeogFromText(?), ?)", location.as_text, within)
                .order(:id)
  end

  # Other contributions from the same person at the same crag within a day of this one:
  # usually several problems on one face, each sent with its own photo, so worth reviewing
  # together and merging onto one photo. Needs a contributor name or email to go on.
  SIBLING_WINDOW = 1.day

  def siblings(state: "pending")
    key = contributor_key
    area = area_for_grouping
    return Contribution.none if key.blank? || area.nil?

    Contribution.where(state: state).where.not(id: id).
      left_joins(:problem).
      where("COALESCE(problems.area_id, contributions.area_id) = ?", area).
      where("#{CONTRIBUTOR_KEY_SQL} = ?", key).
      where(created_at: (created_at - SIBLING_WINDOW)..(created_at + SIBLING_WINDOW)).
      order(:id)
  end

  # How many pending siblings (see #siblings) each of these contributions has, in one query: { id => count }
  def self.sibling_counts(contributions)
    ids = contributions.map(&:id)
    return {} if ids.empty?

    sql = sanitize_sql_array([ <<~SQL, ids, SIBLING_WINDOW.to_i ])
      SELECT c.id, COUNT(o.id)
      FROM contributions c
      LEFT JOIN problems cp ON cp.id = c.problem_id
      JOIN contributions o ON o.id <> c.id AND o.state = 'pending'
      LEFT JOIN problems op ON op.id = o.problem_id
      WHERE c.id IN (?)
        AND #{contributor_key_sql('c')} <> ''
        AND #{contributor_key_sql('c')} = #{contributor_key_sql('o')}
        AND COALESCE(cp.area_id, c.area_id) = COALESCE(op.area_id, o.area_id)
        AND ABS(EXTRACT(EPOCH FROM (o.created_at - c.created_at))) <= ?
      GROUP BY c.id
    SQL
    connection.select_rows(sql).to_h { |id, count| [ id.to_i, count.to_i ] }
  end

  # The topo already on the site whose photo is this very file (same checksum), if any: the
  # contributor's line fits it exactly as drawn
  def same_photo_topo
    photo = photos.first
    return unless photo

    Topo.joins(photo_attachment: :blob).where(active_storage_blobs: { checksum: photo.blob.checksum }).order(:id).first
  end

  audited

  STATES = %w[pending accepted closed]
  MAX_ATTACHMENT_SIZE = 15.megabytes
  MAX_ATTACHMENTS_PER_KIND = 10
  # Across all kinds: caps how much disk a single anonymous submission can take.
  MAX_TOTAL_ATTACHMENT_SIZE = 60.megabytes
  scope :pending, -> { where(state: "pending") }
  scope :accepted, -> { where(state: "accepted") }
  scope :closed, -> { where(state: "closed") }

  validates :state, inclusion: { in: STATES }
  validates :area_name, length: { maximum: 200 }
  validates :contributor_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :must_have_some_content
  validate :existing_topo_in_problem_area
  validate :merge_topo_in_problem_area
  validate :attachments_are_reasonable_images
  validates :start_holds, start_holds: true
  validates :excluded_areas, excluded_areas: true

  # The contribution form posts these as JSON strings from hidden fields.
  JSON_DRAWING_ATTRIBUTES = %i[start_holds excluded_areas]
  before_validation :parse_json_drawings

  def accepted?
    state == "accepted"
  end

  def closed?
    state == "closed"
  end

  def pending?
    state == "pending"
  end

  # What was drawn on the photo, for admin labels: e.g. ["line", "2 start holds", "1 not-in area"]
  def drawing_parts
    parts = []
    parts << "line" if line_coordinates.present?
    parts << ActionController::Base.helpers.pluralize(start_holds.size, "start hold") if start_holds.present?
    parts << ActionController::Base.helpers.pluralize(excluded_areas.size, "not-in area") if excluded_areas.present?
    parts
  end

  # Accepted problem contributions and accepted boulder photos both count.
  def self.top_contributors(limit: 15)
    names = Arel::Nodes::UnionAll.new(
      accepted.where.not(contributor_name: [ nil, "" ]).select(:contributor_name).arel,
      PhotoContribution.accepted.where.not(contributor_name: [ nil, "" ]).select(:contributor_name).arel
    )
    unscoped
      .from(Arel::Nodes::TableAlias.new(Arel::Nodes::Grouping.new(names), "contributions"))
      .group("LOWER(TRIM(contributor_name))")
      .select("MIN(contributor_name) AS display_name, COUNT(*) AS contributions_count")
      .order(Arel.sql("contributions_count DESC, display_name ASC"))
      .limit(limit)
  end

  # Email if given, else name, lowercased: who sent it, as near as an anonymous form allows.
  # The table name is ours, never user input.
  def self.contributor_key_sql(table)
    "COALESCE(NULLIF(LOWER(TRIM(#{table}.contributor_email)), ''), LOWER(TRIM(COALESCE(#{table}.contributor_name, ''))))"
  end
  CONTRIBUTOR_KEY_SQL = contributor_key_sql("contributions")

  private

  def contributor_key
    (contributor_email.to_s.strip.presence || contributor_name.to_s.strip).downcase.presence
  end

  def area_for_grouping
    problem&.area_id || area_id
  end

  def parse_json_drawings
    JSON_DRAWING_ATTRIBUTES.each do |attribute|
      value = self[attribute]
      begin
        value = JSON.parse(value) if value.is_a?(String) && value.present?
      rescue JSON::ParserError
        errors.add(attribute, "must be valid JSON")
        throw :abort
      end
      self[attribute] = value.presence
    end
  end

  # Reject empty/spam submissions: a contribution must carry at least one piece of
  # useful information. `location` is set from lat/lon by Geolocatable's before_validation.
  def must_have_some_content
    has_content =
      photos.attached? ||
      location.present? ||
      comment.present? ||
      line_coordinates.present? ||
      start_holds.present? ||
      excluded_areas.present? ||
      problem_name.present?

    errors.add(:base, "A contribution must include a photo, location, line, comment or problem name") unless has_content
  end

  # Uploads come from anonymous visitors and are shown publicly with image_tag, so only
  # accept a bounded number of reasonably sized images.
  def attachments_are_reasonable_images
    { photos: photos, line_drawings: line_drawings, location_drawings: location_drawings }.each do |name, files|
      next unless files.attached?

      errors.add(name, "can't have more than #{MAX_ATTACHMENTS_PER_KIND} files") if files.size > MAX_ATTACHMENTS_PER_KIND
      errors.add(name, "must be images") unless files.all? { |file| file.content_type.to_s.start_with?("image/") }
      errors.add(name, "must each be under #{MAX_ATTACHMENT_SIZE / 1.megabyte} MB") if files.any? { |file| file.byte_size > MAX_ATTACHMENT_SIZE }
    end

    total = [ photos, line_drawings, location_drawings ].sum { |files| files.sum(&:byte_size) }
    errors.add(:base, "Uploads must total under #{MAX_TOTAL_ATTACHMENT_SIZE / 1.megabyte} MB") if total > MAX_TOTAL_ATTACHMENT_SIZE
  end

  def existing_topo_in_problem_area
    errors.add(:existing_topo_id, "must belong to the same area as the problem") unless topo_in_problem_area?(existing_topo)
  end

  # Also stops an area admin putting a problem on another area's photo
  def merge_topo_in_problem_area
    errors.add(:merge_topo_id, "must belong to the same area as the problem") unless topo_in_problem_area?(merge_topo)
  end

  def topo_in_problem_area?(topo)
    return true if topo.blank? || problem.blank?

    # reorder(nil) drops the ORDER BY inherited from Line's default scope,
    # which Postgres rejects in a SELECT DISTINCT on a different column
    topo_area_ids = (topo.problems.reorder(nil).distinct.pluck(:area_id) + [ topo[:area_id] ]).compact.uniq
    topo_area_ids.empty? || topo_area_ids.include?(problem.area_id)
  end
end
